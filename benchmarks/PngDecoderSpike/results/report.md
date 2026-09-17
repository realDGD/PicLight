# Task 11 — alternative PNG decoder spike (report only, not integrated)

Target: `~/Downloads/万萝图/万萝图.png`, 1.929 GiB, 48000×32000, 8-bit RGBA (PNG type 6).
Machine: Apple M4, macOS 27.0. Raw output: `pngspike-run.txt`. Run 2026-09-18.

Tools (all outside the package; `build.sh` clones and builds them under `.work/`):

- `pngspike.c` — libspng 0.7.4 progressive decode (`spng_decode_row`) with row-wise box
  downsampling. The destination level is the only large allocation; a source row is 192 000
  bytes. Also used to link zlib-ng instead of the system zlib.
- `control.swift` — the production shape: `CGImageSourceCreateThumbnailAtIndex` with
  from-image-always / with-transform / cache-immediately at the same pixel budget, run twice so
  the second pass is page-cache-warm. Measured minutes apart from the libspng runs.

Levels: step 23 → 2087×1392 for the 2048 class, step 5 → 9600×6400 for the 8192 class.

## Results

| Decoder | 2048 level | 8192 level | Peak memory | Notes |
| --- | --- | --- | --- | --- |
| ImageIO (production shape, page-cache warm) | 15 706 / 15 808 ms | ≈16–18 s (Task 8; includes materialization) | sampled footprint 0.09–0.10 GiB | 10.7 MiB bitmap at 2048 |
| **libspng 0.7.4 + Apple system zlib** | **12 520 / 12 645 ms** | **13 079 ms** | maxrss 0.01 GiB / 0.23 GiB | output is the only large buffer |
| libspng 0.7.4 + zlib-ng 2.2.4 (NEON, zlib-compat) | 15 174 / 15 268 ms | 15 844 ms | 0.01 GiB / 0.23 GiB | NEON objects confirmed in `libz.a` (`chunkset_neon.o`, `slide_hash_neon.o`, `adler32_neon.o`) |
| libspng, CRC verification skipped | 12 997 ms | — | 0.01 GiB | no measurable cost in verification |

Best candidate: **libspng + the system zlib, 20.4 % faster and 3.2 s better than ImageIO**
(12.58 s vs 15.76 s mean), reproducible to within 1 % across passes, output byte-identical across
backends and runs (`e77497d867789df3` / `a3ac0a3bf83480aa`).

## Structural properties the spike confirms

- **Memory**: the level being built is the only large allocation — 0.01 GiB at 2048 versus
  ImageIO's 0.10 GiB footprint for the same output, 0.23 GiB at 8192 (which *is* the 234 MiB
  destination). No 5.86 GiB image region, no second full-size bitmap.
- **Cancellation**: the first row is available at ~1 ms and progress is linear — 10 % of rows at
  ≈1.3 s, i.e. a checkpoint every ~0.13 s of work. ImageIO ignores `Task.cancel()` entirely
  (measured earlier: 19.4 s and 62.8 J still consumed after cancellation).
- **Row-wise downsampling is free**: the box filter and the accumulation buffers cost nothing
  measurable next to inflate (the two libspng levels differ by 0.5 s for 21× more output pixels,
  which is output writing, not filtering).

## Verdict: negative — do not integrate

The plan's bar is "≥30 % wall time or ≥5 s absolute improvement, repeatable, without materially
worse peak memory". Measured: **20.4 % / 3.2 s**, repeatable and with much better memory. That is
a real improvement but it is under the bar, and the plan is explicit that a single-digit
percentage is insufficient — this is a double-digit one, and it still does not justify a custom
PNG decoder in production:

- The remaining 3.2 s is the inflate itself. Swapping the inflate backend does not recover it:
  **zlib-ng 2.2.4 (NEON) is 21 % *slower* than Apple's system zlib here** (15.2 s vs 12.6 s), so
  that escape hatch is measured shut rather than assumed closed.
- 3.2 s is an **upper bound** on the production win, not a promise. libspng hands back raw RGBA8;
  ImageIO's path also applies colour management, and a production integration would still have to
  attach the source colour space and profile (§7). Some or all of the 3.2 s could be spent on
  work the app would then have to do itself.
- The structural benefits that *are* clearly real — bounded memory, per-row cancellation, no
  full-size bitmap — are already delivered by the shipped design through a different route
  (bounded level + streaming thumbnail + background materialization), which is why the
  end-to-end E4 numbers changed as much as they did without a custom decoder.

Recorded as a negative result. Per Task 11 step 3 nothing was integrated: no production file
references libspng or zlib-ng, and `Package.swift` still declares no external package.
