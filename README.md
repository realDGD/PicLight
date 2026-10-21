# PicLight

A fast, native macOS image viewer with a Picview-style minimalist experience:
the image is the focus, chrome follows configurable visibility policies, and a
left thumbnail column shows the current folder when opened.

- **Platform:** macOS 14 Sonoma and later
- **Distribution:** independent `.app` / `.dmg` (no App Store, no paid Apple
  Developer Program required for v0.1)
- **Status:** v0.1 implementation — see `docs/release/v0.1-checklist.md` for what
  is verified and what still needs a human

## Install with Homebrew from source

Requires Command Line Tools with Swift 6+ and macOS SDK 26+. This route requires
a published `main` revision containing `Formula/piclight.rb` and
`Resources/Precompiled/`; older revisions cannot use it.

```bash
brew tap --custom-remote realdgd/piclight https://github.com/realDGD/PicLight.git
brew install --HEAD --build-from-source realdgd/piclight/piclight
ln -s "$(brew --prefix)/opt/piclight/PicLight.app" "/Applications/"
open "/Applications/PicLight.app"
```

The formula compiles Swift / C locally with CLT, reuses the checked icon and Metal
resources, and ad-hoc signs the app. It needs no paid Developer ID certificate.
See the [installation guide](docs/release/unsigned-installation.md) for tap trust,
the system `/Applications/PicLight.app` entry, updates and the limits of local signing.
The final settings and folder implementation is integrated alongside bounded animation;
see the [integration Agent Note](.agents/notes/implemented/2026-10-21-settings-main-integration.md).

## Build and run

```bash
swift build                 # debug build
swift run                   # launch the viewer
swift test                  # complete regression suite; report the actual count
xcodebuild -scheme PicViewMac -destination 'platform=macOS' test   # same suite
```

Release artifacts:

```bash
./scripts/build-release.sh  # dist/PicLight.app (ad-hoc signed)
./scripts/make-dmg.sh       # dist/PicLight-0.1.0.dmg
```

The product bundle is `PicLight`; the SwiftPM package and executable target remain
`PicViewMac`. Build requirements and the maintained command reference are in the
[development guide](docs/development.md).

## AI-assisted development

Start with [AGENTS.md](AGENTS.md). It routes feature work, bug fixes, verification
and review to the relevant project skills without loading every historical plan.
The [workflow index](.agents/README.md) links the skills, decision records and task
templates; the [testing guide](docs/testing.md) maps changes to focused tests,
native interaction checks and artifact validation.

```bash
python3 scripts/check-agent-docs.py
```

Downloaded bundles are ad-hoc signed without Apple notarization. The per-app
**Open Anyway** path is documented in the
[installation guide](docs/release/unsigned-installation.md).

## Acceptance runner

There is an in-app acceptance runner that drives the production code paths and
prints a pass/fail report. It exists because the behavior that matters most here
(hover chrome, drawer geometry, animation playback, Trash) is hard to assert from
unit tests alone:

```bash
PICVIEW_SELFTEST=/path/to/acceptance-image.jpg dist/PicLight.app/Contents/MacOS/PicLight
```

It ends with `=== ALL PASSED ===` or a list of failures. Its assertions require a
specific image color/orientation layout; check that the chosen input matches the
assertions before using the runner as acceptance evidence. See the
[testing guide](docs/testing.md) for the recorded fixture limitation and the
separate native-use checks.

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
- Bottom-centre tool dock (rotate / mirror / Fit / Fit width / previous / next /
  100 % / Trash / Info) that auto-hides. It returns when the pointer enters the
  invisible strip along the bottom of the image area, and stays put when pinned
  with the pin control at its right-hand end. Hovering enlarges a button and lifts
  its neighbours, pressing dips it, and neither moves the image by a pixel.
- Left thumbnail column with large single-column thumbnails, always-visible
  filenames and current-item highlighting; while open, it reserves canvas width
  and keeps Fit or the manual viewport consistent with the available area.
- Independent Show / Hide / Auto policies for the native titlebar, bottom tools
  and navigation arrows; auto-hide never moves the canvas. The zoom navigator
  minimap can be disabled in Settings → Appearance.
- [Folder access management](docs/folder-access.md): add/remove/reselect saved
  directories, restore bookmarks on launch, check actual readability, and retry
  failed browsing while preserving an explicitly opened image.
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
  48000×32000 image at 100 %, the visible region carries 100 % of the source's own
  detail energy (the proxy alone carries 18 %), in ~10 s behind a 220 ms debounce.
  Tiles are placed through the same transform as the proxy and verified against a Core
  Graphics reference pixel for pixel, and sources with EXIF orientation are mapped from
  their raw pixel space into the same canonical space the proxy uses.
  Rendering is on-demand Metal with mandatory mipmaps and a Quartz fallback
  (`PICLIGHT_DISABLE_METAL=1` forces Quartz); a resize or a zoom-in upgrades the
  level only after a 300 ms debounce and never during a drag, and the viewer says
  "正在解码…" while the first frame of a big file is still being decoded.
- Folder watching with debounced rescans that preserve the current file by
  identity, and Move to Trash with smart next/previous selection.
- Settings in a fixed 560×560 window, with configurable wheel zoom sensitivity,
  double-click actions (including folder grid, close and native full screen),
  loop browsing, last-window quit behavior and new-window always-on-top defaults.
- Copy file path (⌃⌘C), reveal in Finder (⌘Return), choose a browsing folder,
  random image (R) and toggle current-window always-on-top (⌘X).
- Optional Trash confirmation for Delete; ⌘Delete directly moves to Trash.
  Extension exclusions refresh the current folder while allowing explicit file opens.
- Customizable viewer shortcuts with conflict rejection, Clear All and Restore
  Defaults; cleared bindings stay cleared across launches.
- Settings → Files and Cache shows disk and pipeline memory cache occupancy,
  clears thumbnails across viewers, and reveals the cache in Finder. The same tab
  provides directory selection and explains folder access permissions.
- Settings → File Associations lets you select supported formats and
  make the running `PicLight.app` their default opener. It shows the system's
  current default app for each format, groups JPG/JPEG and TIF/TIFF, and reports
  failures per format. Changes apply only after clicking the apply button;
  command-line development runs cannot change associations.

## Architecture

```text
PicViewMac/
├── App/          app lifecycle, file-open coordination, supported types
├── Window/       standard viewer window, placement rules
├── Folder/       scanning, sorting, session, directory watching
├── Imaging/      decode, caches, thumbnails, animation clock, WebP parity
├── Viewer/       canvas, viewport, gestures, hover chrome, minimap
├── Gallery/      folder grid, folder tree and image/browser transitions
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

Daily packaging validates and copies the precompiled icon and Metal library;
changed resource inputs require an explicit refresh with the resource compiler
toolchain. A bare development run can compile the shipped shader source at first
use. See the [development guide](docs/development.md) for both workflows.
