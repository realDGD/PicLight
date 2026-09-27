import XCTest
import AppKit
@testable import PicViewMac

/// A column that scrolls under the titlebar must not draw its rows there.
///
/// Reported: scrolling the thumbnail column showed thumbnails under the traffic lights and under the
/// left-column button, because the window's content view spans the titlebar and the bar is transparent
/// in this mode. The column's *background* belongs there; its rows do not. Each column now carries a cap
/// of its own material above the scroll view, taking no events.
@MainActor
final class ColumnTitlebarCapTests: XCTestCase {

    override func setUp() async throws {
        try await super.setUp()
        TestAppKit.ensureApplication()
    }

    private func settle(_ seconds: TimeInterval = 0.5) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    private func makeFolder(_ count: Int) throws -> URL {
        let directory = try Fixtures.makeScratchDirectory("column-cap")
        for index in 0..<count {
            try FileManager.default.copyItem(at: Fixtures.url("static.png"),
                                             to: directory.appendingPathComponent("img\(index).png"))
        }
        return directory
    }

    private func makeViewer() throws -> (ViewerWindowController, ViewerViewController, ViewerWindow) {
        let controller = ViewerWindowController()
        TestAppKit.presentOffScreen(controller)
        controller.window?.setFrame(NSRect(x: 0, y: 0, width: 1000, height: 800), display: false)
        controller.showWindow(nil)
        let viewer = controller.viewerViewController
        _ = viewer.view
        let window = try XCTUnwrap(controller.window as? ViewerWindow)
        return (controller, viewer, window)
    }

    /// The thumbnail column: a cap with the column's own material, above the scroll view, exactly as
    /// tall as the titlebar.
    func testTheThumbnailColumnCapsItsTitlebarStrip() throws {
        let directory = try makeFolder(24)
        defer { try? FileManager.default.removeItem(at: directory) }
        let (controller, viewer, window) = try makeViewer()
        defer { TestAppKit.close(controller) }
        viewer.open(url: directory.appendingPathComponent("img0.png"))
        settle(1.0)
        viewer.toggleDrawerForTesting()
        settle(0.8)

        let drawer = try XCTUnwrap(viewer.chromeViewsForTesting["drawer"] as? ThumbnailDrawerView)
        let cap = try XCTUnwrap(drawer.titlebarCapForTesting, "the column's cap")
        let titlebarHeight = window.frame.height - window.contentLayoutRect.height
        XCTAssertEqual(cap.frame.height, titlebarHeight, accuracy: 1,
                       "the cap is exactly the titlebar strip")
        XCTAssertEqual(cap.frame.width, drawer.bounds.width, accuracy: 1,
                       "and spans the column")
        XCTAssertEqual(cap.frame.maxY, drawer.bounds.maxY, accuracy: 1,
                       "at the top of the column, which is the window's top")

        // Above the scroll view: the rows scroll behind it, not over it.
        let scroll = try XCTUnwrap(drawer.subviews.compactMap { $0 as? NSScrollView }.first)
        let capIndex = try XCTUnwrap(drawer.subviews.firstIndex(where: { $0 === cap }))
        let scrollIndex = try XCTUnwrap(drawer.subviews.firstIndex(where: { $0 === scroll }))
        XCTAssertGreaterThan(capIndex, scrollIndex,
                             "the cap is drawn after the scroll view, or the rows would cover it")

        // It looks like the column it caps.
        let surface = try XCTUnwrap(cap as? MaterialHostView)
        XCTAssertEqual(surface.style, drawer.style, "the cap is the column's own surface")
    }

    /// And it takes no events: a scroll that starts in the strip still scrolls the list.
    func testTheCapTakesNoEvents() throws {
        let directory = try makeFolder(24)
        defer { try? FileManager.default.removeItem(at: directory) }
        let (controller, viewer, _) = try makeViewer()
        defer { TestAppKit.close(controller) }
        viewer.open(url: directory.appendingPathComponent("img0.png"))
        settle(1.0)
        viewer.toggleDrawerForTesting()
        settle(0.8)

        let drawer = try XCTUnwrap(viewer.chromeViewsForTesting["drawer"] as? ThumbnailDrawerView)
        let cap = try XCTUnwrap(drawer.titlebarCapForTesting)
        XCTAssertTrue(cap is SurfaceCapView, "a cap is a pixel cover, not a control")
        let inside = drawer.convert(CGPoint(x: drawer.bounds.midX, y: drawer.bounds.maxY - 4), to: cap)
        XCTAssertNil(cap.hitTest(inside), "a click in the strip must fall through to the list")
    }

    /// The browser's tree column has the same problem and the same cap.
    func testTheFolderTreeColumnCapsItsTitlebarStrip() throws {
        let directory = try makeFolder(4)
        defer { try? FileManager.default.removeItem(at: directory) }
        let (controller, viewer, window) = try makeViewer()
        defer { TestAppKit.close(controller) }
        viewer.open(url: directory.appendingPathComponent("img0.png"))
        settle(0.8)
        viewer.perform(.browseFolder)
        settle(1.2)

        let browser = try XCTUnwrap(viewer.folderBrowserForTesting)
        let cap = try XCTUnwrap(browser.view.treeSidebar.titlebarCapForTesting,
                                "the tree column's cap")
        let titlebarHeight = window.frame.height - window.contentLayoutRect.height
        XCTAssertEqual(cap.frame.height, titlebarHeight, accuracy: 1,
                       "the tree's rows must not be drawn under the traffic lights either")
    }

    /// The strip exists only where it replaces a bar that hides: with the titlebar set to always
    /// visible, the window draws its own bar and there must not be a second one.
    ///
    /// Reported exactly this way: "在设置中设置标题栏为始终显示的时候，会有两套标题栏".
    func testOnlyOneTitlebarWhenTheBarIsAlwaysVisible() throws {
        let settings = AppSettings.shared
        let original = settings.titlebar
        settings.titlebar = .alwaysVisible
        defer { settings.titlebar = original }

        let (controller, viewer, window) = try makeViewer()
        defer { TestAppKit.close(controller) }
        viewer.open(url: Fixtures.url("static.png"))
        settle(1.0)
        viewer.windowTitlebarContextChanged()
        settle(0.6)

        XCTAssertEqual(window.titlebarMode, .alwaysVisible, "precondition: the setting is in force")
        let strip = try XCTUnwrap(viewer.chromeViewsForTesting["titleStrip"] as? TitleStripView)
        XCTAssertTrue(strip.isHidden, "the native bar is the only titlebar in this mode")
        XCTAssertFalse(window.titlebarAppearsTransparent, "because the window's bar is showing")
        XCTAssertEqual(window.titleVisibility, .visible, "with the system's own title")
    }

    /// And in the auto-hide mode the strip is the bar: the system title steps aside for it.
    func testTheStripIsTheBarWhenTheTitlebarIsAutoHidden() throws {
        let settings = AppSettings.shared
        let original = settings.titlebar
        settings.titlebar = .autoHide
        defer { settings.titlebar = original }

        let (controller, viewer, window) = try makeViewer()
        defer { TestAppKit.close(controller) }
        viewer.open(url: Fixtures.url("static.png"))
        settle(1.0)
        let zones = viewer.titlebarRevealZones
        viewer.simulatePointer(atWindowPoint: viewer.view.convert(
            CGPoint(x: zones.b.midX, y: zones.b.midY), to: nil))
        settle(0.8)

        let strip = try XCTUnwrap(viewer.chromeViewsForTesting["titleStrip"] as? TitleStripView)
        XCTAssertEqual(window.titlebarState, .full)
        XCTAssertFalse(strip.isHidden, "the strip replaces the auto-hidden bar")
        XCTAssertEqual(window.titleVisibility, .hidden, "so the system title steps aside")
    }
}
