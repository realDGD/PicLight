import XCTest
import AppKit
import CoreGraphics
@testable import PicViewMac

/// The gallery and the session are two views of one list, and a third is the picture on screen.
///
/// Three measured reports live here: the grid kept the old list after an external add (so the cell
/// showing `b.png` opened `a.png`), entering the gallery reset a multi-page document to its first
/// page, and selecting the last image left the grid scrolled at the first sixteen. Plus the layout
/// question: every delivered thumbnail used to rebuild the whole folder's geometry.
@MainActor
final class GallerySyncAndScrollTests: XCTestCase {

    override func setUp() async throws {
        try await super.setUp()
        TestAppKit.ensureApplication()
    }

    private func pump(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    private func waitUntil(_ timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.03))
        }
        return condition()
    }

    private func makeViewer(width: CGFloat = 1000, height: CGFloat = 760)
        -> (ViewerWindowController, ViewerViewController) {
        let controller = ViewerWindowController()
        TestAppKit.presentOffScreen(controller)
        controller.window?.setFrame(NSRect(x: 0, y: 0, width: width, height: height), display: false)
        controller.showWindow(nil)
        let viewer = controller.viewerViewController
        _ = viewer.view
        return (controller, viewer)
    }

    private func makeFolder(_ count: Int, label: String) throws -> URL {
        let directory = try Fixtures.makeScratchDirectory(label)
        for index in 0..<count {
            try FileManager.default.copyItem(
                at: Fixtures.url("static.png"),
                to: directory.appendingPathComponent(String(format: "img%03d.png", index)))
        }
        return directory
    }

    private func enterBrowser(_ viewer: ViewerViewController) throws -> FolderBrowserViewController {
        viewer.perform(.browseFolder)
        pump(0.7)
        viewer.view.layoutSubtreeIfNeeded()
        let browser = try XCTUnwrap(viewer.folderBrowserForTesting)
        browser.view.layoutSubtreeIfNeeded()
        return browser
    }

    // MARK: - One list, two views

    /// An external add must reach the grid: the file the cell shows is the file a click opens.
    func testTheGridFollowsAnExternalAdd() throws {
        let directory = try Fixtures.makeScratchDirectory("gallery-sync")
        defer { try? FileManager.default.removeItem(at: directory) }
        for name in ["b.png", "c.png"] {
            try FileManager.default.copyItem(at: Fixtures.url("static.png"),
                                             to: directory.appendingPathComponent(name))
        }
        let (controller, viewer) = makeViewer()
        defer { TestAppKit.close(controller) }
        viewer.open(url: directory.appendingPathComponent("b.png"))
        XCTAssertTrue(waitUntil(15) { viewer.viewerState.currentImage != nil })
        let browser = try enterBrowser(viewer)
        let grid = browser.view.gallery
        XCTAssertEqual(grid.itemCount, 2, "precondition: b and c are in the grid")

        try FileManager.default.copyItem(at: Fixtures.url("static.png"),
                                        to: directory.appendingPathComponent("a.png"))
        XCTAssertTrue(waitUntil(6) { viewer.session.items.count == 3 },
                      "the watcher's rescan reaches the session")
        pump(0.4)
        browser.view.layoutSubtreeIfNeeded()

        XCTAssertEqual(viewer.session.items.map(\.displayName), ["a.png", "b.png", "c.png"])
        XCTAssertEqual(grid.itemCount, 3,
                       "the grid is the same list as the session (measured before: still 2 items)")
        XCTAssertEqual(grid.cellForTesting(at: 0)?.nameSurface.stringValue, "a.png")

        // The click: what the cell shows is what opens.
        grid.onItemOpened?(0)
        XCTAssertTrue(waitUntil(10) { viewer.session.currentItem?.displayName == "a.png" })
        XCTAssertEqual(viewer.viewerMode, .image, "opening an item leaves the gallery")
    }

    /// The sort shortcut re-orders the grid, not just the session.
    func testTheSortShortcutReordersTheGrid() throws {
        let directory = try makeFolder(4, label: "gallery-sort-shortcut")
        defer { try? FileManager.default.removeItem(at: directory) }
        let (controller, viewer) = makeViewer()
        defer { TestAppKit.close(controller) }
        viewer.open(url: directory.appendingPathComponent("img000.png"))
        XCTAssertTrue(waitUntil(15) { viewer.viewerState.currentImage != nil })
        let browser = try enterBrowser(viewer)
        let grid = browser.view.gallery

        SharedSettingsScope.preservingSort(key: .filename, direction: .ascending) {
            let ascendingOrder = viewer.session.items.map(\.displayName)
            XCTAssertEqual(grid.itemCount, ascendingOrder.count)
            viewer.perform(.toggleSortDirection)
            pump(0.5)
            browser.view.layoutSubtreeIfNeeded()

            let sessionOrder = viewer.session.items.map(\.displayName)
            XCTAssertEqual(sessionOrder, ascendingOrder.reversed(), "the session is re-ordered")
            XCTAssertEqual(toolbarRowTitles(grid: grid, browser: browser), sessionOrder,
                           "and the grid shows the order the session is in")
        }
    }

    /// The gallery's own sort popup re-orders the grid as well — the toolbar entry point.
    func testTheToolbarSortReordersTheGrid() throws {
        let directory = try Fixtures.makeScratchDirectory("gallery-sort-toolbar")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.copyItem(at: Fixtures.url("static.png"),
                                         to: directory.appendingPathComponent("img000.png"))
        try FileManager.default.copyItem(at: Fixtures.url("static.png"),
                                         to: directory.appendingPathComponent("img001.png"))
        let (controller, viewer) = makeViewer()
        defer { TestAppKit.close(controller) }
        viewer.open(url: directory.appendingPathComponent("img000.png"))
        XCTAssertTrue(waitUntil(15) { viewer.viewerState.currentImage != nil })
        let browser = try enterBrowser(viewer)
        let grid = browser.view.gallery
        XCTAssertEqual(grid.itemCount, 2)

        // Two files, so the sort is stable either way; what is asserted is that the grid was rebuilt
        // from the session rather than keeping its own copy of the list.
        SharedSettingsScope.preservingSort(key: .filename, direction: .ascending) {
            browser.select(0)
            browser.view.onSortDirectionChanged?(.descending)
            pump(0.5)
            browser.view.layoutSubtreeIfNeeded()
            XCTAssertEqual(viewer.session.items.map(\.displayName), ["img001.png", "img000.png"])
            XCTAssertEqual(toolbarRowTitles(grid: grid, browser: browser),
                           viewer.session.items.map(\.displayName))
        }
    }

    /// The order the grid draws, read from its cells rather than from the model.
    private func toolbarRowTitles(grid: GalleryGridView,
                                  browser: FolderBrowserViewController) -> [String] {
        (0..<grid.itemCount).compactMap { grid.cellForTesting(at: $0)?.nameSurface.stringValue }
    }

    // MARK: - A republish is not a new picture

    /// Entering the gallery starts the dimension probe, whose republish used to re-open the image
    /// and reset the page.
    func testEnteringTheGalleryKeepsTheCurrentPage() throws {
        let (controller, viewer) = makeViewer()
        defer { TestAppKit.close(controller) }
        viewer.open(url: Fixtures.url("multipage.tiff"))
        guard waitUntil(15, { viewer.viewerState.isMultiPage }) else {
            throw XCTSkip("multipage.tiff is not multi-page in this build")
        }
        viewer.perform(.nextPage)
        XCTAssertTrue(waitUntil(5) { viewer.viewerState.pageIndex == 1 },
                      "precondition: the second page is on screen")

        _ = try enterBrowser(viewer)
        pump(1.0)

        XCTAssertEqual(viewer.viewerState.pageIndex, 1,
                       "the gallery shows the same picture; its list gaining sizes is not a "
                       + "different image (measured before: page 0)")
    }

    /// The same rule for a re-sort: the file may move to another index, the picture does not change.
    func testASortDoesNotReloadTheCurrentImage() throws {
        let (controller, viewer) = makeViewer()
        defer { TestAppKit.close(controller) }
        viewer.open(url: Fixtures.url("multipage.tiff"))
        guard waitUntil(15, { viewer.viewerState.isMultiPage }) else {
            throw XCTSkip("multipage.tiff is not multi-page in this build")
        }
        viewer.perform(.nextPage)
        XCTAssertTrue(waitUntil(5) { viewer.viewerState.pageIndex == 1 })

        SharedSettingsScope.preservingSort(key: .filename, direction: .ascending) {
            viewer.perform(.toggleSortDirection)
            pump(0.6)
        }
        XCTAssertEqual(viewer.viewerState.pageIndex, 1,
                       "re-ordering the list around the same file must not reset its page")
    }

    // MARK: - The selection must be visible

    func testSelectingTheLastImageBringsItOnScreen() throws {
        let directory = try makeFolder(200, label: "gallery-scroll")
        defer { try? FileManager.default.removeItem(at: directory) }
        let (controller, viewer) = makeViewer()
        defer { TestAppKit.close(controller) }
        viewer.open(url: directory.appendingPathComponent("img000.png"))
        XCTAssertTrue(waitUntil(15) { viewer.viewerState.currentImage != nil })
        let browser = try enterBrowser(viewer)
        let grid = browser.view.gallery
        let visibleBefore = grid.visibleIndexes
        XCTAssertFalse(visibleBefore.contains(199), "precondition: the last item is off screen")

        viewer.perform(.lastImage)
        pump(0.6)
        browser.view.layoutSubtreeIfNeeded()

        XCTAssertEqual(viewer.session.currentIndex, 199)
        XCTAssertTrue(grid.visibleIndexes.contains(199),
                      "the selected image is on screen (visible: "
                      + "\(grid.visibleIndexes.sorted().first ?? -1)…"
                      + "\(grid.visibleIndexes.sorted().last ?? -1))")
    }

    // MARK: - Geometry is computed once per change

    func testDeliveredThumbnailsDoNotRebuildTheGeometry() throws {
        let host = GalleryAuditHost(
            items: (0..<4_000).map {
                FolderItem(url: URL(fileURLWithPath: "/tmp/gallery-cache/img-\($0).png"),
                           pixelSize: CGSize(width: 2, height: 2))
            },
            directory: URL(fileURLWithPath: "/tmp/gallery-cache"))
        let browser = FolderBrowserViewController(host: host)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = browser.view
        window.setFrameOrigin(NSPoint(x: -30000, y: -30000))
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        browser.reload()
        window.layoutIfNeeded()
        pump(0.3)

        let grid = browser.view.gallery
        let before = grid.rowsComputationCountForTesting
        let image = CGContext(data: nil, width: 32, height: 32, bitsPerComponent: 8,
                              bytesPerRow: 32 * 4,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            .makeImage()!
        for index in 0..<20 {
            grid.noteDelivered(image, pixelSize: 300, versionToken: "v",
                               for: host.session.items[index].url)
        }
        let after = grid.rowsComputationCountForTesting
        XCTAssertLessThanOrEqual(after - before, 1,
                                 "twenty deliveries with unchanged geometry must not rebuild "
                                 + "4,000 items' rows (rebuilt \(after - before) times)")
    }
}
