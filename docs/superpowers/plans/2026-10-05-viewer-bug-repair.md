# Viewer interaction and layout repair

> **For agentic workers:** Use the existing delegated tasks for independent components and inline execution for integration. Track each verification below.

**Goal:** Resolve the interaction and visual defects reported in `bugs/目前找到的 bugs.md`.

**Architecture:** Keep image and folder presentations separate. Derive native titlebar geometry from the effective mode and visibility state, reserve sidebar header space with layout rather than overlays, and route image gestures from chrome to the canvas. Embed file associations as a peer settings tab.

**Tech Stack:** Swift, AppKit, NSWorkspace, XCTest.

**Spec:** `bugs/目前找到的 bugs.md` and its six screenshots.

## Constraints

- Preserve existing user changes and explicit file-association Apply behavior.
- Keep native traffic lights and a readable native titlebar.
- Leave the decoded image and manual zoom intact through browser/chrome transitions.
- Coordinate SwiftPM runs centrally; delegated workers own disjoint production files.

## Review focus

- Repeated image/browser transitions in both titlebar settings must restore layout and accessories.
- Pinch/wheel events over an open dock must reach the image; gallery and settings controls retain input.
- Revealing/hiding the titlebar must preserve fit/manual zoom and keep pointer reveal zones reachable.
- A hidden folder sidebar must release its width and keep toolbar clear of native controls.
- Every settings tab must fit 560 × 560; selecting associations again refreshes system defaults.

## Tasks

- [x] Window/sidebar worker: add failing regressions for titlebar mode restoration, readable auto-hide, accessory placement/visibility, drawer obstruction and full-card selection; implement in Window and Sidebar files; run relevant tests.
- [x] Gesture/dock worker: add failing tests for chrome event forwarding and first responder recovery; implement in ViewerRootView, ImageCanvasView and dock/navigation views; keep native glass activation behavior; run relevant tests.
- [x] Settings worker: add failing layout/tab regressions; align interaction controls and embed FileAssociationViewController as fifth tab with reselection refresh; run settings and service tests.
- [x] Integration: regress folder toolbar/sidebar geometry and visible up row; remove tree cap, reserve header with scroll layout, use standard source-list styling, route root canvas/focus, preserve viewport across titlebar transitions.
- [x] Verify complete regression suite, build signed release, inspect native image/browser/settings flows against screenshots, and obtain independent code review.
- [x] Deliver updated app and report any behavior that is controlled by macOS or could not be exercised locally.

## Additional regression found during validation

- The empty viewer briefly displayed the minimap before its first chrome update. Image-only surfaces now start hidden with zero alpha before attachment; the first-frame regression failed before the fix and passed afterwards.
- Drawer-close geometry checks must wait for the native titlebar's 0.7-second hide delay before comparing with the hidden-titlebar baseline. Repeated reveal/hide cycles explicitly verify fit, manual zoom, focal point and outer-frame restoration.
- Repeated keyboard drawer toggles consumed the pointer-exit timer and left a later reveal permanently visible. The model now keeps pointer location independently of the timer and resumes the countdown when the last block lifts or auto-hide is restored after browser mode. Stationary-pointer regressions cover both inside and outside the reveal zone.
- Native inspection covered the image drawer, folder navigation and both updated settings tabs. No system file associations were changed during validation. Actual AutoRaise hover activation and physical trackpad pinch cannot be driven by the available UI tool; event routing and key-window focus recovery are exercised with AppKit regression tests.
- A native wheel event over the dock's zoom label changed image zoom from 198% to 170%, confirming overlay scroll forwarding in the packaged app.
- Final focused regression: 90 tests passed, including titlebar visibility, drawer reservations, folder-browser transitions and settings/association behavior; independent review found no production blockers.
- Final packaged app: release build and strict code-signature validation passed. Native restart showed a clean empty viewer, and two consecutive keyboard-only drawer cycles both restored the hidden titlebar without mouse movement.
- Complete final regression: `swift test` passed 936 tests with zero failures (614.756 seconds). Logs: `/tmp/piclight-bugs-final-full.log`; release build: `/tmp/piclight-bugs-delivery-build.log`. Deliverable: `dist/PicLight.app`.
- The existing 120-point synthetic thumbnail-cell test emits a constraint warning below the actual drawer's 180-point minimum; the original required card-width constraints already had this behavior. Normal-width drawer checks pass. No new native viewer or settings constraint warnings remain.
