# Window-manager compatibility (v0.1)

The viewer is an ordinary `NSWindow` with `.titled`, `.closable`,
`.miniaturizable`, `.resizable` and `.fullSizeContentView`. It is visually
titleless (transparent titlebar, hidden title) but it is **not** a true
borderless window, and native window tabbing is disabled app-wide. Hover bars,
the thumbnail drawer and the minimap are subviews of that one window, so they
never add windows for the window manager to see.

## Automated evidence

In this environment the display cannot be captured, so the acceptance runner is
the evidence channel. It drives the production code paths and asserts the
window-manager-visible facts directly:

```bash
PICVIEW_SELFTEST=/path/to/image.png dist/PicViewMac.app/Contents/MacOS/PicViewMac
```

Checks that cover this matrix:

| Requirement | Check in the runner |
| --- | --- |
| Exactly one visible window per viewer, for 1/2/3 viewers, classified by window type | `one visible viewer window`; `WindowArchitectureTests.testOneTwoThreeViewersProduceExactlyThatManyTopLevelWindows` |
| No overlay/child windows for hover UI | `no child overlay windows` |
| Standard titled window, not borderless | `viewer is a standard titled NSWindow` |
| Native tabbing disabled | `native tabbing disabled` |
| Drawer/hover/minimap never change the window count | `opening the drawer never changes canvas geometry`, `immersive does not close or add windows` |
| Rotate/mirror never rewrite the source | `rotate and mirror are view-only` |

Unit-level coverage lives in `PicViewMacTests/WindowPolicyTests.swift` and
`PicViewMacTests/WindowArchitectureTests.swift` (real `NSWindow` construction,
type-based window classification, chrome containment, chrome-vs-geometry
independence for immersive mode, and the standard full-screen command).

`SourcePolicyTests.testProductionCodeNeverUsesNativeWindowTabs` additionally
proves by source scan that `addTabbedWindow`, `tabGroup` and `tabbedWindows`
never appear in production code.

## Manual verification still required (MANUAL-PENDING)

These need a human in front of a display; they were **not** executed in this
environment and are therefore *not* claimed as verified. They are tracked as
M1–M5 in `docs/release/v0.1-checklist.md`.

1. **Mission Control / native tiling** with 1, 2 and 3 viewer windows: each must
   appear as a separate ordinary window that can be tiled and snapped.
2. **Native Full Screen** (`⌃⌘F` or the green button): entering and leaving must
   not create phantom viewer windows, and the window count must return to its
   previous value.
3. **Drawer, top hover bar and minimap**: opening each must not change the
   top-level window count (covered automatically) and must not change the canvas
   frame or zoom (covered automatically).
4. **Third-party window managers** (Rectangle, yabai, AeroSpace, Amethyst — any
   that are installed): move, resize and snap the viewer. Record observed
   behavior. Do not add app-specific workarounds unless a reproducible bug in
   standard window behavior is found.
5. **Stage Manager**: the viewer must participate like any other window —
   including being moved into a stage and back.
6. **Light/Dark switching while running**: covered for `NSApp.appearance`
   behavior by the runner; visual confirmation of the chrome materials still
   needs a human.

## Known-good design choices that keep this working

- `collectionBehavior = [.fullScreenPrimary]` and `NSWindow.toggleFullScreen`
  for Full Screen — never a custom full-screen window.
- `NSWindow.allowsAutomaticWindowTabbing = false` at launch and
  `tabbingMode = .disallowed` on every viewer window.
- No `NSPanel` for hover chrome, no `addTabbedWindow`, no separate overlay
  windows, and no fake traffic-light buttons (the real
  `standardWindowButton` controls are used and only faded).
- Immersive mode changes chrome visibility only; window geometry and Space
  membership are untouched.
