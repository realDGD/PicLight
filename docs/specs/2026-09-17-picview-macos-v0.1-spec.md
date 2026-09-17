# PicViewMac v0.1 Product & Technical Specification

> Working codename: `PicViewMac`. This is an internal target/repository name, not a final product-brand decision.

**Date:** 2026-09-17  
**Status:** Product decisions audited against the prior A–Y discussion  
**Platform:** macOS 14 Sonoma and later  
**Distribution:** Independent `.app` / `.dmg`, no Mac App Store requirement, no paid Apple Developer Program required for v0.1

---

## 1. Product goal

Build a fast, native macOS image viewer with a Picview-like minimalist experience:

- the image is the visual focus;
- chrome is hidden until hover/interaction;
- a left-edge hover drawer shows all supported images in the current folder;
- image switching must feel instantaneous through lazy decode, cache and direction-aware preloading;
- the app remains a standard macOS window from the window manager's perspective;
- macOS 26+ adopts native Liquid Glass APIs instead of imitating them.

The v0.1 implementation should borrow architecture ideas from voidImageViewer—first-frame-first decode, frame-based animation, adjacent-image preload, mip/downsample thinking and stable normalized viewport state—without porting its Win32/GDI windowing/rendering code.

---

## 2. Audited decision register

| ID | Final decision |
|---|---|
| A | Left thumbnail drawer **overlays** the main image instead of shrinking/reflowing the image canvas. |
| A1 | A left-edge hover hot zone opens the drawer. Finalized dimensions/timing: ~12 px hot zone, ~180–220 px drawer, ~150 ms opening animation, ~250 ms delayed close after pointer leaves. Pointer inside drawer keeps it open. |
| B1 | Single-column large thumbnails; approximately 120–150 px visual height, aspect-ratio preserved, current item highlighted, drawer scrolls independently. |
| C3 | Thumbnail filename display has 3 modes: Never / Always / Hover. Default = Hover. |
| D4 | Multiple sort modes. Default = natural filename order. Supported: filename, modification time, creation time, file size, image dimensions; ascending/descending. |
| E1 | Browse **current folder only**. Never recurse into subfolders in v0.1. |
| F1 | Minimum OS = macOS 14 Sonoma. |
| G | Independent distribution. v0.1 does not require Apple Developer Program, Developer ID or notarization. First launch documentation uses System Settings → Privacy & Security → Security → Open Anyway. Never instruct users to disable SIP/Gatekeeper globally. |
| H2+H3 | Default opening behavior = create a new viewer window. Setting allows “reuse current window”. The explicit “open in new/current window” command always exists; modifier behavior inverts the configured default. |
| Window invariant | One visible viewer = one top-level standard `NSWindow`. Never use macOS native window tabs, `addTabbedWindow`, `tabGroup`, special utility panels or separate overlay windows for hover UI. |
| Window appearance | Standard `NSWindow` with `.titled`, `.closable`, `.miniaturizable`, `.resizable`, `.fullSizeContentView`; visually titleless/transparent rather than true `.borderless`. Automatic native tabbing disabled. |
| Top hover | Traffic-light buttons are the **real standard window buttons** and appear only when pointer enters the top hover zone (~44 px). Filename and tools appear with them. Leaving delays fade by ~300 ms; inactivity around 1.5–2 s hides chrome. |
| I3 | Top filename visibility is configurable. Default = shown when top hover chrome is visible. Long names use middle truncation. |
| J2 | v0.1 top tools: rotate, horizontal mirror, Fit, 100%, Move to Trash, More. J3 fully customizable toolbar is future work. Rotation/mirror are view state only in v0.1; do not silently rewrite the source file. |
| K4 | Bottom info fields are configurable. Default: `index / total · zoom · pixel dimensions`. Optional fields: file size, type, color space. Bottom bar follows hover/idle fade behavior. |
| L3 | Two window-size policies. Default = remember last viewer size. Alternative = size window to image subject to current screen's usable bounds. New windows cascade rather than exactly overlap. |
| M3 | Mouse-wheel behavior configurable; default = zoom centered on pointer. Trackpad pinch always zooms. Enlarged images can be panned by drag / trackpad movement. |
| N4 | Trackpad horizontal swipe configurable. Default = Smart: at Fit, swipe changes image; when zoomed, pan first; once the horizontal edge is reached, continuing the gesture changes image. Other modes: always switch / always pan / disabled. |
| O3 | Double-click behavior configurable. Default = toggle `Fit ↔ Fit × 2`. `Fit × 2` means twice the current Fit scale, not “200% of original pixels”. |
| P1 | Navigator/minimap appears only when `zoom > Fit`; bottom-right by default. Shows full image and current viewport. Drag viewport or click minimap to navigate. It fades after ~1.5 s inactivity, reappears on mouse/zoom/pan interaction, and disappears at Fit. |
| Q4 | Format support is phased. v0.1 hard-required set from the latest explicit discussion: BMP, GIF, ICO, PNG, JPG/JPEG, TIF/TIFF, WebP. RAW/pro formats are later phases. See §3 for HEIC/HEIF audit ambiguity. |
| R3 | Animated GIF/WebP: setting controls autoplay, default = autoplay. Pause/resume supported; Space toggles playback on animated content. Respect frame timing and source loop count. Switching away stops the animation clock; revisiting restarts from first frame in v0.1. |
| S2 | Multi-page TIFF supports previous/next page. ICO automatically selects the most appropriate embedded representation; ICO is not exposed as a “page” UI. |
| T2 | Respect EXIF Orientation for display. Provide a basic image-information panel: file info, dimensions, orientation, color space/bit depth when available, capture date, camera/lens, focal length, aperture, shutter, ISO, exposure compensation and GPS when present. |
| U2 | Color-managed SDR: honor ICC/color-space information, including sRGB and Display P3. No dedicated HDR/EDR rendering promise in v0.1. |
| V4 | Delete behavior configurable. Default smart behavior: move current file to Trash, prefer next image; if deleting last image, show previous; if none remain, keep the window with an empty-folder state. |
| W2 | Core macOS/system shortcuts stay fixed; viewer commands are partly customizable. Core command set includes previous/next, Fit, 100%, Fit×2, rotation, mirror, Trash, Open, Close, Settings, Escape, TIFF Page Up/Page Down and animation Space. |
| X3 | **Full Screen** and **Immersive Mode** are separate. Full Screen = native macOS full-screen/Space behavior. Immersive Mode = same ordinary window/Space/size, only viewer chrome is hidden. They may be combined. |
| Y | Viewer appearance configurable; default = Follow System. Do not imitate OS-specific materials. macOS 14–15 use native AppKit appearance/materials; macOS 26+ use native Liquid Glass APIs where appropriate and availability-guarded. Respect system Light/Dark, Reduce Transparency, Reduce Motion and accessibility contrast where practical. |

---

## 3. Audit findings: omissions, ambiguity and implementation defaults

### 3.1 One genuine scope ambiguity: HEIC / HEIF

An earlier Q1 proposal included HEIC/HEIF, while the latest explicit v0.1 list named BMP, GIF, ICO, PNG, JPG, TIF and WebP. The follow-up treated that latest set as the committed v0.1 set.

**Plan rule:** HEIC/HEIF are **not a v0.1 acceptance requirement** until explicitly reconfirmed. The decoder abstraction must not block them; if ImageIO opens them on the running OS, the implementation may expose that capability, but v0.1 tests/release claims must not promise HEIC/HEIF.

### 3.2 Folder contents changing while the viewer is open

This was not separately decided but is required for a coherent “current folder” model.

**Implementation default:** watch only the active directory. Add/remove/rename events trigger a debounced rescan that preserves the current file by URL/file identity when possible. Never recurse.

### 3.3 Finder integration / opening methods

**Implementation baseline:** support Finder double-click / Open With for registered v0.1 types, `⌘O`, drag a supported file onto the app/viewer, and direct `open -a` file events. Opening a file creates/reuses a window according to H2+H3.

### 3.4 Corrupt, partially readable and externally removed files

**Implementation default:** never crash or block the UI. Show a compact non-modal error state, keep folder navigation alive, and allow next/previous. If current file disappears externally, apply the same “prefer next, else previous” navigation semantics as V4 without moving anything to Trash.

### 3.5 Exact 100% semantics on Retina

**Implementation default:** `100%` means **1 image pixel = 1 physical display pixel** at the current screen backing scale. Fit and Fit×2 remain independent scale concepts.

### 3.6 Cache / memory behavior

**Implementation default:** thumbnails and decoded full images are lazy and cancellable. Keep current + nearest neighbors preferentially; evict by decoded byte cost. Do not decode every file in a large folder. No persistent disk thumbnail cache is required in v0.1.

### 3.7 No v0.1 feature commitment for these items

The prior discussion did not commit to slideshow, permanent image editing, rename/move, clipboard editing, “always on top”, custom tabs, updater, cloud/network features, telemetry, RAW/pro formats, HDR/EDR or fully customizable toolbar. They stay out of v0.1 unless separately added.

---

## 4. UI model

### 4.1 Viewer window

A viewer is a standard `NSWindow`:

```text
ViewerWindow (standard NSWindow)
└── ViewerRootView
    ├── ImageCanvas
    ├── TopHoverRegion / drag region
    │   ├── standard traffic-light buttons
    │   ├── filename
    │   └── tool controls
    ├── ThumbnailDrawer (overlay)
    ├── BottomInfoBar (overlay)
    └── NavigatorMinimap (overlay)
```

Rules:

- no true borderless main window;
- no native window tabs;
- no hover `NSPanel`;
- no separate thumbnail window;
- no fake red/yellow/green buttons;
- top transparent region remains a normal window drag area except where controls consume events;
- full screen uses `NSWindow.toggleFullScreen`;
- immersive mode changes only chrome visibility state.

### 4.2 Hover state priority

1. Active pointer interaction always reveals relevant chrome.
2. Top region controls top chrome only.
3. Left-edge region controls thumbnail drawer only.
4. `zoom > Fit` permits minimap; Fit hides it.
5. Immersive mode starts with all chrome hidden but still allows temporary hover reveal.
6. idle fade never blocks keyboard navigation or animation playback.

---

## 5. Core domain model

```swift
struct FolderItem: Identifiable, Hashable {
    let id: FileIdentity
    let url: URL
    let displayName: String
    let fileType: ImageFileType
    let byteSize: Int64?
    let creationDate: Date?
    let modificationDate: Date?
}

struct DecodedImage {
    let sourceURL: URL
    let pixelSize: CGSize
    let colorSpace: CGColorSpace?
    let orientation: CGImagePropertyOrientation
    let frames: [DecodedFrame]
    let pageCount: Int
    let metadata: ImageMetadata
}

struct DecodedFrame {
    let image: CGImage
    let duration: TimeInterval?
}

struct ViewportState {
    var zoomScale: CGFloat
    var fitScale: CGFloat
    var normalizedCenter: CGPoint
    var viewRotationQuarterTurns: Int
    var mirroredHorizontally: Bool
}
```

Folder order and image decode state must remain separate. A rescan may change indices without changing the current file's stable identity.

---

## 6. Decode/render architecture

### 6.1 Decoder abstraction

```swift
protocol ImageDecoding: Sendable {
    func inspect(_ url: URL) async throws -> ImageDescriptor
    func decodeFirstDisplayableFrame(
        _ url: URL,
        target: DecodeTarget
    ) async throws -> DecodedImageHead
    func decodeRemainingFrames(
        _ url: URL,
        descriptor: ImageDescriptor
    ) -> AsyncThrowingStream<DecodedFrame, Error>
}
```

Primary decoder: ImageIO/CoreGraphics.

Animated WebP rule:

- first implement and test with system ImageIO on every supported OS family;
- if timing/loop/disposal/blend behavior fails the fixture matrix, add a narrow `libwebp` decoder only for WebP;
- do not make libwebp a mandatory dependency before the parity tests justify it.

### 6.2 First-frame-first pipeline

```text
request current file
→ inspect metadata
→ decode first displayable frame
→ publish to UI immediately
→ decode remaining animation/TIFF data as needed
→ preload adjacent files at lower priority
```

Decode tasks carry a generation/token. Switching files cancels obsolete current/preload work.

### 6.3 Thumbnail pipeline

Use ImageIO thumbnail/downsample APIs and EXIF transform at thumbnail creation time. Never full-decode an 8K/100MP source merely to create a ~200 px drawer thumbnail.

### 6.4 Rendering

Use a layer-backed AppKit canvas with `CGImage` content and explicit viewport transforms. Keep normalized image center (`0...1`) so window resize and screen changes preserve the user's focal point. The minimap derives its viewport rectangle from the same model.

---

## 7. Sorting and folder behavior

Default order uses natural filename comparison so `2.jpg` precedes `10.jpg`.

Dimension sorting is lazy: inspect dimensions only when that sort mode is selected. Directory watcher events are debounced and re-run filtering/sorting without recursively entering children.

Supported extension/UTType checks are only a fast eligibility filter; actual decoder inspection remains authoritative.

---

## 8. Settings defaults

| Setting | Default |
|---|---|
| Thumbnail filenames | Hover |
| Sort | Natural filename, ascending |
| Browse subfolders | Off / not offered in v0.1 |
| Open file | New window |
| Top filename | On |
| Bottom fields | Index/total + zoom + dimensions |
| Window size | Remember last viewer size |
| Mouse wheel | Zoom |
| Trackpad horizontal swipe | Smart |
| Double-click | Fit ↔ Fit×2 |
| Animated image autoplay | On |
| Animated loop | Follow source |
| Delete follow-up | Smart next/previous |
| Viewer appearance | Follow System |
| Full Screen | Native, user-triggered |
| Immersive Mode | Off |

---

## 9. v0.1 non-functional requirements

- Main-thread file I/O and decode are prohibited.
- Folder navigation remains responsive during thumbnail generation.
- Switching images cancels stale decode/preload work.
- A folder with 10,000 supported filenames must not attempt 10,000 full decodes.
- A corrupt image cannot crash the process or strand navigation.
- Window-manager-visible window count equals the number of actual viewer/settings windows, not thumbnail/hover UI.
- Tiling/Mission Control/Stage Manager/native Full Screen must continue to recognize the viewer as an ordinary macOS window.
- App launches and works without network access.
- No source image is modified by rotate/mirror/view operations.
- Trash uses the system trash API, never permanent unlink as the normal Delete action.

---

## 10. Future phases explicitly outside v0.1

Candidate later work: HEIC/HEIF hard guarantee (if not promoted), RAW, AVIF/JPEG XL/SVG/PSD, HDR/EDR, persistent thumbnail cache, slideshow, permanent rotate/save, J3 customizable toolbar, custom in-window tabs, richer editing/file management and signed/notarized distribution after joining Apple Developer Program.
