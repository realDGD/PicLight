import XCTest
import AppKit
@testable import PicViewMac

/// The bottom info HUD auto-hides.
///
/// It used to be permanently on screen whenever an image was loaded, which made a readout of
/// position, zoom and dimensions — useful for a moment — into permanent furniture over the
/// picture. Now it appears when something it describes changes, and fades once nothing has.
///
/// The rule that matters most is the negative one: the pointer moving over the image is not an
/// event about the image, so it must not summon the readout. That is what the last section
/// checks, and it is the property a naive "any activity shows the chrome" implementation gets
/// wrong.
@MainActor
final class InfoHUDVisibilityTests: XCTestCase {

    override func setUp() async throws {
        try await super.setUp()
        TestAppKit.ensureApplication()
    }

    // MARK: - The model

    /// Hidden with no image, visible the moment one arrives, gone once it has been still.
    func testTheHUDAppearsWithAnImageAndFadesWhenIdle() {
        var model = InfoHUDVisibilityModel()
        XCTAssertFalse(model.update(at: 0), "nothing to describe, nothing to show")
        XCTAssertFalse(model.visible)

        model.setHasImage(true, at: 1.0)
        XCTAssertTrue(model.visible, "an image load is a meaningful change")

        // Still inside the idle window.
        XCTAssertFalse(model.update(at: 1.0 + model.timing.idleFadeDelay - 0.05))
        XCTAssertTrue(model.visible)

        // Past it.
        XCTAssertTrue(model.update(at: 1.0 + model.timing.idleFadeDelay + 0.05),
                      "the fade is a change")
        XCTAssertFalse(model.visible)
        // And it stays hidden: the fade does not restart itself.
        XCTAssertFalse(model.update(at: 1.0 + 100))
        XCTAssertFalse(model.visible)
    }

    /// The idle window is the spec's 1.5–2.0 s.
    func testTheIdleWindowIsInsideTheSpecifiedRange() {
        let timing = InfoHUDVisibilityModel.Timing()
        XCTAssertGreaterThanOrEqual(timing.idleFadeDelay, 1.5)
        XCTAssertLessThanOrEqual(timing.idleFadeDelay, 2.0)
    }

    /// Each of the four documented triggers brings it back.
    func testEveryMeaningfulChangeBringsItBack() {
        for trigger in ["image load", "image switch", "zoom", "pan"] {
            var model = InfoHUDVisibilityModel()
            model.setHasImage(true, at: 0)
            _ = model.update(at: 10)                      // fade it out
            XCTAssertFalse(model.visible, trigger)

            model.noteMeaningfulChange(at: 11)
            XCTAssertTrue(model.visible, "\(trigger) must show the HUD")
        }
    }

    /// Without an image there is nothing to report, and a change must not conjure a readout.
    func testNoImageMeansNoHUDHoweverManyChangesArrive() {
        var model = InfoHUDVisibilityModel()
        for time in [0.0, 1, 2, 3] { model.noteMeaningfulChange(at: time) }
        XCTAssertFalse(model.update(at: 4))
        XCTAssertFalse(model.visible)

        model.setHasImage(true, at: 5)
        XCTAssertTrue(model.visible)
        model.setHasImage(false, at: 6)
        XCTAssertFalse(model.visible, "and losing the image takes it away immediately")
        XCTAssertFalse(model.update(at: 100))
    }

    /// Immersive hides it at once and does not restore it on exit: immersive is the user asking
    /// for fewer readouts, so leaving it must not produce a HUD that was never requested.
    func testImmersiveHidesImmediatelyAndDoesNotRestoreOnExit() {
        var model = InfoHUDVisibilityModel()
        model.setHasImage(true, at: 0)
        XCTAssertTrue(model.visible)

        model.setImmersive(true, at: 0.2)
        XCTAssertFalse(model.visible, "immersive hides it immediately, not after the fade delay")
        XCTAssertFalse(model.update(at: 0.3), "and there is nothing left for the tick to do")
        XCTAssertFalse(model.visible)

        model.setImmersive(false, at: 5)
        XCTAssertFalse(model.visible, "leaving immersive mode must not resurrect the readout")
        // But the next real change does bring it back.
        model.noteMeaningfulChange(at: 6)
        XCTAssertTrue(model.visible)
    }

    /// A change arriving while immersive must not queue a reveal for when immersive ends.
    func testAChangeDuringImmersiveDoesNotQueueAReveal() {
        var model = InfoHUDVisibilityModel()
        model.setHasImage(true, at: 0)
        model.setImmersive(true, at: 1)
        XCTAssertFalse(model.visible)

        model.noteMeaningfulChange(at: 1.1)
        XCTAssertFalse(model.visible, "immersive still wins")

        model.setImmersive(false, at: 2)
        XCTAssertFalse(model.visible, "and nothing was queued behind it")
    }

    // MARK: - The independent state machines

    /// The HUD is its own machine. Moving another surface must not move it, and moving it must
    /// not move another surface.
    func testTheHUDIsIndependentOfTheDockAndTheDrawer() {
        var chrome = ViewerChromeModel()
        chrome.toolDock.setHasImage(true, at: 0)
        // Let the dock's own auto-hide run its course, so "did the HUD reveal the dock?" is asked
        // about a dock that is genuinely away.
        _ = chrome.update(at: chrome.toolDock.timing.hideDelay + 0.1)
        XCTAssertFalse(chrome.snapshot.toolDock, "the dock has auto-hidden")

        // Showing the HUD moves nothing else.
        chrome.infoHUD.setHasImage(true, at: 1.0)
        _ = chrome.update(at: 1.1)
        XCTAssertTrue(chrome.snapshot.infoHUD)
        chrome.infoHUD.setHasImage(false, at: 1.2)
        _ = chrome.update(at: 1.3)
        chrome.infoHUD.setHasImage(true, at: 1.4)
        _ = chrome.update(at: 1.5)
        XCTAssertFalse(chrome.snapshot.drawer, "the HUD must not open the drawer")
        XCTAssertFalse(chrome.snapshot.toolDock, "the HUD must not reveal the dock")

        // Working the dock and the drawer moves nothing in the HUD. The HUD is left to fade on
        // its own idle rule, which is what makes the machines independent.
        let fadedAt = 1.4 + chrome.infoHUD.timing.idleFadeDelay + 0.05
        chrome.toolDock.setPinned(true, at: 2.0)
        chrome.setDrawerOpen(true, at: 2.0)
        _ = chrome.update(at: 2.0)
        XCTAssertTrue(chrome.snapshot.toolDock)
        XCTAssertTrue(chrome.snapshot.drawer)
        XCTAssertTrue(chrome.snapshot.infoHUD, "still inside the HUD's own idle window")

        _ = chrome.update(at: fadedAt)
        XCTAssertFalse(chrome.snapshot.infoHUD, "and it fades on its own schedule")
        XCTAssertTrue(chrome.snapshot.toolDock, "without taking the dock with it")
        XCTAssertTrue(chrome.snapshot.drawer)
    }

    // MARK: - The live viewer

    private func viewer() throws -> (controller: ViewerWindowController, viewer: ViewerViewController) {
        let controller = ViewerWindowController()
        TestAppKit.presentOffScreen(controller)
        let subject = controller.viewerViewController
        controller.showWindow(nil)
        _ = subject.view
        return (controller, subject)
    }

    private func settle(_ seconds: TimeInterval = 0.25) {
        _ = RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    private func waitForImage(_ viewer: ViewerViewController) -> Bool {
        let deadline = Date().addingTimeInterval(10)
        while viewer.viewerState.currentImage == nil, Date() < deadline { settle(0.05) }
        settle(0.4)
        return viewer.viewerState.currentImage != nil
    }

    /// End to end: an image load shows the readout, and a moment later it has faded off screen —
    /// not merely become transparent.
    func testLoadingAnImageShowsTheReadoutAndThenItLeavesTheHierarchy() throws {
        let (controller, viewer) = try self.viewer()
        defer { controller.close() }
        viewer.open(url: Fixtures.url("static.png"))
        XCTAssertTrue(waitForImage(viewer), "the fixture image must load")

        let bar = try XCTUnwrap(viewer.chromeViewsForTesting["bottomBar"])
        XCTAssertFalse(bar.isHidden, "the readout is shown for the image that just arrived")
        XCTAssertEqual(bar.alphaValue, 1, accuracy: 0.01)

        // Wait out the idle window plus the fade, then check it genuinely left the hierarchy
        // rather than sitting there at zero opacity swallowing clicks.
        settle(InfoHUDVisibilityModel.Timing().idleFadeDelay + 0.6)
        XCTAssertTrue(bar.isHidden, "the readout auto-hides after its idle window")
    }

    /// The pointer alone must not bring it back — the property the whole feature turns on.
    func testThePointerAloneDoesNotRevealTheReadout() throws {
        let (controller, viewer) = try self.viewer()
        defer { controller.close() }
        viewer.open(url: Fixtures.url("static.png"))
        XCTAssertTrue(waitForImage(viewer))
        let bar = try XCTUnwrap(viewer.chromeViewsForTesting["bottomBar"])
        settle(InfoHUDVisibilityModel.Timing().idleFadeDelay + 0.6)
        XCTAssertTrue(bar.isHidden)

        // Sweep the pointer across the whole content area, including the readout's own corner and
        // the dock's reveal strip.
        for x in stride(from: CGFloat(0), through: viewer.view.bounds.width, by: 40) {
            for y in stride(from: CGFloat(0), through: viewer.view.bounds.height, by: 60) {
                viewer.simulatePointer(atWindowPoint: NSPoint(x: x, y: y))
                settle(0.02)
            }
        }
        settle(0.3)
        XCTAssertTrue(bar.isHidden, "the pointer must not be able to summon the readout")
    }

    /// Zooming does bring it back, and it fades again once the gesture stops.
    func testZoomAndPanBringItBackAndItFadesAgain() throws {
        let (controller, viewer) = try self.viewer()
        defer { controller.close() }
        viewer.open(url: Fixtures.url("static.png"))
        XCTAssertTrue(waitForImage(viewer))
        let bar = try XCTUnwrap(viewer.chromeViewsForTesting["bottomBar"])
        settle(InfoHUDVisibilityModel.Timing().idleFadeDelay + 0.6)
        XCTAssertTrue(bar.isHidden)

        viewer.perform(.zoomDoubleFit)
        settle(0.2)
        XCTAssertFalse(bar.isHidden, "a zoom is a meaningful change")

        settle(InfoHUDVisibilityModel.Timing().idleFadeDelay + 0.6)
        XCTAssertTrue(bar.isHidden, "and it fades again once the gesture stops")

        viewer.panForTesting(byViewports: 0.25)
        settle(0.2)
        XCTAssertFalse(bar.isHidden, "a pan is a meaningful change too")
    }

    /// Immersive mode takes it away at once.
    func testImmersiveHidesTheReadoutImmediately() throws {
        let (controller, viewer) = try self.viewer()
        defer { controller.close() }
        viewer.open(url: Fixtures.url("static.png"))
        XCTAssertTrue(waitForImage(viewer))
        let bar = try XCTUnwrap(viewer.chromeViewsForTesting["bottomBar"])
        XCTAssertFalse(bar.isHidden)

        viewer.simulateImmersive(true)
        // Long enough for the fade the hide goes through; the point is that immersive *starts*
        // the hide at once rather than waiting out the idle window.
        settle(0.5)
        XCTAssertTrue(bar.isHidden, "immersive mode hides the readout immediately")

        viewer.simulateImmersive(false)
        settle(0.5)
        XCTAssertTrue(bar.isHidden, "and leaving immersive mode does not resurrect it")
    }

    /// The HUD is an overlay: it must never change the canvas it describes.
    func testTheReadoutNeverChangesCanvasGeometry() throws {
        let (controller, viewer) = try self.viewer()
        defer { controller.close() }
        viewer.open(url: Fixtures.url("static.png"))
        XCTAssertTrue(waitForImage(viewer))
        let baseline = viewer.chromeSnapshot

        // Give it a reason to appear, then wait for it to leave.
        viewer.perform(.zoomDoubleFit)
        let zoomed = viewer.chromeSnapshot
        settle(InfoHUDVisibilityModel.Timing().idleFadeDelay + 0.6)

        XCTAssertEqual(viewer.chromeSnapshot.canvasFrame, zoomed.canvasFrame,
                       "hiding the readout must not move the canvas")
        XCTAssertEqual(viewer.chromeSnapshot.fitScale, zoomed.fitScale, accuracy: 0.0001)
        XCTAssertEqual(viewer.chromeSnapshot.zoomScale, zoomed.zoomScale, accuracy: 0.0001)
        XCTAssertGreaterThan(baseline.canvasFrame.width, 0)
    }
}
