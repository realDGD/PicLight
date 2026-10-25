# Window-manager compatibility

The viewer uses a native `NSWindow` with `.titled`, `.closable`,
`.miniaturizable` and `.resizable`. The titlebar follows its configured
Auto / Show / Hide policy; auto-hide configures full-size content for that mode.
The actual traffic lights and native window operations remain AppKit's.
Native window tabbing is disabled app-wide and on every viewer.

The thumbnail column, tool dock, minimap and image-info card belong to the viewer
window. Showing hover chrome must preserve the canvas, zoom and focal point.
Explicitly opening or closing the thumbnail column has its own layout policy;
that operation must not be confused with hover visibility.

## Relevant automated checks

These are source and test entry points, not a claim that the current complete
suite has been run:

| Requirement | Source / test entry point |
| --- | --- |
| Standard viewer window and native tabbing policy | [ViewerWindow](../PicViewMac/Window/ViewerWindow.swift), [WindowPolicyTests](../PicViewMacTests/WindowPolicyTests.swift) |
| One / two / three viewers and chrome containment | [WindowArchitectureTests](../PicViewMacTests/WindowArchitectureTests.swift), including `testOneTwoThreeViewersProduceExactlyThatManyTopLevelWindows` |
| Immersive and native Full Screen have separate states | `WindowArchitectureTests.testImmersiveAndFullScreenAreIndependentStates` |
| Titlebar hover preserves canvas geometry | [TitlebarPresentationRegressionTests](../PicViewMacTests/TitlebarPresentationRegressionTests.swift) |
| Drawer layout and minimap visibility | `WindowArchitectureTests.testDrawerOpenAndCloseCyclesReserveWidthAndRestoreTheCanvasExactly`, `testMinimapVisibilityNeverChangesCanvasGeometry` |
| No native window tabs in production code | [SourcePolicyTests](../PicViewMacTests/SourcePolicyTests.swift) |

Choose checks using the [verification guide](testing.md). The in-app acceptance
runner also depends on specially prepared image content; a successful package
check or arbitrary input does not establish interactive window compatibility.

## Deferred native verification

The [release checklist](release/v0.1-checklist.md) owns the current evidence and
pending checks. M1–M5 cover Mission Control, Stage Manager, native tiling,
installed third-party window managers and native Full Screen. They remain
pending on the final installed revision; no visible check is scheduled by this
document. Record the actual OS, tool and application revision when arranged.

Material appearance, physical gestures and layout stability are tracked there
as separate scenarios. Automated window construction does not establish the
appearance or animation of a real Space transition.

## Implementation boundaries

- Use `collectionBehavior = [.fullScreenPrimary]` and the native
  `NSWindow.toggleFullScreen`, retaining normal window identity.
- Keep `NSWindow.allowsAutomaticWindowTabbing = false` and
  `tabbingMode = .disallowed`.
- Keep hover chrome inside the viewer and use real `standardWindowButton`
  controls. Settings and system authorization panels have their own lifecycle.
- Immersive Mode controls viewer chrome independently of Full Screen; it must
  not manufacture a replacement full-screen window.
