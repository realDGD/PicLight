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
- Multilevel image pyramids beyond the bounded decode buckets needed for cache identity.
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

- Native decode when the source already fits the budget.
- `CGImageSourceCreateThumbnailAtIndex` with transform enabled when the source exceeds the budget.

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

The requested decode budget is derived from the physical canvas requirement, then clamped to 8192. The initial rule is:

```text
required = ceil(max(canvasWidth, canvasHeight) × backingScale × overscan)
budget   = min(bucket(required), 8192)
```

`overscan` should be conservative enough that small zooms above Fit do not instantly reveal softness. Use a fixed implementation constant rather than a user preference in this iteration.

### 4.2 Buckets

Decode/cache identity uses stable buckets rather than arbitrary window-derived dimensions. Initial buckets:

```text
1024, 2048, 4096, 8192, native
```

`native` is used only when the actual source long edge is <= 8192 or another safe bounded condition explicitly permits it. This design does not request native decode for sources larger than 8192.

The exact bucket selection helper must be pure and unit-tested.

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

Tests must explicitly exercise the case where these dimensions differ.

### 5.2 `DecodeTarget`

`DecodeTarget.maxPixelSize` changes from a mostly-ICO representation hint into a real decode budget for ordinary still images and TIFF pages.

The decoder must honor it for single-representation JPEG/PNG/TIFF/WebP/BMP where ImageIO supports thumbnail creation.

ICO retains its representation-selection behavior. Multi-page TIFF retains `pageIndex` semantics.

### 5.3 Cache identity

The current `head:<path>` key is insufficient once multiple decode levels exist.

Cache identity becomes conceptually:

```text
URL + pageIndex + decodeLevel
```

Animation-frame identity also includes frame index.

A 4096 cached bitmap must never satisfy an 8192 request by accident. A larger cached bitmap may only satisfy a smaller request if the implementation explicitly chooses that policy and tests it; the first implementation should prefer exact bucket matching for simplicity.

Cost remains based on the actual decoded bitmap bytes (`bytesPerRow × height`), not the source dimensions.

## 6. ImageIO decode path

For a source larger than the selected budget, `ImageIODecoder` uses a bounded thumbnail path with:

```text
kCGImageSourceCreateThumbnailFromImageAlways = true
kCGImageSourceCreateThumbnailWithTransform = true
kCGImageSourceThumbnailMaxPixelSize = budget
kCGImageSourceShouldCacheImmediately = true
```

The thumbnail transform is responsible for source orientation on the bounded path. The existing full-size CGContext orientation copy must not run after a transformed thumbnail has already been produced.

For small images that are decoded natively, existing orientation correctness remains required.

The implementation must preserve color-space information carried by ImageIO. Existing Display-P3 tests remain valid and must not be weakened.

## 7. Avoid redundant large-PNG decodes

The investigation showed three expensive decode-like activities on first open of the 1.9 GiB PNG: main canvas rasterization, sidebar thumbnail generation, and navigator-preview generation. Each traversed the PNG stream.

The new rule is:

- Once a bounded main bitmap is available, the navigator preview is generated from that bitmap, never from the original file.
- The current sidebar item should reuse/downsample from the current bounded bitmap where possible instead of opening the source again.
- Neighbor sidebar thumbnails may continue using the existing thumbnail pipeline, because they do not yet have a main bounded bitmap.

This does not make the first bounded main decode faster, but it prevents PicLight from repeatedly paying the same 18–20 s source-stream cost for UI chrome.

## 8. Metal rendering architecture

### 8.1 Component boundaries

Add these components:

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

The shader draws a textured quad representing the full logical source rectangle. UV coordinates address the bounded texture. The existing viewport semantics are translated into a GPU transform matrix.

The transform must preserve current behavior for:

- Fit
- Fit Width
- 100%
- Fit ×2
- pointer-centered zoom
- normalized-center panning
- quarter-turn rotation
- horizontal mirror

The mathematical source of truth remains `ViewportState`; do not create a second independent Metal-specific viewport model.

### 8.4 Sampling

Initial behavior should match current visible semantics as closely as practical:

- minification: filtered sampling
- magnification around/above source 100%: preserve current crisp intent; renderer tests define the accepted behavior

Mipmaps may be used if they improve quality/performance without changing geometry semantics. They are not required for the first functional cut if direct sampling meets the acceptance tests.

## 9. On-demand draw lifecycle

`MTKView` must be event-driven:

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

The bounded `CGImage` retains its ImageIO color space. The Metal pipeline must choose a texture/drawable strategy that preserves normal sRGB and Display-P3 behavior on macOS.

This design does not introduce HDR editing or Core Image filters. If the renderer cannot correctly support an input format/color configuration, it must fall back to the Quartz path rather than display incorrect color.

## 11. Quartz fallback

The existing CGContext renderer remains available as a fallback.

Fallback conditions include, but are not limited to:

- no usable `MTLDevice`
- shader/pipeline library failure
- texture creation failure
- unsupported pixel/color configuration

Fallback must display the bounded bitmap, not a huge native lazy source. Failure of Metal must never reintroduce the original 5.86 GiB native-bitmap problem.

The user should not see a blank canvas simply because Metal setup failed.

## 12. Shader packaging and release bundle

Use a real `.metal` source file compiled as a Swift Package resource. Do not compile shader source strings at runtime.

Because the existing release script copies only the SwiftPM executable into the `.app`, the build/release path must also copy the generated resource bundle containing the Metal library into `Contents/Resources`.

`verify-release.sh` must include a packaged-app check proving the Metal resource can be located and a render pipeline can be created from the assembled `.app`/DMG path.

Development-only success under `swift run` is insufficient.

## 13. Controller integration

`ViewerViewController` computes the decode target from the actual canvas/backing-scale requirement before asking `DecodeCoordinator` to show the item.

Important behaviors:

- Main decode target is a stable bucket <= 8192.
- Neighbor preload target must not exceed the main bucket and may be intentionally lower if tests show that is beneficial.
- A cached decode at the requested bucket may be reused.
- Image change publishes descriptor and bounded image together so geometry never briefly uses the bitmap size as source size.

Navigator sizing uses `descriptor.displayPixelSize`, not `currentImage.width/height`.

## 14. Testing strategy

### 14.1 Decode tests

Add tests proving:

- single-representation PNG/JPEG/TIFF honor `DecodeTarget.maxPixelSize`
- a source larger than the budget produces a bounded output
- `descriptor.displayPixelSize` remains the original logical size
- orientation remains correct on bounded output
- Display-P3 remains tagged correctly
- TIFF page selection still works with a budget
- ICO representation selection still works

### 14.2 Geometry tests

Construct cases where source size and bitmap size differ substantially. Verify:

- Fit
- Fit Width
- 100%
- Fit ×2
- pointer-centered zoom
- panning/clamping
- navigator rect
- rotation/mirror

all behave according to source geometry.

### 14.3 Cache tests

Verify:

- 4096 and 8192 entries are distinct
- page index participates in identity
- actual decoded byte size drives cost
- memory-pressure purge still keeps the intended current entry semantics

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

Tests should prefer geometry/pixel invariants over brittle screenshot hashes.

Add a forced-failure injection path so tests can prove automatic Quartz fallback.

### 14.5 Existing regression suite

All existing tests must continue passing, particularly:

- gesture routing
- pointer-centered zoom
- drawer pin/unpin geometry
- navigator layering/viewport updates
- animated images
- multi-page TIFF
- thumbnail selection border
- window/layout behavior

### 14.6 Real 1.9 GiB PNG acceptance

Using `/Users/dgd/Downloads/万萝图/万萝图.png` locally (never committed):

- main render bitmap long edge <= 8192
- no 48000×32000 full ImageIO bitmap allocation in the main-display path
- navigator does not independently decode the source again
- current sidebar preview does not independently decode the source again once the bounded main image exists
- static Metal renderer does not continuously draw
- zoom/pan remain responsive after the bounded image is available

The known baseline is approximately:

```text
first real pixels: ~19.6 s
native ImageIO footprint: 5.86 GiB
peak RSS: 7.8–9.0 GiB
lazy-native interaction: ~0.05 fps
```

The first implementation is expected primarily to reduce memory/swap and interaction cost, not the ~18 s first bounded PNG decode itself.

## 15. Quick Look spike

This spike is exploratory only and must not become a production dependency in this implementation.

Question:

> Can `QLThumbnailGenerator` return a useful preview substantially earlier than the 18 s ImageIO bounded decode when macOS already has a warm thumbnail cache for the file?

Measure:

- cold cache vs warm cache
- before and after Finder/Quick Look has viewed the file
- 2048 and 4096 requests
- wall time
- output dimensions
- process footprint
- whether the request itself appears to trigger a full PNG decode

Success criterion:

A repeatable, materially sub-second or otherwise clearly earlier warm-cache preview. If the API simply repeats the 18 s decode, do not integrate it.

Output: benchmark/report only.

## 16. Alternative PNG decoder spike

This spike is exploratory only.

Candidates:

- libpng
- libspng
- optionally zlib-ng-backed variants if build complexity remains reasonable

Use the same 1.9 GiB PNG and compare against ImageIO for:

- wall time
- CPU time
- peak memory/footprint
- decode-to-4096/8192 behavior
- feasibility of row-by-row downsampling
- cancellation/checkpoint behavior

Do not treat a small single-digit percentage speedup as sufficient justification for a new dependency. The result must be clearly material and repeatable to justify production consideration.

The spike must not assume that decoding only the first N% of a non-interlaced PNG can produce a complete whole-image preview. The PNG stream is sequential; row-wise incremental decode may improve memory and cancellation behavior but still requires the complete stream for a complete full-image downsample.

Output: benchmark/report only.

## 17. Error handling

- Decode failure continues to surface through the existing compact viewer error path.
- Metal initialization failure is non-fatal and selects Quartz fallback.
- Resource-bundle/shader lookup failure is treated as Metal-unavailable, not an app-launch failure.
- A bounded decode that fails may fall back to the existing native path only when the source is already within the safe <=8192 range. Huge sources must not silently fall back to an unbounded native render.

## 18. Implementation order

The later implementation plan should preserve this dependency order:

1. Source-vs-bitmap geometry separation in consumers.
2. Pure decode-budget/bucket helpers and cache identity.
3. ImageIO bounded main decode.
4. Navigator/current-preview reuse.
5. Metal renderer and Quartz fallback.
6. Release-resource packaging.
7. Full regression/performance validation.
8. Quick Look spike.
9. Alternative decoder spike.

The spikes may run independently once the production architecture work is stable, but their results do not gate the bounded-image + Metal implementation.

## 19. Success criteria

The design is successful when all of the following are true:

- A huge source cannot force a native-size canvas bitmap merely to display at Fit.
- The first-version decoded long edge never exceeds 8192 for oversized sources.
- Source geometry remains exact and existing zoom semantics are preserved.
- Large-image interaction uses on-demand Metal when available.
- Static images do not run a continuous GPU loop.
- Metal failures fall back safely to bounded Quartz rendering.
- Navigator/current-preview work does not redundantly re-decode the same huge source after the bounded main bitmap exists.
- Packaged `.app`/DMG builds contain and can load the Metal shader resources.
- Existing behavioral tests remain green.
- The two exploratory spikes remain isolated and produce evidence for later decisions without expanding the production dependency surface.
