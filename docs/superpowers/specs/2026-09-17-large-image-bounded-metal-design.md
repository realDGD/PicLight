# PicLight Large-Image Bounded Decode + On-Demand Metal Design

Date: 2026-09-17
Baseline: `123d943`
Status: design approved in chat; implementation not started

## 1. Purpose

PicLight currently treats the decoded `CGImage` as both the source-image geometry and the renderable bitmap. That works for normal images but fails badly for extreme images. The investigation image is a 1.929 GiB, 48000×32000, non-interlaced RGBA PNG. On the current path, `CGImageSourceCreateImageAtIndex` returns quickly because the image is lazy, then Core Animation forces a full decode during backing-store rasterization. The measured result is about 19.6 s to first real pixels, a 5.86 GiB `Image IO` footprint, 7.8–9.0 GiB peak RSS, and about 0.05 fps when repeatedly interacting with the still-lazy native image.

This design addresses two independent problems:

1. Bound the bitmap presented to the renderer so a huge source can never force a native-size allocation merely to fit the window.
2. Replace the interactive CGContext resampling path with an on-demand Metal renderer so zoom, pan, rotate, and mirror do not repeatedly rasterize large images on the CPU.

This design does **not** attempt to make a 1.9 GiB PNG decode in sub-second time. The investigation proved that ImageIO thumbnail creation still spends roughly 18 s because PNG inflate + row filtering dominates and scales with the compressed stream, not the requested output dimensions.

## 2. Scope

### In scope

- Bounded main-image decoding with a first-version long-edge ceiling of **8192 pixels**.
- Preserve source-image geometry independently from decoded-bitmap geometry.
- Decode-cache keys that include decode level/page identity.
- Reuse the bounded main bitmap for the navigator and current-item preview where practical, avoiding redundant full-stream decodes.
- `ImageCanvasView` remains the interaction shell and owns gestures/hit testing.
- A child `MTKView` renders the bitmap with an on-demand Metal pipeline.
- Quartz/CGContext rendering remains as a functional fallback.
- Resource packaging changes required for `.metal` shaders in the release `.app`.
- Tests covering geometry semantics, bounded decode, cache semantics, renderer parity, fallback, and release packaging.
- Two separate performance spikes: Quick Look thumbnail cache behavior, and alternative PNG decoders.

### Explicitly out of scope

- Sidecar/proxy cache in production.
- Native-resolution tiled rendering.
- Custom PNG decoder in production.
- Core Image as the main rendering path.
- Image pyramids beyond the bounded decode buckets needed for cache identity.
- A LargeImageBackend for random-access native pixels.

## 3. Design principles

### 3.1 One authoritative source geometry

`ImageDescriptor.displayPixelSize` remains the authoritative logical size of the source image. No second independent `sourcePixelSize` state is introduced.

The decoded `CGImage.width/height` describes only the bitmap currently used for rendering.

For example:

```text
source geometry:   48000 × 32000
render bitmap:      8192 × 5461
```

Viewport math, Fit, Fit Width, 100%, normalized center, panning bounds, and navigator geometry all use the source geometry. Rendering maps the bounded bitmap over that logical source rectangle.

This preserves the existing meaning of 100%: one source-image pixel corresponds to one physical display pixel. A bounded image may become visibly undersampled at sufficiently high zoom; that is acceptable in this iteration. Native-detail delivery belongs to a later LargeImageBackend.

### 3.2 Bound first, render second

No huge native lazy `CGImage` should reach the main canvas when its long edge exceeds the selected decode budget.

The main decoder chooses between:

- Native decode only when the source long edge is already <= the selected bucket.
- `CGImageSourceCreateThumbnailAtIndex` with transform enabled when the source exceeds the selected bucket.

For any source whose long edge exceeds 8192, production code must never request native decode in this iteration.

The decode output must be a real bounded bitmap suitable for direct upload to Metal. The renderer must never trigger a hidden 48000×32000 decode merely because the view is scaled to Fit.

### 3.3 Event-driven GPU rendering

Metal is introduced for interaction, not for PNG decompression.

The Metal view runs with:

```swift
isPaused = true
enableSetNeedsDisplay = true
```

A frame is requested only when image content, viewport transform, view size, backing scale, or relevant appearance/color state changes.

No permanent 60/120 Hz loop is allowed for a static image.

## 4. Decode budget

### 4.1 First-version ceiling

The hard ceiling is **8192 pixels on the longest decoded edge**.

The requested decode budget is derived from the physical canvas requirement:

```text
required = ceil(max(canvasWidth, canvasHeight) × backingScale × 1.5)
budget   = min(nextBucketAtOrAbove(required), 8192)
```

The overscan factor is fixed at **1.5** in this iteration. It is not a user preference.

### 4.2 Buckets

Stable decode/cache buckets are:

```text
1024, 2048, 4096, 8192
```

Selection rule:

1. Compute `required` above.
2. Choose the smallest bucket >= `required`.
3. Clamp that bucket to 8192.
4. If the source long edge is <= the selected bucket, decode natively and mark the cache level as native-for-that-source.
5. Otherwise create a bounded bitmap at the selected bucket.

The bucket-selection helper is pure and unit-tested.

### 4.3 Neighbor preload budget

Neighbor preload is intentionally cheaper than the current item:

```text
main 8192 -> preload 4096
main 4096 -> preload 2048
main 2048 -> preload 1024
main 1024 -> preload 1024
```

This is a fixed first-version policy, not a runtime heuristic. When a preloaded image becomes current, the normal current-image request may upgrade it to the current bucket.

## 5. Data model changes

### 5.1 `DecodedImageHead`

`DecodedImageHead` continues to carry:

- rendered `CGImage`
- `ImageDescriptor`
- metadata

No duplicate source-size field is added. Consumers use:

```swift
head.descriptor.displayPixelSize   // logical/source dimensions
head.image.width / height          // bounded render-bitmap dimensions
```

Tests explicitly exercise the case where these dimensions differ.

### 5.2 `DecodeTarget`

`DecodeTarget.maxPixelSize` changes from a mostly-ICO representation hint into a real decode budget for ordinary still images and TIFF pages.

The decoder honors it for single-representation JPEG/PNG/TIFF/WebP/BMP where ImageIO supports thumbnail creation.

ICO retains representation selection. Multi-page TIFF retains `pageIndex` semantics.

### 5.3 Cache identity

The current `head:<path>` key is insufficient once multiple decode levels exist.

Cache identity becomes conceptually:

```text
URL + pageIndex + decodeLevel
```

Animation-frame identity also includes frame index.

A 4096 cached bitmap must never satisfy an 8192 request. The first implementation uses exact level matching; it does not substitute a larger or smaller cached level implicitly.

Cost remains based on actual decoded bitmap bytes (`bytesPerRow × height`), not source dimensions.

## 6. ImageIO decode path

For a source larger than the selected budget, `ImageIODecoder` uses:

```text
kCGImageSourceCreateThumbnailFromImageAlways = true
kCGImageSourceCreateThumbnailWithTransform = true
kCGImageSourceThumbnailMaxPixelSize = budget
kCGImageSourceShouldCacheImmediately = true
```

The thumbnail transform is responsible for source orientation on the bounded path. The existing full-size CGContext orientation copy must not run after a transformed thumbnail has already been produced.

For small images decoded natively, existing orientation correctness remains required.

The implementation preserves color-space information carried by ImageIO. Existing Display-P3 tests remain valid and must not be weakened.

## 7. Avoid redundant large-PNG decodes

The investigation showed three expensive decode-like activities on first open of the 1.9 GiB PNG: main canvas rasterization, sidebar thumbnail generation, and navigator-preview generation. Each traversed the PNG stream.

Rules:

- Once a bounded main bitmap is available, the navigator preview is generated from that bitmap, never from the original file.
- Once a bounded main bitmap is available, the current sidebar item is generated/replaced from that bitmap instead of opening the source again.
- Neighbor sidebar thumbnails may continue using the existing thumbnail pipeline because no main bounded bitmap exists for them yet.

This does not make the first bounded main decode faster, but prevents PicLight from repeatedly paying the same source-stream cost for current-image UI chrome.

## 8. Metal rendering architecture

### 8.1 Component boundaries

Add:

```text
PicViewMac/Viewer/
  ImageCanvasView.swift          existing interaction shell
  MetalCanvasSurface.swift      MTKView subclass/host surface
  MetalImageRenderer.swift      device, queue, pipeline, texture, draw
  ImageShaders.metal            vertex + fragment shader
```

`ImageCanvasView` remains the public interaction surface used by the controller and tests. It owns gestures, hit testing, viewport changes, and callbacks.

`MetalCanvasSurface` fills the canvas bounds but does not become the gesture owner. Mouse/trackpad input remains routed through `ImageCanvasView`.

### 8.2 Renderer inputs

The renderer receives:

- bounded `CGImage`
- authoritative source/display pixel size
- `ViewportState`
- view size
- backing scale
- background state needed for the render pass

The image is uploaded only when the bitmap changes. Zoom/pan/rotate/mirror update uniforms/transform state only.

### 8.3 Geometry

The shader draws a textured quad representing the full logical source rectangle. UV coordinates address the bounded texture. Existing viewport semantics are translated into a GPU transform matrix.

The transform preserves:

- Fit
- Fit Width
- 100%
- Fit ×2
- pointer-centered zoom
- normalized-center panning
- quarter-turn rotation
- horizontal mirror

`ViewportState` remains the mathematical source of truth; there is no second Metal-specific viewport model.

### 8.4 Sampling

Sampling policy is explicit:

- If the render bitmap is a bounded proxy (`bitmap dimensions != source display dimensions`), use linear filtering for both minification and magnification in this iteration. This avoids exposing proxy texels as large hard blocks at high zoom.
- If the render bitmap is native-size, use linear filtering while `zoomScale < 1` and nearest sampling when `zoomScale >= 1`, matching the existing CGContext intent.

Mipmaps are optional and may be added only if tests show they improve quality/performance without changing geometry semantics.

## 9. On-demand draw lifecycle

`MTKView` is event-driven:

```swift
isPaused = true
enableSetNeedsDisplay = true
```

Call `setNeedsDisplay` only for:

- new bitmap
- zoom/pan
- rotate/mirror
- view resize/layout
- backing-scale change
- drawable/color-space change
- explicit appearance/background change that affects the render pass

A static image must not generate a continuous render loop.

## 10. Color management

The renderer must not silently flatten Display-P3 images to unmanaged device RGB.

The bounded `CGImage` retains its ImageIO color space. The Metal surface must configure a compatible drawable color space for supported 8-bit RGB inputs. If the input color space/pixel configuration cannot be represented correctly by the Metal path, the renderer falls back to Quartz.

This iteration does not add HDR editing, tone mapping, or Core Image filters.

## 11. Quartz fallback

The existing CGContext renderer remains available as a fallback.

Fallback conditions include:

- no usable `MTLDevice`
- shader/pipeline library failure
- texture creation failure
- unsupported pixel/color configuration

Fallback displays the bounded bitmap, not a huge native lazy source. Metal failure must never reintroduce the original full-size allocation problem.

The user must not see a blank canvas because Metal setup failed.

## 12. Shader packaging and release bundle

Use a real `.metal` source file compiled as a Swift Package resource. Do not compile shader source strings at runtime.

Because the existing release script copies only the SwiftPM executable into the `.app`, the build/release path must also copy the generated resource bundle containing the Metal library into `Contents/Resources`.

`verify-release.sh` adds a packaged-app check proving the Metal resource can be located and a render pipeline can be created from the assembled `.app`/DMG path.

Development-only success under `swift run` is insufficient.

## 13. Controller integration

`ViewerViewController` computes the current decode target from the actual canvas/backing-scale requirement before asking `DecodeCoordinator` to show the item.

Rules:

- Current decode target follows the bucket policy in §4.
- Previous/next preload target follows §4.3.
- Cache lookups require the exact requested level.
- Image change publishes descriptor and bounded bitmap together so geometry never briefly uses bitmap dimensions as source dimensions.
- Navigator sizing uses `descriptor.displayPixelSize`, not `currentImage.width/height`.

## 14. Testing strategy

### 14.1 Decode tests

Add tests proving:

- single-representation PNG/JPEG/TIFF honor `DecodeTarget.maxPixelSize`
- a source larger than the budget produces bounded output
- `descriptor.displayPixelSize` remains the original logical size
- orientation remains correct on bounded output
- Display-P3 remains tagged correctly
- TIFF page selection still works with a budget
- ICO representation selection still works

### 14.2 Geometry tests

Construct cases where source size and bitmap size differ substantially. Verify Fit, Fit Width, 100%, Fit ×2, pointer-centered zoom, panning/clamping, navigator rect, rotation, and mirror all behave according to source geometry.

### 14.3 Cache tests

Verify:

- 4096 and 8192 entries are distinct
- page index participates in identity
- actual decoded byte size drives cost
- memory-pressure purge still keeps intended current-entry semantics

### 14.4 Renderer tests

Where deterministic rendering is available, compare Metal and Quartz on small fixtures for:

- identity render
- zoom
- pan
- 90° rotation
- mirror
- alpha
- sRGB
- Display-P3 handling

Prefer geometry/pixel invariants over brittle screenshot hashes.

Add a forced-failure injection path so tests prove automatic Quartz fallback.

### 14.5 Existing regression suite

All existing tests must continue passing, particularly gesture routing, pointer-centered zoom, drawer pin/unpin geometry, navigator behavior, animated images, multi-page TIFF, thumbnail selection border, and window/layout behavior.

### 14.6 Real 1.9 GiB PNG acceptance

Using `/Users/dgd/Downloads/万萝图/万萝图.png` locally (never committed):

- main render bitmap long edge <= 8192
- no 48000×32000 full ImageIO bitmap allocation in the main-display path
- navigator does not independently decode the source again
- current sidebar preview does not independently decode the source again once the bounded main image exists
- static Metal renderer does not continuously draw
- zoom/pan remain responsive after the bounded image is available

Known baseline:

```text
first real pixels: ~19.6 s
native ImageIO footprint: 5.86 GiB
peak RSS: 7.8–9.0 GiB
lazy-native interaction: ~0.05 fps
```

This implementation is expected primarily to reduce memory/swap and interaction cost, not the ~18 s first bounded PNG decode itself.

## 15. Quick Look spike

Exploratory only; it does not become a production dependency in this implementation.

Question:

> Can `QLThumbnailGenerator` return a useful preview substantially earlier than the 18 s ImageIO bounded decode when macOS already has a warm thumbnail cache for the file?

Measure:

- cold vs warm cache
- before and after Finder/Quick Look has viewed the file
- 2048 and 4096 requests
- wall time
- output dimensions
- process footprint
- whether the request itself appears to trigger a full PNG decode

Success criterion: repeatable, materially sub-second or otherwise clearly earlier warm-cache preview. If the API simply repeats the ~18 s decode, do not integrate it.

Output: benchmark/report only.

## 16. Alternative PNG decoder spike

Exploratory only.

Candidates:

- libpng
- libspng
- optionally zlib-ng-backed variants if build complexity remains reasonable

Use the same 1.9 GiB PNG and compare against ImageIO for:

- wall time
- CPU time
- peak memory/footprint
- decode-to-4096/8192 behavior
- row-by-row downsampling feasibility
- cancellation/checkpoint behavior

A small single-digit percentage speedup is insufficient justification for a production dependency; the result must be clearly material and repeatable.

The spike must not assume that decoding only the first N% of a non-interlaced PNG can produce a complete whole-image preview. Row-wise incremental decode may improve memory and cancellation behavior but still requires the complete stream for a complete full-image downsample.

Output: benchmark/report only.

## 17. Error handling

- Decode failure continues through the existing compact viewer error path.
- Metal initialization failure is non-fatal and selects Quartz fallback.
- Shader/resource lookup failure is treated as Metal-unavailable, not an app-launch failure.
- A bounded decode failure may fall back to native decode only when the source long edge is <=8192. Oversized sources must not silently fall back to unbounded native rendering.

## 18. Implementation order

The implementation plan must preserve this dependency order:

1. Source-vs-bitmap geometry separation in consumers.
2. Decode-budget/bucket helpers and cache identity.
3. ImageIO bounded main decode.
4. Navigator/current-preview reuse.
5. Metal renderer and Quartz fallback.
6. Release-resource packaging.
7. Full regression/performance validation.
8. Quick Look spike.
9. Alternative decoder spike.

The spikes may run independently once production architecture work is stable, but their results do not gate bounded-image + Metal implementation.

## 19. Success criteria

The design is successful when all are true:

- A huge source cannot force a native-size canvas bitmap merely to display at Fit.
- The decoded long edge never exceeds 8192 for oversized sources.
- Source geometry remains exact and existing zoom semantics are preserved.
- Large-image interaction uses on-demand Metal when available.
- Static images do not run a continuous GPU loop.
- Metal failures fall back safely to bounded Quartz rendering.
- Navigator/current-preview work does not redundantly re-decode the same huge source after the bounded main bitmap exists.
- Packaged `.app`/DMG builds contain and can load the Metal shader resources.
- Existing behavioral tests remain green.
- The two exploratory spikes remain isolated and produce evidence for later decisions without expanding the production dependency surface.
