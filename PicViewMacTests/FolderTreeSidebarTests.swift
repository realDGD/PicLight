import XCTest
import AppKit
@testable import PicViewMac

/// The sidebar as it renders: every row once, every row clickable, the root where the user left it.
///
/// Measured before the fix: the outline was handed a flattened row list *and* told to expand the
/// same nodes, so an expanded folder's children were drawn twice (`上一级, A, B, C, B, C`), and the
/// click handler mapped `selectedRow` into the flattened array — the duplicate rows did nothing when
/// clicked. Descending also re-rooted the tree, so the left column rewrote itself on every step and
/// an expansion was lost on the next refresh.
@MainActor
final class FolderTreeSidebarTests: XCTestCase {

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
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return condition()
    }

    /// A folder with `A/{B/{D}, C}` inside it, and one image in A.
    private func makeTree() throws -> (base: URL, a: URL, b: URL, c: URL, d: URL) {
        let base = try Fixtures.makeScratchDirectory("tree-rows")
        let a = base.appendingPathComponent("A")
        let b = a.appendingPathComponent("B")
        let c = a.appendingPathComponent("C")
        let d = b.appendingPathComponent("D")
        for directory in [a, b, c, d] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try FileManager.default.copyItem(at: Fixtures.url("static.png"),
                                         to: a.appendingPathComponent("img.png"))
        return (base, a, b, c, d)
    }

    private func makeBrowser() -> (ViewerWindowController, ViewerViewController) {
        let controller = ViewerWindowController()
        TestAppKit.presentOffScreen(controller)
        controller.window?.setFrame(NSRect(x: 0, y: 0, width: 1100, height: 760), display: false)
        controller.showWindow(nil)
        let viewer = controller.viewerViewController
        _ = viewer.view
        return (controller, viewer)
    }

    private func enterBrowser(_ viewer: ViewerViewController, on file: URL) throws
        -> FolderBrowserViewController {
        viewer.open(url: file)
        XCTAssertTrue(waitUntil(15) { viewer.viewerState.currentImage != nil })
        viewer.perform(.browseFolder)
        pump(0.8)
        viewer.view.layoutSubtreeIfNeeded()
        let browser = try XCTUnwrap(viewer.folderBrowserForTesting)
        browser.view.layoutSubtreeIfNeeded()
        return browser
    }

    private func renderedRows(_ sidebar: FolderTreeSidebarView) -> [String] {
        (0..<sidebar.visibleRowCount).compactMap { sidebar.renderedName(at: $0) }
    }

    /// The URL the tree itself stores for the row with this name. Tests must not spell folder URLs
    /// themselves: the model canonicalizes (`/var` and `/private/var` are two nodes to a comparison,
    /// and their `resolvingSymlinksInPath()` goes the other way).
    private func treeURL(_ sidebar: FolderTreeSidebarView, named name: String) -> URL? {
        for row in 0..<sidebar.outlineView.numberOfRows {
            guard let item = sidebar.outlineView.item(atRow: row) as? FolderSidebarItem,
                  item.node != nil, item.url.lastPathComponent == name else { continue }
            return item.url
        }
        return nil
    }

    private func expand(_ sidebar: FolderTreeSidebarView, in browser: FolderBrowserViewController,
                        named name: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let url = try XCTUnwrap(treeURL(sidebar, named: name), "the tree has a row named \(name)",
                                file: file, line: line)
        browser.view.onFolderExpansionChanged?(url, true)
        sidebar.layoutSubtreeIfNeeded()
    }

    /// What is rendered is the model's tree, once each.
    func testNoRowIsRenderedTwice() throws {
        let tree = try makeTree()
        defer { try? FileManager.default.removeItem(at: tree.base) }
        let (controller, viewer) = makeBrowser()
        defer { TestAppKit.close(controller) }
        let browser = try enterBrowser(viewer, on: tree.a.appendingPathComponent("img.png"))
        let sidebar = browser.view.treeSidebar

        // Expand B the way a disclosure click does, so D becomes visible.
        try expand(sidebar, in: browser, named: "B")
        let rows = renderedRows(sidebar)

        XCTAssertEqual(rows.first, "上一级")
        XCTAssertTrue(rows.contains("A"), "the browsed folder is a row")
        XCTAssertTrue(rows.contains("D"), "the expanded folder's contents are on screen")
        XCTAssertEqual(Set(rows).count, rows.count,
                       "every row is rendered exactly once (measured before: "
                       + "\(rows.count) rows with duplicates)")
        XCTAssertEqual(sidebar.visibleRowCount, sidebar.outlineView.numberOfRows,
                       "and the count the view reports is the count AppKit renders")
    }

    /// Every rendered row opens the folder it displays.
    func testClickingARenderedRowOpensTheFolderItShows() throws {
        let tree = try makeTree()
        defer { try? FileManager.default.removeItem(at: tree.base) }
        let (controller, viewer) = makeBrowser()
        defer { TestAppKit.close(controller) }
        let browser = try enterBrowser(viewer, on: tree.a.appendingPathComponent("img.png"))
        let sidebar = browser.view.treeSidebar
        try expand(sidebar, in: browser, named: "B")

        let rows = renderedRows(sidebar)
        let index = try XCTUnwrap(rows.firstIndex(of: "C"), "C is a row")
        sidebar.outlineView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        XCTAssertTrue(waitUntil(10) {
            viewer.session.directory?.standardizedFileURL.path == tree.c.standardizedFileURL.path
        }, "clicking the row that shows C opens C (rows were: \(rows))")
    }

    /// Descending inside the tree keeps the root and everything the user expanded.
    func testDescendingKeepsTheRootAndTheExpansion() throws {
        let tree = try makeTree()
        defer { try? FileManager.default.removeItem(at: tree.base) }
        let (controller, viewer) = makeBrowser()
        defer { TestAppKit.close(controller) }
        let browser = try enterBrowser(viewer, on: tree.a.appendingPathComponent("img.png"))
        let sidebar = browser.view.treeSidebar
        try expand(sidebar, in: browser, named: "B")
        XCTAssertTrue(renderedRows(sidebar).contains("D"), "precondition: D is visible")

        // Descend into B, the way the tree's own row does.
        let modelB = try XCTUnwrap(treeURL(sidebar, named: "B"))
        browser.view.onFolderChosen?(modelB)
        XCTAssertTrue(waitUntil(10) {
            viewer.session.directory?.standardizedFileURL.path == tree.b.standardizedFileURL.path
        })
        pump(0.4)
        sidebar.layoutSubtreeIfNeeded()

        let rows = renderedRows(sidebar)
        XCTAssertTrue(rows.contains("A"), "the root is where the user started (rows: \(rows))")
        XCTAssertTrue(rows.contains("B"), "with the folder they moved to highlighted inside it")
        XCTAssertEqual(sidebar.selectedPath, tree.b.standardizedFileURL.path)
    }

    /// The refresh a sort causes keeps the tree — both entry points, because they take different
    /// paths into the browser (the popup reloads it directly, the shortcut notifies through the
    /// session).
    func testARefreshKeepsTheExpansion() throws {
        let tree = try makeTree()
        defer { try? FileManager.default.removeItem(at: tree.base) }
        let (controller, viewer) = makeBrowser()
        defer { TestAppKit.close(controller) }
        let browser = try enterBrowser(viewer, on: tree.a.appendingPathComponent("img.png"))
        let sidebar = browser.view.treeSidebar
        try expand(sidebar, in: browser, named: "B")
        XCTAssertTrue(renderedRows(sidebar).contains("D"), "precondition: B was expanded")

        SharedSettingsScope.preservingSort(key: .filename, direction: .ascending) {
            // The toolbar popup.
            browser.view.onSortKeyChanged?(.fileSize)
            pump(0.6)
            sidebar.layoutSubtreeIfNeeded()
            XCTAssertTrue(renderedRows(sidebar).contains("D"),
                          "the toolbar's sort keeps what was expanded (rows: "
                          + "\(renderedRows(sidebar)))")

            // The menu/keyboard shortcut.
            viewer.perform(.toggleSortDirection)
            pump(0.6)
            sidebar.layoutSubtreeIfNeeded()
            XCTAssertTrue(renderedRows(sidebar).contains("D"),
                          "and so does the sort shortcut (rows: \(renderedRows(sidebar)))")
            XCTAssertEqual(renderedRows(sidebar).first, "上一级")
        }
    }

    /// Clicking a subfolder the way a user does — a real selection on the outline — keeps the root
    /// where it was. This is the report that started the repair ("the left column keeps changing"):
    /// every descent used to rebuild the tree with the subfolder as its root.
    func testClickingASubfolderInTheOutlineKeepsTheRoot() throws {
        let tree = try makeTree()
        defer { try? FileManager.default.removeItem(at: tree.base) }
        let (controller, viewer) = makeBrowser()
        defer { TestAppKit.close(controller) }
        let browser = try enterBrowser(viewer, on: tree.a.appendingPathComponent("img.png"))
        let sidebar = browser.view.treeSidebar
        let rootBefore = try XCTUnwrap(browser.visibleNodesForTesting.first?.url,
                                       "the tree has a root")
        XCTAssertEqual(rootBefore.standardizedFileURL.path, tree.a.standardizedFileURL.path)

        // A real click on the outline's row for B, then for C: the rows the outline renders are what
        // the user sees, and `selectRowIndexes` is what a click does.
        for name in ["B", "C"] {
            let row = try XCTUnwrap((0..<sidebar.outlineView.numberOfRows).first {
                sidebar.renderedName(at: $0) == name
            }, "\(name) is a row")
            sidebar.outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            XCTAssertTrue(waitUntil(10) {
                viewer.session.directory?.standardizedFileURL.path
                    == (name == "B" ? tree.b : tree.c).standardizedFileURL.path
            }, "clicking \(name) opens it")
            pump(0.4)
            sidebar.layoutSubtreeIfNeeded()

            XCTAssertEqual(browser.visibleNodesForTesting.first?.url.standardizedFileURL.path,
                           tree.a.standardizedFileURL.path,
                           "the root is still A after descending into \(name) "
                           + "(rows: \(renderedRows(sidebar)))")
            XCTAssertEqual(sidebar.selectedPath,
                           (name == "B" ? tree.b : tree.c).standardizedFileURL.path,
                           "and the folder that was clicked is the highlighted one")
        }
    }

    /// Going up from the root is the one thing that moves the root: the tree grows upward.
    func testTheUpRowAboveTheRootExtendsTheTreeUpward() throws {
        let tree = try makeTree()
        defer { try? FileManager.default.removeItem(at: tree.base) }
        let (controller, viewer) = makeBrowser()
        defer { TestAppKit.close(controller) }
        let browser = try enterBrowser(viewer, on: tree.a.appendingPathComponent("img.png"))
        let sidebar = browser.view.treeSidebar
        let rows = renderedRows(sidebar)
        XCTAssertEqual(rows.first, "上一级")

        sidebar.outlineView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        // The session's directory is set as soon as the request starts; what has to follow is the
        // tree, so the wait is on the tree's own root.
        XCTAssertTrue(waitUntil(10) {
            browser.visibleNodesForTesting.first?.url.standardizedFileURL.path
                == tree.base.standardizedFileURL.path
        }, "the up row opens the parent of the root and re-roots the tree there")

        sidebar.layoutSubtreeIfNeeded()
        let after = renderedRows(sidebar)
        XCTAssertTrue(after.contains("A"), "the folder that was the root is a row inside it now "
                      + "(rows: \(after))")
        XCTAssertEqual(sidebar.selectedPath, tree.base.standardizedFileURL.path)
    }
}
