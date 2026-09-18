# PicViewMac

A fast, native macOS image viewer with a Picview-style minimalist experience:
the image is the focus, chrome appears on hover, and a left-edge drawer shows the
current folder.

- **Platform:** macOS 14 Sonoma and later
- **Distribution:** independent `.app` / `.dmg` (no App Store, no paid Apple
  Developer Program required for v0.1)
- **Status:** v0.1 implementation — see `docs/release/v0.1-checklist.md` for what
  is verified and what still needs a human

## Build and run

```bash
swift build                 # debug build
swift run                   # launch the viewer
swift test                  # 138 unit tests
xcodebuild -scheme PicViewMac -destination 'platform=macOS' test   # same suite
```

Release artifacts:

```bash
./scripts/build-release.sh  # dist/PicViewMac.app (ad-hoc signed)
./scripts/make-dmg.sh       # dist/PicViewMac-0.1.0.dmg
```

macOS hands an unsigned, un-notarized app to Gatekeeper; the per-app
**Open Anyway** path is documented in
`docs/release/unsigned-installation.md`.

## Acceptance runner

There is an in-app acceptance runner that drives the production code paths and
prints a pass/fail report. It exists because the behavior that matters most here
(hover chrome, drawer geometry, animation playback, Trash) is hard to assert from
unit tests alone:

```bash
PICVIEW_SELFTEST=/path/to/photo.jpg dist/PicViewMac.app/Contents/MacOS/PicViewMac
```

It ends with `=== ALL PASSED ===` or a list of failures.

## Test fixtures

`scripts/make-fixtures.swift` generates every fixture used by the test suite —
BMP, GIF (static/animated/finite-loop), ICO (multi-size), PNG, JPEG with EXIF
orientation, multi-page TIFF, Display P3, corrupt and unsupported files. WebP
files are produced by the `webp` tools, because ImageIO on macOS decodes WebP but
cannot encode it:

```bash
brew install webp                       # cwebp / img2webp, needed once
swift scripts/make-fixtures.swift PicViewMacTests/Fixtures
```

## Features (v0.1)

- Standard `NSWindow` (visually titleless, **not** borderless) with native tabs
  disabled, so Mission Control, tiling and Stage Manager keep working.
- Hover-revealed top bar with the real traffic-light buttons, middle-truncated
  filename and the rotate / mirror / Fit / 100 % / Trash / More tools.
- Left-edge hover drawer with large single-column thumbnails, configurable
  filename display and current-item highlighting; it overlays the image and
  never reflows it.
- Zoom navigator minimap that only exists while `zoom > Fit`.
- Pointer-centered wheel zoom, pinch always zooms, drag pan, and a smart
  trackpad swipe that pans first and switches images at the edge.
- Formats: BMP, GIF, ICO, PNG, JPG/JPEG, TIF/TIFF, WebP — including animated GIF,
  animated WebP and multi-page TIFF.
- EXIF orientation is honored for display without ever rewriting the file;
  rotation and mirroring are view-only.
- Color-managed SDR rendering (sRGB and Display P3 preserved through decode).
- Large images decode into a bounded level (1024–8192) chosen from the canvas
  size, and the bitmap is materialized off the main thread, so opening a 1.9 GiB
  48000×32000 PNG costs one decode pass instead of four and no main-thread stall.
  Zooming past what that proxy can resolve adds native-detail tiles on top: on the
  48000×32000 image at 100 %, the visible region carries 91 % of the source's own
  detail energy (the proxy alone carries 16 %), in ~10 s behind a 220 ms debounce.
  Rendering is on-demand Metal with mandatory mipmaps and a Quartz fallback
  (`PICLIGHT_DISABLE_METAL=1` forces Quartz); a resize or a zoom-in upgrades the
  level only after a 300 ms debounce and never during a drag, and the viewer says
  "正在解码…" while the first frame of a big file is still being decoded.
- Folder watching with debounced rescans that preserve the current file by
  identity, and Move to Trash with smart next/previous selection.
- Configurable settings and customizable viewer shortcuts with conflict
  rejection.

## Architecture

```text
PicViewMac/
├── App/          app lifecycle, file-open coordination, supported types
├── Window/       standard viewer window, placement rules
├── Folder/       scanning, sorting, session, directory watching
├── Imaging/      decode, caches, thumbnails, animation clock, WebP parity
├── Viewer/       canvas, viewport, gestures, hover chrome, minimap
├── Sidebar/      virtualized thumbnail drawer
├── Metadata/     metadata reading and the read-only info panel
├── Settings/     typed settings, shortcuts, settings UI
├── Appearance/   system appearance, materials, accessibility
└── Commands/     command set, routing, main menu
```

Folder order and decode state are deliberately separate: a rescan or a sort
change can move the current file to a new index without the viewer losing its
place, and a superseded decode can never publish over a newer one.

## Privacy before publishing

The repository is self-contained and carries no personal data: no credentials or
tokens, no personal email addresses, no home-directory paths, no private network
addresses, and no machine-specific paths in scripts (`make-fixtures.swift`
resolves the webp tools through `PATH`). Commits use a GitHub noreply address.

Re-check any time with:

```bash
./scripts/privacy-audit.sh
```

Note that git history always publishes the author identity. If you are publishing
yourself, decide which name and address you want in the commits and tag **before
the first push**, because rewriting history afterwards is far more disruptive.

## Known gaps

Tracked in `docs/release/v0.1-checklist.md`. In short: the visual/interaction
matrix (Mission Control, tiling, Stage Manager, native Full Screen, third-party
window managers), a visual pass on Light/Dark and accessibility appearance, and
an Instruments memory profile all still need a human at a display.

At 100 % an oversized source is served by **native-detail tiles**: the app streams the PNG
itself (ImageIO has no region decode — a 512×512 crop costs a full decode, measured), keeps
only the tiles the viewport needs plus a ring, and draws them over the bounded proxy. The
8192 proxy remains the base layer and the whole answer at Fit. Tiles live in memory, so
revisiting a far region costs another pass, and the backend serves PNG that is 8-bit and not
interlaced — other formats keep the proxy path.

One packaging limit remains: a released build wants a compiled `default.metallib` —
`scripts/build-release.sh` fails loudly without the Metal toolchain
(`xcodebuild -downloadComponent MetalToolchain`) instead of shipping a fallback-only app,
while a local run compiles the shipped `ImageShaders.metal` source at startup and says so.
