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
| Full in-app acceptance runner | 43 checks, ≈ 13 s |
| Release bundle size | ≈ 1.7 MB binary, 708 KB DMG |

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
