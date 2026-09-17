import XCTest
import AppKit
@testable import PicViewMac

/// Pointer-zone geometry: pure, so the routing can be checked without synthesising
/// mouse events.
final class PointerZoneTests: XCTestCase {
    private let geometry = ViewerZoneGeometry(topBarHeight: 44, hotZoneWidth: 12, drawerWidth: 200)
    private let bounds = CGRect(x: 0, y: 0, width: 1000, height: 700)

    func testTopBandIsTheTopFortyFourPoints() {
        XCTAssertEqual(geometry.zone(for: CGPoint(x: 500, y: 700), in: bounds, drawerVisible: false),
                       .topChrome)
        XCTAssertEqual(geometry.zone(for: CGPoint(x: 500, y: 656), in: bounds, drawerVisible: false),
                       .topChrome, "exactly 44 pt below the top edge is still the band")
        XCTAssertEqual(geometry.zone(for: CGPoint(x: 500, y: 655), in: bounds, drawerVisible: false),
                       .canvas, "one point lower is the image area")
    }

    func testOnlyTheNarrowLeftEdgeOpensTheDrawer() {
        XCTAssertEqual(geometry.zone(for: CGPoint(x: 0, y: 350), in: bounds, drawerVisible: false),
                       .leftEdgeHotZone)
        XCTAssertEqual(geometry.zone(for: CGPoint(x: 12, y: 350), in: bounds, drawerVisible: false),
                       .leftEdgeHotZone, "the hot zone is exactly hotZoneWidth wide")
        XCTAssertEqual(geometry.zone(for: CGPoint(x: 13, y: 350), in: bounds, drawerVisible: false),
                       .canvas, "13 px in is already the image, not the drawer trigger")
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

    func testTopBandWinsOverTheLeftEdgeAndDrawer() {
        // The top-left corner belongs to the window controls, not the drawer.
        XCTAssertEqual(geometry.zone(for: CGPoint(x: 5, y: 690), in: bounds, drawerVisible: true),
                       .topChrome)
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
    private func makeViewer() throws -> (controller: ViewerWindowController, viewer: ViewerViewController) {
        let controller = ViewerWindowController()
        controller.present()
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
            ["topBar", "bottomBar", "drawer", "minimap"].contains($0.key)
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

        // Pointer into the top band reveals the hover bar.
        viewer.view.layoutSubtreeIfNeeded()
        viewer.handlePointer(atRootPoint: CGPoint(x: viewer.view.bounds.midX,
                                                 y: viewer.view.bounds.height - 10))
        settle(0.5)
        let topBar = viewer.chromeViewsForTesting["topBar"]!
        XCTAssertFalse(topBar.isHidden, "the top band must reveal the hover bar")
        let topPoint = topBar.convert(CGPoint(x: topBar.bounds.midX, y: topBar.bounds.midY), to: content)
        let topHit = content.hitTest(topPoint)
        XCTAssertTrue(topHit === topBar || topHit?.isDescendant(of: topBar) == true,
                      "the visible hover bar must be interactive")

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

    func testDrawerHotZoneIsNarrowAndDrawerStaysWide() throws {
        let (controller, viewer) = try makeViewer()
        defer { controller.close() }
        XCTAssertLessThanOrEqual(ThumbnailDrawerView.hotZoneWidth, 12)
        XCTAssertGreaterThanOrEqual(ThumbnailDrawerView.minimumWidth, 180)
        XCTAssertLessThanOrEqual(ThumbnailDrawerView.maximumWidth, 220)

        // 13 px in must not be part of the trigger region on the live view. The
        // point is derived from the live bounds so the check does not depend on
        // the remembered window size.
        let midY = viewer.view.bounds.midY
        XCTAssertEqual(viewer.zone(forRootPoint: CGPoint(x: 13, y: midY)), .canvas)
        XCTAssertEqual(viewer.zone(forRootPoint: CGPoint(x: 5, y: midY)), .leftEdgeHotZone)
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
    func testHiddenChromeLeavesTheHierarchyEvenWhenTheWindowIsOffScreen() {
        // Deliberately not presented: no on-screen animation will run.
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

    func testChromeReturnsToTheHierarchyWhenRevealed() {
        let controller = ViewerWindowController()
        defer { controller.close() }
        let viewer = controller.viewerViewController
        controller.present()
        _ = viewer.view
        viewer.applyChromeVisibilityForTesting()
        let hidden = Date().addingTimeInterval(2)
        while Date() < hidden { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        let topBar = viewer.chromeViewsForTesting["topBar"]!
        XCTAssertTrue(topBar.isHidden)

        viewer.handlePointer(atRootPoint: CGPoint(x: viewer.view.bounds.midX,
                                                 y: viewer.view.bounds.height - 5))
        let revealed = Date().addingTimeInterval(2)
        while Date() < revealed, topBar.isHidden {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertFalse(topBar.isHidden, "the top band must bring the bar back")
        XCTAssertEqual(topBar.alphaValue, 1, accuracy: 0.01)
    }
}
