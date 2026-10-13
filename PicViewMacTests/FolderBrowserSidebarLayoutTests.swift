import XCTest
import AppKit
import CoreGraphics
@testable import PicViewMac

/// Hiding the folder tree gives its 200 pt to the gallery, and the gallery must *use* it: the scroll
/// view widens, and the grid lays its rows out for the new width.
///
/// The report: with the left column closed the images did not fill the pane.
///
/// The cause is that a document view is not re-laid-out by its scroll view. `GalleryGridView` is
/// `NSScrollView.documentView`, and it watched only the clip view's `boundsDidChangeNotification` —
/// which is posted when *scrolling* moves the visible rectangle, not when the scroll view resizes
/// the clip view. Measured, a sidebar toggle produced one `frameDidChangeNotification` and zero
/// bounds notifications, so `layout()` never ran, and the grid kept the frame and the row geometry
/// of the narrow width. `layoutWidth` already reads the scroll view, so the missing piece was only
/// the trigger.
@MainActor
final class FolderBrowserSidebarLayoutTests: XCTestCase {

    override func setUp() async throws {
        try await super.setUp()
        TestAppKit.ensureApplication()
    }

    private func item(_ index: Int) -> FolderItem {
        FolderItem(url: URL(fileURLWithPath: "/tmp/gallery-sidebar/img-\(index).png"),
                   pixelSize: CGSize(width: 2, height: 2))
    }

    private func pump(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    private func presentOffScreen(_ view: NSView,
                                  size: NSSize = NSSize(width: 1200, height: 800)) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        TestAppKit.prepareForOffScreen(window)
        window.contentView = view
        window.setFrameOrigin(NSPoint(x: -30000, y: -30000))
        window.makeKeyAndOrderFront(nil)
        view.layoutSubtreeIfNeeded()
        window.layoutIfNeeded()
        return window
    }

    private func settle(_ browser: FolderBrowserViewController, _ window: NSWindow) {
        pump(0.1)
        browser.view.layoutSubtreeIfNeeded()
        window.layoutIfNeeded()
    }

    private func makeBrowser(items: Int = 400)
        -> (browser: FolderBrowserViewController, window: NSWindow) {
        let host = GalleryAuditHost(items: (0..<items).map { item($0) },
                                    directory: URL(fileURLWithPath: "/tmp/gallery-sidebar"))
        let browser = FolderBrowserViewController(host: host)
        let window = presentOffScreen(browser.view)
        browser.reload()
        settle(browser, window)
        return (browser, window)
    }

    /// The reported case: closing the left column gives the gallery the whole width.
    func testHidingTheSidebarLetsTheGalleryFillTheWidth() throws {
        let (browser, window) = makeBrowser()
        defer { window.close() }
        let grid = browser.view.gallery
        let scroll = browser.view.galleryScrollView
        let browserWidth = browser.view.bounds.width

        XCTAssertEqual(scroll.frame.width, browserWidth - 200, accuracy: 1,
                       "precondition: the sidebar reserves its 200 pt")
        XCTAssertEqual(grid.frame.width, scroll.contentSize.width, accuracy: 1,
                       "precondition: the grid is laid out for the visible width")

        let passesBefore = grid.layoutPassCountForTesting
        browser.view.setSidebarVisible(false)
        settle(browser, window)

        XCTAssertGreaterThan(grid.layoutPassCountForTesting, passesBefore,
                             "the resize must reach the grid as a layout pass at all")
        XCTAssertEqual(scroll.frame.width, browserWidth, accuracy: 1,
                       "the gallery takes the space the tree gave back")
        XCTAssertEqual(grid.frame.width, scroll.contentSize.width, accuracy: 1,
                       "and the grid is laid out for that width, not the old one")
    }

    /// The rows are the part a stale width gets wrong: with the sidebar away, the same items need
    /// fewer rows, and a row spans the whole grid.
    func testHidingTheSidebarReflowsTheRowsForTheWiderWidth() throws {
        let (browser, window) = makeBrowser()
        defer { window.close() }
        let grid = browser.view.gallery
        let rowsWithSidebar = grid.rows
        XCTAssertFalse(rowsWithSidebar.isEmpty, "precondition: the grid has rows to reflow")

        browser.view.setSidebarVisible(false)
        settle(browser, window)
        let rowsWithoutSidebar = grid.rows

        XCTAssertGreaterThan(rowsWithSidebar.count, rowsWithoutSidebar.count,
                             "the freed width fits the same items in fewer rows")
        XCTAssertEqual(rowsWithoutSidebar.first?.frame.width ?? 0, grid.bounds.width, accuracy: 1,
                       "a row spans the whole grid width")
    }

    /// And back: reopening the tree must give the width back, not leave the grid wide under a
    /// 200 pt overlay.
    func testShowingTheSidebarAgainNarrowsTheGrid() throws {
        let (browser, window) = makeBrowser()
        defer { window.close() }
        let grid = browser.view.gallery
        let narrow = grid.frame.width
        let narrowRows = grid.rows.count

        browser.view.setSidebarVisible(false)
        settle(browser, window)
        XCTAssertGreaterThan(grid.rows.count, 0)
        XCTAssertNotEqual(grid.frame.width, narrow, "precondition: the grid widened")

        browser.view.setSidebarVisible(true)
        settle(browser, window)
        XCTAssertEqual(grid.frame.width, narrow, accuracy: 1,
                       "the tree takes its width back")
        XCTAssertEqual(grid.rows.count, narrowRows, "and the rows reflow back")
    }

    /// The same trigger is what a *window* resize needs: the content area changes size without a
    /// bounds change, so the rows belong to the old width there too.
    func testResizingTheWindowReflowsTheRows() throws {
        let (browser, window) = makeBrowser()
        defer { window.close() }
        let grid = browser.view.gallery
        let wideRows = grid.rows.count

        window.setFrame(NSRect(x: -30000, y: -30000, width: 900, height: 800), display: false)
        settle(browser, window)

        XCTAssertEqual(grid.frame.width, browser.view.galleryScrollView.contentSize.width,
                       accuracy: 1,
                       "the grid follows the narrower content area")
        XCTAssertGreaterThan(grid.rows.count, wideRows,
                             "a narrower pane needs more rows for the same items")
    }

    func testFolderToolbarStaysOverTheGalleryWithSidebarOpenAndClosed() throws {
        let (browser, window) = makeBrowser(items: 4)
        defer { window.close() }
        browser.view.setToolbarLeadingInset(120)
        browser.view.alignToolbarContent(withTitlebarHeight: 28)
        settle(browser, window)
        let back = browser.view.backControl
        let backFrame = browser.view.convert(back.bounds, from: back)
        let galleryFrame = browser.view.galleryScrollView.frame
        XCTAssertGreaterThanOrEqual(backFrame.minX, galleryFrame.minX + 8,
                                    "image controls belong above the gallery, beyond the sidebar")
        XCTAssertEqual(browser.view.treeSidebar.frame.maxY, browser.view.bounds.maxY,
                       accuracy: 1, "the sidebar background continues behind native controls")

        browser.view.setSidebarVisible(false)
        settle(browser, window)
        let collapsedBack = browser.view.convert(back.bounds, from: back)
        XCTAssertGreaterThanOrEqual(collapsedBack.minX, 120,
                                    "with no sidebar the toolbar still clears native controls")
        XCTAssertLessThan(collapsedBack.minX, 150,
                          "the hidden sidebar releases its toolbar space")
    }

    func testNarrowBrowserKeepsNavigationAndSortingReachable() throws {
        let (browser, window) = makeBrowser(items: 4)
        defer { window.close() }
        browser.view.setToolbarLeadingInset(120)
        window.setFrame(NSRect(x: -30000, y: -30000, width: 480, height: 600), display: false)
        settle(browser, window)
        XCTAssertEqual(browser.view.bounds.width, 480, accuracy: 1)
        let visible = browser.view.toolbarViews.filter { !$0.isHidden }
        for control in visible {
            XCTAssertTrue(control.window === window, "visible controls remain attached")
            let frame = browser.view.convert(control.bounds, from: control)
            XCTAssertTrue(browser.view.bounds.contains(frame), "visible controls must fit: \(control)")
            XCTAssertGreaterThanOrEqual(frame.minX, 200, "controls must clear the sidebar")
        }
        let frames = visible.map { browser.view.convert($0.bounds, from: $0) }
            .filter { $0.width > 1 }.sorted { $0.minX < $1.minX }
        for (left, right) in zip(frames, frames.dropFirst()) {
            XCTAssertLessThanOrEqual(left.maxX, right.minX, "toolbar controls cannot overlap")
        }
        XCTAssertGreaterThanOrEqual(browser.view.sortKeyControl.frame.width, 60,
                                    "the current sorting choice must remain readable")
        for control in [browser.view.backControl, browser.view.uniformLayoutControl,
                        browser.view.adaptiveLayoutControl, browser.view.sortDirectionControl] {
            XCTAssertFalse(control.isHiddenOrHasHiddenAncestor)
        }
        XCTAssertFalse(browser.view.sortKeyControl.isHiddenOrHasHiddenAncestor)
        window.setFrame(NSRect(x: -30000, y: -30000, width: 1200, height: 600), display: false)
        settle(browser, window)
        XCTAssertFalse(browser.view.thumbnailSizeSlider.isHiddenOrHasHiddenAncestor,
                       "all toolbar options return when there is room")
    }
}
