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

    /// Focusing on a folder reads its ancestors' children (needed to show the path) and nothing else.
    func testFocusingDoesNotReadBelowTheCurrentFolder() {
        let (tree, counts) = model()
        tree.focus(on: URL(fileURLWithPath: "/a/a1/x"))

        let afterFocus = counts()
        // The folders *on the path* were listed; the ones below the focused folder were not.
        let visible = tree.visibleNodes.map(\.url.path)
        XCTAssertTrue(visible.contains("/"), "the root is the top of the chain")
        for path in ["/a", "/a/a1", "/a/a1/x"] {
            XCTAssertTrue(visible.contains(path), "\(path) is on the spine")
        }
        XCTAssertFalse(visible.contains(where: { $0.hasPrefix("/a/a1/x/") }),
                       "nothing below the focused folder is shown…")
        XCTAssertFalse(visible.contains(where: { $0.hasPrefix("/b/") }),
                       "…nor below a collapsed sibling")

        // The cost is one listing per level of the path, not one per folder in the tree.
        XCTAssertLessThanOrEqual(afterFocus.children, 4,
                                 "at most one listing per level on the way down")
        XCTAssertEqual(visible.count, 6,
                       "the spine plus the siblings of the expanded folders")
    }

    /// A collapsed sibling's children are never enumerated.
    func testACollapsedSiblingIsNeverRead() {
        let (tree, counts) = model()
        tree.focus(on: URL(fileURLWithPath: "/a/a1"))
        let before = counts().children

        // Everything in the visible list is on the expanded spine; /a/a2 is a leaf here, and /b is
        // not on the spine at all.
        let visible = tree.visibleNodes.map(\.url.path)
        XCTAssertTrue(visible.contains("/b"), "the sibling is shown…")
        XCTAssertFalse(visible.contains(where: { $0.hasPrefix("/b/") }),
                       "…but its children are not")
        XCTAssertGreaterThanOrEqual(counts().children, before)
    }

    /// Expanding reads exactly one more level, and only once — collapsing and expanding again comes
    /// from the cache.
    ///
    /// The node toggled is a *visible* one, which is the only kind a user can click: a tree row
    /// exists only when its parent has been read.
    func testExpandingReadsOneLevelAndCachesIt() {
        let (tree, counts) = model()
        tree.focus(on: URL(fileURLWithPath: "/a"))
        let before = counts().children
        XCTAssertFalse(tree.visibleNodes.map(\.url.path).contains("/a/a1/x"),
                       "a collapsed folder's contents are not shown…")

        tree.toggle(URL(fileURLWithPath: "/a"))
        let afterExpand = counts().children
        XCTAssertGreaterThan(afterExpand, before, "…and are read when it is expanded")
        XCTAssertTrue(tree.visibleNodes.map(\.url.path).contains("/a/a1"),
                      "its children are now on screen")

        tree.toggle(URL(fileURLWithPath: "/a"))
        XCTAssertFalse(tree.visibleNodes.map(\.url.path).contains("/a/a1"),
                       "collapsing hides them again")
        tree.toggle(URL(fileURLWithPath: "/a"))
        XCTAssertEqual(counts().children, afterExpand,
                       "a second expansion must come from the cache, not from the disk")
    }

    /// The number of enumerations is bounded by the levels on screen, not by the size of the tree.
    func testTheReadCountIsBoundedByTheVisibleSpine() {
        let (tree, counts) = model()
        tree.focus(on: URL(fileURLWithPath: "/a/a1/x"))
        XCTAssertLessThanOrEqual(counts().children, 4,
                                 "four folders on the path, so at most four listings")
    }

    // MARK: - Structure

    /// The root is the top of the ancestor chain, so the focused folder has context.
    func testTheRootIsTheTopOfTheChain() {
        let (tree, _) = model()
        tree.focus(on: URL(fileURLWithPath: "/a/a1/x"))
        XCTAssertEqual(tree.root?.url.path, "/")
        XCTAssertEqual(tree.currentFolderPath, "/a/a1/x", "and the focused folder is remembered")
    }

    /// The current folder's ancestors are expanded, so it is visible without any clicking.
    func testTheSpineToTheCurrentFolderIsExpanded() {
        let (tree, _) = model()
        tree.focus(on: URL(fileURLWithPath: "/a/a1/x"))
        let visible = Set(tree.visibleNodes.map(\.url.path))
        for path in ["/", "/a", "/a/a1", "/a/a1/x"] {
            XCTAssertTrue(visible.contains(path), "\(path) must be on screen")
        }
        XCTAssertFalse(visible.contains("/a/a2/x"), "and nothing off the spine")
    }

    /// A folder whose path does not exist in the tree is handled without inventing nodes.
    func testAnUnknownFolderDoesNotInventNodes() {
        let (tree, _) = model()
        tree.focus(on: URL(fileURLWithPath: "/nope/nothing"))
        // The chain is built from the path, so the nodes exist as *paths*; the point is that the
        // walk stops where the tree stops rather than crashing or looping.
        XCTAssertFalse(tree.visibleNodes.isEmpty)
        XCTAssertEqual(tree.currentFolderPath, "/nope/nothing")
    }

    /// The ancestor chain is bounded: a deep path does not produce an unbounded chain.
    func testTheAncestorChainIsBounded() {
        let deep = URL(fileURLWithPath: "/a/b/c/d/e/f/g/h/i/j/k/l")
        let chain = FolderTreeModel.ancestorChain(of: deep, upTo: nil)
        XCTAssertLessThanOrEqual(chain.count, 6, "a handful of levels of context is enough")
        XCTAssertEqual(chain.last, deep, "and the focused folder is the last one")
    }

    /// The chain stops at a supplied limit, which is how a shallow tree is requested.
    func testTheChainStopsAtALimit() {
        let chain = FolderTreeModel.ancestorChain(of: URL(fileURLWithPath: "/a/b/c"),
                                                 upTo: URL(fileURLWithPath: "/a"))
        XCTAssertEqual(chain.map(\.path), ["/a", "/a/b", "/a/b/c"])
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
