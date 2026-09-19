# PicLight Viewer UX Redesign Spec

> Status: Draft / product spec  
> Spec branch: `spec/viewer-ux-redesign`  
> Base: `perf/bounded-metal-design@9ff015e1bd2e94dd42d537e8a2b66012ea170cb7`  
> Scope: Viewer chrome, sidebar, folder browser, context menu, titlebar behavior, thumbnail geometry, and related correctness constraints.

## 1. Goals

This iteration turns PicLight from a mostly static image viewer chrome into a more immersive, mode-driven viewer while preserving native macOS behavior and large-image correctness.

Primary goals:

1. Keep the single-image viewer minimal and mostly auto-hidden.
2. Provide explicit, discoverable controls when the user needs them.
3. Add a dedicated folder-browser mode for browsing all images in the current folder.
4. Make thumbnail layout stable across extreme aspect ratios.
5. Keep all image operations routed through shared commands/state instead of duplicating behavior.
6. Preserve large-image bounded decoding, tile-cache correctness, and existing Metal rendering behavior.
7. Keep standard macOS traffic-light buttons real; do not draw fake replacements.

## 2. Non-goals

This spec does not include:

- Gutter redesign.
- Warm-area policy redesign.
- A full replacement of every SF Symbol in the app.
- A new thumbnail-cache architecture beyond what is required for correctness or the folder browser.
- A full file manager.
- Recursive indexing of the entire disk.
- Guaranteed warm native-detail cache reuse after every disable/re-enable transition.

## 3. Viewer Modes

Introduce an explicit viewer mode:

```swift
enum ViewerMode {
    case image
    case folderBrowser
}
```

The two modes share:

- `FolderSession`
- current item / current index
- sorting state
- thumbnail pipeline/cache
- supported-image filtering

They do not share the same presentation hierarchy.

### 3.1 Image mode

Contains:

- image canvas
- auto-hiding bottom tool dock
- auto-hiding bottom-left info HUD
- optional thumbnail drawer
- left/right floating previous/next controls
- image context menu
- auto-hiding titlebar behavior

### 3.2 Folder-browser mode

Contains:

- gallery toolbar
- folder tree sidebar
- gallery collection/grid
- layout controls
- thumbnail-size slider
- sort controls
- selected/current image highlight

It is not a temporary overlay on the image canvas.

## 4. Thumbnail Drawer

### 4.1 No edge-hover reveal

Remove the current left-edge hot-zone behavior.

Moving the pointer to the left edge must not open the thumbnail drawer.

The drawer may be shown or hidden only through explicit user actions, such as:

- sidebar button
- shortcut / viewer command
- another explicit UI control

### 4.2 Filenames are always visible

Thumbnail filenames are always shown.

The old `never / always / hover` user-facing setting is removed from Settings and must not affect production behavior even if an old UserDefaults value remains.

### 4.3 Fixed square thumbnail slot

Use a fixed square thumbnail display slot instead of making the image view itself determine row geometry.

Initial target:

- thumbnail slot: `132 × 132 pt`
- filename slot: approximately `18 pt`
- row height: approximately `168 pt`

The source image must:

- preserve aspect ratio
- use aspect-fit
- be centered horizontally and vertically inside the square slot
- never be stretched
- never be cropped by default

Examples:

- 1:1 → fills the square
- 3:2 → centered letterbox vertically
- 5:1 → centered thin horizontal strip
- 1:4 → centered thin vertical strip

This removes the current “very wide image appears top-aligned” behavior.

### 4.4 Selection geometry

Selection background/card must use stable geometry based on the thumbnail slot + filename slot, not on the intrinsic source-image dimensions.

Requirements:

- no whole-row accidental fill
- no hover-induced card resize
- filename fully contained
- long filename cannot expand outside the drawer
- middle truncation for long names
- selection border remains aligned to the visible thumbnail presentation

## 5. Bottom-left Info HUD

The existing `BottomInfoBarView` remains the information source.

Typical default fields:

- current index / total
- zoom percent
- pixel dimensions

The HUD becomes auto-hiding.

Show on:

- image load
- image switch
- zoom
- pan / meaningful viewport interaction

Hide:

- after approximately 1.5–2.0 seconds of inactivity
- immediately in immersive state

Pointer movement alone should not necessarily reveal it.

The HUD is informational, not interactive, so it does not need a reveal zone.

## 6. Bottom Tool Dock

### 6.1 Auto-hide and pin

Default dock state: unpinned.

Unpinned:

- dock auto-hides
- bottom-center reveal zone shows it
- pointer over dock/reveal zone keeps it visible
- pointer exit hides it after a short delay

Pinned:

- dock stays visible whenever an image is available and the viewer is not in immersive mode

Pin button:

- always the rightmost dock control
- separator immediately before it
- unpinned: `pin.square`, `.labelColor`
- pinned: `pin.square.fill`, `.systemBlue`
- tooltip/accessibility:
  - 固定工具栏
  - 取消固定工具栏

Pin state is per viewer window/session and is not persisted unless a later product decision changes this.

### 6.2 Visibility animation

Dock show/hide:

- opacity
- small vertical translation (~8 pt)
- ~0.15–0.20 s
- Reduce Motion: no slide; direct or very short fade

Transitions must be idempotent.

Repeated `mouseMoved` events while the target visibility is already unchanged must not restart the same fade/slide animation.

### 6.3 Hover and press animation

Existing hover-neighbor behavior may remain, but press feedback must compose with it.

Model:

```
effectiveScale = hoverScale × pressScale
```

Suggested values:

- hovered item: ~1.12
- neighboring item: ~1.04
- pressed factor: ~0.92

Press down ~0.06 s, release ~0.12 s.

Reduce Motion disables unnecessary scale/bounce animation.

### 6.4 Dock content

The dock should evolve toward the following logical groups:

#### Zoom group

- zoom out button
- current zoom percentage text
- zoom in button
- fit/actual-pixel related action

Zoom step should use a multiplicative factor rather than arbitrary fixed deltas; initial recommendation: ×1.25 / ÷1.25.

The displayed percentage comes from the existing viewport state.

#### Navigation group

- previous image
- `current / total`
- next image

The center index uses the same `FolderSession.positionDescription` source as the info HUD.

#### Image actions

At minimum, actions already supported by ViewerCommand / existing dock behavior:

- rotate
- mirror
- move to trash
- fit / actual-pixel actions as applicable

#### Browser / chrome actions

- folder browser: `square.grid.3x3.square`
- thumbnail/sidebar toggle
- image info

Then:

- separator
- pin

Do not duplicate image-operation logic inside the dock; use the shared command path.

## 7. Floating Previous / Next Buttons

Add two auto-hiding floating controls at the vertical center of the canvas edges.

Symbols:

- `chevron.left`
- `chevron.right`

Behavior:

- default hidden
- reveal when pointer enters corresponding side reveal zone
- remain visible while hovered
- hide after short delay (~0.7 s)
- hover scale + press feedback consistent with the dock
- no layout reflow

Availability:

- first item: previous hidden/disabled
- last item: next hidden/disabled

Geometry:

- anchored to actual canvas edges
- if a pinned drawer reserves space, the left control follows the canvas, not the window edge

## 8. Titlebar

### 8.1 Setting

Add a Settings choice:

- 自动隐藏 — default
- 始终显示

Auto-hide is the default for new installs and for users without an existing explicit value.

### 8.2 Native traffic lights

Always use real standard window buttons:

- close
- minimize
- zoom/full-screen

Do not draw fake red/yellow/green controls.

### 8.3 Two-level reveal in auto-hide mode

Auto-hide titlebar mode has two reveal zones.

#### Zone A — traffic lights only

A narrow upward reveal region beneath the traffic-light area.

Moving upward through A reveals only the three native traffic-light buttons.

It must not reveal the full titlebar.

#### Zone B — full titlebar

Moving upward through the rest of the top reveal region shows the full titlebar.

If traffic-lights-only mode is already visible and the pointer moves from A into B, promote to full-titlebar mode.

### 8.4 Hide behavior

Keep revealed while pointer is within the visible titlebar/traffic-light controls.

After exit:

- hide after a short delay (~0.7 s)

Do not hide while:

- actively dragging the window
- a titlebar interaction is in progress
- a modal/sheet state requires stable window controls

Reduce Motion:

- no slide animation
- direct state change or very short fade

### 8.5 Window architecture

Always-visible mode should preserve the existing standard-window path.

Auto-hide mode may require `.fullSizeContentView` or equivalent native window configuration so the canvas truly occupies the titlebar region when hidden.

This is an intentional change from the previous invariant that content always begins below a permanently visible standard titlebar.

Regression targets:

- native full screen
- Mission Control
- Stage Manager
- native tiling
- window dragging
- double-click titlebar behavior
- Amethyst / yabai compatibility
- standard traffic-light actions

## 9. Folder Browser Mode

The dock button `square.grid.3x3.square` means “Browse Folder”.

Clicking it enters a dedicated folder-browser mode.

### 9.1 Return behavior

Folder-browser toolbar includes a clear back button.

Back returns to single-image mode and preserves:

- current selected image
- existing image-view viewport where possible
- current sorting state

Do not unnecessarily re-decode the current image simply because the browser mode was entered and exited.

### 9.2 Two gallery layouts

Provide two explicit layout modes next to the back button.

#### Layout A — uniform grid

- uniform item slots
- image aspect-fit inside a consistent thumbnail area
- filename below
- regular grid alignment

Suggested internal name: `uniformGrid`.

#### Layout B — adaptive/aspect-oriented grid

- items visually preserve source aspect more strongly
- wide and tall images can occupy different visual shapes/sizes
- still deterministic and scrollable

Suggested internal name: `adaptiveGrid`.

Do not call this masonry unless the implementation is actually masonry.

### 9.3 Thumbnail-size slider

Toolbar contains a slider controlling gallery thumbnail size.

Initial suggested range:

- ~80 pt minimum
- ~160 pt default
- ~320 pt maximum

The slider changes presentation size / collection layout.

Requirements:

- live reflow
- no full-source decode solely because the slider moves
- retain scroll position around current selection where possible
- thumbnail pipeline may request a larger representation only when actually needed, preferably debounced

### 9.4 Folder sidebar

In folder-browser mode, the left sidebar changes purpose.

It no longer shows image thumbnails.

It becomes a folder tree/navigator similar to the reference screenshots:

- rooted at the image's own folder: the current folder is the root row and is highlighted
- child folders, expand/collapse
- lazy-load children on expansion
- clicking a folder updates the gallery

The folders *above* the current one are deliberately not shown: the sidebar is for moving around
inside the folder that is open, not for displaying the path it lives on.

Do not recursively scan the entire disk.

### 9.5 Gallery selection and opening

Current image is visually highlighted.

Single click:

- selects image
- may update `FolderSession.currentIndex`

Double click / Return:

- enters single-image mode for the selected image

Escape:

- leaves folder-browser mode
- keeps current selection

### 9.6 Sorting

Folder browser and single-image navigation share the same sort order.

Initial required sort options:

- name
- extension
- modification date
- creation date
- file size
- ascending
- descending

Potential later additions:

- Finder order
- capture date
- tags
- random order

These are not required for the first implementation unless already supported.

## 10. Canvas Context Menu

Right-clicking the image canvas opens a context menu.

At minimum:

- 复制图像
- zoom out
- zoom in
- fit
- fit width if exposed
- actual pixels
- previous image
- next image
- rotate
- mirror
- browse folder
- show/hide thumbnail drawer
- image info
- move to trash

Actions corresponding to dock/menu functionality must route through the same `ViewerCommand` / shared command handler.

Do not implement separate versions of rotate, zoom, trash, etc.

### 10.1 Copy Image

Copy-image behavior must not silently copy only the bounded proxy while presenting it as the original image.

For very large images, do not synchronously full-decode a 48k source into multi-gigabyte memory just to satisfy Copy.

Before implementation, audit macOS pasteboard support for lazy or file-backed representations.

Required behavior:

- responsive UI
- no unbounded full decode
- accurate semantics about whether source/original data or rendered bitmap is placed on the pasteboard

## 11. Settings Window

Existing decision remains:

- fixed content size: `560 × 560`
- not resizable
- all tabs must fit without clipping

Add titlebar behavior setting:

- 自动隐藏 (default)
- 始终显示

Remove the old thumbnail-filename visibility preference from the UI.

## 12. Independent Chrome State Machines

Do not use one global “pointer moved → show all chrome” state.

The following are logically independent:

- titlebar reveal
- bottom tool dock
- left/right navigation controls
- bottom-left info HUD
- thumbnail drawer

They may share timing utilities, but their state and reveal triggers must remain independent.

## 13. Geometry Invariants

Showing or hiding chrome must not unexpectedly alter image geometry unless the user explicitly pins a layout-reserving sidebar.

Auto-hidden overlays must not change:

- canvas frame
- fit scale
- zoom scale
- normalized center

The pinned drawer may intentionally reserve canvas width.

Tool dock, floating nav controls, info HUD, and auto-hidden titlebar controls are overlays.

## 14. Performance / Large-folder Constraints

- Thumbnail drawer and folder browser must virtualize rows/items.
- Do not instantiate thousands of AppKit views at once.
- Reuse the existing thumbnail pipeline and future bounded thumbnail cache.
- Folder tree uses lazy enumeration.
- Gallery-size slider must not trigger source-resolution decoding for every mouse-move event.
- UI animations must be idempotent and must not restart on every pointer event.

## 15. Native-detail / Source-identity Correctness Prerequisite

The current native-detail source-version work must be hardened before this UX branch is considered implementation-ready.

Known remaining risk:

- same-path file replacement while the old native-detail pass is still running
- old pass may emit v1 pixels after cache version has already changed to v2
- these pixels must never be stored under the new source identity

Required contract:

A native-detail pass captures:

- source path
- stable source identity/version
- generation
- orientation
- color space
- page index

If a request arrives for the same path but a different source identity:

- invalidate/cancel old pass
- advance generation
- purge old-version entries
- start a new pass
- old pass late tiles are rejected before cache storage

Do not consider same-path correctness solved solely because a purge usually runs.

### 15.1 Source identity

The current `size + mtime` version is an improvement but is not a perfect file identity.

Longer-term shared identity should be usable by:

- native tile cache
- thumbnail cache

Candidate fields:

- canonical path
- device/volume identity
- inode/file number where available
- size
- modification time
- possibly change time/source generation

Do not rely only on `URL.resourceValues` if it can return stale cached metadata.

### 15.2 NativeTileCache source-version lifecycle

The `sourceVersions` map must not grow without bound after corresponding cache entries are gone.

Future cleanup should remove unused source-version records when safe.

## 16. Deferred Engineering Work

Still deferred unless implementation work explicitly pulls it in:

- thumbnail byte accounting using `bytesPerRow × height`
- thumbnail file identity
- bounded byte-budget thumbnail LRU
- identical native-detail request churn (`generation +3 / requests +3` on identical updates)

These should remain visible in implementation planning.

## 17. Acceptance Criteria

### Image mode

- titlebar auto-hide is default
- A-zone reveals only native traffic lights
- B-zone reveals full titlebar
- left/right nav controls reveal independently
- bottom info HUD auto-hides
- dock auto-hides when unpinned
- dock can be pinned with correct symbols/tint
- dock animations do not restart continuously on pointer movement
- drawer does not open by edge hover
- drawer filename is always visible
- drawer thumbnail slot is fixed-square and aspect-fit
- extreme wide/tall thumbnails are centered

### Folder browser

- `square.grid.3x3.square` enters folder browser
- clear back button exists
- two layout modes exist
- thumbnail-size slider works
- folder tree replaces thumbnail sidebar
- current image is highlighted
- Return/double-click opens selected image
- Esc/back returns to image mode
- sort order is shared with image navigation

### Context menu

- right-click works on canvas
- copy-image exists
- dock-equivalent actions are available
- actions route through shared commands

### Settings

- fixed 560×560
- not resizable
- titlebar auto-hide setting exists and defaults on
- no thumbnail-filename visibility setting

### Correctness / performance

- no chrome animation changes canvas geometry unexpectedly
- no unbounded view creation in large folders
- large-image copy does not synchronously full-decode multi-gigabyte bitmaps
- same-path in-flight old native pass cannot repopulate cache with stale pixels

## 18. Suggested Implementation Phases

1. Native source-identity hardening.
2. Square thumbnail-slot refactor.
3. Bottom info HUD auto-hide + remove drawer edge reveal.
4. Dock zoom/index/content refresh + idempotent transitions.
5. Floating previous/next controls.
6. Context menu and command routing.
7. Titlebar auto-hide setting + A/B reveal.
8. Folder-browser mode shell.
9. Uniform/adaptive gallery layouts + slider.
10. Folder tree sidebar + sorting integration.
11. Performance/sanitizer/real-file acceptance.
