# PicViewMac v0.1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a native macOS 14+ minimalist image viewer with a Picview-style hover UI, left-edge current-folder thumbnail drawer, fast image navigation, animation/TIFF support, color-managed rendering and ordinary `NSWindow` behavior that remains compatible with macOS window management.

**Architecture:** AppKit owns app/window lifecycle, viewer composition and high-performance image interaction. Core folder/decode/cache/viewport logic is isolated into focused Swift types with XCTest coverage. ImageIO/CoreGraphics/ColorSync are the default image stack; WebP gets a libwebp-specific path only if system parity tests prove it necessary.

**Tech Stack:** Swift 6 language mode where practical, AppKit, ImageIO, CoreGraphics, CoreAnimation, ColorSync, UniformTypeIdentifiers, XCTest; macOS deployment target 14.0.

**Spec:** `docs/specs/2026-09-17-picview-macos-v0.1-spec.md`

## Global Constraints

- Minimum supported OS: macOS 14 Sonoma.
- Main viewer is a standard `NSWindow`, visually titleless but **not** a true borderless/special window.
- One visible viewer equals one top-level `NSWindow`; hover bars, minimap and thumbnail drawer remain inside that window.
- Disable native window tabbing; never use `addTabbedWindow`, `tabGroup` or a separate overlay `NSPanel`.
- Current-folder browsing is non-recursive.
- Default opening behavior creates a new window; reuse-current is a setting.
- v0.1 hard-required formats: BMP, GIF, ICO, PNG, JPG/JPEG, TIF/TIFF, WebP.
- HEIC/HEIF are not a v0.1 release claim until scope is explicitly reconfirmed.
- Rotation/mirror are view-only in v0.1.
- Delete means Move to Trash.
- Full Screen and Immersive Mode are distinct features.
- Default appearance follows the system; use availability-gated native Liquid Glass on macOS 26+, never a hand-drawn imitation.
- No required network service, telemetry or cloud dependency.
- No App Store sandbox requirement for v0.1 independent distribution.
- No Apple Developer Program / Developer ID / notarization requirement for v0.1 release flow.

---

## File structure to create

```text
PicViewMac/
├── PicViewMac.xcodeproj/
├── PicViewMac/
│   ├── App/
│   │   ├── AppDelegate.swift
│   │   ├── AppEnvironment.swift
│   │   ├── FileOpenCoordinator.swift
│   │   └── SupportedImageTypes.swift
│   ├── Window/
│   │   ├── ViewerWindow.swift
│   │   ├── ViewerWindowController.swift
│   │   └── WindowPlacementStore.swift
│   ├── Folder/
│   │   ├── FileIdentity.swift
│   │   ├── FolderItem.swift
│   │   ├── FolderSession.swift
│   │   ├── FolderScanner.swift
│   │   ├── FolderWatcher.swift
│   │   └── ImageSort.swift
│   ├── Imaging/
│   │   ├── ImageDescriptor.swift
│   │   ├── ImageMetadata.swift
│   │   ├── ImageDecoder.swift
│   │   ├── ImageIODecoder.swift
│   │   ├── DecodeCoordinator.swift
│   │   ├── DecodeCache.swift
│   │   ├── ThumbnailPipeline.swift
│   │   ├── ThumbnailCache.swift
│   │   ├── AnimationClock.swift
│   │   └── WebPParity.swift
│   ├── Viewer/
│   │   ├── ViewerViewController.swift
│   │   ├── ViewerState.swift
│   │   ├── ViewportState.swift
│   │   ├── ImageCanvasView.swift
│   │   ├── GestureRouter.swift
│   │   ├── NavigatorView.swift
│   │   ├── TopHoverBarView.swift
│   │   ├── BottomInfoBarView.swift
│   │   └── HoverVisibilityController.swift
│   ├── Sidebar/
│   │   ├── ThumbnailDrawerView.swift
│   │   ├── ThumbnailItemView.swift
│   │   └── ThumbnailFilenameMode.swift
│   ├── Metadata/
│   │   ├── MetadataReader.swift
│   │   └── ImageInfoViewController.swift
│   ├── Settings/
│   │   ├── AppSettings.swift
│   │   ├── SettingsView.swift
│   │   ├── ShortcutDefinition.swift
│   │   └── ShortcutStore.swift
│   ├── Appearance/
│   │   ├── ViewerAppearance.swift
│   │   ├── MaterialHostView.swift
│   │   └── AccessibilityAppearance.swift
│   ├── Commands/
│   │   ├── ViewerCommand.swift
│   │   ├── ViewerCommandRouter.swift
│   │   └── MainMenuBuilder.swift
│   └── Resources/
│       └── Assets.xcassets
├── PicViewMacTests/
│   ├── FolderScannerTests.swift
│   ├── FolderSessionTests.swift
│   ├── ImageSortTests.swift
│   ├── ImageIODecoderTests.swift
│   ├── ThumbnailPipelineTests.swift
│   ├── DecodeCoordinatorTests.swift
│   ├── ViewportStateTests.swift
│   ├── GestureRouterTests.swift
│   ├── AnimationClockTests.swift
│   ├── AppSettingsTests.swift
│   └── Fixtures/
├── docs/
│   ├── specs/
│   │   └── 2026-09-17-picview-macos-v0.1-spec.md
│   ├── superpowers/plans/
│   │   └── 2026-09-17-picview-macos-v0.1-implementation-plan.md
│   └── release/
│       └── unsigned-installation.md
└── scripts/
    ├── build-release.sh
    └── make-dmg.sh
```

---

## Task 1: Bootstrap the native macOS app and prove ordinary-window behavior

**Files:**
- Create: `PicViewMac/App/AppDelegate.swift`
- Create: `PicViewMac/Window/ViewerWindow.swift`
- Create: `PicViewMac/Window/ViewerWindowController.swift`
- Create: `PicViewMac/App/AppEnvironment.swift`
- Create: `PicViewMacTests/WindowPolicyTests.swift`

**Interfaces:**
- Produces: `ViewerWindowController.open(url: URL?)`
- Produces: `ViewerWindow.configureStandardViewerChrome()`

- [ ] **Step 1: Create the Xcode macOS app target with deployment target 14.0 and XCTest target.**
- [ ] **Step 2: Write a failing window-policy test around the pure policy values.**

```swift
func testViewerWindowPolicyDisablesNativeTabsAndKeepsStandardStyle() {
    let policy = ViewerWindow.Policy.default
    XCTAssertTrue(policy.styleMask.contains(.titled))
    XCTAssertTrue(policy.styleMask.contains(.resizable))
    XCTAssertTrue(policy.styleMask.contains(.fullSizeContentView))
    XCTAssertFalse(policy.styleMask.contains(.borderless))
    XCTAssertEqual(policy.tabbingMode, .disallowed)
}
```

- [ ] **Step 3: Run the targeted test and confirm it fails because `ViewerWindow.Policy` does not exist.**

```bash
xcodebuild test -scheme PicViewMac -destination 'platform=macOS' \
  -only-testing:PicViewMacTests/WindowPolicyTests
```

- [ ] **Step 4: Implement `ViewerWindow.Policy.default`, set `NSWindow.allowsAutomaticWindowTabbing = false` during app launch, and create the standard style mask.**

```swift
struct Policy {
    let styleMask: NSWindow.StyleMask
    let tabbingMode: NSWindow.TabbingMode

    static let `default` = Policy(
        styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
        tabbingMode: .disallowed
    )
}
```

Configure transparent titlebar, hidden title, no toolbar, standard traffic-light buttons retained.

- [ ] **Step 5: Verify the test passes and manually verify Mission Control/native tiling sees exactly one viewer window.**
- [ ] **Step 6: Commit.**

```bash
git add PicViewMac PicViewMacTests
git commit -m "feat: bootstrap standard viewer window"
```

**Acceptance gate:** ordinary `NSWindow`; no native tabs; no borderless window; no overlay windows.

---

## Task 2: Register v0.1 file types and route all opening paths through one coordinator

**Files:**
- Create: `PicViewMac/App/SupportedImageTypes.swift`
- Create: `PicViewMac/App/FileOpenCoordinator.swift`
- Modify: app target Info.plist/document type declarations
- Test: `PicViewMacTests/SupportedImageTypesTests.swift`

**Interfaces:**
- Produces: `SupportedImageTypes.isCandidate(_ url: URL) -> Bool`
- Produces: `FileOpenCoordinator.open(urls: [URL], behavior: OpenBehavior)`

- [ ] **Step 1: Write failing tests covering `.bmp`, `.gif`, `.ico`, `.png`, `.jpg`, `.jpeg`, `.tif`, `.tiff`, `.webp`, uppercase extensions and an unsupported `.pdf`.**
- [ ] **Step 2: Run and verify failure.**
- [ ] **Step 3: Implement canonical v0.1 type filtering using `UTType` when available plus extension fallback for candidate filtering.**
- [ ] **Step 4: Register Finder/Open With document types and forward `application(_:open:)`, `⌘O`, drag-open and explicit menu opens to `FileOpenCoordinator`.**
- [ ] **Step 5: Add `OpenBehavior` with `.newWindow`, `.reuseCurrent`, and `.configuredDefault`; modifier inversion is resolved only in the command layer.**
- [ ] **Step 6: Run tests and manually open one file from Finder.**
- [ ] **Step 7: Commit.**

```bash
git commit -am "feat: route supported image opening"
```

---

## Task 3: Implement current-folder scanning, stable identity and natural sorting

**Files:**
- Create: `Folder/FileIdentity.swift`
- Create: `Folder/FolderItem.swift`
- Create: `Folder/FolderScanner.swift`
- Create: `Folder/ImageSort.swift`
- Test: `FolderScannerTests.swift`, `ImageSortTests.swift`

**Interfaces:**
- Produces: `FolderScanner.scan(containing fileURL: URL) async throws -> [FolderItem]`
- Produces: `ImageSort.sort(_:by:direction:) -> [FolderItem]`

- [ ] **Step 1: Add fixture-directory tests proving no subdirectory recursion and `2.jpg < 10.jpg` in filename order.**
- [ ] **Step 2: Add tests for modification date, creation date, byte size, ascending/descending.**
- [ ] **Step 3: Implement directory enumeration with the exact resource keys needed for current sort; skip directories/packages as image items.**
- [ ] **Step 4: Implement natural filename comparison with stable URL tie-breaker.**
- [ ] **Step 5: Implement lazy dimension lookup path used only by dimension sort.**
- [ ] **Step 6: Run tests and commit.**

```bash
git commit -am "feat: scan and sort current folder"
```

---

## Task 4: Build `FolderSession` and live directory updates

**Files:**
- Create: `Folder/FolderSession.swift`
- Create: `Folder/FolderWatcher.swift`
- Test: `FolderSessionTests.swift`

**Interfaces:**
- Produces: `FolderSession.currentItem`
- Produces: `FolderSession.items`
- Produces: `FolderSession.goNext()`, `goPrevious()`, `rescanPreservingCurrent()`

- [ ] **Step 1: Write tests that preserve current file identity across insert/rename/resort when possible.**
- [ ] **Step 2: Write tests that externally removing current item selects next, else previous, else empty state.**
- [ ] **Step 3: Implement session navigation independent of sort implementation.**
- [ ] **Step 4: Implement a directory file-descriptor `DispatchSource` watcher with debounce; watcher only schedules rescan and never recursively watches children.**
- [ ] **Step 5: Run tests and commit.**

```bash
git commit -am "feat: keep folder session in sync"
```

---

## Task 5: Define image descriptors, metadata and the ImageIO decoder

**Files:**
- Create: `Imaging/ImageDescriptor.swift`
- Create: `Imaging/ImageMetadata.swift`
- Create: `Imaging/ImageDecoder.swift`
- Create: `Imaging/ImageIODecoder.swift`
- Create: `Metadata/MetadataReader.swift`
- Test: `ImageIODecoderTests.swift`
- Add: self-owned/generated fixtures for every required format

**Interfaces:**
- Produces: `ImageDecoding.inspect`
- Produces: `ImageDecoding.decodeFirstDisplayableFrame`
- Produces: `ImageDecoding.decodeRemainingFrames`

- [ ] **Step 1: Create tiny deterministic fixtures: BMP, static GIF, animated GIF, ICO with multiple sizes, PNG, JPEG with EXIF orientation, multi-page TIFF, static WebP, animated WebP, corrupt file, ICC/P3 test image.**
- [ ] **Step 2: Write descriptor tests for dimensions, frame/page count, orientation and metadata presence.**
- [ ] **Step 3: Write tests proving an oriented JPEG reports the correct display orientation without rewriting the source.**
- [ ] **Step 4: Implement ImageIO source creation with incremental metadata inspection and structured decoder errors.**
- [ ] **Step 5: Implement first-displayable-frame decode and preserve source color-space data.**
- [ ] **Step 6: Implement TIFF page enumeration and ICO representation selection by target pixel requirement.**
- [ ] **Step 7: Run tests and commit.**

```bash
git commit -am "feat: decode required image formats with ImageIO"
```

---

## Task 6: Prove animated WebP system parity before adding any third-party decoder

**Files:**
- Create: `Imaging/WebPParity.swift`
- Test: `ImageIODecoderTests.swift`

**Interfaces:**
- Produces: `WebPParityReport` used only by tests/build decision.

- [ ] **Step 1: Add animated WebP fixtures that exercise multiple frame durations, alpha, blend/disposal behavior and finite/infinite loops.**
- [ ] **Step 2: Write tests comparing decoded frame count, canvas size, duration sequence and loop metadata to known fixture expectations.**
- [ ] **Step 3: Run the matrix on the current build SDK/runtime and record failures in the test output.**
- [ ] **Step 4: If all parity tests pass, keep ImageIO and do not add libwebp. If any required behavior fails, add a narrowly scoped `WebPDecoder.swift` backed by libwebp and keep all other formats on ImageIO.**
- [ ] **Step 5: If libwebp is introduced, add its BSD notice and attribution to release notices.**
- [ ] **Step 6: Commit the chosen decoder path with the parity tests as evidence.**

```bash
git commit -am "test: lock animated webp decoding behavior"
```

---

## Task 7: Implement cancellable decode coordination, adjacent preload and bounded caches

**Files:**
- Create: `Imaging/DecodeCoordinator.swift`
- Create: `Imaging/DecodeCache.swift`
- Create: `Imaging/ThumbnailCache.swift`
- Test: `DecodeCoordinatorTests.swift`

**Interfaces:**
- Produces: `DecodeCoordinator.show(item:)`
- Produces: first-frame publication + later animation-frame stream
- Produces: direction hint `.forward/.backward/.unknown`

- [ ] **Step 1: Write a fake decoder test proving switching A→B cancels A publication even if A finishes later.**
- [ ] **Step 2: Write tests proving forward navigation prioritizes next then previous; backward navigation reverses priority.**
- [ ] **Step 3: Implement task-generation tokens and cancellation.**
- [ ] **Step 4: Implement cost-based `NSCache` storage. Prefer current, previous and next; never eagerly full-decode the directory.**
- [ ] **Step 5: Set decoded-image cache cost from actual bytes (`bytesPerRow × height` per frame) and respond to memory-pressure notifications by purging non-current entries.**
- [ ] **Step 6: Run tests and commit.**

```bash
git commit -am "feat: preload adjacent images with bounded cache"
```

---

## Task 8: Implement lazy thumbnail generation and the A/A1/B1/C3 drawer

**Files:**
- Create: `Imaging/ThumbnailPipeline.swift`
- Create: `Sidebar/ThumbnailDrawerView.swift`
- Create: `Sidebar/ThumbnailItemView.swift`
- Create: `Sidebar/ThumbnailFilenameMode.swift`
- Test: `ThumbnailPipelineTests.swift`

**Interfaces:**
- Produces: `ThumbnailPipeline.thumbnail(for:maxPixelSize:) async throws -> CGImage`
- Consumes: `FolderSession.items`
- Emits: selected `FolderItem.ID`

- [ ] **Step 1: Write a test proving thumbnail generation requests a bounded pixel size and applies EXIF transform.**
- [ ] **Step 2: Implement ImageIO downsampling without full-resolution decode.**
- [ ] **Step 3: Implement a ~12 px invisible left-edge tracking area, overlay drawer width constrained to 180–220 px, ~150 ms reveal and ~250 ms delayed close.**
- [ ] **Step 4: Implement single-column large cells, independent scroll, current-item highlight and auto-scroll-current-into-view on keyboard navigation.**
- [ ] **Step 5: Implement Never/Always/Hover filename modes, default Hover.**
- [ ] **Step 6: Verify opening the drawer never changes canvas frame/zoom state.**
- [ ] **Step 7: Commit.**

```bash
git commit -am "feat: add hover thumbnail drawer"
```

---

## Task 9: Implement viewport math, Fit, physical-pixel 100% and resize stability

**Files:**
- Create: `Viewer/ViewportState.swift`
- Create: `Viewer/ViewerState.swift`
- Test: `ViewportStateTests.swift`

**Interfaces:**
- Produces: `fitScale(imagePixels:viewPoints:backingScale:)`
- Produces: `actualPixelScale(backingScale:)`
- Produces: normalized center and viewport rectangle

- [ ] **Step 1: Write tests for Fit on landscape/portrait images and for 100% = 1 image pixel per physical display pixel.**
- [ ] **Step 2: Write a resize test proving the normalized center stays stable as view dimensions change.**
- [ ] **Step 3: Write a test for default double-click `Fit ↔ Fit×2`.**
- [ ] **Step 4: Implement scale calculations and normalized-center clamping.**
- [ ] **Step 5: Implement view-only quarter-turn rotation and horizontal mirror in state.**
- [ ] **Step 6: Run tests and commit.**

```bash
git commit -am "feat: define stable image viewport math"
```

---

## Task 10: Render the image canvas and pointer-centered zoom/pan

**Files:**
- Create: `Viewer/ImageCanvasView.swift`
- Create: `Viewer/GestureRouter.swift`
- Test: `GestureRouterTests.swift`

**Interfaces:**
- Consumes: `DecodedImageHead`, `ViewportState`
- Produces: pointer/gesture intents, never folder navigation directly

- [ ] **Step 1: Write pure gesture-routing tests for wheel mode, pinch-always-zoom and drag-pan.**
- [ ] **Step 2: Implement a layer-backed AppKit canvas that draws the current `CGImage` with color-space preserved.**
- [ ] **Step 3: Implement pointer-centered wheel zoom and pinch zoom.**
- [ ] **Step 4: Implement drag pan and two-finger pan while zoomed.**
- [ ] **Step 5: Clamp panning to meaningful image bounds while permitting the smart-edge swipe detector to observe overscroll intent.**
- [ ] **Step 6: Run tests and commit.**

```bash
git commit -am "feat: render and navigate zoomed images"
```

---

## Task 11: Implement N4 smart swipe navigation

**Files:**
- Modify: `Viewer/GestureRouter.swift`
- Test: `GestureRouterTests.swift`

**Interfaces:**
- Produces: `GestureIntent.pan`, `.previousImage`, `.nextImage`

- [ ] **Step 1: Write tests for: Fit→switch; zoomed-and-not-edge→pan; zoomed-at-edge-with-continued-swipe→switch.**
- [ ] **Step 2: Add modes `.smart`, `.alwaysSwitch`, `.alwaysPan`, `.disabled`.**
- [ ] **Step 3: Implement hysteresis so a small accidental overscroll does not switch images.**
- [ ] **Step 4: Run tests and commit.**

```bash
git commit -am "feat: add smart trackpad edge navigation"
```

---

## Task 12: Implement the P1 navigator/minimap from the shared viewport model

**Files:**
- Create: `Viewer/NavigatorView.swift`
- Modify: `Viewer/ViewerViewController.swift`

**Interfaces:**
- Consumes: normalized viewport from `ViewportState`
- Produces: requested normalized center

- [ ] **Step 1: Write geometry tests mapping a main viewport to minimap rectangle coordinates.**
- [ ] **Step 2: Render a low-cost full-image preview in the bottom-right only when `zoom > fitScale`.**
- [ ] **Step 3: Implement viewport dragging and click-to-center.**
- [ ] **Step 4: Connect minimap visibility to the shared idle controller: show on zoom/pan/mouse, fade after ~1.5 s, hide at Fit.**
- [ ] **Step 5: Commit.**

```bash
git commit -am "feat: add zoom navigator minimap"
```

---

## Task 13: Implement animation playback and multi-page TIFF navigation

**Files:**
- Create: `Imaging/AnimationClock.swift`
- Modify: `Viewer/ViewerState.swift`
- Test: `AnimationClockTests.swift`

**Interfaces:**
- Produces: `PlaybackState.staticImage/playing/paused`
- Produces: frame index changes respecting source durations and loop count
- TIFF page index is separate from folder index

- [ ] **Step 1: Write clock tests with deterministic injected time for variable frame durations and finite/infinite loops.**
- [ ] **Step 2: Implement autoplay setting, default on.**
- [ ] **Step 3: Bind Space to pause/resume only when current content is animated.**
- [ ] **Step 4: Stop clock on image switch; revisiting starts from frame 0 in v0.1.**
- [ ] **Step 5: Implement TIFF Page Up/Page Down without changing folder item.**
- [ ] **Step 6: Show TIFF `page / count` in image information/bottom chrome without confusing it with folder `index / total`.**
- [ ] **Step 7: Commit.**

```bash
git commit -am "feat: play animations and browse tiff pages"
```

---

## Task 14: Build hover chrome with real standard window controls

**Files:**
- Create: `Viewer/HoverVisibilityController.swift`
- Create: `Viewer/TopHoverBarView.swift`
- Create: `Viewer/BottomInfoBarView.swift`
- Modify: `Viewer/ViewerViewController.swift`

**Interfaces:**
- Produces: independent visibility state for top, bottom, drawer and minimap
- Consumes: pointer activity + immersive state

- [ ] **Step 1: Write state-machine tests for top enter, delayed leave (~300 ms), idle hide (~1.5–2 s) and interaction reveal.**
- [ ] **Step 2: Place the real `standardWindowButton` controls in the full-size titlebar layout; fade/hide them rather than replacing them with custom circles.**
- [ ] **Step 3: Make the rest of the ~44 px top region a drag surface without stealing events from controls.**
- [ ] **Step 4: Add centered, middle-truncated filename controlled by I3 setting.**
- [ ] **Step 5: Add J2 tools: rotate, mirror, Fit, 100%, Trash, More. Add animation pause button only for animated content.**
- [ ] **Step 6: Add K4 bottom fields and default field set.**
- [ ] **Step 7: Commit.**

```bash
git commit -am "feat: add hover viewer chrome"
```

---

## Task 15: Implement metadata panel, orientation and color-managed SDR behavior

**Files:**
- Create: `Metadata/ImageInfoViewController.swift`
- Modify: `Metadata/MetadataReader.swift`
- Modify: `Viewer/ImageCanvasView.swift`
- Test: `ImageIODecoderTests.swift`

**Interfaces:**
- Consumes: `ImageMetadata`
- Produces: read-only image-info UI

- [ ] **Step 1: Add fixture assertions for EXIF orientation, camera/lens fields, GPS presence and ICC/P3 color space.**
- [ ] **Step 2: Ensure display transform honors source orientation while metadata reports original orientation.**
- [ ] **Step 3: Ensure `CGImage` color-space information survives decode/render path; do not flatten everything to unmanaged device RGB.**
- [ ] **Step 4: Build the read-only info panel reachable from More.**
- [ ] **Step 5: Confirm HDR/EDR is not advertised or special-cased.**
- [ ] **Step 6: Commit.**

```bash
git commit -am "feat: show metadata with color-managed sdr"
```

---

## Task 16: Implement Move to Trash and external-removal behavior

**Files:**
- Create: `Commands/ViewerCommand.swift`
- Create: `Commands/ViewerCommandRouter.swift`
- Modify: `Folder/FolderSession.swift`
- Test: `FolderSessionTests.swift`

**Interfaces:**
- Produces: `ViewerCommand.moveToTrash`
- Uses: `FileManager.trashItem(at:resultingItemURL:)`

- [ ] **Step 1: Write a folder-session test for V4 smart selection after removal.**
- [ ] **Step 2: Implement system Trash operation; never use permanent delete as the standard Delete action.**
- [ ] **Step 3: On successful trash, update/rescan and apply smart next/previous selection.**
- [ ] **Step 4: On failure, keep current item and show a non-modal error.**
- [ ] **Step 5: Handle watcher-detected external removal using the same selection policy without trashing.**
- [ ] **Step 6: Commit.**

```bash
git commit -am "feat: move images to trash safely"
```

---

## Task 17: Implement settings, persistence and W2 shortcut customization

**Files:**
- Create: `Settings/AppSettings.swift`
- Create: `Settings/SettingsView.swift`
- Create: `Settings/ShortcutDefinition.swift`
- Create: `Settings/ShortcutStore.swift`
- Create: `Commands/MainMenuBuilder.swift`
- Test: `AppSettingsTests.swift`

**Interfaces:**
- Produces: typed settings model backed by `UserDefaults`
- Produces: customizable viewer command shortcuts with conflict validation

- [ ] **Step 1: Write default-value tests matching the spec table exactly.**
- [ ] **Step 2: Implement typed settings for C3/D4/H/L/M/N/O/R/V/Y plus bottom-field selection and top filename visibility.**
- [ ] **Step 3: Implement fixed system shortcuts (`⌘O`, `⌘W`, `⌘,`, `⌘Q`, native full screen) and customizable viewer commands.**
- [ ] **Step 4: Reject shortcut conflicts rather than silently overriding another command.**
- [ ] **Step 5: Build native Settings UI.**
- [ ] **Step 6: Commit.**

```bash
git commit -am "feat: persist viewer settings and shortcuts"
```

---

## Task 18: Implement window sizing, new/reuse behavior and multi-screen placement

**Files:**
- Create: `Window/WindowPlacementStore.swift`
- Modify: `Window/ViewerWindowController.swift`
- Modify: `App/FileOpenCoordinator.swift`
- Test: `WindowPlacementStoreTests.swift`

**Interfaces:**
- Produces: `.rememberLastSize` and `.fitImageToScreen`
- Produces: deterministic new-window cascade

- [ ] **Step 1: Write pure geometry tests that clamp remembered/image-derived frame into a screen's visible frame.**
- [ ] **Step 2: Persist last viewer content size, not transient full-screen frame.**
- [ ] **Step 3: Implement image-sized mode with usable-screen bounds and Fit fallback for oversized images.**
- [ ] **Step 4: Cascade new windows and recover from disconnected monitors by clamping to an available screen.**
- [ ] **Step 5: Implement configured default new/reuse behavior plus explicit inverse command.**
- [ ] **Step 6: Commit.**

```bash
git commit -am "feat: manage viewer window placement"
```

---

## Task 19: Separate native Full Screen from Immersive Mode

**Files:**
- Modify: `Viewer/ViewerState.swift`
- Modify: `Commands/ViewerCommandRouter.swift`
- Modify: `Viewer/HoverVisibilityController.swift`
- Test: `ViewerStateTests.swift`

**Interfaces:**
- Produces: `isImmersive: Bool`
- Full screen remains native NSWindow state, not duplicated in viewer state

- [ ] **Step 1: Write tests proving immersive toggling changes chrome policy but not window geometry state.**
- [ ] **Step 2: Bind native full screen to the standard macOS command (`toggleFullScreen`).**
- [ ] **Step 3: Bind Immersive Mode to a separate command; it hides all chrome initially but permits temporary hover reveal.**
- [ ] **Step 4: Verify full screen + immersive can be active simultaneously.**
- [ ] **Step 5: Commit.**

```bash
git commit -am "feat: separate fullscreen and immersive modes"
```

---

## Task 20: Add native appearance abstraction and macOS 26+ Liquid Glass

**Files:**
- Create: `Appearance/ViewerAppearance.swift`
- Create: `Appearance/MaterialHostView.swift`
- Create: `Appearance/AccessibilityAppearance.swift`
- Modify: hover/sidebar/minimap views

**Interfaces:**
- Produces: `.system`, `.black`, `.darkGray`, `.white`, `.custom`
- Produces: a system-material host chosen by OS availability

- [ ] **Step 1: Implement Follow System without forcing `NSApp.appearance`.**
- [ ] **Step 2: On macOS 14–15, use native AppKit visual-effect/material behavior for auxiliary chrome.**
- [ ] **Step 3: Under `#available(macOS 26, *)`, use native glass APIs for appropriate interactive hover/sidebar/minimap surfaces; never place glass over the image canvas merely for decoration.**
- [ ] **Step 4: Respect Reduce Transparency and Reduce Motion by reducing/removing material/transitions instead of fighting system accessibility choices.**
- [ ] **Step 5: Manually verify Light/Dark switching while the app is running.**
- [ ] **Step 6: Commit.**

```bash
git commit -am "feat: follow native macos appearance"
```

---

## Task 21: Harden error states and huge-folder/huge-image responsiveness

**Files:**
- Modify: scanner/decoder/cache/viewer files as needed
- Add: `PicViewMacTests/StressBehaviorTests.swift`

**Interfaces:**
- No new public interface; this is a cross-component acceptance gate.

- [ ] **Step 1: Generate a temporary folder with 10,000 candidate filenames and assert scan/sort does not decode image bodies.**
- [ ] **Step 2: Add a fake slow decoder test proving stale thumbnails and full-image requests cancel when scrolled/switched away.**
- [ ] **Step 3: Add corrupt/truncated fixture tests and ensure next/previous remains usable.**
- [ ] **Step 4: Observe memory-pressure notification in cache tests and verify non-current cache eviction.**
- [ ] **Step 5: Profile a large JPEG/TIFF manually with Instruments; record peak decoded memory and main-thread stalls in `docs/performance-v0.1.md`.**
- [ ] **Step 6: Commit.**

```bash
git commit -am "test: harden large folder and decode behavior"
```

---

## Task 22: Window-manager compatibility verification

**Files:**
- Create: `docs/window-manager-compatibility.md`

**Interfaces:**
- Manual acceptance matrix only.

- [ ] **Step 1: Verify native macOS tiling and Mission Control with 1, 2 and 3 viewer windows.**
- [ ] **Step 2: Verify entering/exiting native Full Screen does not create phantom viewer windows.**
- [ ] **Step 3: Verify opening/closing thumbnail drawer, top hover bar and minimap never changes the top-level window count.**
- [ ] **Step 4: If installed, manually check Rectangle, yabai and/or AeroSpace; record observed behavior without adding app-specific hacks unless a reproducible standard-window bug exists.**
- [ ] **Step 5: Verify Stage Manager behavior.**
- [ ] **Step 6: Commit the matrix.**

```bash
git add docs/window-manager-compatibility.md
git commit -m "docs: verify standard window manager behavior"
```

---

## Task 23: Build unsigned/ad-hoc release packaging and user installation documentation

**Files:**
- Create: `scripts/build-release.sh`
- Create: `scripts/make-dmg.sh`
- Create: `docs/release/unsigned-installation.md`

**Interfaces:**
- Produces: `dist/PicViewMac.app`
- Produces: `dist/PicViewMac-<version>.dmg`

- [ ] **Step 1: Add Release archive/build command with deployment target 14.0.**
- [ ] **Step 2: Ad-hoc sign the finished bundle for structural code-sign integrity.**

```bash
codesign --force --deep --sign - "dist/PicViewMac.app"
codesign --verify --deep --strict --verbose=2 "dist/PicViewMac.app"
```

- [ ] **Step 3: Create a DMG containing the app and an Applications shortcut.**
- [ ] **Step 4: Write installation instructions: drag to Applications, attempt first launch, then System Settings → Privacy & Security → Security → Open Anyway.**
- [ ] **Step 5: Explicitly do not recommend `spctl --master-disable`, SIP disable, or global Gatekeeper disable.**
- [ ] **Step 6: Test the DMG on a clean local macOS user account before release.**
- [ ] **Step 7: Commit.**

```bash
git commit -am "build: package independent macos release"
```

---

## Task 24: v0.1 release gate

**Files:**
- Create: `docs/release/v0.1-checklist.md`

- [ ] **Step 1: Run all unit tests.**

```bash
xcodebuild test -scheme PicViewMac -destination 'platform=macOS'
```

Expected: zero failures.

- [ ] **Step 2: Build Release and verify code-sign structure.**
- [ ] **Step 3: Run format matrix: BMP, GIF, ICO, PNG, JPEG, TIFF, WebP including animation/multi-page/orientation/corrupt fixtures.**
- [ ] **Step 4: Run interaction matrix: A/A1/B1/C3/D4 through Y against the spec.**
- [ ] **Step 5: Run window-manager compatibility matrix.**
- [ ] **Step 6: Run accessibility appearance checks: Light/Dark, Reduce Transparency, Reduce Motion.**
- [ ] **Step 7: Verify no source image changed after rotate/mirror/view operations.**
- [ ] **Step 8: Verify Trash behavior and empty-folder state.**
- [ ] **Step 9: Verify offline launch and use.**
- [ ] **Step 10: Tag only after the checklist is complete.**

```bash
git tag -a v0.1.0 -m "PicViewMac v0.1.0"
```

---

## Self-review against the spec

### Coverage

- A/A1/B1/C3 → Task 8
- D4/E1 + current-folder live behavior → Tasks 3–4
- F1/G → Tasks 1, 23
- H2/H3 + standard NSWindow/no native tabs → Tasks 1, 18, 22
- top hover/I3/J2/K4 → Task 14
- L3 → Task 18
- M3/N4/O3 → Tasks 9–11
- P1 → Task 12
- Q4/R3/S2 → Tasks 5–6, 13
- T2/U2 → Task 15
- V4 → Task 16
- W2 → Task 17
- X3 → Task 19
- Y → Task 20
- performance/cancellation/error-state omissions → Tasks 7, 21
- Finder/Open With omission → Task 2
- release without paid Developer ID → Task 23

### Explicitly unresolved product scope

Only one prior-answer ambiguity remains material to v0.1 scope: whether HEIC/HEIF must be a release-guaranteed format. This plan intentionally does not make that guarantee; the architecture remains ready for it.

### No silent scope expansion

No slideshow, permanent editor, RAW/pro-format promise, HDR/EDR promise, updater, telemetry, custom tabs or J3 toolbar customization is included in v0.1.

---

## Execution order

Implement Tasks 1–5 first to reach a basic single-image viewer backed by a real folder session. Tasks 7–12 then deliver the fast Picview-like browsing feel. Tasks 13–20 complete format/UI/settings behavior. Tasks 21–24 are hardening, compatibility and release gates.

Each task is a reviewer-sized unit and should be committed separately. At execution time, create an isolated git worktree before implementation if the repository already contains other active work.
