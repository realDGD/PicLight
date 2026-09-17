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

## Known gaps

Tracked in `docs/release/v0.1-checklist.md`. In short: the visual/interaction
matrix (Mission Control, tiling, Stage Manager, native Full Screen, third-party
window managers), a visual pass on Light/Dark and accessibility appearance, and
an Instruments memory profile all still need a human at a display.
