import XCTest
import AppKit
@testable import PicViewMac

/// Pointer-zone geometry: pure, so the routing can be checked without synthesising
/// mouse events.
@MainActor
final class PointerZoneTests: XCTestCase {

    override func setUp() async throws {
        try await super.setUp()
        TestAppKit.ensureApplication()
    }
    private var geometry: ViewerZoneGeometry {
        ViewerZoneGeometry(topBarHeight: 0, drawerWidth: 200)
    }
    private let bounds = CGRect(x: 0, y: 0, width: 1000, height: 700)

    /// The window management strip is the standard titlebar, so nothing in the
    /// content area belongs to it.
    func testThereIsNoTopChromeZone() {
        XCTAssertEqual(geometry.zone(for: CGPoint(x: 500, y: 700), in: bounds, drawerVisible: false),
                       .canvas)
        XCTAssertEqual(geometry.zone(for: CGPoint(x: 500, y: 690), in: bounds, drawerVisible: false),
                       .canvas, "the content area under the titlebar is image, not chrome")
    }

    /// The left edge is not a trigger: the drawer opens only from an explicit control, so no
    /// pointer position alone can summon it.
    func testTheLeftEdgeIsNotADrawerTrigger() {
        for x in [0, 1, 23, 24, 25, 100] as [CGFloat] {
            XCTAssertEqual(geometry.zone(for: CGPoint(x: x, y: 350), in: bounds,
                                         drawerVisible: false),
                           .canvas,
                           "\(x) px in must not reveal the drawer")
        }
        XCTAssertEqual(geometry.zone(for: CGPoint(x: 100, y: 350), in: bounds, drawerVisible: false),
                       .canvas, "a hidden drawer must not claim its own width")
    }

    func testVisibleDrawerKeepsItsOwnSurfaceInteractive() {
        XCTAssertEqual(geometry.zone(for: CGPoint(x: 100, y: 350), in: bounds, drawerVisible: true),
                       .drawerSurface)
        XCTAssertEqual(geometry.zone(for: CGPoint(x: 199, y: 350), in: bounds, drawerVisible: true),
                       .drawerSurface)
        XCTAssertEqual(geometry.zone(for: CGPoint(x: 250, y: 350), in: bounds, drawerVisible: true),
                       .canvas)
    }

    /// The top-left corner is the corner this change is most easily got wrong: it used to be the
    /// hot zone's strongest point, and it must now belong to the image.
    func testTheTopLeftCornerIsImage() {
        XCTAssertEqual(geometry.zone(for: CGPoint(x: 5, y: 690), in: bounds, drawerVisible: false),
                       .canvas)
        XCTAssertEqual(geometry.zone(for: CGPoint(x: 5, y: 690), in: bounds, drawerVisible: true),
                       .drawerSurface, "an *open* drawer owns its own surface, corner included")
    }

    func testMinimapSurfaceIsIdentifiedWhenSupplied() {
        let minimap = CGRect(x: 820, y: 70, width: 168, height: 120)
        XCTAssertEqual(geometry.zone(for: CGPoint(x: 900, y: 130), in: bounds,
                                     drawerVisible: false, minimapRect: minimap),
                       .minimapSurface)
        XCTAssertEqual(geometry.zone(for: CGPoint(x: 700, y: 130), in: bounds,
                                     drawerVisible: false, minimapRect: minimap),
                       .canvas)
    }

    func testPointsOutsideTheContentAreaFallBackToCanvas() {
        XCTAssertEqual(geometry.zone(for: CGPoint(x: -5, y: 350), in: bounds, drawerVisible: true),
                       .canvas)
        XCTAssertEqual(geometry.zone(for: CGPoint(x: 500, y: 900), in: bounds, drawerVisible: true),
                       .canvas)
    }
}

/// The real view hierarchy: hidden chrome must not keep a transparent hit-test
/// surface, and hover tracking must not depend on which subview is on top.
@MainActor
final class ViewerHitTestingTests: XCTestCase {

    override func setUp() async throws {
        try await super.setUp()
        TestAppKit.ensureApplication()
    }
    private func makeViewer() throws -> (controller: ViewerWindowController, viewer: ViewerViewController) {
        TestAppKit.ensureApplication()
        let controller = ViewerWindowController()
        TestAppKit.presentOffScreen(controller)
        let viewer = controller.viewerViewController
        _ = viewer.view
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        viewer.view.layoutSubtreeIfNeeded()
        return (controller, viewer)
    }

    private func settle(_ seconds: TimeInterval = 0.3) {
        _ = RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    func testHiddenChromeDoesNotHitTest() throws {
        let (controller, viewer) = try makeViewer()
        defer { controller.close() }
        guard let content = controller.window?.contentView else { return XCTFail("no content view") }

        viewer.applyChromeVisibilityForTesting()
        settle()

        let hoverChrome = viewer.chromeViewsForTesting.filter {
            ViewerViewController.hoverChromeNames.contains($0.key)
        }
        for (name, chrome) in hoverChrome {
            guard chrome.isHidden else {
                XCTFail("\(name) should be hidden with no pointer in its region")
                continue
            }
            let center = chrome.convert(CGPoint(x: chrome.bounds.midX, y: chrome.bounds.midY),
                                        to: content)
            let hit = content.hitTest(center)
            XCTAssertFalse(hit === chrome || hit?.isDescendant(of: chrome) == true,
                           "\(name) is hidden but still intercepts clicks at \(center)")
        }
    }

    func testVisibleChromeDoesHitTestAndLeavesTheRestToTheCanvas() throws {
        let (controller, viewer) = try makeViewer()
        defer { controller.close() }
        guard let content = controller.window?.contentView else { return XCTFail("no content view") }

        // The tool dock auto-hides: bring it back through its reveal strip, then it
        // must be genuinely interactive rather than merely drawn.
        viewer.open(url: Fixtures.url("static.png"))
        let dockDeadline = Date().addingTimeInterval(10)
        while viewer.viewerState.currentImage == nil, Date() < dockDeadline { settle(0.05) }
        settle(0.5)
        let dock = viewer.chromeViewsForTesting["toolDock"] as! ViewerToolDockView
        revealToolDock(viewer, dock)
        XCTAssertFalse(dock.isHidden, "the revealed dock is on screen")
        let dockPoint = dock.convert(CGPoint(x: dock.bounds.midX, y: dock.bounds.midY), to: content)
        let dockHit = content.hitTest(dockPoint)
        XCTAssertTrue(dockHit === dock || dockHit?.isDescendant(of: dock) == true,
                      "the tool dock must be interactive, got \(String(describing: dockHit))")

        // A point in the middle of the image belongs to the canvas once an image
        // is loaded, because the empty state steps aside for it.
        viewer.open(url: Fixtures.url("static.png"))
        let loadedDeadline = Date().addingTimeInterval(10)
        while viewer.viewerState.currentImage == nil, Date() < loadedDeadline { settle(0.05) }
        settle(0.4)
        XCTAssertTrue(viewer.chromeViewsForTesting["emptyState"]!.isHidden,
                      "sanity: the empty state must be gone before this assertion means anything")
        let canvasPoint = CGPoint(x: content.bounds.midX, y: content.bounds.midY)
        let canvasHit = content.hitTest(canvasPoint)
        XCTAssertTrue(canvasHit is ImageCanvasView,
                      "the image area must belong to the canvas, got \(String(describing: canvasHit))")
    }

    func testHiddenDrawerLeavesTheImageAreaToTheCanvas() throws {
        let (controller, viewer) = try makeViewer()
        defer { controller.close() }
        guard let content = controller.window?.contentView else { return XCTFail("no content view") }

        // With an image loaded the empty state steps aside, so a click must reach
        // the canvas rather than a transparent drawer surface.
        viewer.open(url: Fixtures.url("static.png"))
        let loaded = Date().addingTimeInterval(10)
        while viewer.viewerState.currentImage == nil, Date() < loaded { settle(0.05) }
        settle(0.4)
        XCTAssertTrue(viewer.chromeViewsForTesting["emptyState"]!.isHidden,
                      "sanity: with an image loaded the empty state steps aside")

        viewer.applyChromeVisibilityForTesting()
        settle()
        let drawer = viewer.chromeViewsForTesting["drawer"]!
        XCTAssertTrue(drawer.isHidden)

        // A click 100 px in, at drawer height, must reach the canvas rather than a
        // transparent drawer surface.
        let point = CGPoint(x: 100, y: content.bounds.midY)
        let hit = content.hitTest(point)
        XCTAssertTrue(hit is ImageCanvasView,
                      "a hidden drawer must not swallow clicks across its width, got \(String(describing: hit))")
    }

    func testRootViewOwnsTheOnlyPointerTrackingArea() throws {
        let (controller, viewer) = try makeViewer()
        defer { controller.close() }

        // The canvas and the drawer used to add their own `.mouseMoved` areas,
        // which is why real hover events never reached the viewer controller.
        func mouseMovedAreas(in view: NSView) -> [String] {
            var found: [String] = []
            if view.trackingAreas.contains(where: { $0.options.contains(.mouseMoved) }) {
                found.append(String(describing: type(of: view)))
            }
            for subview in view.subviews { found.append(contentsOf: mouseMovedAreas(in: subview)) }
            return found
        }
        let owners = mouseMovedAreas(in: viewer.view)
        XCTAssertEqual(owners, ["ViewerRootView"],
                       "exactly the root view may track pointer movement, found \(owners)")
    }

    func testDrawerWidthStaysInRangeAndTheLeftEdgeIsNotATrigger() throws {
        let (controller, viewer) = try makeViewer()
        defer { controller.close() }
        XCTAssertGreaterThanOrEqual(ThumbnailDrawerView.minimumWidth, 180)
        XCTAssertLessThanOrEqual(ThumbnailDrawerView.maximumWidth, 220)

        // Points are derived from the live bounds so the check does not depend on the
        // remembered window size.
        let midY = viewer.view.bounds.midY
        for x in [0, 1, 23, 25, 100] as [CGFloat] {
            XCTAssertEqual(viewer.zone(forRootPoint: CGPoint(x: x, y: midY)), .canvas,
                           "the pointer alone must not reveal the drawer at x=\(x)")
        }
    }
}

/// Regression: hiding chrome must not depend on the fade animation running.
///
/// The original implementation only set `isHidden` from the animation completion
/// handler. For a window that is off screen or whose animation is coalesced, that
/// callback never fires, and the surface stayed in the hierarchy at alpha 0 -
/// a transparent layer that still swallowed clicks across its whole width. This
/// is exactly what a freshly launched bundle did.
@MainActor
final class ChromeHideGuaranteeTests: XCTestCase {

    override func setUp() async throws {
        try await super.setUp()
        TestAppKit.ensureApplication()
    }
    func testHiddenChromeLeavesTheHierarchyEvenWhenTheWindowIsOffScreen() {
        // Deliberately not presented: no on-screen animation will run.
        TestAppKit.ensureApplication()
        let controller = ViewerWindowController()
        defer { controller.close() }
        let viewer = controller.viewerViewController
        _ = viewer.view
        XCTAssertFalse(controller.window?.isVisible == true, "the window must stay off screen")

        viewer.applyChromeVisibilityForTesting()
        // Wait past the fade duration plus the fallback margin.
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }

        for (name, chrome) in viewer.chromeViewsForTesting
        where ["topBar", "bottomBar", "drawer", "minimap"].contains(name) {
            XCTAssertTrue(chrome.isHidden,
                          "\(name) is still in the hierarchy at alpha \(chrome.alphaValue); "
                            + "hiding must not rely on the animation callback")
        }
    }

    /// The drawer is revealed by an explicit control now, not by pointer position. This keeps the
    /// original regression — a hidden surface must come back through the real hide/show path and
    /// end at full opacity — while driving it the way the product does.
    func testDrawerReturnsToTheHierarchyWhenRevealed() {
        TestAppKit.ensureApplication()
        let controller = ViewerWindowController()
        defer { controller.close() }
        let viewer = controller.viewerViewController
        TestAppKit.presentOffScreen(controller)
        _ = viewer.view
        viewer.applyChromeVisibilityForTesting()
        let hidden = Date().addingTimeInterval(2)
        while Date() < hidden { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        let drawer = viewer.chromeViewsForTesting["drawer"]!
        XCTAssertTrue(drawer.isHidden)

        // The pointer must not: an edge hover is not a reveal trigger any more.
        viewer.handlePointer(atRootPoint: CGPoint(x: 5, y: viewer.view.bounds.midY))
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        XCTAssertTrue(drawer.isHidden, "the pointer alone must not reveal the drawer")

        // The explicit control does.
        viewer.perform(.toggleThumbnailDrawer)
        let revealed = Date().addingTimeInterval(2)
        while Date() < revealed, drawer.isHidden {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertFalse(drawer.isHidden, "the drawer command must bring the drawer back")
        XCTAssertEqual(drawer.alphaValue, 1, accuracy: 0.01)
    }
}
