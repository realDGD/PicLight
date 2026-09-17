# PicLight Large-Image Bounded Decode + On-Demand Metal Design

Date: 2026-09-17
Baseline: `123d943`
Status: core architecture approved; policy benchmarks and reviewer-added tests required before implementation planning

## 1. Purpose

PicLight currently treats the decoded `CGImage` as both the source-image geometry and the renderable bitmap. That works for normal images but fails badly for extreme images. The investigation image is a 1.929 GiB, 48000×32000, non-interlaced RGBA PNG. On the current path, `CGImageSourceCreateImageAtIndex` returns quickly because the image is lazy, then Core Animation forces a full decode during backing-store rasterization. The measured result is about 19.6 s to first real pixels, a 5.86 GiB `Image IO` footprint, 7.8–9.0 GiB peak RSS, and about 0.05 fps when repeatedly interacting with the still-lazy native image.

This design addresses two independent problems:

1. Bound the bitmap presented to the renderer so a huge source can never force a native-size allocation merely to fit the window.
2. Replace the interactive CGContext resampling path with an on-demand Metal renderer so zoom, pan, rotate, and mirror do not repeatedly rasterize large images on the CPU.

This design does **not** attempt to make a 1.9 GiB PNG decode in sub-second time. The investigation proved that ImageIO thumbnail creation still spends roughly 18 s because PNG inflate + row filtering dominates and scales with the compressed stream, not the requested output dimensions.

A second objective of this revision is to record unresolved policy disagreements explicitly and settle them with repeatable benchmark evidence rather than architectural preference.

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
- Production policy choices for preload/cache and dimension probing until the benchmark gates in §18 complete.

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

The exact materialization implementation still has to pass the A-series validation in §18.1 before it is frozen in the implementation plan.

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

The dimension/probe mechanism used to decide whether a non-current drawer item is oversized remains a benchmarked policy choice in §18.3; ordinary folder scanning must not be made globally expensive without evidence.

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

The first candidate is mipmapped textures with a linear min/mag filter and `mipFilter = .linear`. Do not use explicit shader LOD in a way that bypasses the mip chain.

Mipmap memory is budgeted at approximately 4/3 of base texture memory (for example an 8192 proxy is roughly 227 MiB of texture storage rather than 171 MiB base-only).

Whether mipmaps are an unconditional implementation requirement or may be replaced by an equivalent prefiltered strategy is decided by the D-series quality/performance benchmark in §18.4. The acceptance condition is visual/metric parity sufficient to avoid obvious aliasing or shimmer versus Quartz `.high` at strong minification.

### 9.5 MTKView lifecycle

Use default `framebufferOnly = true` unless a demonstrated renderer requirement forces otherwise.

`MTKView` remains on-demand:

```swift
isPaused = true
enableSetNeedsDisplay = true
```

Call `setNeedsDisplay` for new bitmap, viewport changes, resize/layout, backing-scale changes, drawable/color changes, and render-affecting appearance/background changes only.

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

## 13. Preload/cache policy: unresolved debate, benchmark required

This section intentionally records the disagreement instead of prematurely choosing one policy.

### 13.1 Shared conclusions

All reviewers agree:

- Oversized (>8192) main-image neighbor preload is disabled.
- A preload that uses a lower decode level than the eventual current request cannot satisfy an exact-level cache lookup; it should not be justified as a future cache hit.
- Raising memory use for speculative preload is not automatically acceptable on a 16 GB Mac.
- Preload policy must account for actual materialized bitmap cost, not compressed file size.

### 13.2 Policy candidates under dispute

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

The B-series benchmark in §18.2 decides the production policy. Until then, no implementation plan may hard-code one of B0–B4 as final.

## 14. Dimension/oversized detection policy: unresolved debate, benchmark required

Current ordinary folder scanning intentionally leaves `FolderItem.pixelSize` unset unless dimension sorting asks for it. The existing `FolderScanner.pixelSize(of:)` header probe is cheap relative to decode, but probing every file in a large directory may still change folder-open behavior.

Policy candidates:

**C1 — eager folder-wide dimension fill (Fable-favored simplicity)**

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

The C-series benchmark in §18.3 decides the production policy.

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
- B-series chosen policy respects its stated working-set limit.

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
- chosen C-series dimension policy identifies oversized items without changing unrelated folder semantics.

### 15.7 Existing regression suite

All existing tests remain green, particularly gesture routing, pointer-centered zoom, drawer pin/unpin geometry, navigator behavior, animated images, multi-page TIFF, thumbnail selection border, and window/layout behavior.

Tests that previously encoded `decoded dimensions == source display dimensions` as a universal invariant must be corrected rather than deleted.

## 16. Real 1.9 GiB PNG acceptance

Using `/Users/dgd/Downloads/万萝图/万萝图.png` locally (never committed):

- verify the source SHA-256 before the run and after the run;
- main render bitmap long edge <=8192;
- no 48000×32000 full-size native bitmap reaches canvas/renderer;
- navigator/current sidebar do not independently re-decode the source after the main bitmap exists;
- oversized neighbor main preload stays disabled;
- oversized non-current drawer items do not launch full-stream thumbnail decodes;
- static Metal renderer does not continuously draw;
- zoom/pan remain responsive after the render bitmap exists;
- main-thread ping p95 remains <100 ms during background decode/interaction, measured separately from time-to-image;
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

## 17. Policy benchmark harness

Performance policy choices live in a dedicated benchmark harness (for example `benchmarks/LargeImagePolicyBench/`) or an equivalent isolated test tool. It is not part of the production target.

Every benchmark records enough raw output to reproduce the decision. Do not reduce results to a single undocumented score.

### 17.1 A-series — materialization validation

Compare at least:

- A1: `CreateImageAtIndex` with relevant cache flags, then first real draw;
- A2: native-sized `CreateThumbnailAtIndex`, then draw;
- A3: `CreateImageAtIndex -> background CGContext materialize -> draw materialized result`.

Use representative normal/native-sized inputs (for example ~4K, ~6K, and <=8192) plus the giant image only as a safety negative control where appropriate.

Measure:

- create/materialize wall time;
- first renderer draw time after publication;
- peak `phys_footprint`;
- observable `Image IO` regions;
- color space and pixel layout before/after;
- whether a second expensive decode occurs during first Quartz/Metal draw.

A3 is the current preferred mechanism, but implementation planning freezes it only after this validation confirms the expected behavior.

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
- whether lower-level preload provides any useful page-cache warming despite bitmap-cache miss.

Hard constraints before latency comparison:

- oversized >8192 gets zero main-image neighbor preload;
- no swap storm attributable to the policy;
- no policy may rely on immediately-evicted entries as useful cache state;
- stale speculative decode must not dominate foreground work;
- memory use must remain defensible on the target 16 GB Mac.

Among policies satisfying the hard constraints, choose based on reproducible navigation benefit versus memory/energy cost. A tiny latency win does not justify hundreds of MiB of extra resident working set.

### 17.3 C-series — dimension probe arbitration

Use folders of approximately 100, 1000, and 5000 supported images where practical.

Compare:

- C1 eager folder-wide header dimension probing;
- C2 on-demand current/visible/candidate probing with dimension cache;
- C3 byte-size coarse filter followed by required header confirmation.

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

Record:

- visible aliasing/shimmer;
- deterministic image-quality metric where useful;
- GPU frame time;
- texture memory;
- mip generation time.

The selected Metal path must not show a material quality regression versus the Quartz reference at strong minification.

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

No implementation plan is generated until:

- the reviewer-added tests have been incorporated or explicitly rejected with technical rationale; and
- A/B/C/D benchmark decisions needed by the plan are resolved, or the plan explicitly treats a benchmark as its first gating task before production policy code.

## 21. Error handling

- Decode failure continues through the existing viewer error path.
- Metal initialization/resource/pipeline failure is non-fatal and selects Quartz.
- Missing Metal resources must never trap.
- Oversized bounded-decode failure must not silently fall back to unbounded native rendering.
- Loading-state failure/cancellation must leave the UI responsive and in a deterministic state.

## 22. Revised implementation dependency order

The eventual implementation plan must respect:

1. Run/complete the A/B/C/D policy benchmark gates required to freeze disputed policies.
2. Source-vs-bitmap geometry separation.
3. Shared oversized predicate and chosen dimension-probe policy.
4. Native materialization path and oversized bounded decode.
5. Cache identity plus chosen preload/cache policy.
6. Navigator/current-preview reuse and oversized drawer protection.
7. Metal renderer, mip/minification policy, and Quartz source-rect fallback.
8. Non-trapping Metal resource lookup and release-resource packaging.
9. Full correctness/regression/real-image acceptance validation.
10. Quick Look spike.
11. Alternative PNG decoder spike.

## 23. Success criteria

The design/implementation is successful only when all are true:

- Oversized sources cannot force a native-size canvas bitmap merely to display at Fit.
- Oversized decoded long edge never exceeds 8192.
- Normal <=8192 sources retain native-resolution semantics without publishing a lazy render-time decode to the canvas.
- Source geometry remains exact and existing zoom semantics are preserved.
- Current navigator/sidebar reuse avoids redundant current-source decode.
- Oversized neighbor preload and oversized non-current drawer thumbnail storms are prevented.
- Chosen preload/cache and dimension-probe policies are backed by B/C benchmark evidence, not reviewer preference.
- Large-image interaction uses on-demand Metal when available.
- Strong minification meets the D-series quality gate.
- Static images do not run a continuous GPU loop.
- Metal failures fall back safely to source-geometry Quartz rendering.
- Packaged `.app`/DMG builds can load Metal resources; missing resources fall back without crash.
- Main-thread responsiveness and live-memory acceptance pass on the real 1.9 GiB PNG.
- Existing behavioral tests remain green.
- Reviewer-added discriminating tests are resolved before implementation planning.
- Quick Look/decoder spikes remain isolated unless later evidence justifies production adoption.
