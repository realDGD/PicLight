import XCTest
import AppKit
@testable import PicViewMac

/// The folder tree's laziness and its structure.
///
/// The spec is explicit that the whole disk must not be walked and that children load on expansion.
/// The model is driven entirely through injected providers here, so every enumeration is counted and
/// the laziness claim is a number rather than a description.
@MainActor
final class FolderTreeTests: XCTestCase {

    override func setUp() async throws {
        try await super.setUp()
        TestAppKit.ensureApplication()
    }

    /// A tree described as text: "/" holds a, b; "/a" holds a1, a2; "/a/a1" holds a1x.
    private func fixtureTree() -> (children: (URL) -> [URL], hasChildren: (URL) -> Bool,
                                   counts: () -> (children: Int, hasChildren: Int)) {
        var childCalls = 0
        var hasCalls = 0
        let table: [String: [String]] = [
            "/": ["/a", "/b"],
            "/a": ["/a/a1", "/a/a2"],
            "/a/a1": ["/a/a1/x"],
            "/a/a2": [],
            "/a/a1/x": [],
            "/b": [],
        ]
        let children: (URL) -> [URL] = { url in
            childCalls += 1
            return (table[url.path] ?? []).map { URL(fileURLWithPath: $0) }
        }
        let hasChildren: (URL) -> Bool = { url in
            hasCalls += 1
            return !(table[url.path] ?? []).isEmpty
        }
        return (children, hasChildren, { (childCalls, hasCalls) })
    }

    private func model() -> (FolderTreeModel, () -> (children: Int, hasChildren: Int)) {
        let fixture = fixtureTree()
        return (FolderTreeModel(childrenProvider: fixture.children,
                               hasChildrenProvider: fixture.hasChildren),
                fixture.counts)
    }

    // MARK: - Laziness

    /// Focusing on a folder reads that folder and nothing else: no ancestor is listed, and nothing
    /// below the focused folder is shown.
    func testFocusingReadsOnlyTheFocusedFolder() {
        let (tree, counts) = model()
        tree.focus(on: URL(fileURLWithPath: "/a/a1/x"))

        XCTAssertEqual(counts().children, 1,
                       "exactly one listing: the folder the gallery is showing")
        XCTAssertEqual(tree.visibleNodes.map(\.url.path), ["/a/a1/x"],
                       "a leaf folder is a one-row tree")
    }

    /// The folders inside the current folder are listed without being read themselves.
    func testFocusingShowsTheFoldersInsideTheCurrentFolder() {
        let (tree, counts) = model()
        tree.focus(on: URL(fileURLWithPath: "/a"))

        XCTAssertEqual(counts().children, 1, "one listing: /a itself")
        XCTAssertEqual(tree.visibleNodes.map(\.url.path), ["/a", "/a/a1", "/a/a2"],
                       "the current folder and its immediate subfolders")
        XCTAssertFalse(tree.visibleNodes.map(\.url.path).contains("/a/a1/x"),
                       "a collapsed child's contents are not shown…")
        XCTAssertFalse(tree.visibleNodes.map(\.url.path).contains("/b"),
                       "…and siblings of the current folder are not part of this tree at all")
    }

    /// The reported bug: the tree used to be rooted above the browsed folder, so the sidebar filled
    /// up with the path the image happens to live on.
    func testTheTreeNeverShowsTheFoldersAboveTheCurrentOne() {
        let (tree, _) = model()
        tree.focus(on: URL(fileURLWithPath: "/a/a1/x"))
        let visible = Set(tree.visibleNodes.map(\.url.path))
        XCTAssertFalse(visible.contains("/"), "the volume is not a row")
        XCTAssertFalse(visible.contains("/a"), "nor is the parent folder")
        XCTAssertFalse(visible.contains("/a/a1"), "nor the grandparent")
        XCTAssertTrue(visible.contains("/a/a1/x"), "the browsed folder is the root")

        tree.focus(on: URL(fileURLWithPath: "/a/a1"))
        let next = Set(tree.visibleNodes.map(\.url.path))
        XCTAssertEqual(next, ["/a/a1", "/a/a1/x"], "re-rooting on another folder replaces the tree")
    }

    /// A folder whose path does not exist in the tree is handled without inventing nodes.
    func testAnUnknownFolderDoesNotInventNodes() {
        let (tree, _) = model()
        tree.focus(on: URL(fileURLWithPath: "/nope/nothing"))
        XCTAssertEqual(tree.visibleNodes.map(\.url.path), ["/nope/nothing"],
                       "the folder is the root even when the file system has nothing at it")
        XCTAssertEqual(tree.currentFolderPath, "/nope/nothing")
    }

    /// Expanding reads exactly one more level, and only once — collapsing and expanding again comes
    /// from the cache.
    ///
    /// The node toggled is a *visible* one, which is the only kind a user can click: a tree row
    /// exists only when its parent — here the root — has been read.
    func testExpandingReadsOneLevelAndCachesIt() {
        let (tree, counts) = model()
        tree.focus(on: URL(fileURLWithPath: "/a"))
        let before = counts().children
        XCTAssertFalse(tree.visibleNodes.map(\.url.path).contains("/a/a1/x"),
                       "a collapsed folder's contents are not shown…")

        tree.toggle(URL(fileURLWithPath: "/a/a1"))
        let afterExpand = counts().children
        XCTAssertGreaterThan(afterExpand, before, "…and are read when it is expanded")
        XCTAssertTrue(tree.visibleNodes.map(\.url.path).contains("/a/a1/x"),
                      "its children are now on screen")

        tree.toggle(URL(fileURLWithPath: "/a/a1"))
        XCTAssertFalse(tree.visibleNodes.map(\.url.path).contains("/a/a1/x"),
                       "collapsing hides them again")
        tree.toggle(URL(fileURLWithPath: "/a/a1"))
        XCTAssertEqual(counts().children, afterExpand,
                       "a second expansion must come from the cache, not from the disk")
    }

    /// The number of enumerations is bounded by the tree's visible levels, not by the folder's size:
    /// focusing is one listing, and each expansion is one more.
    func testTheReadCountIsBoundedByTheVisibleLevels() {
        let (tree, counts) = model()
        tree.focus(on: URL(fileURLWithPath: "/a"))
        XCTAssertEqual(counts().children, 1, "focusing lists the current folder only")

        tree.toggle(URL(fileURLWithPath: "/a/a1"))
        XCTAssertEqual(counts().children, 2, "expanding a child lists that child, once")
        tree.toggle(URL(fileURLWithPath: "/a/a1"))
        tree.toggle(URL(fileURLWithPath: "/a/a1"))
        XCTAssertEqual(counts().children, 2, "and a re-expansion comes from the cache")
    }

    // MARK: - Structure

    /// The root is the folder the gallery is showing, so the tree is that folder's contents.
    func testTheRootIsTheFocusedFolder() {
        let (tree, _) = model()
        tree.focus(on: URL(fileURLWithPath: "/a/a1/x"))
        XCTAssertEqual(tree.root?.url.path, "/a/a1/x")
        XCTAssertEqual(tree.currentFolderPath, "/a/a1/x", "and the focused folder is remembered")
    }

    /// The current folder is expanded, so what is inside it is visible without any clicking.
    func testTheCurrentFolderIsExpanded() {
        let (tree, _) = model()
        tree.focus(on: URL(fileURLWithPath: "/a/a1"))
        let visible = Set(tree.visibleNodes.map(\.url.path))
        XCTAssertTrue(visible.contains("/a/a1"), "the folder itself is the root row")
        XCTAssertTrue(visible.contains("/a/a1/x"), "with what is inside it on screen")
        XCTAssertFalse(visible.contains("/a"), "and nothing above it")
    }

    // MARK: - Real file system

    /// The production enumeration is one level, immediate subdirectories only.
    func testTheProductionEnumerationIsOneLevelOfDirectories() throws {
        let directory = try Fixtures.makeScratchDirectory("folder-tree")
        defer { try? FileManager.default.removeItem(at: directory) }
        for name in ["sub1", "sub2"] {
            try FileManager.default.createDirectory(at: directory.appendingPathComponent(name),
                                                    withIntermediateDirectories: true)
        }
        try FileManager.default.copyItem(at: Fixtures.url("static.png"),
                                         to: directory.appendingPathComponent("image.png"))

        let found = FolderTreeModel.subdirectories(of: directory).map(\.lastPathComponent)
        XCTAssertEqual(found.sorted(), ["sub1", "sub2"],
                       "files are not folders, and nothing below was read")
    }

    /// The cheap "has children" question does not list the folder.
    func testHasSubdirectoryAnswersWithoutListing() throws {
        let directory = try Fixtures.makeScratchDirectory("folder-tree-empty")
        defer { try? FileManager.default.removeItem(at: directory) }
        XCTAssertFalse(FolderTreeModel.hasSubdirectory(directory),
                       "an empty folder has no children")
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("sub"),
                                               withIntermediateDirectories: true)
        XCTAssertTrue(FolderTreeModel.hasSubdirectory(directory))
    }
}
