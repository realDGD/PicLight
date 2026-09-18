import XCTest
import AppKit
@testable import PicViewMac

/// The floating previous/next controls.
///
/// Two auto-hiding overlays at the vertical centre of the canvas edges. The properties that carry
/// the design are: they are anchored to the *canvas* (so a pinned drawer moves the left one with
/// the image, and the pair sits at the centre of the image area rather than of the window), they
/// are overlays in the strict sense that showing them cannot touch the canvas geometry, and their
/// visibility is a per-side state driven by a per-side reveal strip.
@MainActor
final class FloatingNavigationTests: XCTestCase {

    override func setUp() async throws {
        try await super.setUp()
        TestAppKit.ensureApplication()
    }

    // MARK: - Fixtures

    private func makeFolder(_ count: Int) throws -> (directory: URL, controller: ViewerWindowController,
                                                     viewer: ViewerViewController) {
        let directory = try Fixtures.makeScratchDirectory("floating-nav")
        for index in 0..<count {
            try FileManager.default.copyItem(at: Fixtures.url("static.png"),
                                             to: directory.appendingPathComponent("img\(index).png"))
        }
        let controller = ViewerWindowController()
        TestAppKit.presentOffScreen(controller)
        let viewer = controller.viewerViewController
        controller.showWindow(nil)
        _ = viewer.view
        viewer.open(url: directory.appendingPathComponent("img0.png"))
        XCTAssertTrue(waitForImage(viewer))
        return (directory, controller, viewer)
    }

    private func waitForImage(_ viewer: ViewerViewController, timeout: TimeInterval = 10) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while viewer.viewerState.currentImage == nil, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        return viewer.viewerState.currentImage != nil
    }

    @discardableResult
    private func settle(_ seconds: TimeInterval = 0.25) -> Bool {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
        return true
    }

    private func nav(_ viewer: ViewerViewController) throws -> FloatingNavigationView {
        try XCTUnwrap(viewer.chromeViewsForTesting["floatingNavigation"] as? FloatingNavigationView)
    }

    private func cleanup(_ directory: URL, _ controller: ViewerWindowController) {
        controller.close()
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Geometry: the overlay contract

    /// Default hidden, in the hierarchy or at least invisible, before any pointer arrives.
    func testBothControlsStartHidden() throws {
        let (directory, controller, viewer) = try makeFolder(3)
        defer { cleanup(directory, controller) }
        let navigation = try nav(viewer)
        XCTAssertTrue(navigation.previousControl.isHidden)
        XCTAssertTrue(navigation.nextControl.isHidden)
        XCTAssertFalse(viewer.chromeSnapshot.previousNavigation)
        XCTAssertFalse(viewer.chromeSnapshot.nextNavigation)
    }

    /// The reveal zones are the canvas's own edge strips, not the window's.
    func testTheRevealZonesFollowTheCanvasEdges() throws {
        let (directory, controller, viewer) = try makeFolder(3)
        defer { cleanup(directory, controller) }
        let canvas = viewer.chromeSnapshot.canvasFrame
        let zones = viewer.floatingNavigationRevealZones

        XCTAssertEqual(zones.previous.minX, canvas.minX, accuracy: 0.5)
        XCTAssertEqual(zones.previous.minY, canvas.minY, accuracy: 0.5)
        XCTAssertEqual(zones.previous.height, canvas.height, accuracy: 0.5)
        XCTAssertEqual(zones.previous.width, FloatingNavigationView.revealZoneWidth, accuracy: 0.5)
        XCTAssertEqual(zones.next.maxX, canvas.maxX, accuracy: 0.5)
        XCTAssertEqual(zones.next.width, FloatingNavigationView.revealZoneWidth, accuracy: 0.5)
        XCTAssertLessThan(zones.previous.maxX, zones.next.minX,
                          "the two strips must not overlap in a normal window")
    }

    /// A pinned drawer takes canvas width; the left control must follow the canvas rather than stay
    /// pinned to the window's left edge.
    func testTheLeftControlFollowsTheCanvasWhenTheDrawerReservesWidth() throws {
        let (directory, controller, viewer) = try makeFolder(3)
        defer { cleanup(directory, controller) }
        let navigation = try nav(viewer)
        let before = navigation.frame.minX

        viewer.toggleDrawerForTesting()
        settle(0.5)
        XCTAssertGreaterThan(viewer.chromeSnapshot.drawerReservedWidth, 0,
                             "the drawer must actually be reserving width")
        XCTAssertGreaterThan(navigation.frame.minX, before,
                             "the navigation overlay follows the canvas, not the window edge")
        XCTAssertEqual(navigation.frame.minX, viewer.chromeSnapshot.canvasFrame.minX, accuracy: 0.5)
    }

    /// The pair is at the vertical centre of the canvas — which, with a titlebar and no bottom
    /// chrome, is not the centre of the window.
    func testTheControlsSitAtTheVerticalCentreOfTheCanvas() throws {
        let (directory, controller, viewer) = try makeFolder(3)
        defer { cleanup(directory, controller) }
        let navigation = try nav(viewer)
        XCTAssertEqual(navigation.frame.midY, viewer.chromeSnapshot.canvasFrame.midY, accuracy: 0.5)
        for control in [navigation.previousControl, navigation.nextControl] {
            XCTAssertEqual(control.frame.midY, navigation.bounds.midY, accuracy: 0.5)
        }
    }

    /// The strict overlay contract: revealing, using and hiding the controls must not move the
    /// canvas, change the fit or the zoom, or re-centre the image.
    func testShowingAndHidingNeverChangesCanvasGeometry() throws {
        let (directory, controller, viewer) = try makeFolder(3)
        defer { cleanup(directory, controller) }
        let canvas = viewer.chromeSnapshot.canvasFrame
        let fit = viewer.chromeSnapshot.fitScale
        let zoom = viewer.chromeSnapshot.zoomScale
        let center = viewer.canvasViewportForTesting.normalizedCenter

        let zones = viewer.floatingNavigationRevealZones
        viewer.simulatePointer(atWindowPoint: viewer.view.convert(CGPoint(x: zones.next.midX, y: zones.next.midY), to: nil))
        settle(0.3)
        XCTAssertTrue(viewer.chromeSnapshot.nextNavigation, "the control is on screen")

        viewer.simulatePointer(atWindowPoint: NSPoint(x: viewer.view.bounds.midX,
                                                     y: viewer.view.bounds.midY))
        settle(FloatingNavigationVisibilityModel.Timing().hideDelay + 0.4)
        XCTAssertFalse(viewer.chromeSnapshot.nextNavigation, "and then off again")

        XCTAssertEqual(viewer.chromeSnapshot.canvasFrame, canvas)
        XCTAssertEqual(viewer.chromeSnapshot.fitScale, fit, accuracy: 1e-9)
        XCTAssertEqual(viewer.chromeSnapshot.zoomScale, zoom, accuracy: 1e-9)
        XCTAssertEqual(viewer.canvasViewportForTesting.normalizedCenter.x, center.x, accuracy: 1e-9)
        XCTAssertEqual(viewer.canvasViewportForTesting.normalizedCenter.y, center.y, accuracy: 1e-9)
    }

    /// The overlay spans the canvas but must not swallow the drag that pans the image.
    func testTheOverlayLeavesTheMiddleOfTheCanvasToTheCanvas() throws {
        let (directory, controller, viewer) = try makeFolder(3)
        defer { cleanup(directory, controller) }
        let navigation = try nav(viewer)
        // A hidden overlay must not intercept anything, so the check is made with the controls on
        // screen — the state in which a mistake would actually swallow a drag.
        navigation.setAvailable(previous: true, next: true)
        navigation.setVisible(previous: true, next: true)
        settle(0.3)

        // `hitTest` takes a point in the receiver's *superview's* coordinates.
        func hit(_ point: CGPoint) -> NSView? {
            guard let superview = navigation.superview else { return nil }
            return navigation.hitTest(navigation.convert(point, to: superview))
        }

        XCTAssertNil(hit(CGPoint(x: navigation.bounds.midX, y: navigation.bounds.midY)),
                     "a point between the two buttons belongs to the image underneath")
        // And over a button it does hit — the control has to be clickable.
        for control in [navigation.previousControl, navigation.nextControl] {
            XCTAssertTrue(hit(CGPoint(x: control.frame.midX, y: control.frame.midY)) === control,
                          "the control must be clickable where it is drawn")
        }
    }

    // MARK: - Visibility

    /// Each side reveals its own control and says nothing about the other.
    func testEachSideRevealsOnlyItsOwnControl() throws {
        let (directory, controller, viewer) = try makeFolder(3)
        defer { cleanup(directory, controller) }
        // A middle image, so both sides are available: on the first one there is deliberately no
        // previous control to reveal.
        viewer.perform(.nextImage)
        settle(0.5)
        let zones = viewer.floatingNavigationRevealZones

        viewer.simulatePointer(atWindowPoint: viewer.view.convert(CGPoint(x: zones.previous.midX, y: zones.previous.midY), to: nil))
        settle(0.3)
        XCTAssertTrue(viewer.chromeSnapshot.previousNavigation)
        XCTAssertFalse(viewer.chromeSnapshot.nextNavigation,
                       "the left strip must not reveal the right control")

        // Move straight to the other side: the first hides on its own timer, the second appears.
        viewer.simulatePointer(atWindowPoint: viewer.view.convert(CGPoint(x: zones.next.midX, y: zones.next.midY), to: nil))
        settle(0.3)
        XCTAssertTrue(viewer.chromeSnapshot.nextNavigation)
        settle(FloatingNavigationVisibilityModel.Timing().hideDelay + 0.4)
        XCTAssertFalse(viewer.chromeSnapshot.previousNavigation,
                       "and the left one hides after its delay")
        XCTAssertTrue(viewer.chromeSnapshot.nextNavigation,
                      "while the pointer is still in the right strip")
    }

    /// The hide delay is the spec's 0.7 s.
    func testTheHideDelayIsSevenTenthsOfASecond() {
        XCTAssertEqual(FloatingNavigationVisibilityModel.Timing().hideDelay, 0.7, accuracy: 1e-9)
    }

    /// The model's own timing: revealed at once, kept while the pointer is inside, hidden one
    /// delay after it leaves.
    func testTheModelRevealsImmediatelyAndHidesAfterTheDelay() {
        var model = FloatingNavigationVisibilityModel()
        model.setHasImage(true, at: 0)
        model.setAvailable(previous: true, next: true)
        XCTAssertFalse(model.previous.visible, "default hidden")

        model.setPointer(previousSide: false, nextSide: true, at: 0)
        XCTAssertTrue(model.next.visible, "entering the strip shows it at once")
        XCTAssertFalse(model.previous.visible)

        _ = model.update(at: 0.3)
        XCTAssertTrue(model.next.visible, "hovering keeps it")

        model.setPointer(previousSide: false, nextSide: false, at: 0.5)
        _ = model.update(at: 0.5 + model.timing.hideDelay - 0.05)
        XCTAssertTrue(model.next.visible, "and the hide waits out the delay")
        _ = model.update(at: 0.5 + model.timing.hideDelay + 0.05)
        XCTAssertFalse(model.next.visible)
    }

    /// A pointer resting on the button itself keeps it shown after it has left the strip — that is
    /// the only way to press a control that hides when you leave its zone.
    func testRestingOnTheButtonKeepsItShown() {
        var model = FloatingNavigationVisibilityModel()
        model.setHasImage(true, at: 0)
        model.setAvailable(previous: true, next: true)
        model.setPointer(previousSide: true, nextSide: false, at: 0)
        model.setPointer(previousSide: false, nextSide: false, at: 0.2)
        model.pointerOnPrevious = true

        for step in 1...10 { _ = model.update(at: 0.2 + Double(step) * 0.2) }
        XCTAssertTrue(model.previous.visible, "a pointer on the button keeps it on screen")

        model.pointerOnPrevious = false
        _ = model.update(at: 4.0 + model.timing.hideDelay + 0.05)
        XCTAssertFalse(model.previous.visible, "and releasing it lets the delay run")
    }

    /// Immersive mode hides both; leaving it must not restore them without a pointer.
    func testImmersiveHidesBothAndDoesNotRestoreThem() {
        var model = FloatingNavigationVisibilityModel()
        model.setHasImage(true, at: 0)
        model.setAvailable(previous: true, next: true)
        model.setPointer(previousSide: true, nextSide: true, at: 0)
        XCTAssertTrue(model.previous.visible)
        XCTAssertTrue(model.next.visible)

        model.setImmersive(true, at: 0.1)
        _ = model.update(at: 0.2)
        XCTAssertFalse(model.previous.visible)
        XCTAssertFalse(model.next.visible)

        model.setImmersive(false, at: 0.3)
        _ = model.update(at: 0.4)
        XCTAssertFalse(model.previous.visible, "immersive is not a state to be restored from")
        XCTAssertFalse(model.next.visible)
    }

    /// With no image there is nothing to navigate to.
    func testNoImageMeansNoControls() {
        var model = FloatingNavigationVisibilityModel()
        model.setAvailable(previous: true, next: true)
        model.setPointer(previousSide: true, nextSide: true, at: 0)
        _ = model.update(at: 0.1)
        XCTAssertFalse(model.previous.visible,
                       "the pointer cannot reveal a control with nothing to navigate")
        XCTAssertFalse(model.next.visible)

        // An image arriving is not a pointer in the reveal strip: with the pointer gone, the
        // controls stay away until it comes back.
        model.setPointer(previousSide: false, nextSide: false, at: 0.2)
        model.setHasImage(true, at: 0.3)
        _ = model.update(at: 0.4)
        XCTAssertFalse(model.previous.visible)
        XCTAssertFalse(model.next.visible)
    }

    // MARK: - Availability

    /// First image: no previous. Last image: no next. Middle: both.
    func testTheFirstAndLastImagesHaveNoControlOnTheirClosedSide() throws {
        let (directory, controller, viewer) = try makeFolder(3)
        defer { cleanup(directory, controller) }
        let navigation = try nav(viewer)

        XCTAssertFalse(navigation.previousAvailable, "the first image has no previous")
        XCTAssertTrue(navigation.nextAvailable)

        viewer.perform(.nextImage)
        settle(0.5)
        XCTAssertTrue(navigation.previousAvailable, "the middle has both")
        XCTAssertTrue(navigation.nextAvailable)

        viewer.perform(.nextImage)
        settle(0.5)
        XCTAssertTrue(navigation.previousAvailable)
        XCTAssertFalse(navigation.nextAvailable, "the last image has no next")
    }

    /// An unavailable control is hidden even with the pointer in its strip.
    func testAnUnavailableControlStaysHiddenEvenWhenRevealed() throws {
        let (directory, controller, viewer) = try makeFolder(3)
        defer { cleanup(directory, controller) }
        let navigation = try nav(viewer)
        let zones = viewer.floatingNavigationRevealZones

        // On the first image, hover the previous side.
        viewer.simulatePointer(atWindowPoint: viewer.view.convert(CGPoint(x: zones.previous.midX, y: zones.previous.midY), to: nil))
        settle(0.3)
        XCTAssertTrue(navigation.previousControl.isHidden,
                      "there is nowhere to go, so the control is not offered")
        XCTAssertFalse(viewer.chromeSnapshot.previousNavigation)

        // Move to the last image and hover the next side.
        viewer.perform(.lastImage)
        settle(0.5)
        viewer.simulatePointer(atWindowPoint: viewer.view.convert(CGPoint(x: zones.next.midX, y: zones.next.midY), to: nil))
        settle(0.3)
        XCTAssertTrue(navigation.nextControl.isHidden)
    }

    // MARK: - Pressing them

    /// The controls navigate, through the same commands the dock and the menu use.
    func testPressingTheControlsNavigates() throws {
        let (directory, controller, viewer) = try makeFolder(3)
        defer { cleanup(directory, controller) }
        let navigation = try nav(viewer)

        // Through the button's own target/action, which is how a click reaches the viewer.
        func press(_ control: DockButton) throws {
            XCTAssertNotNil(control.target)
            XCTAssertNotNil(control.action)
            _ = control.sendAction(try XCTUnwrap(control.action), to: control.target)
            settle(0.5)
        }

        try press(navigation.nextControl)
        XCTAssertEqual(viewer.session.currentIndex, 1, "next advances")

        try press(navigation.previousControl)
        XCTAssertEqual(viewer.session.currentIndex, 0, "previous goes back")

        try press(navigation.previousControl)
        XCTAssertEqual(viewer.session.currentIndex, 0,
                       "and the first image is the end of the line, not a wrap-around")
    }

    /// Hover and press feedback is the dock's, because it is the dock's button class.
    func testTheControlsUseTheDockFeedbackVocabulary() throws {
        let (directory, controller, viewer) = try makeFolder(3)
        defer { cleanup(directory, controller) }
        let navigation = try nav(viewer)
        for control in [navigation.previousControl, navigation.nextControl] {
            XCTAssertEqual(control.hoverScale, 1)
            control.setHoverScale(ViewerToolDockView.hoveredScale, duration: 0)
            XCTAssertEqual(control.hoverScale, ViewerToolDockView.hoveredScale, accuracy: 1e-9)
            control.setPressed(true, reduceMotion: false)
            XCTAssertEqual(control.effectiveScale,
                           ViewerToolDockView.hoveredScale * ViewerToolDockView.pressedScale,
                           accuracy: 1e-9)
            control.setPressed(false, reduceMotion: false)
            control.setHoverScale(1, duration: 0)
        }
        XCTAssertEqual(FloatingNavigationView.previousSymbol, "chevron.left")
        XCTAssertEqual(FloatingNavigationView.nextSymbol, "chevron.right")
    }

    /// A pointer sweep that does not enter either strip must not show anything.
    func testAPointerSweepAcrossTheMiddleShowsNothing() throws {
        let (directory, controller, viewer) = try makeFolder(3)
        defer { cleanup(directory, controller) }
        let zones = viewer.floatingNavigationRevealZones
        let middle = (zones.previous.maxX + zones.next.minX) / 2

        for y in stride(from: CGFloat(40), through: viewer.view.bounds.height - 40, by: 60) {
            viewer.simulatePointer(atWindowPoint: NSPoint(x: middle, y: y))
            settle(0.02)
        }
        settle(0.3)
        XCTAssertFalse(viewer.chromeSnapshot.previousNavigation)
        XCTAssertFalse(viewer.chromeSnapshot.nextNavigation)
    }
}
