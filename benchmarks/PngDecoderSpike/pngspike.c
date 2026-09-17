// Alternative PNG decoder spike (Task 11 of the large-image plan).
//
// libspng, progressive (row-by-row) decode with row-wise box downsampling, which is
// the structural shape the plan asks about: memory stays at one source row plus the
// destination level, cancellation points exist every row, and no full-size bitmap is
// ever allocated. Report only; nothing here is linked into the app.
//
// Usage: pngspike <file.png> <targetMaxPixelSize> [checkpoints] [nocrc]

#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <time.h>
#include <sys/resource.h>

#include "spng.h"

static uint64_t now_ns(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC_RAW, &ts);
    return (uint64_t)ts.tv_sec * 1000000000ull + (uint64_t)ts.tv_nsec;
}

static double ms_since(uint64_t t0) { return (double)(now_ns() - t0) / 1e6; }

/// ru_maxrss is bytes on macOS; this is the same quantity the app's harness reports.
static double peak_rss_gib(void) {
    struct rusage usage;
    getrusage(RUSAGE_SELF, &usage);
    return (double)usage.ru_maxrss / 1073741824.0;
}

static uint64_t fnv1a(const uint8_t *bytes, size_t count) {
    uint64_t hash = 1469598103934665603ull;
    for (size_t i = 0; i < count; i++) { hash ^= bytes[i]; hash *= 1099511628211ull; }
    return hash;
}

int main(int argc, char **argv) {
    if (argc < 3) {
        fprintf(stderr, "usage: pngspike <file.png> <targetMaxPixelSize> [checkpoints]\n");
        return 2;
    }
    const char *path = argv[1];
    long target = atol(argv[2]);
    int checkpoints = argc > 3 ? atoi(argv[3]) : 10;
    if (target <= 0) { fprintf(stderr, "bad target\n"); return 2; }

    uint64_t start = now_ns();
    FILE *file = fopen(path, "rb");
    if (!file) { perror("fopen"); return 1; }

    spng_ctx *ctx = spng_ctx_new(0);
    spng_set_image_limits(ctx, 200000, 200000);
    // "nocrc" skips chunk verification so the spike can say how much of the gap to
    // ImageIO is integrity checking rather than inflate.
    int skip_crc = argc > 4 && strcmp(argv[4], "nocrc") == 0;
    spng_set_crc_action(ctx, skip_crc ? SPNG_CRC_DISCARD : SPNG_CRC_USE,
                        skip_crc ? SPNG_CRC_DISCARD : SPNG_CRC_USE);
    spng_set_png_file(ctx, file);

    struct spng_ihdr ihdr;
    int error = spng_get_ihdr(ctx, &ihdr);
    if (error) { fprintf(stderr, "ihdr: %s\n", spng_strerror(error)); return 1; }

    error = spng_decode_image(ctx, NULL, 0, SPNG_FMT_RGBA8, SPNG_DECODE_PROGRESSIVE);
    if (error) { fprintf(stderr, "progressive init: %s\n", spng_strerror(error)); return 1; }

    // 0.7.x has no spng_get_rowbytes; SPNG_FMT_RGBA8 is 4 bytes per pixel at every
    // source depth, and the whole-image size is used to cross-check that.
    size_t row_size = (size_t)ihdr.width * 4;
    size_t full_size = 0;
    spng_decoded_image_size(ctx, SPNG_FMT_RGBA8, &full_size);
    if (full_size != row_size * (size_t)ihdr.height) {
        fprintf(stderr, "unexpected full size %zu for %zu x %u\n", full_size, row_size, ihdr.height);
        return 1;
    }

    size_t step = (size_t)((double)ihdr.width / (double)target);
    if (step < 1) step = 1;
    size_t out_width = (ihdr.width + step - 1) / step;
    size_t out_height = (ihdr.height + step - 1) / step;

    uint8_t *row = malloc(row_size);
    uint64_t *sums = calloc(out_width * 4, sizeof(uint64_t));
    uint64_t *counts = calloc(out_width, sizeof(uint64_t));
    uint8_t *out = malloc(out_width * out_height * 4);
    if (!row || !sums || !counts || !out) { fprintf(stderr, "out of memory\n"); return 1; }

    printf("pngspike: %s\n", path);
    printf("  libspng %s | %ux%u %u-bit type %u | row_bytes %zu\n",
           spng_version_string(), ihdr.width, ihdr.height, ihdr.bit_depth,
           ihdr.color_type, row_size);
    printf("  target %ld -> step %zu -> %zux%zu level (%.1f MiB)\n",
           target, step, out_width, out_height,
           (double)(out_width * out_height * 4) / 1048576.0);

    size_t out_y = 0;
    size_t band_rows = 0;
    double first_row_ms = -1;
    int next_checkpoint = 1;

    for (uint32_t y = 0; y < ihdr.height; y++) {
        error = spng_decode_row(ctx, row, row_size);
        // The final row reports SPNG_EOI, which is the normal end of the stream.
        if (error && error != SPNG_EOI) {
            fprintf(stderr, "row %u: %s\n", y, spng_strerror(error));
            return 1;
        }
        if (y == 0) first_row_ms = ms_since(start);

        for (size_t x = 0; x < out_width; x++) {
            size_t x0 = x * step;
            size_t x1 = x0 + step;
            if (x1 > ihdr.width) x1 = ihdr.width;
            uint64_t r = 0, g = 0, b = 0, a = 0;
            for (size_t xi = x0; xi < x1; xi++) {
                const uint8_t *p = row + xi * 4;
                r += p[0]; g += p[1]; b += p[2]; a += p[3];
            }
            sums[x * 4 + 0] += r;
            sums[x * 4 + 1] += g;
            sums[x * 4 + 2] += b;
            sums[x * 4 + 3] += a;
            counts[x] += (x1 - x0);
        }
        band_rows++;

        int last_row = (y + 1 == ihdr.height);
        if (band_rows == step || last_row) {
            for (size_t x = 0; x < out_width; x++) {
                uint64_t n = counts[x];
                for (int c = 0; c < 4; c++) {
                    out[(out_y * out_width + x) * 4 + c] = (uint8_t)(sums[x * 4 + c] / n);
                }
            }
            out_y++;
            memset(sums, 0, out_width * 4 * sizeof(uint64_t));
            memset(counts, 0, out_width * sizeof(uint64_t));
            band_rows = 0;
        }

        while (next_checkpoint <= checkpoints
               && (double)(y + 1) >= (double)ihdr.height * (double)next_checkpoint / (double)checkpoints) {
            printf("  %3d%% rows  %8.0f ms   peak RSS %.2f GiB\n",
                   next_checkpoint * 100 / checkpoints, ms_since(start), peak_rss_gib());
            next_checkpoint++;
        }
    }

    double total_ms = ms_since(start);
    int finish = spng_decode_image(ctx, NULL, 0, SPNG_FMT_RGBA8, SPNG_DECODE_PROGRESSIVE);
    if (finish && finish != SPNG_EOI) {
        fprintf(stderr, "finish: %s\n", spng_strerror(finish));
    }

    uint64_t hash = fnv1a(out, out_width * out_height * 4);
    printf("  total %.0f ms | first row at %.0f ms | peak RSS %.2f GiB | rows/s %.0f\n",
           total_ms, first_row_ms, peak_rss_gib(), (double)ihdr.height / (total_ms / 1000.0));
    printf("  output checksum %016llx\n", (unsigned long long)hash);

    spng_ctx_free(ctx);
    free(row); free(sums); free(counts); free(out);
    fclose(file);
    return 0;
}
