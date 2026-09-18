# PicViewMac v0.1 — performance notes

Measured on the development machine (Apple silicon, macOS 27, Xcode 27 toolchain)
using the automated suites in `PicViewMacTests/`. Numbers are from
`swift test` on the debug build unless stated otherwise; the point of this
document is the *shape* of the behavior, not precise benchmarks.

## Folder scanning

| Scenario | Result |
| --- | --- |
| 10,000 candidate filenames, no decodable bodies | scan + natural sort ≈ 3.6 s, ≤ 20 s budget asserted |
| 10,000 candidates | zero image bodies inspected; every `pixelSize` stays `nil` |
| 2,000 files opened through the viewer | UI call returns immediately; decode work happens off the main actor |

Scanning reads directory metadata only. Dimensions are filled lazily and only
when **Sort → image dimensions** is selected (`FolderScanner.fillDimensions`),
so no other sort mode pays for header reads.

## Decoding and caching

- `ImageIODecoder` runs every decode in a detached task at `userInitiated`
  priority; the main thread never performs file I/O or decode work.
- Decoded images are cached by **real decoded byte cost**
  (`bytesPerRow × height`) under a 768 MiB ceiling, so one 8K image evicts before
  a folder of small images does. The budget is sized from measurement: at 384 MiB
  the integrated large-image working set silently evicted the entry on screen
  (`results/gates-15.8-integrated.txt`).
- Cache entries are keyed by `DecodeCacheKey` — source URL, representation index
  and decode level — because the same file can legitimately exist at several
  sizes. `currentHeadKey` names the entry on screen, and memory pressure purges
  everything except it (`DecodeCache.purge(keeping:)`).
- Animation frames are decoded on demand (`decodeFrame(_:index:)`) instead of
  holding a whole animation in memory; a cancelled/older generation can never
  publish over a newer one (asserted in `DecodeCoordinatorTests`).

## Thumbnails

- Thumbnails come from `CGImageSourceCreateThumbnailAtIndex` with
  `kCGImageSourceThumbnailMaxPixelSize`, so a 4000×3000 source is never fully
  decoded to fill a ~132 px drawer row (asserted in `ThumbnailPipelineTests`).
- Drawer rows are virtualized by `NSTableView`; a 1,000-item folder builds only
  the visible cells (asserted in `ThumbnailDrawerTests`).

## Known measurements

| Metric | Value |
| --- | --- |
| Unit test suite | 392 tests, ≈ 104 s |
| Full in-app acceptance runner | 46 checks, ≈ 14 s |
| Release bundle size | ≈ 1.7 MB binary, 708 KB DMG |

## Automated stress coverage (added for rc1)

`LargeFolderStressTests`, `RapidSwitchCancellationTests` and `CacheInvariantTests`
now assert the *shape* of the behavior rather than a wall-clock number:

| Scenario | Asserted |
| --- | --- |
| 10,000-file folder | scans, sorts naturally, never recurses, inspects no image bodies |
| 2,000-file folder opened in the viewer | at most 4 decode requests (current + neighbours) |
| 5,000-item drawer while closed | fewer than 100 thumbnail requests |
| Scrubbing 58 selections quickly | at most 3 decode tasks left in flight |
| 500 forward + 500 backward switches | correct final index, at most 3 tasks in flight |
| 160 thumbnail decodes | RSS recorded before/after, no threshold asserted |

## Not measured (no Instruments run)

`Task 21 Step 5` asks for an Instruments profile of a large JPEG/TIFF (peak
decoded memory and main-thread stalls). **That was not done here** — this
environment has no display access and no automated Instruments harness. Peak
memory is therefore bounded by design (cost-based cache limits) but not
empirically recorded. Run before making performance claims in a release note:

```bash
xcrun xctrace record --template 'Time Profiler' --launch -- \
  dist/PicViewMac.app/Contents/MacOS/PicViewMac /path/to/large/photo.jpg
```

## Large images (bounded decode and on-demand Metal)

Sources whose long edge is at most 8192 decode at native resolution; anything
larger is decoded straight into a bounded level (1024 / 2048 / 4096 / 8192, chosen
by `ceil(max(canvasWidth, canvasHeight) × backingScale × 1.5)`, snapped up, never
above native). Behaviour that follows from that design:

- Decoding a bounded level costs what the *decode* costs, not what the output
  size costs: on the 48000×32000 investigation image every level costs ≈ 18 s and
  ≈ 75 J, which is why the level is picked from canvas geometry and a header-only
  size probe rather than re-decoded at each zoom step.
- The bitmap is materialized in the background (`BitmapMaterializer`) before it is
  published, so the first frame on screen never pays for PNG inflate; the file is
  streamed once per load and the source depth/colour space is preserved (indexed
  sources expand losslessly, > 8-bit sources stay deep).
- Metal draws the current bitmap on demand (`enableSetNeedsDisplay`, `isPaused`)
  with mandatory mipmaps and `linear` min/mag/mip filtering; the Quartz path
  remains and is semantically identical (`PICLIGHT_DISABLE_METAL=1` forces it for
  A/B measurement).
- Level upgrades triggered by a window resize *or a zoom-in* are debounced 300 ms, only run when
  the bitmap is actually undersampled for the settled canvas, never start while the
  pointer or a live resize is moving, and keep the current bitmap on screen until
  the replacement is ready (`ResizeUpgradePolicy`). Zooming past the 1.5× headroom
  therefore sharpens up to the 8192 proxy, at the cost of one bounded decode per
  bucket step; beyond 8192 the bitmap stays a proxy by design.
- Oversized drawer items render a placeholder instead of decoding; the current
  item is served from the bitmap already on screen.

| Scenario (48000×32000 PNG, 1.929 GiB, 637×212 pt canvas) | Before | After |
| --- | --- | --- |
| Full-file decode passes per load | 4 | 1 |
| Main-thread stall | 20.9 s | 23 ms |
| Load energy | 136.6 J | 83.4 J |
| Peak RSS | 6.885 GiB | 2.111 GiB |
| Peak footprint (sampled) | 5.86 GiB bitmap | 0.198 GiB |
| Largest `Image IO` region in vmmap | 5.7 GiB | 0.36 GiB |

The bitmap for that canvas is the 2048 level (10.7 MB), because the level is the
one the canvas's own geometry implies; a window that opens larger asks for the
level it needs, and settling a window larger afterwards buys the coarser level
after the debounce.

## Native detail above the 8192 proxy

100 % on a source above 8192 is no longer the proxy upscaled. When the display density passes what
the proxy can resolve (`zoomScale × backingScale` against `proxyLongEdge / sourceLongEdge`), the app
streams the PNG itself and draws native tiles over the proxy:

| measurement (48000×32000 at 100 %, 2× display) | value |
| --- | --- |
| detail energy of the frame with tiles | 3.49 (source itself: 3.49) |
| detail energy of the same frame without tiles | 0.64 |
| time from the zoom gesture to tiles on screen | 10.5 s (220 ms debounce + one pass) |
| whole-image decodes for the gesture | 0 (the level path stands down; the pass replaces it) |
| peak footprint / peak RSS | 0.226 GiB / 2.113 GiB |
| main-thread stall | max 88 ms (tile texture uploads; warm tiles now upload on a background queue) |
| warm tiles kept | 24–40 (nine-grid plan; the budget is the cache's own 256 MiB) |
| pan one viewport | 0 new uploads, 0 new traversals, every drawn tile a GPU cache hit |
| footprint with the warm plan | 0.348 GiB |

Why a custom decoder: measured with `bench/regionbench`, no format ImageIO reads offers a region
decode — a 512×512 crop costs a full decode in every case (PNG 375 ms against 403 ms) — so native
pixels for part of a huge file can only come from streaming it and keeping what the viewport asks
for. Tiles are byte-budgeted, LRU, with the viewport's tiles pinned; the backend serves PNG that is
8-bit and not interlaced, and tiles are in memory only, so a far revisit costs another pass.

## Energy numbers are session-scoped

An absolute energy figure from one sitting does not transfer to another on this machine. The
archived animated-playback baseline (78.1 J, 249 mJ per drawn frame) does not reproduce: the same
baseline revision, measured later, gives 99.0–109.8 J and 304–338 mJ per frame over eight runs, with
swap at 3.7 GiB used and load average ~2.4. What the same-session A/B does show
(`benchmarks/LargeImagePolicyBench/results/anim-ab-summary.md`, `sample-animation.sh`):

| arm | samples | draws / 20 s | energy | per drawn frame |
| --- | --- | --- | --- | --- |
| baseline 123d943 (Quartz) | 8 | 319.9 | 102.6 J | 320.8 mJ |
| HEAD, Metal on | 5 | 319.8 | 88.5 J | 276.9 mJ |
| HEAD, Metal off | 5 | 297.0 | 84.3 J | 283.9 mJ |

So the animated path is 11–14 % cheaper per drawn frame than the baseline beside it, Metal on versus
off is within noise per frame while rendering ~8 % more frames, and the earlier "+3–18 % residual"
was an artefact of comparing a fresh run against an archived number. Treat any single energy value
here as comparable only within the run that produced it.

## Large-image working set (integrated DecodeCache + mipmapped Metal texture)

Measured 2026-09-18 on the 16 GB target Mac with the production decoder, cache and
renderer (`benchmarks/LargeImagePolicyBench`, command `picbench integrated`; raw output
in `results/gates-15.8-integrated.txt`):

| set | bitmap cache | current texture (base+mips) | peak footprint | swap growth | entries retained | preload hits |
| --- | --- | --- | --- | --- | --- | --- |
| three ~8192-class images | 682.7 MiB | 227.5 MiB | 1.475 GiB | 0 MiB | 3/3 (current retained) | 2 |
| three ~6000-class images | 344.4 MiB | 153.9 MiB | 1.283 GiB | 0 MiB | 3/3 (current retained) | 2 |

The 768 MiB figure is the **DecodeCache** budget, not a whole-app ceiling: the composed
working set with the current image's mip chain peaks at ~1.5 GiB of footprint, with no
swap growth attributable to the workload. The acceptance in the design spec (cache
within budget, no sustained memory pressure, swap growth < 512 MiB, and the preload
benefit still visible) passes on this evidence, so the cache budget stands as chosen and
mipmaps stay mandatory — at 384 MiB the same scenario silently evicted the on-screen
entry, which is why the budget was raised.
