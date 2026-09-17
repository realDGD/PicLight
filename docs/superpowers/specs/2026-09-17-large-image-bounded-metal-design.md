# PicLight Large-Image Bounded Decode + On-Demand Metal Design

Date: 2026-09-17
Baseline: `123d943`
Status: policy gates complete; implementation planning approved; E4 remains a post-implementation acceptance gate

## 1. Purpose

PicLight currently treats the decoded `CGImage` as both the source-image geometry and the renderable bitmap. That works for normal images but fails badly for extreme images. The investigation image is a 1.929 GiB, 48000×32000, non-interlaced RGBA PNG. On the current path, `CGImageSourceCreateImageAtIndex` returns quickly because the image is lazy, then Core Animation forces a full decode during backing-store rasterization. The measured result is about 19.6 s to first real pixels, a 5.86 GiB `Image IO` footprint, 7.8–9.0 GiB peak RSS, and about 0.05 fps when repeatedly interacting with the still-lazy native image.

This design addresses two independent problems:

1. Bound the bitmap presented to the renderer so a huge source can never force a native-size allocation merely to fit the window.
2. Replace the interactive CGContext resampling path with an on-demand Metal renderer so zoom, pan, rotate, and mirror do not repeatedly rasterize large images on the CPU.

This design does **not** attempt to make a 1.9 GiB PNG decode in sub-second time. The investigation proved that ImageIO thumbnail creation still spends roughly 18 s because PNG inflate + row filtering dominates and scales with the compressed stream, not the requested output dimensions.

A second objective of this revision is to settle policy disagreements with repeatable benchmark evidence rather than architectural preference. That work is **done**: the A/B/C/D and E-series gates ran on 2026-09-17, every decision the implementation plan needs is frozen in §5.1/§5.3/§9.4/§9.5/§13.3/§14.1, and the numbers are in §17.5 with the harness in `benchmarks/LargeImagePolicyBench/`.

## 2. Scope

### In scope

- A hard oversized threshold of **8192 pixels on the source long edge**.
- Native-resolution, explicitly materialized images for sources whose long edge is <=8192.
- Bounded main-image decoding with a maximum render-bitmap long edge of **8192 pixels** for oversized sources.
- Preserve source-image geometry independently from decoded-bitmap geometry.
- Decode-cache keys that include decode level/page identity.
- Reuse the current materialized/bounded bitmap for the navigator and current-item preview where practical.
- `ImageCanvasView` remains the interaction shell and owns gestures/hit testing.
- A child `MTKView` renders the bitmap with an on-demand Metal pipeline.
- Quartz/CGContext rendering remains as a functional fallback using source geometry.
- Resource packaging changes required for `.metal` shaders in the release `.app`.
- Correctness tests, packaged-app tests, real-image acceptance tests, and policy A/B benchmarks.
- Separate Quick Look and alternative PNG decoder spikes.

### Explicitly out of scope

- Sidecar/proxy cache in production.
- Native-resolution tiled rendering.
- Custom PNG decoder in production.
- Core Image as the main rendering path.
- Native-detail delivery for oversized images above the 8192 proxy ceiling.
- A LargeImageBackend for random-access native pixels.

## 3. Evidence already established

The following are not open policy questions and should not be re-litigated without contradictory measurements:

- For the 48000×32000 PNG, ImageIO thumbnail output from 64 through 16384 px remains roughly 18 s because inflate + PNG row filtering dominates.
- A bounded 4096/8192 bitmap greatly lowers pixel-buffer footprint even though it does not materially lower first-decode wall time.
- The current lazy-native path can allocate a 5.86 GiB `Image IO` region during real rasterization.
- `Task.cancel()` does not stop the underlying long-running ImageIO decode for the test PNG.
- Metal improves interaction cost dramatically after a bitmap exists; it does not accelerate PNG decompression.
- On-demand Metal is preferred over a permanent 60/120 Hz loop for a static viewer.
- RSS alone is not a valid pixel-buffer acceptance metric for this workload because the 1.93 GiB compressed source can be mmap-resident.

## 4. Design principles

### 4.1 One authoritative source geometry

`ImageDescriptor.displayPixelSize` remains the authoritative logical size of the source image. No second independent `sourcePixelSize` state is introduced.

The decoded `CGImage.width/height` describes only the bitmap currently used for rendering.

Example:

```text
source geometry:   48000 × 32000
render bitmap:      8192 × 5461
```

Viewport math, Fit, Fit Width, 100%, normalized center, panning bounds, and navigator geometry all use source geometry. Rendering maps the render bitmap over that logical source rectangle.

This preserves the existing meaning of 100%: one source-image pixel corresponds to one physical display pixel. An oversized bounded image may become undersampled at high zoom; native-detail delivery belongs to a later LargeImageBackend.

Concrete consumers that must stop treating bitmap dimensions as source dimensions include at least:

- `ImageCanvasView.imagePixelSize` and every Fit/pan/rotate/zoom calculation derived from it.
- The CGContext draw rectangle in the Quartz path.
- Navigator sizing in `ViewerViewController.regenerateNavigatorPreview`.

Thumbnail cell layout remains bitmap-local and must not be converted to source geometry merely because the main canvas is.

### 4.2 Shared oversized predicate

Define one pure policy helper:

```text
isOversized(sourcePixelSize) := max(width, height) > 8192
```

This single predicate controls all giant-image safety rules that depend on the 8192 source threshold:

- main image uses bounded decode instead of native resolution;
- oversized previous/next main-image preload is disabled;
- non-current oversized drawer items do not start the expensive ImageIO thumbnail path in this iteration.

Do not duplicate slightly different `>8192` rules in the controller, decoder, and drawer.

### 4.3 Event-driven GPU rendering

Metal is introduced for interaction, not PNG decompression.

The Metal view runs with:

```swift
isPaused = true
enableSetNeedsDisplay = true
```

A frame is requested only when image content, viewport transform, view size, backing scale, drawable/color state, or relevant background state changes.

No permanent 60/120 Hz loop is allowed for a static image.

## 5. Main decode policy

### 5.1 Source long edge <=8192: native resolution, explicit materialization

A normal image up to and including 8192 pixels on its long edge keeps native resolution so ordinary photographs do not become permanently soft at 100%.

However, the app must not publish the lazy `CGImageSourceCreateImageAtIndex` result directly to the canvas. Cache flags alone are not considered proof of materialization.

The intended candidate path is:

```text
CGImageSourceCreateImageAtIndex
    -> lazy source CGImage
    -> background CGContext draw into a known 8-bit render layout
    -> CGContext.makeImage()
    -> materialized CGImage delivered to cache/renderer
```

The materialization context must preserve the source `CGColorSpace`; normalization of byte layout must not silently convert Display-P3 to sRGB.

Explicit prohibitions:

- Do not rely on `kCGImageSourceShouldCache` or `kCGImageSourceShouldCacheImmediately` as the materialization mechanism.
- Do not use `CGImageSourceCreateThumbnailAtIndex(maxPixelSize >= sourceLongEdge)` as the native materialization mechanism.

**Resolved by the A-series gate (§17.5): A3 is the frozen mechanism.** Measured on an incompressible 8192×5461 PNG, A1 (lazy result plus cache flags) pays the entire decode *inside the renderer's first draw* — 0.507 s — and does roughly twice the total work, because the create-time decode is never reused (CPU 1.02 s vs A3's 0.63 s; energy 5416 mJ vs 3020 mJ). A2 (native-sized thumbnail) costs 1.5× A3's peak footprint (0.502 GiB vs 0.337 GiB) and is prohibited for oversized sources anyway (7.45 GiB on the investigation image). On the giant the cache flags were additionally **non-deterministic**: identical options produced a 0 ms create in one run and a 20.6 s create in another, so their prohibition is a correctness requirement, not a style preference.

Materialization must be **observable**, not self-reported: the delivered bitmap's first renderer draw must not re-enter `PNGReadPlugin`/`inflate`, and must not re-materialize at a different destination size (A6).

### 5.2 Source long edge >8192: bounded ImageIO decode

For oversized sources, use:

```text
kCGImageSourceCreateThumbnailFromImageAlways = true
kCGImageSourceCreateThumbnailWithTransform = true
kCGImageSourceThumbnailMaxPixelSize = budget
kCGImageSourceShouldCacheImmediately = true
```

The hard maximum output long edge is 8192.

The thumbnail transform is responsible for source orientation on the bounded path. The existing full-size CGContext orientation copy must not run after a transformed thumbnail has already been produced.

Oversized sources must never silently fall back to unbounded native decode in this iteration.

### 5.3 Oversized decode buckets

For oversized images, stable buckets are:

```text
1024, 2048, 4096, 8192
```

The initial current-image requirement remains:

```text
required = ceil(max(canvasWidth, canvasHeight) × backingScale × 1.5)
budget   = min(nextBucketAtOrAbove(required), 8192)
```

The overscan factor is fixed at 1.5 in this iteration.

The bucket helper is pure and unit-tested.

**Bucket base: resolved by E1 (§17.5) — the formula above stays.** It can never undersample, and its extra density relative to a displayed-image-size formula is exactly the zoom headroom available before a level change; every level change costs a full, uncancellable stream decode (18.1–18.5 s measured). The worst case is accepted and documented: in short-wide window geometries the view-sized formula can select 8192 where a displayed-size formula would select 2048 (170.7 MB vs 10.7 MB bitmap; 0.756 GiB vs 0.098 GiB transient footprint). Removing that waste requires a cheap level-upgrade path, which this iteration does not have.

## 6. Data model changes

### 6.1 `DecodedImageHead`

`DecodedImageHead` continues to carry:

- rendered/materialized `CGImage`
- `ImageDescriptor`
- metadata

Consumers use:

```swift
head.descriptor.displayPixelSize   // logical/source dimensions
head.image.width / height          // render-bitmap dimensions
```

The old incidental invariant `head.image dimensions == descriptor.displayPixelSize` is no longer generally valid. Existing tests/comments that imply it is universal must be narrowed to native-resolution cases.

### 6.2 `DecodeTarget`

`DecodeTarget.maxPixelSize` becomes a real output budget for oversized ordinary still images and TIFF pages, not only an ICO representation hint.

ICO retains representation-selection semantics. If no ICO representation satisfies a requested budget, preserve the existing representation-selection behavior rather than silently introducing a new resampling policy.

Multi-page TIFF retains `pageIndex` semantics.

Animated giant GIF/WebP frame budgeting is explicitly not solved in this iteration and must be documented as a known limitation.

Measured so the limitation is not hypothetical (E5, §17.5): playing a 1 MPixel, 30-frame GIF in the current app runs at **15.9 fps** against a nominal 25 fps, frame periods p95 = 121 ms, **249 mJ per drawn frame** (3.9 W over a 20 s window), main-thread ping p95 = 98 ms / max 107 ms. Frame decoding stays off the main thread, but the animation path is not free and must not regress.

### 6.3 Cache identity

Cache identity becomes conceptually:

```text
URL + pageIndex + decodeLevel
```

Animation-frame identity also includes frame index.

Exact level matching is the default. A smaller preload level must not be assumed to satisfy a later larger current-image request.

Cost remains actual render-bitmap bytes (`bytesPerRow × height`), not source dimensions.

## 7. Pixel layout and color

The Metal upload path must inspect the actual `CGImage` layout rather than assume every ImageIO output has the same component order.

For common 8-bit RGBA/BGRA inputs:

- choose a compatible `MTLPixelFormat` from `bitmapInfo`, `alphaInfo`, bits-per-component, and bits-per-pixel;
- avoid an unnecessary full-size normalization copy when a compatible layout can be uploaded directly;
- preserve the source color space.

For unsupported/exotic layouts (for example some 16-bit, float, or indexed forms), either normalize explicitly with a tested conversion path or fall back to Quartz. Incorrect color is not an acceptable Metal fallback mode.

## 8. Avoid redundant source-stream work

Rules already accepted:

- Navigator preview for the current image is generated from the current materialized/bounded bitmap, never by re-opening the original source.
- Current sidebar preview is generated/replaced from the current main bitmap, never by independently decoding the same giant source again.
- Oversized previous/next **main-image preload is disabled**.
- Non-current oversized drawer items do not start the expensive full-stream ImageIO thumbnail path in this iteration; they keep a placeholder until a cheaper policy is available.
- Placeholder behavior must not alter selection-border semantics or hit testing.

The dimension/probe mechanism is **C2 from §14.1**: on-demand header probing for current/preload-candidate/drawer-visible items with a small dimension cache. Byte size may order probes but never classify oversized status. Ordinary folder scanning remains lightweight unless dimension sorting explicitly requests a folder-wide fill.

## 9. Metal rendering architecture

### 9.1 Component boundaries

Add:

```text
PicViewMac/Viewer/
  ImageCanvasView.swift          existing interaction shell
  MetalCanvasSurface.swift      MTKView subclass/host surface
  MetalImageRenderer.swift      device, queue, pipeline, texture, draw
  MetalLibraryLocator.swift     non-trapping resource lookup
  ImageShaders.metal            vertex + fragment shader
```

`ImageCanvasView` remains the public interaction surface. The child `MTKView` does not become the gesture owner.

### 9.2 Renderer inputs

The renderer receives:

- render `CGImage`
- authoritative source/display pixel size
- `ViewportState`
- logical view size in points
- `drawableSize` in pixels
- backing scale
- background/render state

The bitmap uploads only when content changes. Zoom/pan/rotate/mirror update transform state only.

### 9.3 Geometry and Retina rule

The textured quad represents the full logical source rectangle. UVs address the render texture.

`ViewportState` remains the sole viewport model.

NDC/drawable conversion uses `MTKView.drawableSize` in pixels. Logical source/view geometry starts in points and is converted using the backing scale deliberately. Do not mix point dimensions and drawable pixel dimensions implicitly; tests must catch the classic Retina 2×/0.5× sizing error.

The transform preserves Fit, Fit Width, 100%, Fit ×2, pointer-centered zoom, normalized-center panning, quarter-turn rotation, and horizontal mirror.

### 9.4 Minification quality

Large minification must not regress visibly below the current Quartz `.high` intent.

Use mipmapped textures with a linear min/mag filter and `mipFilter = .linear`. Do not use explicit shader LOD in a way that bypasses the mip chain.

Mipmap memory is budgeted at approximately 4/3 of base texture memory (for example an 8192 proxy is roughly 227 MiB of texture storage rather than 171 MiB base-only).

**Resolved by the D-series gate (§17.5): mipmaps are mandatory.** Bilinear minification without a mip chain regressed against the current Quartz `.high` renderer on real content (shimmer 1.53×/1.93×/2.61× of the reference at 1.7×/3.7×/11.3× minification; up to 41× on a 1-px checkerboard) and inflated high-frequency detail (detail 39.0 vs the reference's 22.8). Mipmapped linear sampling was at parity or better (0.85×–1.04× of the reference's shimmer) and was also *faster* on the GPU (0.49–1.23 ms vs 0.62–2.62 ms per frame), because sampling smaller mips is cache-friendlier. Cost: +33 % texture memory (227 MiB vs 170.7 MiB at the 8192 bucket) and 3–7 ms one-time generation.

**Proxy magnification (D6, §17.5): linear.** For a proxy whose texels cover ~5.9 source pixels, nearest magnification measured worse on every axis against ground truth: RMSE 34.49 vs linear's 31.78 at 6× on the investigation image's proxy (24.61 vs 22.90 at 4× on a photo), and it added 2.2–5.6 % hard-edge pixels — a visible block grid — where linear left 0.0–0.1 %. No content class in the measured set favoured nearest. The real quality lever at high zoom is a level upgrade, not the filter: until a LargeImageBackend exists, linear magnification plus the honest undersampling statement in §4.1 is the policy.

### 9.5 MTKView lifecycle

Use default `framebufferOnly = true` unless a demonstrated renderer requirement forces otherwise.

`MTKView` remains on-demand:

```swift
isPaused = true
enableSetNeedsDisplay = true
```

Call `setNeedsDisplay` for new bitmap, viewport changes, resize/layout, backing-scale changes, drawable/color changes, and render-affecting appearance/background changes only.

**Level stability across resize and backing-scale changes (E2, §17.5).** Only oversized sources have decode levels, so for ≤8192 sources resizing and display changes are free. For oversized sources, a resize that crosses a bucket boundary requires a new bounded decode: 18.1–18.5 s, uncancellable. Policy:

- never recompute a decode level during an active drag;
- debounce ~300 ms after the resize settles;
- upgrade only when the current bitmap is undersampled (fewer than 1 texel per backing pixel at the current zoom);
- keep showing the current bitmap until the replacement is ready; never blank the canvas;
- shrinking the window never re-decodes: the smaller requirement is already satisfied by the existing bucket.

## 10. Quartz fallback

Quartz remains a first-class fallback, not a debug-only path.

Fallback conditions include:

- no usable `MTLDevice`;
- Metal library/pipeline failure;
- texture creation failure;
- unsupported pixel/color configuration.

Critical geometry rule:

> Quartz fallback draws the render bitmap into the **logical source rectangle**, not a rectangle sized from `bitmap.width/height`.

Therefore a 8192×5461 proxy for a 48000×32000 source has the same Fit/100%/pan geometry as the Metal path.

Fallback may never re-open or publish an oversized lazy native source merely because Metal failed.

## 11. Shader/resource lookup and packaging

Do not call a generated `Bundle.module` accessor from the runtime fallback path if missing resources can trap.

Implement a non-trapping `MetalLibraryLocator` whose search order mirrors the useful SwiftPM resource locations, including development/test overrides and packaged-app locations, conceptually:

1. package-resource override used by development/test when available;
2. `Bundle.main.resourceURL`;
3. framework/test bundle resource location (`Bundle(for:)` style lookup);
4. `Bundle.main.bundleURL` fallback where appropriate.

Failure returns `nil` and selects Quartz. It must never `fatalError` merely because the renderer resource bundle is absent.

The release script must copy the SwiftPM resource bundle/compiled Metal library into the packaged app's `Contents/Resources`.

`verify-release.sh` must test both:

- packaged app can locate/create the Metal pipeline;
- a deliberately missing-resource test path remains launchable and selects Quartz rather than trapping.

## 12. Loading state and responsiveness

A long bounded PNG decode is expected to remain roughly 18 s on the investigation file. During that interval:

- the app must remain event-loop responsive;
- it shows an explicit loading/placeholder state instead of publishing a lazy native image and then freezing during CA commit;
- the previous valid image or neutral placeholder policy must be deterministic and tested.

Acceptance uses main-thread ping latency, not time-to-image, as the responsiveness metric. The initial target is p95 main-thread ping stall <100 ms during background decode/zoom activity, with the old multi-second CA stall as the failure class being eliminated.

## 13. Preload/cache policy: resolved by the B-series benchmark

The measurement is in §17.5. The candidates below are retained as the evaluated set, with their measured outcomes.

### 13.1 Shared conclusions

All reviewers agree:

- Oversized (>8192) main-image neighbor preload is disabled.
- A preload that uses a lower decode level than the eventual current request cannot satisfy an exact-level cache lookup; it should not be justified as a future cache hit.
- Raising memory use for speculative preload is not automatically acceptable on a 16 GB Mac.
- Preload policy must account for actual materialized bitmap cost, not compressed file size.

### 13.2 Policy candidates evaluated (B0–B4)

**Candidate B0 — no preload**

- Lowest speculative CPU/memory.
- Worst expected sequential-navigation latency when images could have been prefetched cheaply.

**Candidate B1 — fixed two-neighbor preload under existing 384 MiB cache**

- Same-level prev + next when requests fit.
- Risks immediate `NSCache` eviction for large native entries and may waste decode work.

**Candidate B2 — cost-aware 384 MiB policy (GPT proposal)**

- Preload only exact-current-level images.
- Estimate/measure decoded cost and choose 0, 1, or 2 neighbors so current + speculative working set stays within the cache budget/safety margin.
- Does not enlarge cache merely to support speculation.

**Candidate B3 — enlarged cache policy (Fable review alternative)**

- Increase cache capacity enough to hold more large native current/neighbor images when measurements show strong navigation benefit.
- Trades memory pressure for higher hit probability.

**Candidate B4 — lower-level preload (negative-control candidate)**

- Included specifically to measure whether page-cache warming provides any useful benefit even though exact-level bitmap cache misses are guaranteed.
- It must not be selected merely because it uses less bitmap memory.

### 13.3 Decision

**B3 — enlarged cache (`totalCostLimit` 768 MiB) with the oversized-preload prohibition — is the production policy.**

Evidence (B-series, §17.5):

- For ≤8192 images preload cuts median navigation latency 4–7× (0.151 s → 0.022–0.038 s) and is **energy-neutral** (total 4648 mJ for B0 vs 4731 mJ for B1 on the normal set), because the same decode has to happen either way — preload only moves it earlier.
- Above the 384 MiB budget, B1 and B2 spend ~3.4 s CPU and ~15 J per workload preloading entries that `NSCache` evicts before use, and end at roughly 1.8–2× B0's total energy. B2's cost gate cannot prevent the eviction of the entry it did preload.
- B3 over the same workload keeps 2/2 preload hits, performs 1 decode instead of 3, and lands at B0's energy (9000 mJ vs 9271 mJ) with 8× lower latency: the enlarged budget converts wasted speculation into useful work.
- B4 (lower-level preload) is **falsified**: 0 preload hits, navigation latency worse than no preload at all (0.169 s vs 0.151 s), and 2.1× B0's energy.
- B0 is rejected: it gives up 4–7× navigation latency for no memory benefit.

Working-set consequence — bound the **DecodeCache** by construction, do not trust `NSCache`. Measured: 8192 + 2×4096 = 256 MB is retained under 384 MiB; native 8192×8192 ×3 = 768 MB was also retained; but current 8192×8192 + neighbour 8192×5461 = 426.7 MB (just over budget) caused `NSCache` to evict **the on-screen entry** while keeping the later one. With a 768 MiB cache budget and the ≤256 MB per-entry ceiling for native ≤8192 sources, current + 2 neighbours is bounded at ≤768 MiB **inside the bitmap cache**.

The 768 MiB figure is **not** the whole application's large-image working-set ceiling. Metal adds a mipmapped texture for the current image (approximately 4/3 of base texture memory; up to ~341 MiB for an 8192×8192 RGBA8 image), so an extreme current+two-neighbour cache plus current Metal texture can approach ~1.1 GiB before AppKit, metadata, source mmap pages, and other allocations. The integrated cache+GPU working set must therefore pass §15.8 before release; if it causes sustained memory pressure or unacceptable swap growth, the 768 MiB cache limit is revisited with measured evidence rather than assumed safe from the B-series cache-only result.

## 14. Dimension/oversized detection policy: resolved by the C-series benchmark

Current ordinary folder scanning intentionally leaves `FolderItem.pixelSize` unset unless dimension sorting asks for it. Measurement (§17.5) shows the header probe is cheap: 0.08 ms per small file, 0.71 ms per 1.9 GB file (warm page cache), 0.373 s for a 5000-file folder, all off the main thread.

Policy candidates:

**C1 — eager folder-wide dimension fill (simplicity control; no reviewer advocated it)**

- Every scanned supported image gets header dimensions.
- Oversized decisions become immediate later.
- Potentially increases folder-open latency for hundreds/thousands of files.

**C2 — on-demand header probe + small dimension cache (GPT proposal)**

- Probe current, preload candidates, and drawer-visible items only when the size is actually needed.
- Cache the result for reuse.
- Preserves cheap directory enumeration but adds asynchronous probe coordination.

**C3 — byte-size coarse filter, then header probe**

- Uses already-known file size to skip some probes, then confirms actual pixel dimensions when needed.
- Must be proven sufficiently accurate/safe; byte size alone can never be the final oversized decision.

### 14.1 Decision

**C2 — on-demand header probe with a dimension cache — is the production policy, with byte size permitted only to *order* probes.** C1 remains the behaviour when the user sorts by dimensions (the existing scanner path already does exactly this, off the main thread) and is the fallback if C2's coordination proves troublesome. The two are not distinguishable on cost alone at this scale (0.373 s vs 0.002 s, both invisible); C2 wins on the unmeasured risk of slow or network volumes, where per-file header reads become seeks.

**C3 is rejected in both directions — byte size is not a sound oversized test for PNG.** `noise-8192x5461.png` is 148 MB but **not** oversized; `solid-12000x12000.png` is 2.5 MB but **is** oversized. The one-way variant misclassified 2/5 files in the adversarial mixed folder; the two-way variant misclassified 5/5 without probing anything.

## 15. Test strategy — correctness and regression

### 15.1 Decode/materialization tests

Add tests proving:

- oversized single-representation PNG/JPEG/TIFF honor `DecodeTarget.maxPixelSize`;
- bounded output long edge never exceeds the selected bucket;
- `descriptor.displayPixelSize` remains the original logical size;
- bounded bitmap dimensions may differ from source display dimensions while preserving aspect ratio;
- EXIF orientation is applied exactly once;
- Display-P3 remains tagged/preserved through native materialization and bounded decode;
- TIFF page selection still works with a budget;
- ICO representation semantics remain unchanged;
- native <=8192 delivery goes through explicit materialization rather than directly publishing the ImageIO lazy source object;
- a materialized image's first renderer draw does not trigger a second long ImageIO decode/materialization pass.

Do not implement the last two checks as a meaningless self-reported `isMaterialized` flag only; include observable timing/allocation/instrumented-path evidence.

### 15.2 Geometry tests

Use fixtures where source size and render-bitmap size differ substantially. Verify source-geometry behavior for:

- Fit;
- Fit Width;
- 100%;
- Fit ×2;
- pointer-centered zoom;
- pan/clamp;
- navigator rect;
- quarter-turn rotation;
- mirror;
- Quartz fallback mapping;
- Metal mapping;
- Retina backing-scale changes.

### 15.3 Cache tests

Verify:

- distinct decode levels do not alias;
- page/frame identity is included;
- actual decoded bytes drive cost;
- memory-pressure purge semantics remain correct;
- entries whose individual cost exceeds the cache budget behave explicitly (no tests should assume they remain cached);
- exact-level preload hit/miss behavior is observable;
- B3 respects the 768 MiB **DecodeCache** limit; do not treat that value as a whole-app working-set limit.

### 15.4 Renderer tests

Compare Metal and Quartz on small deterministic fixtures for:

- identity;
- zoom;
- pan;
- 90° rotation;
- mirror;
- alpha;
- sRGB;
- Display-P3;
- BGRA vs RGBA layout;
- mipmapped strong minification;
- 1× vs 2× backing scale.

Prefer geometry/pixel invariants and image-quality metrics over brittle full screenshot hashes.

Add a forced Metal failure injection path so Quartz fallback is deterministic in tests.

### 15.5 Resource/package tests

Test:

- development build resource lookup;
- xctest resource lookup;
- packaged `.app` resource lookup;
- packaged DMG path;
- missing Metal resource bundle does not crash and selects Quartz;
- shader/pipeline creation failure selects Quartz.

### 15.6 Drawer/thumbnail safety tests

Test:

- current item reuses the main render bitmap for its thumbnail after main decode;
- navigator reuses the main render bitmap;
- non-current oversized drawer item remains placeholder and does not call expensive thumbnail decode;
- placeholder does not change current-item selection border/hit testing;
- many oversized visible drawer items do not start N parallel full-stream ImageIO decodes;
- C2 identifies oversized items without changing unrelated folder semantics.

### 15.7 Existing regression suite

All existing tests remain green, particularly gesture routing, pointer-centered zoom, drawer pin/unpin geometry, navigator behavior, animated images, multi-page TIFF, thumbnail selection border, and window/layout behavior.

Tests that previously encoded `decoded dimensions == source display dimensions` as a universal invariant must be corrected rather than deleted.

### 15.8 Integrated DecodeCache + Metal working-set acceptance

The B-series chose a 768 MiB bitmap-cache budget before the production Metal renderer existed. Because the current rendered image also owns a mipmapped GPU texture, implementation validation must measure the composed working set rather than assuming the cache-only number is the application limit.

Run at least these local workloads on the 16 GB target Mac:

- three near-threshold native images around 8192×8192;
- three medium native images around 6000×6000;
- a mixed near-threshold set that exercises current + previous + next preload while the current image owns its mip chain.

Record:

- DecodeCache retained cost and entry count;
- current Metal base-texture and mip-chain allocation;
- process `phys_footprint` and RSS;
- system memory-pressure state and swap growth across the workload;
- navigation latency/cache-hit rate, so memory safety is not improved by accidentally disabling the B3 benefit.

Acceptance:

- DecodeCache retained cost stays <=768 MiB;
- no sustained memory-pressure warning attributable to the viewer workload;
- system-wide swap growth stays <512 MiB across the workload;
- navigation still shows the B3 preload benefit rather than silently evicting the on-screen/current entry;
- if these conditions fail, revise the DecodeCache limit based on the integrated measurement before release. The failure does **not** justify removing mandatory mipmaps, whose quality/performance decision is independently established by D-series data.

## 16. Real 1.9 GiB PNG acceptance

Using `/Users/dgd/Downloads/万萝图/万萝图.png` locally (never committed):

- verify the source SHA-256 before the run and after the run;
- main render bitmap long edge <=8192, and within one bucket step below the requested budget, and the first render bitmap is actually present (upper bounds alone would let a permanent-placeholder implementation pass);
- no 48000×32000 full-size native bitmap reaches canvas/renderer;
- navigator/current sidebar do not independently re-decode the source after the main bitmap exists;
- oversized neighbor main preload stays disabled;
- oversized non-current drawer items do not launch full-stream thumbnail decodes;
- static Metal renderer does not continuously draw;
- zoom/pan remain responsive after the render bitmap exists;
- main-thread ping p95 remains <100 ms during background decode/interaction, measured separately from time-to-image;
- animation playback does not regress against the recorded baseline (1 MPixel 30-frame GIF: 15.9 fps, 249 mJ per drawn frame, ping p95 98 ms);
- `phys_footprint`, not RSS, is the primary live pixel-buffer metric;
- sample `vmmap` while decode/render is active (for example around t+5 s and/or t+10 s) and assert there is no >1 GiB anonymous `Image IO` region analogous to the old 5.86 GiB allocation.

Known baseline:

```text
first real pixels: ~19.6 s
native ImageIO footprint: 5.86 GiB
peak RSS: 7.8–9.0 GiB
lazy-native interaction: ~0.05 fps
```

The implementation is expected primarily to reduce memory/swap and interaction cost, not the ~18 s first bounded PNG decode itself.

**E4 baseline** (measured on `123d943` with the instrumented copy, opening the investigation image with drawer and navigator visible; reproduce with `benchmarks/LargeImagePolicyBench/run-e4.sh`):

```text
full-stream traversals: 4      (canvas rasterization ×2, navigator preview ×1, sidebar 300 px thumbnail ×1)
open energy:            136.6 J
main-thread stall:      20.9 s (max main-queue ping latency)
peak RSS:               6.885 GiB
time to published image: 0.239 s (the image is lazy — that is the trap)
```

Post-implementation acceptance targets, measured with the same command (`run-e4.sh <rev>`): full-stream traversals **== 1**, open energy **≤ ~70 J** (one bounded decode), main-thread ping p95 **< 100 ms**, and no `Image IO` region > 1 GiB. RSS is expected to stay around 2.0–2.7 GiB because 1.93 GB of the source is mmapped; that is an expected floor, not a failure.

## 17. Policy benchmark harness

Performance policy choices live in the dedicated benchmark harness at `benchmarks/LargeImagePolicyBench/` (see its `README.md`; build with `build.sh`). It is not part of the production target: no `Package.swift` change, nothing linked into the app.

Every benchmark records enough raw output to reproduce the decision. Do not reduce results to a single undocumented score.

**Decision-criteria requirements (added after the reviewer criteria audit).** Each series must state, per candidate, which measurement would support it and which would falsify it; a benchmark that can only produce a single winner score is not acceptable. Series-specific requirements follow in each subsection.

### 17.1 A-series — materialization validation

Compare at least:

- A1: `CreateImageAtIndex` with relevant cache flags, then first real draw;
- A2: native-sized `CreateThumbnailAtIndex`, then draw;
- A3: `CreateImageAtIndex -> background CGContext materialize -> draw materialized result`.

Use representative normal/native-sized inputs (for example ~4K, ~6K, and <=8192) plus the giant image only as a safety negative control where appropriate.

Requirements:

- split the decision by input class: ≤8192 → choose a materialization mechanism; >8192 → the native-materialize candidate must be **asserted unusable**, not scored, so a cheap-but-lazy candidate cannot win an aggregate;
- the decisive member of the ≤8192 class is an **incompressible 8192-long-edge PNG** (compressible or solid fixtures decode almost instantly and hide the stall); the class must also contain a JPEG (DCT decodes ~10× faster) and results must be reported per format;
- the giant is a safety negative control only.

Measure:

- create/materialize wall time;
- first renderer draw time after publication, plus a draw at a *different* destination size (re-materialization);
- peak `phys_footprint`;
- observable `Image IO` regions;
- color space and pixel layout before/after;
- whether a second expensive decode occurs during first Quartz/Metal draw;
- an observable materialization proof (`vmmap` at publication; a `sample` stack during the post-publication draw must contain no `PNGReadPlugin`/`inflate` frames), not a self-reported flag.

A3 is the frozen mechanism (§5.1); the numbers below are from this gate's run.

### 17.2 B-series — preload/cache arbitration

Image set must include at least:

- ordinary photo around 4032×3024;
- medium image around 6000×4000;
- near-threshold image around 8K;
- the 48000×32000 investigation PNG as oversized/no-preload control.

Navigation workloads:

```text
sequential: 1 -> 2 -> 3 -> 4 -> 5
ping-pong:  1 -> 2 -> 1 -> 2 -> 3
random:     1 -> 8 -> 3 -> 12 -> 2
```

Compare B0–B4 from §13.2.

Record:

- navigation-to-first-render latency;
- cache hit/miss count by exact level;
- decode count;
- cache eviction count;
- speculative/stale decode CPU time;
- peak `phys_footprint`;
- energy where available;
- number of concurrent decode jobs;
- swap/memory-pressure symptoms;
- whether lower-level preload provides any useful page-cache warming despite bitmap-cache miss;
- per-task CPU/energy measured **inside** each speculative task, so work completed after cancellation is counted (the giant's decode still costs 62.8 J after `Task.cancel()`);
- results reported **per format and per class** — never aggregated, because preload cannot help oversized images (18 s either way) and helps cheap ones a lot;
- a run with the drawer open, so thumbnail work contends with preload work.

Hard constraints before latency comparison (numeric):

- oversized >8192 gets zero main-image neighbor preload;
- no swap storm attributable to the policy: system-wide swap growth <512 MB across the workload;
- no policy may rely on immediately-evicted entries as useful cache state (verify with an explicit retention probe);
- stale speculative decode must not dominate foreground work: speculative CPU <25 % of foreground CPU;
- concurrent decode jobs <=2;
- bitmap DecodeCache retained cost <=768 MiB for B3.

The 768 MiB number here applies to the bitmap cache only. The integrated production working set with mandatory Metal mipmaps is validated separately by §15.8; B-series cache-only results must not be used to claim a 768 MiB whole-app ceiling.

A candidate that wins latency while violating any of these is rejected, not ranked.

Among policies satisfying the hard constraints, choose based on reproducible navigation benefit versus memory/energy cost. A tiny latency win does not justify hundreds of MiB of extra resident working set.

### 17.3 C-series — dimension probe arbitration

Use folders of approximately 100, 1000, and 5000 supported images where practical.

Compare:

- C1 eager folder-wide header dimension probing;
- C2 on-demand current/visible/candidate probing with dimension cache;
- C3 byte-size coarse filter followed by required header confirmation.

Requirements:

- include an **adversarial mixed folder**: one small-file giant (a few MB that is oversized — e.g. a 12000×12000 solid PNG) and one large-file non-oversized image (e.g. a 148 MB 8192×5461 PNG). Byte size must not be able to classify either one; a filter that decides "not oversized" from small bytes must fail this case;
- byte size may be used only to *order* probes, never to decide;
- folder-open latency must be measured on a cold-ish cache.

Record:

- folder-open latency;
- time until drawer is interactive;
- number of header probes;
- CPU/I/O;
- memory;
- oversized classification correctness;
- behavior when sorting by dimensions;
- behavior when rapidly scrolling the drawer.

Do not replace the existing lightweight ordinary scan behavior unless the evidence justifies it.

### 17.4 D-series — minification quality and mipmaps

Compare:

- D1 Metal bilinear only;
- D2 Metal mipmapped with linear mip filtering;
- D3 Quartz `.high` reference (and any equivalent prefiltered candidate if proposed).

Use synthetic checkerboard/fine-line/text fixtures plus real photos at approximately 4:1, 8:1, 16:1, and 32:1 minification.

Requirements:

- alongside any single-frame metric, record a **two-frame shimmer metric** (RMS difference between renders at sub-pixel offsets), because a single-frame metric can be won by a blurrier candidate and aliasing is a temporal artifact;
- evaluate at app-reachable minification (Fit ≈ 2.0–4.3×, 0.5× fit, 0.25× fit ≈ 8–17×); 32× is a stress case only;
- verify the harness is unbiased with a 1.0× sanity check (Metal must match the Quartz reference there).

Record:

- visible aliasing/shimmer;
- deterministic image-quality metric where useful;
- GPU frame time;
- texture memory;
- mip generation time.

The selected Metal path must not show a material quality regression versus the Quartz reference at strong minification.

### 17.5 Gate results (measured 2026-09-17, MacBook Air M4 / 16 GB, macOS 27.0)

Source for every row: the harness in `benchmarks/LargeImagePolicyBench/` (see its README for the exact commands). Fixtures are generated, never committed; the 1.9 GiB investigation PNG is referenced in place and its SHA-256 is verified before and after.

**A — materialization (decides §5.1).** Incompressible PNGs, canvas long edge 3200 px.

| input | mode | delivered_in | first_draw | peak footprint | CPU | energy |
|---|---|---|---|---|---|---|
| 8192×5461 PNG | A1 lazy + cache flags | 0.482 s | **0.507 s (decode inside draw)** | 0.214 GiB | 1.02 s | 5416 mJ |
| 8192×5461 PNG | A2 native thumbnail | 0.504 s | 0.062 s | 0.502 GiB | 0.63 s | 3194 mJ |
| 8192×5461 PNG | **A3 background materialize** | 0.498 s (0.495 s materialize) | **0.058 s** | 0.337 GiB | 0.63 s | 3020 mJ |
| 6000×4000 PNG | A1 / A3 | 0.254 / 0.267 s | 0.279 / 0.038 s | 0.136 / 0.174 GiB | 0.59 / 0.35 s | 2915 / 1745 mJ |
| 4032×3024 PNG | A1 / A3 | 0.132 / 0.136 s | 0.152 / 0.028 s | 0.097 / 0.104 GiB | 0.35 / 0.22 s | 1598 / 1093 mJ |
| 4032×3024 JPEG | A1 / A3 | 0.038 / 0.059 s | 0.030 / 0.028 s | 0.096 / 0.099 GiB | 0.11 / 0.11 s | 552 / 580 mJ |
| giant (A5 control) | A1 | 20.620 s | 19.017 s | **5.78 GiB** | 51.3 s | **214 J** |
| 12000×9000 | A2 native thumb | 0.226 s | 0.127 s | **1.204 GiB** | 0.48 s | 2899 mJ |

A3-native on the giant was deliberately not run: the source bitmap plus the destination copy is ~11.7 GiB, and the 2× relationship is confirmed by the 12000×9000 row.

**B — preload/cache (decides §13).** Per-task CPU/energy accounting, so post-cancellation work is included.

normal set (4032 PNG, 4032 JPEG, 6000 PNG, 8192 PNG; sequential; 0.6 s dwell):

| policy | lat p50 | preload hits | decodes | speculative CPU | total energy |
|---|---|---|---|---|---|
| B0 | 0.151 s | 0 | 4 | 0 | 4648 mJ |
| B1 (384 MiB) | 0.038 s | 3 | 1 | 0.81 s | 4731 mJ |
| B2 (cost-aware 384 MiB) | 0.022 s | 3 | 1 | 0.84 s | 4329 mJ |
| B3 (768 MiB) | 0.036 s | 3 | 1 | 0.81 s | 4573 mJ |
| B4 (lower level) | 0.169 s | **0** | 4 | 1.50 s | **9803 mJ** |

budget-busting set (native bitmaps 256 + 170.7 + 196 MB > 384 MiB):

| policy | lat p50 | preload hits | decodes | speculative CPU | total energy |
|---|---|---|---|---|---|
| B0 | 0.546 s | 0 | 3 | 0 | 9271 mJ |
| B1 | 0.062 s | 1 | 2 | 3.40 s | 17099 mJ |
| B2 | 0.056 s | 1 | 2 | 3.50 s | 16807 mJ |
| **B3 (768 MiB)** | 0.065 s | **2** | **1** | **1.07 s** | **9000 mJ** |
| B4 | 0.568 s | 0 | 3 | 3.46 s | 18790 mJ |

Cache-working-set probes (`cacheplan`): bounded working set 256 MB retained under 384 MiB; native 8192²×3 = 768 MB retained; current 8192²+8192×5461 = 426.7 MB → **the on-screen entry was evicted**; memory-pressure purge keeps the current entry. A cancelled giant decode still consumes 62.8 J / 19.4 s.

**C — dimension probe (decides §14).**

| scenario | policy | cost | probes | misclassified |
|---|---|---|---|---|
| 5000 small PNGs | C1 eager | 0.373 s | 5000 (0.08 ms each) | 0 |
| 5000 small PNGs | C2 on-demand (20 visible) | 0.002 s | 20 | 0 |
| 30 × 1.9 GB clones | C1 eager | 0.002 s | 30 (0.71 ms each) | 0 |
| adversarial mixed folder | C3 one-way byte filter | ~0 | 3 | **2/5** |
| adversarial mixed folder | C4 two-way byte filter | ~0 | **0** | **5/5** |

**D — minification (decides §9.4).** Real 8192×5461 photo, offscreen render, shimmer = RMS between two sub-pixel offsets:

| minification | variant | RMSE vs Quartz | shimmer | shimmer ratio | GPU ms |
|---|---|---|---|---|---|
| 1.7× | Quartz `.high` | 0 | 11.41 | 1.00× | – |
| 1.7× | D1 bilinear no-mip | 11.55 | 17.42 | **1.53×** | 1.24 |
| 1.7× | D2 mipmapped | 6.67 | 11.90 | 1.04× | 1.23 |
| 3.7× | D1 / D2 | 12.01 / 6.19 | 20.85 / 9.21 | **1.93×** / 0.85× | 2.62 / 0.51 |
| 11.3× | D1 / D2 | 8.16 / 2.88 | 11.89 / 4.01 | **2.61×** / 0.89× | 1.15 / 0.49 |

Sanity check: at 1.0× both Metal variants match Quartz (RMSE 0.32). 1-px checkerboard stress: D1 up to 54.7 shimmer vs the reference's 1.32 (41×).

**E1 — bucket base (decides §5.3).** Over 5 window geometries × 5 image shapes: the view-sized formula never undersamples and yields 2.1–8.2 texels per backing pixel at Fit (vs 1.5–2.0 for a displayed-size formula), i.e. it buys 2–8× zoom headroom before a level change. Identical at full screen; up to 16× more bitmap in short-wide windows.

**E2 — resize/level stability (decides §9.5).** Derived from measured level-change cost (18.1–18.5 s per bucket, uncancellable); only oversized sources are affected.

**D6 — proxy magnification (decides §9.4).** Proxy built by high-quality downsampling, rendered at N× and compared against the original pixels:

| case | magFilter | RMSE vs truth | blockiness | detail |
|---|---|---|---|---|
| photo, 4× | nearest | 24.61 | 0.0218 | 15.50 |
| photo, 4× | linear | **22.90** | **0.0000** | 2.26 |
| investigation proxy, 6× | nearest | 34.49 | 0.0563 | 13.69 |
| investigation proxy, 6× | linear | **31.78** | **0.0013** | 1.93 |
| fine lines, 4× | nearest / linear | 112.56 / 112.52 | 0.0010 / 0.0000 | 0.16 / 0.06 |

Linear wins on every measured axis; nearest's extra Laplacian is the block grid, not detail.

**E5 — animation frame path (decides the §6.2 limitation wording).** 1 MPixel, 30-frame GIF, 20 s window in the instrumented app:

```text
frames drawn: 313 (15.9 fps vs the 25 fps nominal 40 ms delay)
frame period: p50 56 ms, p95 121 ms, max 137 ms, stdev 29.5 ms
main-thread ping: p50 26 ms, p95 98 ms, max 107 ms
energy: 78.1 J over 20 s = 3.9 W = 249 mJ per drawn frame
peak footprint 0.185 GiB / RSS 0.280 GiB, no oversized traversal
```

**E4 — app budget.** Baseline in §16; pass/fail requires the implementation.

## 18. Quick Look spike

Exploratory only; it does not become a production dependency in this implementation.

Question:

> Can `QLThumbnailGenerator` return a useful preview substantially earlier than the ~18 s ImageIO bounded decode when macOS already has a warm **Quick Look thumbnail cache**, not merely warm filesystem page cache?

Measure cold/warm Quick Look cache, before/after Finder/Quick Look viewing, 2048/4096 requests, wall time, output dimensions, process footprint, and whether the request itself appears to trigger a full PNG decode.

Warm filesystem page cache alone is not a successful result if decode time remains ~18 s.

Success: repeatable materially earlier preview. If the API simply repeats the full decode, do not integrate it.

## 19. Alternative PNG decoder spike

Candidates:

- libpng;
- libspng;
- optionally zlib-ng-backed variants if build complexity remains reasonable.

Use the same giant PNG and compare ImageIO's observed baseline (~112 MB/s compressed stream, ~83 Mpixel/s, roughly 18.1–19.2 s run-to-run) for:

- wall time;
- CPU time;
- peak footprint;
- decode-to-4096/8192 behavior;
- row-wise downsampling feasibility;
- cancellation/checkpoint behavior.

A production candidate must show at least one of:

- >=30% repeatable wall-time improvement; or
- >=5 s repeatable absolute wall-time improvement;

and must not materially worsen peak memory versus the bounded ImageIO path.

The spike must not assume that reading only the first N% of a non-interlaced PNG can produce a complete whole-image preview.

## 20. Reviewer-added test gate

Before implementation planning, the external reviewer (Claude Fable in the current review loop) is explicitly asked to **add tests, not merely review prose**.

Reviewer instructions:

1. Read this revised spec and the diff from the previous spec commit.
2. For each disputed policy (A/B/C/D), identify any test or benchmark case missing from §15–§17 that could falsify either GPT's or Fable's preferred strategy.
3. Add concrete proposed cases under a `Reviewer-added tests` subsection, including input, measurement, and pass/fail interpretation.
4. Prefer tests that distinguish competing policies; do not add redundant happy-path coverage.
5. Identify any benchmark whose current success criterion could accidentally choose a locally fast but globally harmful policy.
6. Explicitly state whether the added tests are blocking for implementation planning or can wait for implementation validation.

### 20.1 Gate status (closed 2026-09-17)

The reviewer-added tests were incorporated and executed; results are in §17.5. Outcomes:

| reviewer test | outcome |
|---|---|
| A4 materialization matrix | run — A3 frozen (§5.1) |
| A5 oversized native materialize | run — threshold held (§5.1) |
| A6 observable materialization | adopted as a test requirement (§15.1, §5.1) |
| B5 cancelled/stale preload cost | run — oversized preload prohibition justified (§13.3) |
| B6 system-level pressure + per-format reporting | adopted into the B-series harness; per-format split kept modular |
| C4 adversarial small-file giant | run — C3 rejected (§14.1) |
| C5 cold-cache probe cost | run — C2 chosen (§14.1) |
| D5 two-frame shimmer | run — mipmaps mandatory (§9.4) |
| D6 proxy magnification | run — linear magnification chosen (§9.4) |
| E1 bucket base | run — formula kept (§5.3) |
| E2 resize/level stability | run — policy added (§9.5) |
| E3 cache working set | run — budget raised to 768 MiB (§13.3) |
| E4 one-traversal + energy budget | baseline captured (§16); pass/fail at implementation |
| E5 animation frame stall | run — baseline recorded, non-regression required (§6.2, §16) |

All A/B/C/D and E-series decisions needed by an implementation plan are resolved; D6 and E5 were closed by measurement rather than deferred. The only remaining gate is E4's post-implementation run, which is inherently a property of the change itself: build, then `run-e4.sh <rev>` and compare against the §16 baseline.

## 21. Error handling

- Decode failure continues through the existing viewer error path.
- Metal initialization/resource/pipeline failure is non-fatal and selects Quartz.
- Missing Metal resources must never trap.
- Oversized bounded-decode failure must not silently fall back to unbounded native rendering.
- Loading-state failure/cancellation must leave the UI responsive and in a deterministic state.

## 22. Revised implementation dependency order

The eventual implementation plan must respect:

1. ~~Run/complete the A/B/C/D policy benchmark gates required to freeze disputed policies.~~ **Done — see §17.5. Policies frozen: A3 materialization, B3 preload/cache (768 MiB), C2 dimension probe, mandatory mipmaps, E1a bucket formula, E2 resize policy.**
2. Source-vs-bitmap geometry separation.
3. Shared oversized predicate and chosen dimension-probe policy.
4. Native materialization path and oversized bounded decode.
5. Cache identity plus chosen preload/cache policy.
6. Navigator/current-preview reuse and oversized drawer protection.
7. Metal renderer, mip/minification policy, and Quartz source-rect fallback.
8. Non-trapping Metal resource lookup and release-resource packaging.
9. Run the integrated DecodeCache + mipmapped-Metal working-set acceptance in §15.8; retain B3 only if the composed memory behaviour is safe.
10. Full correctness/regression/real-image acceptance validation, including E4.
11. Quick Look spike.
12. Alternative PNG decoder spike.

## 23. Success criteria

The design/implementation is successful only when all are true:

- Oversized sources cannot force a native-size canvas bitmap merely to display at Fit.
- Oversized decoded long edge never exceeds 8192.
- Normal <=8192 sources retain native-resolution semantics without publishing a lazy render-time decode to the canvas.
- Source geometry remains exact and existing zoom semantics are preserved.
- Current navigator/sidebar reuse avoids redundant current-source decode.
- Oversized neighbor preload and oversized non-current drawer thumbnail storms are prevented.
- Chosen preload/cache and dimension-probe policies are backed by B/C benchmark evidence, not reviewer preference (B3 / 768 MiB, C2 + probe ordering: §13.3, §14.1).
- The integrated bitmap-cache + mipmapped-Metal working set passes §15.8; 768 MiB is treated as the DecodeCache limit, not a whole-app memory ceiling.
- An open of the investigation image performs exactly **one** full-stream traversal and <= ~70 J of open energy, measured against the §16 baseline (4 traversals, 136.6 J).
- No main-thread stall >100 ms (p95) during background decode, zoom, pan, or window resize; the resize policy in §9.5 is honoured.
- Large-image interaction uses on-demand Metal when available.
- Strong minification meets the D-series quality gate.
- Static images do not run a continuous GPU loop.
- Metal failures fall back safely to source-geometry Quartz rendering.
- Packaged `.app`/DMG builds can load Metal resources; missing resources fall back without crash.
- Main-thread responsiveness and live-memory acceptance pass on the real 1.9 GiB PNG.
- Existing behavioral tests remain green.
- Reviewer-added discriminating tests are resolved before implementation planning (see §20.1).
- Quick Look/decoder spikes remain isolated unless later evidence justifies production adoption.
