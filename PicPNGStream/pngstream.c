#include "PicPNGStream.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <zlib.h>

#define PS_INPUT_WINDOW (1u << 20)

struct ps_decoder {
    FILE *file;
    z_stream zstream;
    int zstream_live;

    ps_info info;
    ps_rect region;

    uint8_t *input;          /* PS_INPUT_WINDOW */
    size_t input_filled;
    size_t input_consumed;
    /* PNG's zlib stream is the concatenation of every IDAT payload, with chunk framing
     * (length/type/CRC) between them, so the reader has to walk chunks while inflating
     * rather than treat the file as one stream. */
    uint32_t chunk_remaining;   /* bytes left in the current IDAT payload */
    int stream_ended;

    uint8_t *previous_row;   /* unfiltered, source layout */
    uint8_t *current_row;    /* unfiltered, source layout */
    size_t row_bytes;        /* source bytes per row (no filter byte) */

    uint8_t palette[256][3];
    int palette_entries;
    uint8_t palette_alpha[256];
    int palette_alpha_entries;

    uint8_t *region_pixels;
    int32_t rows_done;

    int saw_iend;
    int finished;
    char error[256];
};

static void ps_error(ps_decoder *decoder, const char *message) {
    if (decoder && decoder->error[0] == 0) {
        snprintf(decoder->error, sizeof(decoder->error), "%s", message);
    }
}

static uint32_t read_be32(const uint8_t *bytes) {
    return ((uint32_t)bytes[0] << 24) | ((uint32_t)bytes[1] << 16)
         | ((uint32_t)bytes[2] << 8) | (uint32_t)bytes[3];
}

static int channels_for_color_type(int color_type) {
    switch (color_type) {
        case 0: return 1;   /* grey */
        case 2: return 3;   /* rgb */
        case 3: return 1;   /* palette index */
        case 4: return 2;   /* grey + alpha */
        case 6: return 4;   /* rgba */
        default: return 0;
    }
}

/* 1/2/4-bit grey and palette are legal; everything else in this decoder is 8-bit. */
static int supported(const ps_info *info) {
    if (info->interlaced) return 0;
    if (info->color_type == 0 || info->color_type == 3) {
        return info->bit_depth == 1 || info->bit_depth == 2
            || info->bit_depth == 4 || info->bit_depth == 8;
    }
    if (info->color_type == 2 || info->color_type == 4 || info->color_type == 6) {
        return info->bit_depth == 8;
    }
    return 0;
}

ps_decoder *ps_open(const char *path, ps_info *info, char *err, size_t err_len) {
    if (!path || !info) return NULL;
    FILE *file = fopen(path, "rb");
    if (!file) {
        if (err) snprintf(err, err_len, "cannot open file");
        return NULL;
    }
    uint8_t signature[8];
    if (fread(signature, 1, 8, file) != 8
        || memcmp(signature, "\x89PNG\r\n\x1a\n", 8) != 0) {
        fclose(file);
        if (err) snprintf(err, err_len, "not a PNG file");
        return NULL;
    }

    ps_decoder *decoder = calloc(1, sizeof(ps_decoder));
    if (!decoder) {
        fclose(file);
        if (err) snprintf(err, err_len, "out of memory");
        return NULL;
    }
    decoder->file = file;
    memset(info, 0, sizeof(*info));

    /* Walk the chunk headers until the first IDAT. Everything needed before decoding —
     * image shape, palette, transparency — appears there; the pixel data is inflated
     * later, row by row, by ps_step. The IDAT payload itself is never buffered: only its
     * header is consumed, so a 2 GiB image costs one 1 MiB input window. */
    uint8_t header[8];
    while (fread(header, 1, 8, file) == 8) {
        uint32_t length = read_be32(header);
        const uint8_t *type = header + 4;

        if (memcmp(type, "IDAT", 4) == 0) {
            if (decoder->row_bytes == 0) {
                ps_error(decoder, "IDAT before IHDR");
                goto fail;
            }
            decoder->chunk_remaining = length;
            break;                      /* payload is read on demand by refill_input */
        }
        if (memcmp(type, "IEND", 4) == 0) {
            ps_error(decoder, "no image data");
            goto fail;
        }

        /* Ancillary or header chunk: read it, unless it is unreasonably large, in which
         * case skip it — nothing this decoder needs is bigger than a palette. */
        const int needed = memcmp(type, "IHDR", 4) == 0 || memcmp(type, "PLTE", 4) == 0
                        || memcmp(type, "tRNS", 4) == 0;
        uint8_t *payload = NULL;
        if (needed) {
            if (length > (1u << 20)) { ps_error(decoder, "oversized header chunk"); goto fail; }
            payload = length ? malloc(length) : NULL;
            if (length && (!payload || fread(payload, 1, length, file) != length)) {
                free(payload);
                ps_error(decoder, "truncated chunk");
                goto fail;
            }
        } else if (fseek(file, (long)length, SEEK_CUR) != 0) {
            ps_error(decoder, "truncated chunk");
            goto fail;
        }
        if (fseek(file, 4, SEEK_CUR) != 0) {   /* skip CRC: the proxy decode already
                                                  validated the file's integrity */
            free(payload);
            ps_error(decoder, "truncated chunk");
            goto fail;
        }

        if (memcmp(type, "IHDR", 4) == 0 && length >= 13) {
            decoder->info.width = (int32_t)read_be32(payload);
            decoder->info.height = (int32_t)read_be32(payload + 4);
            decoder->info.bit_depth = payload[8];
            decoder->info.color_type = payload[9];
            decoder->info.interlaced = payload[12];
            if (decoder->info.width <= 0 || decoder->info.height <= 0) {
                free(payload);
                ps_error(decoder, "invalid dimensions");
                goto fail;
            }
            if (decoder->info.interlaced) {
                free(payload);
                ps_error(decoder, "interlaced PNG is not served by the tile decoder");
                goto fail;
            }
            if (!supported(&decoder->info)) {
                free(payload);
                snprintf(decoder->error, sizeof(decoder->error),
                         "unsupported PNG: bit depth %d, color type %d",
                         decoder->info.bit_depth, decoder->info.color_type);
                goto fail;
            }
            int channels = channels_for_color_type(decoder->info.color_type);
            size_t bits = (size_t)decoder->info.width * channels * decoder->info.bit_depth;
            decoder->row_bytes = (bits + 7) / 8;
            decoder->info.row_bytes = decoder->row_bytes;
        } else if (memcmp(type, "PLTE", 4) == 0) {
            int entries = (int)(length / 3);
            if (entries > 256) entries = 256;
            for (int i = 0; i < entries; i++) {
                decoder->palette[i][0] = payload[i * 3 + 0];
                decoder->palette[i][1] = payload[i * 3 + 1];
                decoder->palette[i][2] = payload[i * 3 + 2];
            }
            decoder->palette_entries = entries;
        } else if (memcmp(type, "tRNS", 4) == 0) {
            int entries = (int)length;
            if (entries > 256) entries = 256;
            for (int i = 0; i < entries; i++) decoder->palette_alpha[i] = payload[i];
            decoder->palette_alpha_entries = entries;
        }
        free(payload);
    }

    if (decoder->row_bytes == 0) {
        ps_error(decoder, "no IDAT found");
        goto fail;
    }
    decoder->input = malloc(PS_INPUT_WINDOW);
    if (!decoder->input) {
        ps_error(decoder, "out of memory");
        goto fail;
    }
    /* One byte more than the scanline: PNG prefixes every row with its filter type, and
     * zlib writes that byte too. Allocating exactly `row_bytes` let zlib's back-reference
     * reads run one byte past the buffer, which AddressSanitizer reported as a
     * heap-buffer-overflow (READ of size 6 after a 5-byte region). */
    decoder->previous_row = calloc(1, decoder->row_bytes + 1);
    decoder->current_row = calloc(1, decoder->row_bytes + 1);
    if (!decoder->previous_row || !decoder->current_row) {
        ps_error(decoder, "out of memory");
        goto fail;
    }
    if (inflateInit(&decoder->zstream) != Z_OK) {
        ps_error(decoder, "zlib init failed");
        goto fail;
    }
    decoder->zstream_live = 1;
    if (!decoder->palette_alpha_entries) {
        memset(decoder->palette_alpha, 255, sizeof(decoder->palette_alpha));
    }
    *info = decoder->info;
    return decoder;

fail: {
    char message[256];
    snprintf(message, sizeof(message), "%s", decoder->error[0] ? decoder->error : "failed");
    ps_close(decoder);
    if (err) snprintf(err, err_len, "%s", message);
    return NULL;
}
}

int ps_set_region(ps_decoder *decoder, ps_rect region) {
    if (!decoder) return 0;
    if (region.width <= 0 || region.height <= 0) return 0;
    if (region.x < 0 || region.y < 0) return 0;
    if (region.x + region.width > decoder->info.width) return 0;
    if (region.y + region.height > decoder->info.height) return 0;
    free(decoder->region_pixels);
    decoder->region_pixels = calloc((size_t)region.width * region.height, 4);
    if (!decoder->region_pixels) {
        ps_error(decoder, "out of memory");
        return 0;
    }
    decoder->region = region;
    return 1;
}

/// Refills the input window from the concatenated IDAT payloads, skipping the framing
/// (CRC, headers, and any non-IDAT chunk) between them. Returns 0 at end of stream.
static int refill_input(ps_decoder *decoder) {
    if (decoder->input_consumed < decoder->input_filled) return 1;
    decoder->input_filled = 0;
    decoder->input_consumed = 0;

    while (1) {
        if (decoder->chunk_remaining == 0) {
            if (decoder->stream_ended) return 0;
            if (fseek(decoder->file, 4, SEEK_CUR) != 0) {   /* CRC of the chunk just read */
                return 0;
            }
            uint8_t header[8];
            if (fread(header, 1, 8, decoder->file) != 8) {
                decoder->stream_ended = 1;
                return 0;
            }
            uint32_t length = read_be32(header);
            if (memcmp(header + 4, "IDAT", 4) != 0) {
                /* A non-IDAT chunk after the image data means the zlib stream is over. */
                decoder->stream_ended = 1;
                return 0;
            }
            decoder->chunk_remaining = length;
            if (length == 0) continue;
        }
        size_t room = PS_INPUT_WINDOW;
        size_t want = decoder->chunk_remaining < room ? decoder->chunk_remaining : room;
        size_t read = fread(decoder->input, 1, want, decoder->file);
        if (read == 0) {
            decoder->stream_ended = 1;
            return 0;
        }
        decoder->chunk_remaining -= (uint32_t)read;
        decoder->input_filled = read;
        return 1;
    }
}

/// Multiplies RGB by alpha, the layout the renderer uploads for the proxy as well
/// (CGContext's premultipliedLast) and what a source-over blend expects. Straight-alpha
/// bytes would composite semi-transparent pixels too brightly.
static inline uint8_t premultiply(uint8_t value, uint8_t alpha) {
    if (alpha == 255) return value;
    return (uint8_t)(((unsigned)value * alpha + 127) / 255);
}

static void expand_row(ps_decoder *decoder) {
    const ps_info *info = &decoder->info;
    /* +1 skips the filter byte: the unfiltered pixel data starts after it. Reading from
     * the filter byte shifts every pixel by one byte, which the ImageIO comparison caught. */
    const uint8_t *row = decoder->current_row + 1;
    int32_t y = decoder->rows_done;
    if (!decoder->region_pixels) return;
    if (y < decoder->region.y || y >= decoder->region.y + decoder->region.height) return;

    uint8_t *out = decoder->region_pixels
                 + (size_t)(y - decoder->region.y) * decoder->region.width * 4;
    int32_t x0 = decoder->region.x;
    int32_t x1 = decoder->region.x + decoder->region.width;

    switch (info->color_type) {
        case 6: { /* rgba */
            const uint8_t *source = row + (size_t)x0 * 4;
            for (int32_t x = x0; x < x1; x++) {
                uint8_t alpha = source[3];
                out[0] = premultiply(source[0], alpha);
                out[1] = premultiply(source[1], alpha);
                out[2] = premultiply(source[2], alpha);
                out[3] = alpha;
                source += 4;
                out += 4;
            }
            break;
        }
        case 2: /* rgb */
            for (int32_t x = x0; x < x1; x++) {
                out[0] = row[x * 3 + 0]; out[1] = row[x * 3 + 1];
                out[2] = row[x * 3 + 2]; out[3] = 255;
                out += 4;
            }
            break;
        case 4: { /* grey + alpha */
            for (int32_t x = x0; x < x1; x++) {
                uint8_t alpha = row[x * 2 + 1];
                uint8_t v = premultiply(row[x * 2], alpha);
                out[0] = v; out[1] = v; out[2] = v; out[3] = alpha;
                out += 4;
            }
            break;
        }
        case 0: { /* grey, possibly sub-byte */
            int depth = info->bit_depth;
            int max = (1 << depth) - 1;
            for (int32_t x = x0; x < x1; x++) {
                int value;
                if (depth == 8) {
                    value = row[x];
                } else {
                    int per_byte = 8 / depth;
                    int shift = 8 - depth * ((x % per_byte) + 1);
                    value = (row[x / per_byte] >> shift) & max;
                }
                uint8_t v = (uint8_t)(value * 255 / max);
                out[0] = v; out[1] = v; out[2] = v; out[3] = 255;
                out += 4;
            }
            break;
        }
        case 3: { /* palette */
            int depth = info->bit_depth;
            for (int32_t x = x0; x < x1; x++) {
                int index;
                if (depth == 8) {
                    index = row[x];
                } else {
                    int per_byte = 8 / depth;
                    int shift = 8 - depth * ((x % per_byte) + 1);
                    index = (row[x / per_byte] >> shift) & ((1 << depth) - 1);
                }
                if (index >= decoder->palette_entries) index = 0;
                uint8_t alpha = decoder->palette_alpha[index];
                out[0] = premultiply(decoder->palette[index][0], alpha);
                out[1] = premultiply(decoder->palette[index][1], alpha);
                out[2] = premultiply(decoder->palette[index][2], alpha);
                out[3] = alpha;
                out += 4;
            }
            break;
        }
        default:
            break;
    }
}

static void unfilter_row(ps_decoder *decoder) {
    const ps_info *info = &decoder->info;
    int channels = channels_for_color_type(info->color_type);
    size_t bpp = (size_t)((channels * info->bit_depth + 7) / 8);
    if (bpp == 0) bpp = 1;
    uint8_t filter = decoder->current_row[0];
    uint8_t *row = decoder->current_row + 1;
    const uint8_t *previous = decoder->previous_row + 1;
    size_t n = decoder->row_bytes;

    switch (filter) {
        case 0:
            break;
        case 1:
            for (size_t i = bpp; i < n; i++) row[i] = (uint8_t)(row[i] + row[i - bpp]);
            break;
        case 2:
            for (size_t i = 0; i < n; i++) row[i] = (uint8_t)(row[i] + previous[i]);
            break;
        case 3: {
            for (size_t i = 0; i < n; i++) {
                unsigned left = i >= bpp ? row[i - bpp] : 0;
                row[i] = (uint8_t)(row[i] + ((left + previous[i]) >> 1));
            }
            break;
        }
        case 4: {
            for (size_t i = 0; i < n; i++) {
                int a = i >= bpp ? row[i - bpp] : 0;
                int b = previous[i];
                int c = i >= bpp ? previous[i - bpp] : 0;
                int p = a + b - c;
                int pa = p > a ? p - a : a - p;
                int pb = p > b ? p - b : b - p;
                int pc = p > c ? p - c : c - p;
                int pred = (pa <= pb && pa <= pc) ? a : (pb <= pc ? b : c);
                row[i] = (uint8_t)(row[i] + pred);
            }
            break;
        }
        default:
            ps_error(decoder, "unknown PNG filter type");
            break;
    }
}

int ps_step(ps_decoder *decoder, char *err, size_t err_len) {
    if (!decoder) return -1;
    if (decoder->finished) return 0;
    if (decoder->error[0]) {
        if (err) snprintf(err, err_len, "%s", decoder->error);
        return -1;
    }
    if (decoder->rows_done >= decoder->info.height) {
        decoder->finished = 1;
        return 0;
    }

    size_t stride = decoder->row_bytes + 1;   /* filter byte + data */
    size_t produced = 0;
    while (produced < stride) {
        if (decoder->zstream.avail_in == 0) {
            if (!refill_input(decoder)) {
                ps_error(decoder, "truncated image data");
                if (err) snprintf(err, err_len, "%s", decoder->error);
                return -1;
            }
            decoder->zstream.next_in = decoder->input + decoder->input_consumed;
            decoder->zstream.avail_in = (uInt)(decoder->input_filled - decoder->input_consumed);
        }
        uint8_t *target = decoder->current_row + produced;
        size_t room = stride - produced;
        decoder->zstream.next_out = target;
        decoder->zstream.avail_out = (uInt)room;
        int status = inflate(&decoder->zstream, Z_NO_FLUSH);
        size_t written = room - decoder->zstream.avail_out;
        produced += written;
        decoder->input_consumed = decoder->input_filled - decoder->zstream.avail_in;
        if (status == Z_STREAM_END) {
            break;    /* last row may be the final output of the stream */
        }
        if (status != Z_OK && status != Z_BUF_ERROR) {
            snprintf(decoder->error, sizeof(decoder->error), "zlib error %d", status);
            if (err) snprintf(err, err_len, "%s", decoder->error);
            return -1;
        }
        if (status == Z_BUF_ERROR && written == 0 && decoder->zstream.avail_in == 0) {
            continue;   /* need more input; the refill above will supply it */
        }
    }

    if (produced < stride) {
        decoder->finished = 1;
        return 0;
    }

    unfilter_row(decoder);
    if (decoder->error[0]) {
        if (err) snprintf(err, err_len, "%s", decoder->error);
        return -1;
    }
    expand_row(decoder);

    /* Swap scanline buffers: the row just unfiltered becomes "previous". */
    uint8_t *swap = decoder->previous_row;
    decoder->previous_row = decoder->current_row;
    decoder->current_row = swap;
    decoder->rows_done += 1;

    if (decoder->rows_done >= decoder->info.height) {
        decoder->finished = 1;
        return 0;
    }
    return 1;
}

int32_t ps_rows_done(const ps_decoder *decoder) {
    return decoder ? decoder->rows_done : 0;
}

const uint8_t *ps_region_pixels(const ps_decoder *decoder) {
    return decoder ? decoder->region_pixels : NULL;
}

size_t ps_region_bytes(const ps_decoder *decoder) {
    if (!decoder || !decoder->region_pixels) return 0;
    return (size_t)decoder->region.width * decoder->region.height * 4;
}

const char *ps_last_error(const ps_decoder *decoder) {
    if (!decoder) return "no decoder";
    return decoder->error;
}

void ps_close(ps_decoder *decoder) {
    if (!decoder) return;
    if (decoder->zstream_live) inflateEnd(&decoder->zstream);
    if (decoder->file) fclose(decoder->file);
    free(decoder->input);
    free(decoder->previous_row);
    free(decoder->current_row);
    free(decoder->region_pixels);
    free(decoder);
}
