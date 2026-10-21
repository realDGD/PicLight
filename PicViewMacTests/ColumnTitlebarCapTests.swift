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

    /// The image's drawer starts below a readable native titlebar. A second material cap
    /// inside it hides the first thumbnail and creates the extra blurred rectangle from the report.
    func testTheThumbnailColumnHasOneSurfaceAndNoTitlebarCap() throws {
        let directory = try makeFolder(24)
        defer { try? FileManager.default.removeItem(at: directory) }
        let (controller, viewer, window) = try makeViewer()
        defer { TestAppKit.close(controller) }
        viewer.open(url: directory.appendingPathComponent("img0.png"))
        settle(1.0)
        viewer.toggleDrawerForTesting()
        settle(0.8)

        let drawer = try XCTUnwrap(viewer.chromeViewsForTesting["drawer"] as? ThumbnailDrawerView)
        XCTAssertFalse(drawer.subviews.contains { $0 is SurfaceCapView },
                       "the drawer must not draw a second titlebar material over its first row")
        let scroll = try XCTUnwrap(drawer.subviews.compactMap { $0 as? NSScrollView }.first)
        XCTAssertEqual(scroll.frame, drawer.bounds, "rows can use the full drawer")
        let drawerFrame = drawer.convert(drawer.bounds, to: nil)
        let button = try XCTUnwrap(window.standardWindowButton(.closeButton))
        XCTAssertLessThanOrEqual(drawerFrame.maxY, button.convert(button.bounds, to: nil).minY,
                                 "native titlebar layout keeps rows below the controls")
    }

    func testTheTopOfTheThumbnailListIsNotCoveredByAnExtraSurface() throws {
        let drawer = ThumbnailDrawerView()
        drawer.frame = NSRect(x: 0, y: 0, width: 200, height: 500)
        drawer.layoutSubtreeIfNeeded()
        let scroll = try XCTUnwrap(drawer.subviews.compactMap { $0 as? NSScrollView }.first)
        let scrollIndex = try XCTUnwrap(drawer.subviews.firstIndex(of: scroll))
        XCTAssertTrue(drawer.subviews.dropFirst(scrollIndex + 1).isEmpty,
                      "no cap may blur or cover the top of the thumbnail list")
    }

    /// Header space is reserved by layout, so the first action is never behind a material cap.
    func testTheFolderTreeKeepsTheUpRowBelowTheNativeControls() throws {
        let directory = try makeFolder(4)
        defer { try? FileManager.default.removeItem(at: directory) }
        let (controller, viewer, window) = try makeViewer()
        defer { TestAppKit.close(controller) }
        viewer.open(url: directory.appendingPathComponent("img0.png"))
        settle(0.8)
        viewer.perform(.browseFolder)
        settle(1.2)

        let browser = try XCTUnwrap(viewer.folderBrowserForTesting)
        let sidebar = browser.view.treeSidebar
        XCTAssertFalse(sidebar.subviews.contains { $0 is SurfaceCapView },
                       "a second material overlay must not cover the up row")
        let titlebarHeight = window.frame.height - window.contentLayoutRect.height
        let row = sidebar.outlineView.rect(ofRow: 0)
        let rowInBrowser = browser.view.convert(row, from: sidebar.outlineView)
        XCTAssertEqual(sidebar.renderedName(at: 0), "上一级")
        XCTAssertLessThanOrEqual(rowInBrowser.maxY,
                                browser.view.bounds.maxY - titlebarHeight,
                                "the whole up row is below the native titlebar")
        XCTAssertTrue(browser.view.bounds.contains(rowInBrowser),
                      "the first action remains visible")
    }

    /// The bar is the system's, one bar at a time: in the always-visible mode the window draws it, and
    /// in the auto-hide mode it appears on the same terms — with its own title, not a surface of ours.
    ///
    /// Reported: "在设置中设置标题栏为始终显示的时候，会有两套标题栏", then "删除我们刚刚说的标题栏，采用
    /// 原生标题栏".
    func testTheTitlebarIsTheSystemsOwn() throws {
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
        XCTAssertNil(viewer.chromeViewsForTesting["titleStrip"],
                     "the viewer draws no titlebar surface of its own")
        XCTAssertFalse(window.titlebarAppearsTransparent, "the window's bar is showing")
        XCTAssertEqual(window.titleVisibility, .visible, "with its own title")
        XCTAssertEqual(window.title, "static.png", "which is the file name")

        // The size readout is a native accessory in that bar, not a view of ours.
        XCTAssertFalse(controller.sizeReadoutTextForTesting.isEmpty,
                       "the pixel size sits in the bar's trailing corner")
    }

    /// And in the auto-hide mode the bar comes back as the system's bar too.
    func testTheAutoHiddenBarIsAlsoTheSystemsOwn() throws {
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

        XCTAssertEqual(window.titlebarState, .full)
        XCTAssertFalse(window.titlebarAppearsTransparent, "a real bar, with its own material")
        XCTAssertEqual(window.titleVisibility, .visible, "and its own title")
        XCTAssertEqual(window.title, "static.png")
        XCTAssertFalse(controller.sizeReadoutTextForTesting.isEmpty,
                       "with the pixel size in its trailing corner")
    }
}
