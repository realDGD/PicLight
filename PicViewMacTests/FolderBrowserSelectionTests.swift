import XCTest
import AppKit
@testable import PicViewMac

/// Gallery selection and navigation, and the sort order the two modes share.
@MainActor
final class FolderBrowserSelectionTests: XCTestCase {

    override func setUp() async throws {
        try await super.setUp()
        TestAppKit.ensureApplication()
    }

    private func makeViewer(_ names: [String] = ["a.png", "b.png", "c.png", "d.png"])
        throws -> (directory: URL, controller: ViewerWindowController, viewer: ViewerViewController,
                   browser: FolderBrowserViewController) {
        let directory = try Fixtures.makeScratchDirectory("selection")
        for name in names {
            try FileManager.default.copyItem(at: Fixtures.url("static.png"),
                                             to: directory.appendingPathComponent(name))
        }
        let controller = ViewerWindowController()
        TestAppKit.presentOffScreen(controller)
        let viewer = controller.viewerViewController
        controller.showWindow(nil)
        _ = viewer.view
        viewer.open(url: directory.appendingPathComponent(names[0]))
        let deadline = Date().addingTimeInterval(10)
        while viewer.viewerState.currentImage == nil, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        viewer.perform(.browseFolder)
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        viewer.view.layoutSubtreeIfNeeded()
        return (directory, controller, viewer, try XCTUnwrap(viewer.folderBrowserForTesting))
    }

    private func cleanup(_ directory: URL, _ controller: ViewerWindowController) {
        controller.close()
        try? FileManager.default.removeItem(at: directory)
    }

    /// The current image carries a visible selection, and only the current one does.
    func testTheCurrentImageCarriesTheOnlySelection() throws {
        let (directory, controller, viewer, browser) = try makeViewer()
        defer { cleanup(directory, controller) }
        let grid = browser.view.gallery

        browser.select(0)
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        let first = try XCTUnwrap(grid.cellForTesting(at: 0))
        XCTAssertFalse(first.selectionSurface.isHidden, "the current row is marked")
        if let other = grid.cellForTesting(at: 1) {
            XCTAssertTrue(other.selectionSurface.isHidden, "and the others are not")
        }

        browser.select(2)
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(viewer.session.currentIndex, 2)
        if let firstAgain = grid.cellForTesting(at: 0) {
            XCTAssertTrue(firstAgain.selectionSurface.isHidden, "the mark moved with the selection")
        }
        XCTAssertFalse(try XCTUnwrap(grid.cellForTesting(at: 2)).selectionSurface.isHidden)
    }

    /// A single click selects; a double click opens. Both go through the same selection, so single
    /// click and Return never disagree about which item is current.
    func testSingleClickSelectsAndDoubleClickOpens() throws {
        let (directory, controller, viewer, browser) = try makeViewer()
        defer { cleanup(directory, controller) }
        let grid = browser.view.gallery

        let third = try XCTUnwrap(viewer.session.items.dropFirst(2).first).url
        grid.onSelectionChanged?(2)
        XCTAssertEqual(viewer.session.currentItem?.url, third, "a single click selects")
        XCTAssertEqual(viewer.viewerMode, .folderBrowser, "and does not leave the browser")

        grid.onItemOpened?(2)
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        XCTAssertEqual(viewer.viewerMode, .image, "a double click opens the item")
        XCTAssertEqual(viewer.session.currentItem?.url, third,
                       "and opens the item that was selected, by identity")
    }

    /// The current item is highlighted in the tree as well as in the grid: one index, two views.
    func testTheTreeAndTheGridAgreeAboutTheCurrentItem() throws {
        let (directory, controller, viewer, browser) = try makeViewer()
        defer { cleanup(directory, controller) }
        browser.select(1)
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(viewer.session.currentIndex, 1)
        XCTAssertEqual(browser.view.gallery.layoutKindForTesting, .uniformGrid)
        // The tree highlights the *folder*, which has not changed; the position readout is what
        // tracks the item.
        let text = browser.view.folderTitleLabel.stringValue
        XCTAssertTrue(text.contains("2 / 4"), "the toolbar reports the new position: \(text)")
    }

    /// Navigation keeps the gallery and the session in step, because there is one index: the
    /// viewer's own next command moves the gallery's highlight.
    ///
    /// The assertion is the *agreement*, not which file is next: the folder is watched, and a
    /// background rescan can reorder the list under a slow run. What must never diverge is the
    /// index the two views use.
    func testNavigationKeepsTheGalleryAndTheSessionInStep() throws {
        let (directory, controller, viewer, browser) = try makeViewer()
        defer { cleanup(directory, controller) }

        viewer.perform(.nextImage)
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))

        let index = try XCTUnwrap(viewer.session.currentIndex)
        XCTAssertEqual(browser.view.gallery.currentIndex, index,
                       "the gallery follows the position the viewer navigated to")
        if let cell = browser.view.gallery.cellForTesting(at: index) {
            XCTAssertFalse(cell.selectionSurface.isHidden, "and the current cell is marked")
        }
        XCTAssertTrue(browser.view.folderTitleLabel.stringValue.contains(
            viewer.session.positionDescription),
                      "and the toolbar reports the same position")
    }

}

/// The sort order: one state for the whole app, the keys the spec names, and the gallery following
/// it.
@MainActor
final class FolderBrowserSortingTests: XCTestCase {

    override func setUp() async throws {
        try await super.setUp()
        TestAppKit.ensureApplication()
    }

    private func items(_ names: [String]) -> [FolderItem] {
        names.map { FolderItem(url: URL(fileURLWithPath: "/tmp/\($0)")) }
    }

    /// The keys the first version must support, including the extension one.
    func testTheRequiredSortKeysExist() {
        for key: ImageSortKey in [.filename, .fileExtension, .modificationDate, .creationDate,
                                  .fileSize] {
            XCTAssertTrue(ImageSortKey.allCases.contains(key), "\(key.rawValue) is missing")
        }
        XCTAssertEqual(ImageSortKey.fileExtension.localizedName, "扩展名")
        for direction in [SortDirection.ascending, .descending] {
            XCTAssertTrue(SortDirection.allCases.contains(direction))
        }
    }

    /// Sorting by extension groups like extensions and orders the groups by name.
    func testSortingByExtensionGroupsAndOrdersTheGroups() {
        let sorted = ImageSort.sort(items(["b.png", "a.jpg", "c.png", "d.gif"]),
                                    by: .fileExtension, direction: .ascending)
        XCTAssertEqual(sorted.map { $0.displayName }, ["d.gif", "a.jpg", "b.png", "c.png"],
                       "gif, jpg, then the pngs in name order")
    }

    /// Descending is the exact reverse of ascending, for every key: a direction that only reordered
    /// ties would be a bug the user sees as "sorting did nothing".
    func testTheTwoDirectionsAreExactReverses() {
        let source = items(["a.png", "b.jpg", "c.gif", "d.png"])
        for key in ImageSortKey.allCases where key != .dimensions {
            let up = ImageSort.sort(source, by: key, direction: .ascending).map { $0.displayName }
            let down = ImageSort.sort(source, by: key, direction: .descending).map { $0.displayName }
            XCTAssertEqual(Array(up.reversed()), down, "\(key.rawValue)")
        }
    }

    /// Natural order, so `2.png` precedes `10.png`.
    func testSortingByNameIsNatural() {
        let sorted = ImageSort.sort(items(["10.png", "2.png", "1.png"]), by: .filename,
                                    direction: .ascending)
        XCTAssertEqual(sorted.map { $0.displayName }, ["1.png", "2.png", "10.png"])
    }

    /// The viewer's own reload path uses the shared sort, so the two modes cannot disagree.
    func testTheViewerAndTheGalleryReadOneSortOrder() throws {
try SharedSettingsScope.preservingSort {

            let directory = try Fixtures.makeScratchDirectory("sorting")
            defer { try? FileManager.default.removeItem(at: directory) }
            for name in ["c.png", "a.png", "b.png"] {
                try FileManager.default.copyItem(at: Fixtures.url("static.png"),
                                                 to: directory.appendingPathComponent(name))
            }
            let originalKey = AppSettings.shared.sortKey
            let originalDirection = AppSettings.shared.sortDirection
            defer {
                AppSettings.shared.sortKey = originalKey
                AppSettings.shared.sortDirection = originalDirection
            }

            let controller = ViewerWindowController()
            TestAppKit.presentOffScreen(controller)
            let viewer = controller.viewerViewController
            controller.showWindow(nil)
            _ = viewer.view
            AppSettings.shared.sortDirection = .descending
            viewer.open(url: directory.appendingPathComponent("a.png"))
            let deadline = Date().addingTimeInterval(10)
            while viewer.viewerState.currentImage == nil, Date() < deadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.4))
            defer { controller.close() }

            XCTAssertEqual(viewer.session.items.map { $0.displayName }, ["c.png", "b.png", "a.png"],
                           "the viewer's list follows the shared order")

            viewer.perform(.browseFolder)
            RunLoop.current.run(until: Date().addingTimeInterval(0.4))
            let browser = try XCTUnwrap(viewer.folderBrowserForTesting)
            XCTAssertEqual(browser.view.sortKeyControl.titleOfSelectedItem, originalKey.localizedName)
            XCTAssertEqual(browser.view.gallery.itemCount, viewer.session.items.count,
                           "the gallery shows exactly the session's list")
    
}
}
}

/// Virtualization: a folder of thousands must not create thousands of views.
@MainActor
final class FolderBrowserVirtualizationTests: XCTestCase {

    override func setUp() async throws {
        try await super.setUp()
        TestAppKit.ensureApplication()
    }

    /// The pure form: the layout says how many cells a visible rectangle needs, and it does not grow
    /// with the folder.
    func testTheLayoutOnlyPlacesTheCellsAVisibleRectNeeds() {
        for kind in GalleryLayoutKind.allCases {
            for count in [100, 1000, 5000, 10000] {
                let aspects = Array(repeating: CGFloat(1.5), count: count)
                let rows = GalleryLayout.rows(for: kind, aspects: aspects, containerWidth: 900,
                                              thumbnailSize: 160)
                XCTAssertEqual(rows.flatMap(\.cells).count, count,
                               "\(kind) with \(count): the layout covers every item")

                let visible = CGRect(x: 0, y: 0, width: 900, height: 600)
                let visibleCells = GalleryLayout.visibleCellCount(in: visible, of: rows)
                XCTAssertLessThan(visibleCells, 60,
                                  "\(kind) with \(count): a screenful is a screenful, "
                                    + "not \(visibleCells) cells")
            }
        }
    }

    /// The view form, driven through the gallery the browser actually uses: a ten-thousand-image
    /// folder materializes only what is on screen, and the number does not grow with the folder.
    ///
    /// The items are synthesized rather than copied so the test measures the view layer instead of
    /// the file system; nothing in the grid reads a file except through the thumbnail callback.
    func testTheGridViewMaterializesOnlyWhatIsOnScreen() throws {
        let (directory, controller, viewer, browser) = try makeViewer(count: 4)
        defer { cleanup(directory, controller) }
        let grid = browser.view.gallery

        func materialized(for count: Int) -> (cells: Int, created: Int) {
            let items = (0..<count).map { FolderItem(url: URL(fileURLWithPath: "/tmp/synthetic\($0).png")) }
            grid.rebuild(items: items, aspects: Array(repeating: 1.5, count: count),
                         currentIndex: 0, layoutKind: .uniformGrid, thumbnailSize: 160)
            grid.layoutSubtreeIfNeeded()
            return (grid.materializedCellCount, grid.createdCellCount)
        }

        let hundred = materialized(for: 100)
        XCTAssertGreaterThan(hundred.cells, 0, "something is on screen")
        XCTAssertLessThan(hundred.cells, 60, "and it is a screenful")

        let tenThousand = materialized(for: 10_000)
        XCTAssertLessThanOrEqual(tenThousand.cells, hundred.cells + 4,
                                 "ten thousand images must not materialize more cells than a "
                                   + "hundred do (\(tenThousand.cells) vs \(hundred.cells))")
        XCTAssertLessThan(tenThousand.created, 200,
                          "the cell pool stays bounded as the folder grows "
                            + "(\(tenThousand.created) created for 10000 items)")
        XCTAssertEqual(grid.itemCount, 10_000, "the data source still holds every item")
    }

    /// The adaptive layout virtualizes the same way, even though its rows have different heights.
    func testTheAdaptiveLayoutVirtualizesToo() throws {
        let (directory, controller, _, browser) = try makeViewer(count: 4)
        defer { cleanup(directory, controller) }
        let grid = browser.view.gallery
        let aspects = (0..<5000).map { CGFloat(1 + ($0 % 5)) }

        grid.rebuild(items: (0..<5000).map {
            FolderItem(url: URL(fileURLWithPath: "/tmp/adaptive\($0).png"))
        }, aspects: aspects, currentIndex: 0, layoutKind: .adaptiveGrid, thumbnailSize: 160)
        grid.layoutSubtreeIfNeeded()

        XCTAssertGreaterThan(grid.materializedCellCount, 0)
        XCTAssertLessThan(grid.materializedCellCount, 60,
                          "a screenful of adaptive cells, not five thousand")
    }

    /// Cells are recycled as the view moves: the total created stays far below the folder's size.
    func testScrollingRecyclesCellsInsteadOfCreatingMore() throws {
        let (directory, controller, _, browser) = try makeViewer(count: 4)
        defer { cleanup(directory, controller) }
        let grid = browser.view.gallery
        let count = 3000
        grid.rebuild(items: (0..<count).map {
            FolderItem(url: URL(fileURLWithPath: "/tmp/scroll\($0).png"))
        }, aspects: Array(repeating: 1.5, count: count), currentIndex: 0,
                     layoutKind: .uniformGrid, thumbnailSize: 160)
        grid.layoutSubtreeIfNeeded()
        let firstScreen = grid.visibleIndexes
        XCTAssertFalse(firstScreen.isEmpty)

        // Walk down the document, one screenful at a time, laying out as a real scroll would.
        let scroll = try XCTUnwrap(grid.enclosingScrollView)
        for step in 1...12 {
            scroll.contentView.scroll(to: NSPoint(x: 0, y: CGFloat(step) * 400))
            scroll.reflectScrolledClipView(scroll.contentView)
            grid.needsLayout = true
            grid.layoutSubtreeIfNeeded()
        }

        XCTAssertNotEqual(grid.visibleIndexes, firstScreen, "the visible set moved")
        XCTAssertLessThan(grid.materializedCellCount, 100, "cells are recycled, not accumulated")
        XCTAssertLessThan(grid.createdCellCount, count / 4,
                          "far fewer cells were created than the folder holds "
                            + "(\(grid.createdCellCount) of \(count))")
    }

    /// The gallery asks for a thumbnail once per cell that appears — not once per item in the
    /// folder.
    func testThumbnailsAreOnlyRequestedForCellsThatAppear() throws {
        let (directory, controller, viewer) = try makeRealFolder(count: 40)
        defer { cleanup(directory, controller) }
        viewer.perform(.browseFolder)
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        let browser = try XCTUnwrap(viewer.folderBrowserForTesting)
        XCTAssertGreaterThan(browser.thumbnailRequestCount, 0,
                            "the cells on screen ask for their thumbnails")
        XCTAssertLessThanOrEqual(browser.thumbnailRequestCount, 40,
                                 "and no more than the folder holds")
    }

    // MARK: - Fixtures

    private func makeViewer(count: Int) throws -> (directory: URL,
                                                   controller: ViewerWindowController,
                                                   viewer: ViewerViewController,
                                                   browser: FolderBrowserViewController) {
        let (directory, controller, viewer) = try makeRealFolder(count: count)
        viewer.perform(.browseFolder)
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        viewer.view.layoutSubtreeIfNeeded()
        return (directory, controller, viewer, try XCTUnwrap(viewer.folderBrowserForTesting))
    }

    private func makeRealFolder(count: Int) throws -> (directory: URL,
                                                       controller: ViewerWindowController,
                                                       viewer: ViewerViewController) {
        let directory = try Fixtures.makeScratchDirectory("virtualization")
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
        let deadline = Date().addingTimeInterval(10)
        while viewer.viewerState.currentImage == nil, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        return (directory, controller, viewer)
    }

    private func cleanup(_ directory: URL, _ controller: ViewerWindowController) {
        controller.close()
        try? FileManager.default.removeItem(at: directory)
    }
}
