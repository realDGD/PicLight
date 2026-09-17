# PicLight Large-Image Bounded Decode + On-Demand Metal — Implementation Plan

> **For agentic workers:** implement task by task, in order. Each task is a reviewer-sized unit and is committed
> separately. Steps use checkbox (`- [ ]`) syntax for tracking. Do not re-open a frozen policy; if a measurement
> contradicts one, stop and record the counter-evidence in the spec before changing behaviour.

**Goal:** make PicLight handle multi-gigapixel images without native-size allocations or main-thread stalls, while
ordinary images keep native-resolution quality — bounded decode for the bitmap, on-demand Metal for interaction.

**Architecture:** `ImageDescriptor.displayPixelSize` stays the single authoritative source geometry; the decoded
`CGImage` becomes *only* the render bitmap, delivered materialized. A pure decode-budget helper chooses native vs a
bounded bucket. `DecodeCache` gains level/page identity and a 768 MiB bitmap budget. Interaction moves to an
on-demand `MTKView` with mandatory mipmaps; Quartz remains a first-class fallback that renders the bounded bitmap into
the *source* rectangle.

**Tech stack:** Swift 6, AppKit, ImageIO/CoreGraphics, MetalKit, XCTest. macOS 14+.

**Spec:** `docs/superpowers/specs/2026-09-17-large-image-bounded-metal-design.md` @ `71365d2`
**Evidence:** `benchmarks/LargeImagePolicyBench/` (`results/gates-report.md`, `results/gates-*.txt`)

---

## Frozen decisions (do not re-litigate)

| Area | Decision | Evidence |
| --- | --- | --- |
| Main decode, ≤8192 source | native resolution, **explicitly materialized off-thread** (A3) | §17.5 A-series |
| Main decode, >8192 source | `CGImageSourceCreateThumbnailAtIndex` bounded to a bucket ≤8192 | §17.5 A-series / A5 |
| Materialization mechanism | `CGImageSourceCreateImageAtIndex` + background `CGContext` draw; **never** the cache flags, **never** a native-sized thumbnail | §5.1, A1 is non-deterministic |
| Bucket formula | `required = ceil(max(canvasW, canvasH) × backingScale × 1.5)`, buckets 1024/2048/4096/8192 | §5.3, E1 |
| Preload / cache | **B3**: exact-level preload, `DecodeCache` budget 768 MiB, oversized neighbours get no preload | §13.3, B-series |
| Dimension probe | **C2**: on-demand header probe + cache; byte size may only *order* probes | §14.1, C-series |
| Minification | mipmapped, `mipFilter = .linear`, mandatory | §9.4, D-series |
| Magnification (proxy) | linear | §9.4, D6 |
| Resize / backing scale | debounce 300 ms, upgrade only when undersampled, never during a drag | §9.5, E2 |
| Drawer | current item from the main bitmap; non-current oversized → placeholder, no full-stream decode | §8, R7 |
| Animation frames | out of scope for budgeting, but **must not regress** the recorded baseline | §6.2, E5 |

## Global constraints

- Never write to, re-encode or move a source file. The investigation image stays read-only; its SHA-256 is verified
  before and after any measurement run.
- No native-size bitmap for an oversized source may ever reach the canvas or the renderer — including through the
  Quartz fallback.
- No 60/120 Hz render loop for a static image.
- Main-thread ping p95 < 100 ms during background decode, zoom, pan and resize.
- All existing tests stay green; the two tests that encoded `decoded dimensions == display dimensions` as a universal
  invariant are narrowed to native-resolution cases, not deleted.
- Keep `Package.swift`, the release scripts and the harness honest: the harness extracts production sources from git
  at build time, so it must keep building after every task (`benchmarks/LargeImagePolicyBench/build.sh`).

## Known traps (all hit during the gates; encode the fix, don't rediscover it)

| Trap | Fix |
| --- | --- |
| `DecodeCache` keys on `url.path` and remembers only `currentURL`, so level-aware identity cannot express which entry the purge must keep | introduce a `DecodeCacheKey` struct and `currentHeadKey`; **never** fake a URL/path to smuggle the level (the `@level=` path trick exists only in the B-series harness, which had to work with the unmodified cache) |
| `NSCache` tolerates being over budget, then evicts the **on-screen** entry while keeping a later one | bound the working set by construction; add the retention probe as a unit test |
| `Bundle.module` **traps** when the resource bundle is missing | `MetalLibraryLocator` returns `nil`; nothing on the runtime path may touch the generated accessor |
| `kCGImageSourceShouldCache*` behaviour is non-deterministic on a huge PNG (0 ms vs 20.6 s, same options) | never use them as a materialization mechanism |
| A native-sized thumbnail request costs ~2.6× the direct native path (7.45 GiB measured) | bounded thumbnails only, with `maxPixelSize` ≤ bucket |
| Thumbnail output is premultiplied-first/BGRA; native output is `.last`/RGBA | choose the `MTLPixelFormat` from `alphaInfo`/`bitmapInfo`/`bitsPerPixel`; normalize only exotic layouts |
| `CGContext` is bottom-up, Metal UV is top-down | flip on upload or map UVs correctly — a flip produced a false 60–85 RMSE in the D harness |
| NDC computed from `bounds` instead of `drawableSize` halves the image on Retina | quad size in points × zoom × backingScale; NDC from `drawableSize` |
| Any level change on the investigation image is a full, uncancellable ~18 s decode | §9.5 debounce policy; never upgrade during a drag; keep showing the current bitmap |
| `Task.cancel()` does not stop an in-flight ImageIO decode (19.4 s / 62.8 J still consumed) | decide *before* starting an oversized preload — skip it entirely |
| A proxy rendered without mipmaps is 1.5–2.6× the current renderer's shimmer (41× on a checkerboard) | mipmaps are mandatory, not an optimization |
| `ImageCanvasView` derives geometry from the bitmap today (`imagePixelSize`, and the draw rect at ~L149–165 of `123d943`) | both the Metal path and the Quartz fallback must map the bitmap over the **source** rect |

## Files to create / modify

```text
PicViewMac/Imaging/
  DecodeBudget.swift            new  pure: required/bucket/native decision, unit-tested against the E1 matrix
  DimensionProbe.swift          new  C2 actor: header probe + cache (wraps FolderScanner.pixelSize(of:))
  OversizedPolicy.swift         new  single predicate shared by preload and drawer
  BitmapMaterializer.swift      new  A3: background CGContext draw into a canonical layout, observable
  ImageIODecoder.swift          mod  honour the budget; bounded path; no double orientation
  DecodeCache.swift             mod  level/page identity in the key; default budget 768 MiB
  DecodeCoordinator.swift       mod  per-item budget; oversized preload skipped before starting

PicViewMac/Viewer/
  RenderImage.swift             new  value type: bitmap + sourcePixelSize (what the canvas renders)
  ImageCanvasView.swift         mod  takes RenderImage; source-rect mapping; hosts the Metal surface
  MetalCanvasSurface.swift      new  MTKView host, on-demand lifecycle
  MetalImageRenderer.swift      new  device/queue/pipeline/texture/mips/transform
  MetalLibraryLocator.swift     new  non-trapping resource lookup
  ViewerViewController.swift    mod  budget computation, navigator + current-thumbnail reuse, drawer policy

PicViewMac/Shaders/ImageShaders.metal   new
Package.swift                            mod  resource declaration for the shader
scripts/build-release.sh                 mod  copy the SwiftPM resource bundle into Contents/Resources
scripts/verify-release.sh                mod  packaged pipeline check + missing-resource fallback check

PicViewMacTests/
  DecodeBudgetTests.swift        new      LargeImageGeometryTests.swift   new
  CacheIdentityTests.swift       new      MetalParityTests.swift          new
  MetalFallbackTests.swift       new      ResourcePackagingTests.swift    new
  DrawerSafetyTests.swift        new      (plus narrow the two invariant tests in ImageIODecoderTests)
```

---

## Task 1: Separate source geometry from render-bitmap geometry

**Files:** `PicViewMac/Viewer/RenderImage.swift` (new), `ImageCanvasView.swift`, `ViewerViewController.swift`,
`PicViewMacTests/LargeImageGeometryTests.swift` (new), `PicViewMacTests/ImageIODecoderTests.swift` (narrow).

**Interfaces:**
```swift
/// The render bitmap is *only* a bitmap. Geometry is always derived from the descriptor,
/// so there is no second copy that can drift from `ImageDescriptor.displayPixelSize`.
struct RenderImage: Equatable {
    let bitmap: CGImage
    let descriptor: ImageDescriptor
    var sourcePixelSize: CGSize { descriptor.displayPixelSize }
}
```
The animated-frame path (`ViewerState.apply(frame:)`) must reuse the descriptor already published by
`apply(head:)` — a frame changes pixels, never geometry. Do not add a size field to `DecodedFrame`.

- [x] Step 1: Add `RenderImage`; change `ImageCanvasView` to render a `RenderImage` and to take all geometry
      (`imagePixelSize`, the drawn rect in `draw(_:)`) from `sourcePixelSize`. No code path may fall back to
      `bitmap.width/height` for geometry.
- [x] Step 2: The Quartz draw maps the bitmap into the **source** rectangle
      (`CGRect(x: -source.w/2, y: -source.h/2, width: source.w, height: source.h)`), so the fallback and Metal agree
      even when the bitmap is a proxy. Keep the existing `interpolationQuality` rule keyed off `zoomScale`.
- [x] Step 3: `ViewerViewController` publishes `RenderImage(bitmap:sourcePixelSize:)` from the decoded head and uses
      `descriptor.displayPixelSize` for `applyNavigatorSize` (currently `image.width/height`).
- [x] Step 4: Leave `ThumbnailItemView.swift` alone — drawer cells legitimately size by the thumbnail's own pixels.
- [x] Step 5: Tests — `LargeImageGeometryTests`: source 48000×32000 with an 8192×5461 bitmap asserts Fit, Fit Width,
      100 %, Fit ×2, pointer-centered zoom, pan/clamp, navigator rect, rotation and mirror all behave exactly as they
      do for a native-size bitmap. Narrow the invariant assertions in `ImageIODecoderTests` to native cases and add a
      bounded-case test asserting bitmap dims ≠ display dims while aspect and orientation stay correct.
- [x] Step 6: Run `swift test`; all geometry, viewport, layout and gesture tests green.

```bash
git add PicViewMac/Viewer/RenderImage.swift PicViewMac/Viewer/ImageCanvasView.swift PicViewMac/Viewer/ViewerViewController.swift PicViewMacTests/LargeImageGeometryTests.swift PicViewMacTests/ImageIODecoderTests.swift
git commit -m "refactor: make source geometry authoritative over the render bitmap"
```

## Task 2: Decode budget, oversized predicate, dimension probe, cache identity

**Files:** `DecodeBudget.swift`, `OversizedPolicy.swift`, `DimensionProbe.swift`, `DecodeCache.swift` (all new/mod),
`PicViewMacTests/DecodeBudgetTests.swift`, `CacheIdentityTests.swift` (new).

**Interfaces:**
```swift
enum DecodeLevel: Hashable { case native, bucket(Int) }        // buckets 1024/2048/4096/8192
enum DecodeBudget {
    static let buckets = [1024, 2048, 4096, 8192]
    static let overscan = 1.5
    static func level(canvasPoints: CGSize, backingScale: CGFloat, sourceLongEdge: Int) -> DecodeLevel
    static func pixelBudget(for level: DecodeLevel, sourceLongEdge: Int) -> Int?
}
enum OversizedPolicy { static func isOversized(sourceLongEdge: Int) -> Bool }   // > 8192
actor DimensionProbe { func longEdge(of url: URL) async -> Int? }               // C2: probe + cache

struct DecodeCacheKey: Hashable {          // the single encoding of cache identity
    let url: URL
    let pageIndex: Int
    let level: DecodeLevel
}
// DecodeCache API becomes key-based:
//   func head(for key: DecodeCacheKey) -> DecodedImageHead?
//   func store(head: DecodedImageHead, for key: DecodeCacheKey)
//   func setCurrent(_ key: DecodeCacheKey?)          // was setCurrent(_ url: URL?)
//   func purge(keeping key: DecodeCacheKey?)         // was purge(keeping url: URL?)
// A private static func nsKey(_ key: DecodeCacheKey) -> NSString is the only place that turns
// the struct into an NSString for NSCache; nothing else may build key strings.
```

- [x] Step 1: Implement `DecodeBudget` exactly as §5.3/E1: `required = ceil(max(canvasW, canvasH) × backingScale × 1.5)`,
      smallest bucket ≥ required, clamp 8192; **`.native` whenever `sourceLongEdge <= 8192`**, otherwise the clamped
      bucket. Table-test it against the E1 matrix (default window, full screen, narrow, short-wide × landscape,
      portrait, extreme, wide).
- [x] Step 2: Implement `OversizedPolicy` as the one predicate used by both preload and drawer.
- [x] Step 3: Implement `DimensionProbe` on top of the existing header probe (`FolderScanner.pixelSize(of:)`), with a
      bounded cache; byte size is *not* an input to the decision (it may only order work later, if ever).
- [x] Step 4: `DecodeCache`: replace `headKey(_ url:)` with the `DecodeCacheKey` struct above and switch
      `setCurrent(_:)` / `purge(keeping:)` to take a key. This is load-bearing: with a key that carries only the URL,
      the memory-pressure purge cannot tell whether the on-screen entry is `page 0 / bucket(8192)` or
      `page 0 / bucket(4096)` and will keep the wrong one. Update the two `DecodeCoordinator` call sites
      (`cache.setCurrent(url)` when a show begins, `purgeCache(keeping:)`) to pass the key they actually requested.
      Raise the default `totalCostLimit` to 768 MiB; keep `cost = bytesPerRow × height`.
- [x] Step 5: Tests — budget table; oversized predicate boundary (8192/8193); probe caching (one probe per URL);
      cache identity (4096≠8192, page participates, cost is real bytes); the two E3 retention probes as unit tests
      using synthetic bitmaps: 8192+2×4096 = 256 MB retained, and the 426.7 MB case documented as "NSCache may evict
      the earlier entry" so no test assumes otherwise; and specifically **memory-pressure purge keeps the entry for the
      currently shown (page, level)** while a different level of the same URL is dropped.
- [x] Step 6: `swift test`.

```bash
git add PicViewMac/Imaging/DecodeBudget.swift PicViewMac/Imaging/OversizedPolicy.swift PicViewMac/Imaging/DimensionProbe.swift PicViewMac/Imaging/DecodeCache.swift PicViewMac/Imaging/DecodeCoordinator.swift PicViewMacTests/DecodeBudgetTests.swift PicViewMacTests/CacheIdentityTests.swift
git commit -m "feat: decode budget, oversized predicate, dimension probe and level-aware cache identity"
```

## Task 3: Bounded main decode + explicit materialization (A3)

**Files:** `BitmapMaterializer.swift` (new), `ImageIODecoder.swift`, `DecodeCoordinator.swift`,
`PicViewMacTests/ImageIODecoderTests.swift` (extend).

**Interfaces:**
```swift
enum BitmapMaterializer {
    /// Background CGContext draw into a canonical 8-bit layout, preserving the source CGColorSpace.
    static func materialize(_ image: CGImage) -> CGImage?
}
```

- [x] Step 1: `BitmapMaterializer.materialize(_:)` is a **synchronous CPU operation**; `decodeFirstDisplayableFrame`
      already runs inside `Task.detached(priority: .userInitiated)` (`ImageIODecoder.swift` ~L23), so the materializer
      must **not** create a second detached task — a nested task only complicates priority, cancellation and test
      tracing. Worst case on the ≤8192 path is ~0.5 s (measured 0.495 s for 8192×5461).
- [x] Step 2: Materialization must be *observable without timing*: tests assert the delivered bitmap does not re-enter
      the decoder/materializer (a counting seam over `CGImageSourceCreateImageAtIndex` and `BitmapMaterializer`)
      and that the bitmap is already resident. **No absolute wall-clock thresholds in XCTest** — the gate measured
      3 ms for the same-size redraw and 58 ms for the first draw, and a loaded machine moves both. Timing lives in the
      harness with a relative bound: `matbench --mode a3` on the 8192 fixture must stay within 1.5× of the recorded A3
      baseline (first draw 0.058 s, peak footprint 0.337 GiB).
- [x] Step 3: `ImageIODecoder.decodeFirstDisplayableFrame(_:target:)`:
      - `target.maxPixelSize == nil` or `>= budget` and `sourceLongEdge <= 8192` → `CreateImageAtIndex` + materialize;
      - oversized → `CreateThumbnailAtIndex` with `FromImageAlways`, `WithTransform`, `ShouldCacheImmediately`,
        `ThumbnailMaxPixelSize = bucket`; the transform owns orientation, so `apply(orientation:)` must **not** run
        afterwards;
      - keep ICO representation selection and TIFF `pageIndex` semantics exactly as today;
      - never call `CreateThumbnailAtIndex` with `maxPixelSize >= sourceLongEdge` for an oversized source.
- [x] Step 4: Preserve the source colour space through both paths (Display-P3 tests stay valid).
- [x] Step 5: **Bit-depth policy — never silently flatten high-depth sources.** Today a 16-bit source with orientation
      `.up` returns the native `CGImage` untouched (`decodeOriented` early-returns on `.up`), so it keeps full
      precision; an unconditional 8-bit materialization would quietly downgrade it. Policy:
      ```text
      8-bit RGB/RGBA/gray      -> A3 canonical 8-bit layout (premultipliedLast for RGB, 8-bit gray for gray),
                                  colour space object preserved
      indexed / palette        -> expand to 8-bit RGBA in the source's backing colour space. This is LOSSY-FREE
                                  (palette entries are 8-bit; a tRNS alpha is preserved) and it is the only option:
                                  a bitmap context cannot be created with an indexed colour space, so "preserve the
                                  palette layout" is not implementable. The expanded bitmap is 8-bit-class and stays
                                  on the Metal path — indexed images must NOT be pushed to the Quartz fallback just
                                  because their file storage was indexed.
      >8 bits/component, float -> materialize at the SAME bitsPerComponent and colour space (16-bit int or float
                                  context); the renderer's exotic-layout policy (spec §7) routes it to Quartz
                                  exactly as today
      ```
      Add `depth16.png`, `depth16.tiff` and `indexed-palette.png` fixtures (small, committed under
      `PicViewMacTests/Fixtures`). Tests assert: 16-bit keeps `bitsPerComponent == 16` and its colour space; the
      palette image's expanded pixels **exactly equal** the palette's RGB values (per-index), including a transparent
      index staying transparent; and both still render. Note in the PR that this refines spec §7 with an explicit
      no-downgrade rule.
- [x] Step 6: `DecodeCoordinator` passes the per-item budget; neighbour preload uses the same policy; **skip oversized
      neighbours before starting any task** (no cancellation-based mitigation: ImageIO ignores cancellation).
- [x] Step 7: Tests — bounded long edge ≤ bucket; `displayPixelSize` unchanged; orientation applied exactly once;
      P3 tagged; 16-bit precision preserved; TIFF page + ICO still correct; materialization observability proof.
- [x] Step 8: Verify against the gate harness (the shipped path must reproduce the gate numbers):
      `benchmarks/LargeImagePolicyBench/.work/picbench matbench <fixture> --mode a3` for an 8192 PNG
      (expect ≈0.06 s first draw, ≈0.34 GiB peak footprint) and a bounded thumbnail for the oversized fixture.

```bash
git add PicViewMac/Imaging/BitmapMaterializer.swift PicViewMac/Imaging/ImageIODecoder.swift PicViewMac/Imaging/DecodeCoordinator.swift PicViewMacTests/ImageIODecoderTests.swift PicViewMacTests/Fixtures
git commit -m "feat: bounded main decode with explicit background materialization"
```

## Task 4: Stop redundant source-stream work (navigator, current drawer item, oversized drawer items)

**Files:** `ViewerViewController.swift`, `ThumbnailPipeline.swift`, `PicViewMacTests/DrawerSafetyTests.swift` (new).

- [x] Step 1: Navigator preview and the current item's drawer thumbnail are generated from the current render bitmap
      (`ThumbnailPipeline.preview(from:)`), never by re-opening the source. Keep the file-based thumbnail path for
      non-current items at or below the pixel budget.
- [x] Step 2: Non-current oversized drawer items render a placeholder; `OversizedPolicy` decides before any decode is
      requested. Placeholder must not touch selection-border semantics or hit testing.
- [x] Step 3: Tests — with a counting decoder seam: opening an oversized image performs **exactly one** full-stream
      traversal; navigator and current drawer item contribute none; N oversized drawer items launch zero full-stream
      decodes.
- [x] Step 4: Checkpoint with the app harness (Metal does not exist yet, so this isolates the decode-side win):
      `benchmarks/LargeImagePolicyBench/run-e4.sh <rev>` on the investigation image. Expect traversals to drop from
      the 4 in the recorded baseline toward 1, the main-thread stall to fall well below 20.9 s, and energy toward
      ~60 J. Record the numbers in the PR; the formal E4 gate runs in Task 8.

```bash
git add PicViewMac/Viewer/ViewerViewController.swift PicViewMac/Imaging/ThumbnailPipeline.swift PicViewMacTests/DrawerSafetyTests.swift
git commit -m "feat: reuse the bounded bitmap for navigator and current drawer item, protect the drawer"
```

## Task 5: Metal renderer with mandatory mipmaps, on-demand, with a Quartz fallback

**Files:** `MetalCanvasSurface.swift`, `MetalImageRenderer.swift`, `MetalLibraryLocator.swift`,
`PicViewMac/Shaders/ImageShaders.metal`, `ImageCanvasView.swift`, `Package.swift`,
`PicViewMacTests/MetalParityTests.swift`, `MetalFallbackTests.swift` (new).

- [ ] Step 1: `Package.swift` gains `resources: [.process("Shaders/ImageShaders.metal")]` on the executable target.
      Do **not** compile shader source strings at runtime.
- [ ] Step 2: `MetalLibraryLocator` mirrors SwiftPM's search order (dev override → `Bundle.main.resourceURL` →
      `Bundle(for:)`-style → `Bundle.main.bundleURL`) and returns `nil` on failure. No `fatalError`; nothing on the
      runtime path may call the generated `Bundle.module` accessor.
- [ ] Step 3: `MetalImageRenderer`: pipeline from the locator. Texture format comes from a **complete layout mapping
      table over `bitsPerComponent` + `alphaInfo` + `byteOrder` + `bitsPerPixel`** — `alphaInfo` alone does not
      determine memory order (`byteOrder32Little` + `premultipliedFirst` is BGRA in memory; the same byte order with
      `premultipliedLast` is RGBA). 8-bit layouts map to `bgra8Unorm`/`rgba8Unorm`; anything else (16-bit, float,
      indexed, unusual byte orders) goes to Quartz per spec §7 or through one tested `CGContext` normalization —
      never guessed. Blending is premultiplied source-over the canvas background colour. Pair the mapping with a
      **channel-identity pixel test** (a fixture with known, distinct R/G/B values) so a red/blue swap cannot pass as
      "parity".
- [ ] Step 4: Mipmaps are **mandatory**: generate after upload, `mipFilter = .linear`, no shader LOD clamp that
      bypasses the chain. Sampler min/mag linear; magnification of a proxy stays linear (D6).
- [ ] Step 5: Colour management is configured on the **surface**, not merely carried by the texture: the
      `MTKView`/`CAMetalLayer` colour space is set from the render bitmap's colour space, so a Display-P3 image is
      composited as P3 instead of being reinterpreted as sRGB downstream. If the drawable cannot be configured for the
      input's colour space, route to Quartz (spec §10).
- [ ] Step 6: Geometry: quad = `displayPixelSize × zoom` in points × backingScale, NDC from `drawableSize`; rotate by
      quarter turns; mirror; keep `ViewportState` as the only viewport model. Flip on upload (or map UVs) so the image
      is not upside down — verify with a 1:1 parity test at scale 1.0 (RMSE must be ≈0 against the Quartz reference, as
      the D-series sanity check showed).
- [ ] Step 7: On-demand lifecycle in `MetalCanvasSurface`: `isPaused = true`, `enableSetNeedsDisplay = true`;
      `setNeedsDisplay` only for new bitmap, viewport change, resize/layout, backing-scale change, drawable/colour
      change, background change.
- [ ] Step 8: `ImageCanvasView` keeps gestures/hit testing and hosts the surface; on any Metal failure it renders the
      **bounded bitmap over the source rect** through the existing Quartz path (never a native lazy source).
- [ ] Step 9: Tests — parity on small fixtures for identity/zoom/pan/90° rotation/mirror/alpha/sRGB/P3/BGRA-vs-RGBA/1×
      vs 2× backing scale/strong minification; a forced-failure injection proving the fallback is selected and no
      `Image IO` allocation appears.
- [ ] Step 10: Verify with the harness: `.work/minbench` parity numbers at 1.0× (≈0 RMSE) and the D-series minification
      numbers for the shipped sampler setup; `renderbench` zoom/pan/idle for 60 fps and ~40 mW.

```bash
git add PicViewMac/Viewer/MetalCanvasSurface.swift PicViewMac/Viewer/MetalImageRenderer.swift PicViewMac/Viewer/MetalLibraryLocator.swift PicViewMac/Shaders PicViewMac/Viewer/ImageCanvasView.swift Package.swift PicViewMacTests/MetalParityTests.swift PicViewMacTests/MetalFallbackTests.swift
git commit -m "feat: on-demand Metal renderer with mandatory mipmaps and Quartz fallback"
```

## Task 6: Release packaging for the Metal resources

**Files:** `scripts/build-release.sh`, `scripts/verify-release.sh`, `PicViewMacTests/ResourcePackagingTests.swift`.

- [ ] Step 1: `build-release.sh` copies the SwiftPM resource bundle (the compiled `default.metallib`) into
      `PicLight.app/Contents/Resources` in addition to the executable.
- [ ] Step 2: `verify-release.sh` adds two checks: the packaged app can locate/create the Metal pipeline; and a
      deliberately missing-resource build still launches and selects Quartz (no trap).
- [ ] Step 3: Tests — resource lookup paths for `swift run`, xctest and the packaged `.app`; missing bundle → `nil`,
      no crash.
- [ ] Step 4: Verify end to end: `scripts/build-release.sh && scripts/verify-release.sh`, plus a manual launch of the
      packaged app on the investigation image.

```bash
git add scripts/build-release.sh scripts/verify-release.sh PicViewMacTests/ResourcePackagingTests.swift
git commit -m "build: ship and verify Metal shader resources in the release bundle"
```

## Task 7: Integrated working-set acceptance (spec §15.8)

**Files:** `benchmarks/LargeImagePolicyBench/` (extend), `docs/performance-v0.1.md` (record).

- [ ] Step 1: Extend the harness with an integrated workload runner: open a folder of 3 near-threshold 8192-class
      images and a folder of 3 × 6000-class images, navigating current → prev → next with preload enabled while the
      current image owns its mip chain; report DecodeCache retained cost and entry count, current base+mip texture
      bytes, `phys_footprint`, RSS, system swap growth, hit rate and navigation latency.
- [ ] Step 2: Run on the 16 GB target Mac and record raw output under `results/`.
- [ ] Step 3: Acceptance: cache cost ≤ 768 MiB; no sustained memory-pressure warning attributable to the viewer;
      swap growth < 512 MiB across the workload; the B3 preload benefit still visible (no silent eviction of the
      current entry). If it fails, re-tune the **cache** limit with this measurement and re-run — **mipmaps stay**.
- [ ] Step 4: Record the measured working set (cache + textures + footprint) in `docs/performance-v0.1.md` so the
      768 MiB figure is never quoted as a whole-app ceiling again.

```bash
git add benchmarks/LargeImagePolicyBench docs/performance-v0.1.md
git commit -m "test: integrated decode-cache + Metal working-set acceptance"
```

## Task 8: Real-image acceptance (spec §16) and E4

**Files:** `benchmarks/LargeImagePolicyBench/results/`, `docs/large-image-performance-investigation.md` (append).

- [ ] Step 1: `run-e4.sh <rev>` on the investigation image; assert against the recorded baseline
      (4 traversals → **1**, 136.6 J → **≤ ~70 J**, 20.9 s stall → **p95 < 100 ms**).
- [ ] Step 2: `vmmap` at t+5 s and t+10 s during the load: no `Image IO` region > 1 GiB; bitmap long edge ≤ 8192 and
      within one bucket step of the requested budget; no native 48000×32000 bitmap anywhere on the display path.
- [ ] Step 3: Record RSS for **diagnostics only** — it moves with mmapped source pages and system cache and is not a
      pass/fail signal. The gates remain `phys_footprint`, the `vmmap` `Image IO` assertion and swap growth (spec §16).
- [ ] Step 4: Animation non-regression: `PICLIGHT_BENCH_SECONDS=20 run-e4.sh <rev> anim-1000.gif` — compare with the
      E5 baseline (15.9 fps, 249 mJ per frame, ping p95 98 ms).
- [ ] Step 5: Record all raw outputs under `benchmarks/LargeImagePolicyBench/results/`.

```bash
git add benchmarks/LargeImagePolicyBench/results docs/large-image-performance-investigation.md
git commit -m "test: real-image acceptance for bounded decode and Metal rendering"
```

## Task 9: Regression sweep and documentation

- [ ] Step 1: Full `swift test`; fix every regression rather than relaxing a test. Confirm the narrowed invariant tests
      still cover native-resolution behaviour.
- [ ] Step 2: Sweep the existing behavioural suites explicitly: gesture routing, pointer-centered zoom, drawer
      pin/unpin, navigator, animation, multi-page TIFF, thumbnail selection border, window/layout.
- [ ] Step 3: Update `docs/performance-v0.1.md` and the README with the new behaviour (bounded decode, on-demand Metal,
      the resize policy, and the fact that 100 % zoom on an oversized image is intentionally undersampled until a
      LargeImageBackend exists).
- [ ] Step 4: Confirm the two spikes remain isolated (no production dependency added).

```bash
git add PicViewMac PicViewMacTests docs README.md
git commit -m "test: regression sweep and documentation for large-image handling"
```

## Task 10: Quick Look spike (isolated, no production dependency)

- [ ] Step 1: Measure `QLThumbnailGenerator` cold vs warm **Quick Look cache** (not merely page cache) for 2048/4096 on
      the investigation image; record wall time, output size, footprint, and whether it triggers a full PNG decode.
- [ ] Step 2: Success requires a repeatable materially earlier preview; otherwise record the negative result and stop.
- [ ] Step 3: Report only — do not integrate.

## Task 11: Alternative PNG decoder spike (isolated)

- [ ] Step 1: Benchmark libpng/libspng (optionally zlib-ng) on the same image against the ImageIO baseline
      (≈112 MB/s compressed, ≈83 Mpixel/s, 18.1–19.2 s run-to-run).
- [ ] Step 2: Bar for a production candidate: ≥30 % wall-time or ≥5 s absolute improvement, repeatable, without
      materially worse peak memory; row-wise downsampling and cancellation checkpoints are the structural wins to
      look for. A single-digit percentage is insufficient.
- [ ] Step 3: Report only — do not integrate.

## Task 12: Release gate

- [ ] Step 1: `swift test` green; `scripts/build-release.sh` + `scripts/verify-release.sh` green including the packaged
      Metal check and the missing-resource fallback.
- [ ] Step 2: Re-run Task 7 (integrated working set) and Task 8 (E4) on the release build.
- [ ] Step 3: Confirm every §23 success criterion with a named measurement; anything unmeasured is recorded as open.

```bash
git add docs benchmarks
git commit -m "chore: large-image release gate"
```

---

## Verification map

| Spec requirement | Verified by |
| --- | --- |
| §4.1 single source geometry | Task 1 tests (source ≠ bitmap dims) |
| §5.1 A3 materialization | Task 3 timing proof + harness `matbench a3` |
| §5.3 bucket formula | Task 2 table tests (E1 matrix) |
| §9.4 mipmaps mandatory | Task 5 parity + minbench numbers |
| §9.5 resize policy | Task 1/5 tests + manual resize check |
| §8 no redundant source work | Task 4 counting-decoder tests + E4 traversals == 1 |
| §15.8 integrated working set | Task 7 (raw output recorded) |
| §16 real-image acceptance | Task 8 (run-e4.sh, vmmap sampling) |
| §23 success criteria | Task 12 |

## Execution order

Tasks 1–3 are the load-bearing sequence: geometry first (so a wrong bitmap size cannot silently break pan/zoom),
then the pure policy helpers, then the decode path itself. Tasks 4–6 deliver the user-visible win (no stalls, on-demand
GPU rendering, shippable resources). Tasks 7–9 are the acceptance gates, 10–11 are the isolated spikes and 12 is the
release gate.

**Order note (one deliberate deviation from §22).** §22 lists "cache identity plus chosen preload/cache policy" as a
single step after the decode path; this plan lands cache identity in Task 2, *before* the decode path, because the
bounded decode needs the level to key the cache at all — implementing the decode first would mean writing level-blind
cache code and then rewriting it. The preload half of §22.5 stays in Task 3 step 4. Everything else follows §22's
order exactly.

## Risk register

| Risk | Mitigation |
| --- | --- |
| Geometry regression breaks pan/zoom subtly | Task 1 lands first and alone, with the full geometry matrix before any decode change |
| NSCache evicts the on-screen entry under the integrated working set | Task 7 measures it; the cache limit is re-tuned from data, mipmaps stay |
| Metal texture layout mismatch (BGRA/RGBA, premultiplied) | format chosen from the bitmap + parity tests including alpha and P3 |
| Retina geometry error (bounds vs drawableSize) | explicit 1×/2× parity tests |
| Resource bundle missing in the packaged app | packaging test + negative fallback test in Task 6 |
| Level upgrades on resize cause 18 s stalls | §9.5 debounce policy implemented in Task 1/5 and checked in Task 8 |
| Preload of oversized neighbours silently reintroduced | `OversizedPolicy` is the single predicate; Task 4 tests assert zero oversized decodes |

## Rollback

Each task is a separate commit on `perf/bounded-metal-design`; revert any task independently. Metal is optional by
construction (Quartz fallback), and the decode path degrades to today's behaviour if the budget helper returns
`.native` everywhere — so reverting Task 5 or Task 3 does not require touching the others.

## Self-review against the spec

### Coverage

- §2 in-scope items → Tasks 1–9, 12; spikes → Tasks 10–11
- §4.1 / §4.2 / §4.3 → Tasks 1, 2, 5
- §5.1 / §5.2 / §5.3 → Tasks 2, 3
- §6 data model → Tasks 1, 2, 3
- §7 pixel layout and colour → Task 5 steps 3, 9
- §8 redundant work → Task 4
- §9 Metal architecture → Task 5; §9.4 mipmaps → Task 5 step 4; §9.5 resize → Tasks 1, 5
- §10 Quartz fallback → Task 5 steps 7–8
- §11 resource lookup and packaging → Tasks 5 step 2, 6
- §12 loading state and responsiveness → Tasks 1, 4, 8
- §13 preload/cache (B3) → Tasks 2, 3, 4, 7
- §14 dimension probe (C2) → Task 2
- §15 test strategy → every task's Steps; §15.8 → Task 7
- §16 acceptance → Task 8
- §17 harness → extended in Tasks 3, 7, 8
- §21 error handling → Tasks 3, 5
- §22 order → task order; §23 criteria → Task 12

### Explicitly not in this plan

- Native-detail delivery above the 8192 proxy at high zoom (a later LargeImageBackend).
- Animation frame budgeting beyond the non-regression baseline.
- Sidecar/proxy cache in production; Core Image as the render path; custom decoder or tiling in production.

### No silent scope expansion

Nothing here adds features beyond the spec: no new formats, no editing, no HDR, no updater, no telemetry, no permanent
60/120 Hz loop, and no change to window/drawer semantics beyond the oversized-item placeholder the spec already
requires.
