// Row-streaming PNG decoder for native-detail tiles.
//
// Why this exists at all: ImageIO has no region decode. Measured on a 12000×9000 PNG,
// drawing a 512×512 corner costs 375 ms and a 0.43 GiB peak against a 403 ms / 0.44 GiB
// full decode — the same work either way — and on the 1.9 GiB investigation image the
// lazy path allocates a 5.86 GiB single region. So the only way to put *native* pixels
// on screen for a region of a huge PNG, without ever materializing the whole bitmap, is
// to inflate the stream ourselves, keep the rows a caller asked for, and throw the rest
// away.
//
// The decoder is deliberately narrow: 8-bit truecolour / truecolour+alpha / greyscale /
// greyscale+alpha / palette (with sub-byte depths 1/2/4 for grey and palette), no
// interlace. Anything else is refused by name so the caller can fall back to the bounded
// proxy instead of guessing. That is a product decision, not a shortcut: an interlaced or
// 16-bit source keeps the proxy path, which preserves depth correctly.
//
// Memory is bounded by construction: one input window (1 MiB), zlib's own window, two
// scanline buffers, and the caller's region buffer. Nothing scales with image size.

#ifndef PIC_PNG_STREAM_H
#define PIC_PNG_STREAM_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct ps_decoder ps_decoder;

typedef struct {
    int32_t width;
    int32_t height;
    int32_t bit_depth;
    int32_t color_type;   /* 0 grey, 2 rgb, 3 palette, 4 grey+alpha, 6 rgba */
    int32_t interlaced;
    size_t row_bytes;     /* bytes of one filtered scanline, excluding the filter byte */
} ps_info;

typedef struct {
    int32_t x;
    int32_t y;
    int32_t width;
    int32_t height;
} ps_rect;

/// Opens the file, parses up to and including the first IDAT header, and reports the
/// image shape. Returns NULL with `err` filled on an unsupported or malformed file.
ps_decoder *ps_open(const char *path, ps_info *info, char *err, size_t err_len);

/// Region of the source to retain, in pixels. Must be set before the first `ps_step`
/// that reaches those rows; rows outside it are inflated and discarded. Returns 0 on a
/// bad rectangle.
int ps_set_region(ps_decoder *decoder, ps_rect region);

/// Decodes the next scanline (inflate + unfilter + expand into the region buffer).
/// Returns 1 while there is more work, 0 at end of image, -1 on error. One call is
/// microseconds to a fraction of a millisecond, which is the cancellation granularity:
/// a caller that stops calling it stops the decode immediately — unlike ImageIO, whose
/// decode ignores Task.cancel().
int ps_step(ps_decoder *decoder, char *err, size_t err_len);

/// How many source rows have been decoded so far (for progress and cancellation tests).
int32_t ps_rows_done(const ps_decoder *decoder);

/// RGBA8 pixels of the retained region, tightly packed, width*height*4 bytes, with RGB
/// premultiplied by alpha — the same layout the viewer uploads for the bounded proxy
/// (CGContext's premultipliedLast) and what a source-over blend expects. Rows are filled
/// as the decode passes them; the buffer is fully valid once `ps_rows_done` reaches
/// region.y + region.height.
const uint8_t *ps_region_pixels(const ps_decoder *decoder);

/// Bytes of the region buffer, so callers can hold the tile cache to a real cost.
size_t ps_region_bytes(const ps_decoder *decoder);

void ps_close(ps_decoder *decoder);

/// Last error text, for a caller that kept the decoder around.
const char *ps_last_error(const ps_decoder *decoder);

#ifdef __cplusplus
}
#endif

#endif /* PIC_PNG_STREAM_H */
