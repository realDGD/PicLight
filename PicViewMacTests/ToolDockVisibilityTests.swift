import XCTest
import AppKit
@testable import PicViewMac

/// The tool dock auto-hides. These are the rules — pure, plus the two the viewer wires
/// them into (the reveal strip and the pin).
@MainActor
final class ToolDockVisibilityTests: XCTestCase {

    override func setUp() async throws {
        try await super.setUp()
        TestAppKit.ensureApplication()
    }

    // MARK: - Model

    func testTheDockHasNoReasonToExistWithoutAnImage() {
        var model = ToolDockVisibilityModel()
        XCTAssertFalse(model.visible)
        _ = model.update(at: 0)
        XCTAssertFalse(model.visible, "no image, no dock")

        model.setHasImage(true, at: 10)
        _ = model.update(at: 10)
        XCTAssertTrue(model.visible, "a new image shows the dock so it can be discovered")
    }

    /// The headline behaviour: with the pointer elsewhere, the dock leaves on its own.
    func testTheDockHidesByItselfAfterTheHideDelay() {
        var model = ToolDockVisibilityModel()
        model.setHasImage(true, at: 0)
        _ = model.update(at: 0)
        XCTAssertTrue(model.visible)

        XCTAssertFalse(model.update(at: model.timing.hideDelay - 0.01),
                       "nothing changes before the delay is up")
        XCTAssertTrue(model.visible)
        XCTAssertTrue(model.update(at: model.timing.hideDelay + 0.01))
        XCTAssertFalse(model.visible)
    }

    func testTheRevealStripShowsTheDockAfterTheShowDelay() {
        var model = ToolDockVisibilityModel()
        model.setHasImage(true, at: 0)
        _ = model.update(at: model.timing.hideDelay + 1)
        XCTAssertFalse(model.visible, "starting from the hidden state")

        model.setPointer(inZone: true, at: 100)
        XCTAssertFalse(model.update(at: 100), "entering the strip is not instant")
        XCTAssertFalse(model.visible)
        XCTAssertTrue(model.update(at: 100 + model.timing.showDelay + 0.01))
        XCTAssertTrue(model.visible)
    }

    func testTheDockStaysWhileThePointerIsInTheStrip() {
        var model = ToolDockVisibilityModel()
        model.setHasImage(true, at: 0)
        model.setPointer(inZone: true, at: 1)
        _ = model.update(at: 10)

        // A long time in the strip: still there, because no exit has been recorded.
        XCTAssertFalse(model.update(at: 500))
        XCTAssertTrue(model.visible)
    }

    func testLeavingTheStripStartsTheHideCountdown() {
        var model = ToolDockVisibilityModel()
        model.setHasImage(true, at: 0)
        model.setPointer(inZone: true, at: 0)
        _ = model.update(at: 1)
        XCTAssertTrue(model.visible)

        model.setPointer(inZone: false, at: 10)
        XCTAssertFalse(model.update(at: 10 + model.timing.hideDelay - 0.01))
        XCTAssertTrue(model.visible, "a pointer that merely passes through does not hide it")
        XCTAssertTrue(model.update(at: 10 + model.timing.hideDelay + 0.01))
        XCTAssertFalse(model.visible)
    }

    // MARK: - Pin

    func testPinnedDockIgnoresThePointerAndTheClock() {
        var model = ToolDockVisibilityModel()
        model.setHasImage(true, at: 0)
        model.setPinned(true, at: 0)
        _ = model.update(at: 0)
        XCTAssertTrue(model.visible)

        XCTAssertFalse(model.update(at: 100_000), "a pinned dock never times out")
        XCTAssertTrue(model.visible)
    }

    func testUnpinningWithThePointerAwayStartsTheCountdown() {
        var model = ToolDockVisibilityModel()
        model.setHasImage(true, at: 0)
        model.setPinned(true, at: 0)
        _ = model.update(at: 0)

        model.setPinned(false, at: 10)
        XCTAssertTrue(model.update(at: 10 + model.timing.hideDelay + 0.01))
        XCTAssertFalse(model.visible, "handing the dock back to auto-hide")
    }

    func testUnpinningWithThePointerInTheStripKeepsItOpen() {
        var model = ToolDockVisibilityModel()
        model.setHasImage(true, at: 0)
        model.setPointer(inZone: true, at: 1)
        _ = model.update(at: 2)
        model.setPinned(true, at: 2)
        model.setPinned(false, at: 5)

        XCTAssertFalse(model.update(at: 50), "the pointer is still in the strip")
        XCTAssertTrue(model.visible)
    }

    // MARK: - Immersive

    func testImmersiveTakesTheDockAwayAndGivesItBack() {
        var model = ToolDockVisibilityModel()
        model.setHasImage(true, at: 0)
        model.setPinned(true, at: 0)
        _ = model.update(at: 0)

        XCTAssertTrue(model.visible, "sanity: it was on screen before immersive")
        model.setImmersive(true, at: 1)
        XCTAssertFalse(model.update(at: 1))
        XCTAssertFalse(model.visible, "immersive hides every overlay surface")
        XCTAssertTrue(model.pinned, "and does not silently unpin")

        model.setImmersive(false, at: 2)
        _ = model.update(at: 2)
        XCTAssertTrue(model.visible, "a pinned dock comes back")
    }

    func testLeavingImmersiveShowsAnUnpinnedDockThenHidesIt() {
        var model = ToolDockVisibilityModel()
        model.setHasImage(true, at: 0)
        model.setImmersive(true, at: 1)
        _ = model.update(at: 1)
        XCTAssertFalse(model.visible)

        model.setImmersive(false, at: 2)
        _ = model.update(at: 2)
        XCTAssertTrue(model.visible, "the user is shown the dock again")
        XCTAssertTrue(model.update(at: 2 + model.timing.hideDelay + 0.01))
        XCTAssertFalse(model.visible, "and then the usual auto-hide applies")
    }

    func testLosingTheImageHidesTheDockImmediately() {
        var model = ToolDockVisibilityModel()
        model.setHasImage(true, at: 0)
        model.setPinned(true, at: 0)
        _ = model.update(at: 0)

        XCTAssertTrue(model.visible, "sanity: a pinned dock is on screen")
        model.setHasImage(false, at: 5)
        XCTAssertFalse(model.update(at: 5))
        XCTAssertFalse(model.visible, "not even a pin outranks an empty viewer")
    }

    // MARK: - Parameters

    func testTimingsSitInTheIntendedRanges() {
        let timing = ToolDockVisibilityModel.Timing()
        XCTAssertGreaterThanOrEqual(timing.showDelay, 0)
        XCTAssertLessThanOrEqual(timing.showDelay, 0.1, "the dock must feel attached to the pointer")
        XCTAssertGreaterThanOrEqual(timing.hideDelay, 0.6, "or it flickers on every pass")
        XCTAssertLessThanOrEqual(timing.hideDelay, 1.0)
    }

    func testTransitionParametersSitInTheIntendedRanges() {
        XCTAssertGreaterThanOrEqual(ViewerToolDockView.revealZoneTolerance, 20)
        XCTAssertLessThanOrEqual(ViewerToolDockView.revealZoneTolerance, 30)
        XCTAssertGreaterThanOrEqual(ViewerToolDockView.hiddenSlideDistance, 6)
        XCTAssertLessThanOrEqual(ViewerToolDockView.hiddenSlideDistance, 10)
        XCTAssertEqual(ViewerToolDockView.hiddenOffset(reduceMotion: true), 0,
                       "Reduce Motion means no slide")
        XCTAssertGreaterThanOrEqual(AccessibilityAppearance.chromeAnimationDuration(reduceMotion: false),
                                    0.15)
        XCTAssertLessThanOrEqual(AccessibilityAppearance.chromeAnimationDuration(reduceMotion: false),
                                 0.20)
    }

    // MARK: - Reveal zone geometry

    func testRevealZoneCoversThePillSidewaysAndTheGapBelow() {
        let bounds = CGRect(x: 0, y: 0, width: 900, height: 600)
        let dock = CGRect(x: 400, y: ViewerToolDockView.bottomInset, width: 300,
                          height: ViewerToolDockView.height)
        let zone = ViewerToolDockView.revealZone(dockFrame: dock, in: bounds)

        XCTAssertEqual(zone.minX, dock.minX - ViewerToolDockView.revealZoneTolerance)
        XCTAssertEqual(zone.width, dock.width + 2 * ViewerToolDockView.revealZoneTolerance)
        XCTAssertEqual(zone.minY, bounds.minY, "the strip runs from the window's bottom edge")
        XCTAssertEqual(zone.height,
                       ViewerToolDockView.height + ViewerToolDockView.bottomInset
                         + ViewerToolDockView.revealZoneMargin)

        XCTAssertTrue(zone.contains(CGPoint(x: dock.midX, y: bounds.minY + 1)),
                      "the empty band under the pill is part of the strip")
        XCTAssertTrue(zone.contains(CGPoint(x: dock.midX, y: dock.maxY + 4)))
        XCTAssertFalse(zone.contains(CGPoint(x: dock.midX, y: dock.maxY + 40)),
                       "well above the pill is image, not dock")
        XCTAssertFalse(zone.contains(CGPoint(x: dock.minX - 40, y: dock.midY)))
        XCTAssertFalse(zone.contains(CGPoint(x: dock.maxX + 40, y: dock.midY)))
    }

    func testRevealZoneIsEmptyWithoutALaidOutDock() {
        let zone = ViewerToolDockView.revealZone(dockFrame: .zero,
                                                in: CGRect(x: 0, y: 0, width: 900, height: 600))
        XCTAssertTrue(zone.isNull, "a dock with no size has no strip to reveal it")
    }

    // MARK: - Viewer wiring

    private func makeViewer() throws -> (controller: ViewerWindowController, viewer: ViewerViewController) {
        let controller = ViewerWindowController()
        TestAppKit.presentOffScreen(controller)
        let viewer = controller.viewerViewController
        _ = viewer.view
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        viewer.view.layoutSubtreeIfNeeded()
        return (controller, viewer)
    }

    private func settle(_ seconds: TimeInterval = 0.3) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    private func loadImage(_ viewer: ViewerViewController) {
        viewer.open(url: Fixtures.url("static.png"))
        let deadline = Date().addingTimeInterval(10)
        while viewer.viewerState.currentImage == nil, Date() < deadline { settle(0.05) }
        settle(0.2)
    }

    func testTheDockIsHiddenWithoutAnImageAndHidesAfterAnImageAppears() throws {
        let (controller, viewer) = try makeViewer()
        defer { controller.close() }
        let dock = try XCTUnwrap(viewer.chromeViewsForTesting["toolDock"] as? ViewerToolDockView)

        viewer.applyChromeVisibilityForTesting()
        settle(0.3)
        XCTAssertTrue(dock.isHidden, "the empty viewer has no tools to offer")

        loadImage(viewer)
        XCTAssertFalse(dock.isHidden, "the dock shows itself once an image is on screen")

        idleAwayFromToolDock(viewer)
        XCTAssertTrue(dock.isHidden, "and auto-hides again")
    }

    func testTheRevealStripBringsTheDockBackAndItLeavesAgain() throws {
        let (controller, viewer) = try makeViewer()
        defer { controller.close() }
        loadImage(viewer)
        let dock = try XCTUnwrap(viewer.chromeViewsForTesting["toolDock"] as? ViewerToolDockView)
        idleAwayFromToolDock(viewer)

        revealToolDock(viewer, dock)
        XCTAssertFalse(dock.isHidden)
        XCTAssertEqual(dock.alphaValue, 1, accuracy: 0.01, "fully faded in")
        XCTAssertEqual(dock.slideOffset, 0, accuracy: 0.5, "and fully slid into place")

        idleAwayFromToolDock(viewer)
        XCTAssertTrue(dock.isHidden)
        XCTAssertEqual(dock.alphaValue, 0, accuracy: 0.01)
        XCTAssertEqual(dock.slideOffset, -ViewerToolDockView.hiddenSlideDistance, accuracy: 0.5,
                       "hidden means faded and pushed towards the bottom edge")
    }

    func testTheZoneFollowsTheDockWhenTheDrawerIsPinned() throws {
        let (controller, viewer) = try makeViewer()
        defer { controller.close() }
        controller.window?.setContentSize(NSSize(width: 900, height: 600))
        loadImage(viewer)
        let dock = try XCTUnwrap(viewer.chromeViewsForTesting["toolDock"] as? ViewerToolDockView)
        let canvas = try XCTUnwrap(viewer.chromeViewsForTesting["canvas"])
        let unpinnedZone = viewer.toolDockRevealZone
        XCTAssertEqual(unpinnedZone.midX, canvas.frame.midX, accuracy: 2)

        viewer.toggleDrawerForTesting()
        settle(0.6)

        let pinnedZone = viewer.toolDockRevealZone
        XCTAssertEqual(pinnedZone.midX, canvas.frame.midX, accuracy: 2,
                       "the strip is centred on the pill, which is centred on the canvas")
        XCTAssertGreaterThan(pinnedZone.minX, unpinnedZone.minX,
                             "pinning the drawer moves the canvas and the strip with it")
        XCTAssertGreaterThanOrEqual(pinnedZone.minX, canvas.frame.minX - 1,
                                    "the strip never reaches over the sidebar")
    }

    func testAPinnedDockSurvivesThePointerLeaving() throws {
        let (controller, viewer) = try makeViewer()
        defer { controller.close() }
        loadImage(viewer)
        let dock = try XCTUnwrap(viewer.chromeViewsForTesting["toolDock"] as? ViewerToolDockView)

        viewer.toggleToolDockPinForTesting()
        XCTAssertTrue(viewer.isToolDockPinned)
        XCTAssertTrue(dock.isPinned, "the button mirrors the model")

        idleAwayFromToolDock(viewer)
        XCTAssertFalse(dock.isHidden, "a pinned dock stays put")

        viewer.toggleToolDockPinForTesting()
        XCTAssertFalse(viewer.isToolDockPinned)
        idleAwayFromToolDock(viewer)
        XCTAssertTrue(dock.isHidden, "unpinning hands it back to auto-hide")
    }

    /// Immersive is a "hide everything" mode; the dock comes back with the rest.
    func testImmersiveHidesTheDockAndLeavingItBringsItBack() throws {
        let (controller, viewer) = try makeViewer()
        defer { controller.close() }
        loadImage(viewer)
        let dock = try XCTUnwrap(viewer.chromeViewsForTesting["toolDock"] as? ViewerToolDockView)
        revealToolDock(viewer, dock)
        XCTAssertFalse(dock.isHidden)

        viewer.simulateImmersive(true)
        settle(0.4)
        XCTAssertTrue(dock.isHidden)

        viewer.simulateImmersive(false)
        settle(0.4)
        XCTAssertFalse(dock.isHidden, "leaving immersive restores the dock")
    }
}
