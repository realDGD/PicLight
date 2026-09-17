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
  (`bytesPerRow × height`) with a 384 MB ceiling and a 24-entry cap, so one 8K
  image evicts before a folder of small images does.
- Memory pressure purges everything except the image currently on screen
  (`DecodeCache.purge(keeping:)` fed by the coordinator's current URL).
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
| Unit test suite | 138 tests, ≈ 8 s |
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
