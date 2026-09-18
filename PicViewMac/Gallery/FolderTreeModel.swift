import Foundation

/// The folder browser's sidebar, as a lazy tree.
///
/// The spec is explicit that the whole disk must not be walked: children are enumerated when a node
/// is first expanded and then kept, and nothing below a collapsed node is ever read. A node's
/// parent chain is built from the path rather than searched for, so "parent context" costs one
/// enumeration of each ancestor rather than a scan.
@MainActor
public final class FolderTreeModel {

    /// One node of the tree.
    public struct Node: Identifiable, Hashable {
        public let url: URL
        public var id: String { url.path }
        public var name: String { url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent }
        /// Whether this node has children. Filled in when its parent's children were enumerated,
        /// so a collapsed folder can still show a disclosure triangle without reading it.
        public var hasChildren: Bool
        public var isExpanded: Bool
        /// Loaded children, or nil when the node has not been expanded yet.
        public var children: [Node]?
    }

    public private(set) var root: Node?
    /// The folder the gallery is showing, highlighted in the tree. Canonical, like every other path
    /// in this type: the viewer's session also canonicalizes the folder it scans, and a tree that
    /// spelled paths differently from the session would highlight the wrong row (`/var` versus
    /// `/private/var` is the same folder to the file system and two nodes to a comparison).
    public private(set) var currentFolder: URL?
    /// How many times the file system has been enumerated, so a test can prove laziness.
    public private(set) var enumerationCount = 0

    /// Injectable so tests can describe a tree without touching the disk.
    private let childrenProvider: (URL) -> [URL]
    /// Injectable for the same reason, and counted separately: asking whether a folder has children
    /// is the operation that must not read it.
    private let hasChildrenProvider: (URL) -> Bool

    public init(childrenProvider: ((URL) -> [URL])? = nil,
                hasChildrenProvider: ((URL) -> Bool)? = nil) {
        self.childrenProvider = childrenProvider ?? FolderTreeModel.subdirectories(of:)
        self.hasChildrenProvider = hasChildrenProvider ?? FolderTreeModel.hasSubdirectory(_:)
    }

    /// The production enumeration: immediate subdirectories only, sorted like Finder, skipping
    /// packages and anything unreadable. Deliberately not recursive — one level, on demand.
    public static func subdirectories(of url: URL) -> [URL] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey]
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        return entries.compactMap { entry in
            guard let values = try? entry.resourceValues(forKeys: Set(keys)),
                  values.isDirectory == true, values.isPackage != true else { return nil }
            // Canonical spelling, because the ancestor chain is built by deleting path components
            // from a canonicalized path: without this, `/var/...` and `/private/var/...` are the
            // same folder to the file system and two different nodes to the tree.
            return entry.resolvingSymlinksInPath()
        }
        .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    /// Whether a directory contains any subdirectory at all, answered without listing it: the
    /// enumerator stops at the first entry it finds. This is what keeps a disclosure triangle honest
    /// without paying to read a folder the user has not expanded.
    public static func hasSubdirectory(_ url: URL) -> Bool {
        guard let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants,
                      .skipsSubdirectoryDescendants]) else { return false }
        for case let entry as URL in enumerator {
            let values = try? entry.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
            if values?.isDirectory == true, values?.isPackage != true { return true }
        }
        return false
    }

    // MARK: - Building

    /// Points the tree at `folder`, building the ancestor chain above it so the current folder can
    /// be highlighted inside its parent's context. Only the ancestors' own children are enumerated.
    ///
    /// The root is the *top* of the chain, not the folder itself: a tree rooted at the current
    /// folder shows no context, which is the opposite of what a folder navigator is for.
    public func focus(on folder: URL, upTo limit: URL? = nil) {
        let standardized = URL(fileURLWithPath: folder.resolvingSymlinksInPath().path)
        currentFolder = standardized
        let chain = Self.ancestorChain(of: standardized,
                                       upTo: limit.map { URL(fileURLWithPath: $0.resolvingSymlinksInPath().path) })
        root = Self.build(from: chain, load: loadNode, expand: expand)
    }

    /// Builds the visible spine top-down: each node on the chain is expanded and its child on the
    /// chain replaced by the subtree below it.
    ///
    /// Written recursively because `Node` is a value type: expanding a *copy* of a node and then
    /// walking into that copy leaves the tree itself untouched, which is exactly what happened
    /// first — the root came out expanded and every level under it collapsed.
    static func build(from chain: [URL],
                      load: (URL) -> Node,
                      expand: (inout Node) -> Void) -> Node? {
        guard let first = chain.first else { return nil }
        var node = load(first)
        let rest = Array(chain.dropFirst())
        guard !rest.isEmpty else { return node }

        node.isExpanded = true
        expand(&node)
        guard var children = node.children,
              let index = children.firstIndex(where: { $0.url.path == rest[0].path }),
              let subtree = build(from: rest, load: load, expand: expand) else {
            // The chain and the file system disagree — a folder that vanished mid-scan. Showing the
            // level we do have, collapsed, is better than showing a lie about expansion.
            node.isExpanded = false
            return node
        }
        children[index] = subtree
        node.children = children
        return node
    }

    /// The ancestors from the top of the chain down to `folder`, outermost first.
    static func ancestorChain(of folder: URL, upTo limit: URL?) -> [URL] {
        var chain: [URL] = []
        var cursor = folder
        while true {
            chain.append(cursor)
            if let limit, cursor == limit { break }
            // Rebuilt from the path so the spelling matches the providers': `deletingLastPathComponent`
            // leaves a trailing slash on the result, and `URL(fileURLWithPath: "/a/")` is not equal to
            // `URL(fileURLWithPath: "/a")` — which silently stopped the walk at the first level.
            let parentPath = cursor.deletingLastPathComponent().resolvingSymlinksInPath().path
            let parent = URL(fileURLWithPath: parentPath)
            if parent == cursor { break }
            if limit == nil, chain.count >= 6 { break }   // a handful of levels of context is enough
            cursor = parent
        }
        return chain.reversed()
    }

    private func loadNode(at url: URL) -> Node {
        Node(url: url, hasChildren: hasChildrenProvider(url), isExpanded: false, children: nil)
    }

    /// Reads a node's children, once. The children themselves are not read: whether each one has
    /// children of its own is a separate, cheap question.
    public func expand(_ node: inout Node) {
        guard node.children == nil else { return }
        enumerationCount += 1
        let urls = childrenProvider(node.url)
        node.children = urls.map { url in
            Node(url: url, hasChildren: hasChildrenProvider(url), isExpanded: false, children: nil)
        }
        node.hasChildren = !urls.isEmpty
    }

    /// Expands or collapses the node at `url`, wherever it is in the visible tree.
    public func toggle(_ url: URL) {
        guard var tree = root else { return }
        _ = toggle(url, in: &tree)
        root = tree
    }

    private func toggle(_ url: URL, in node: inout Node) -> Bool {
        if node.url == url {
            node.isExpanded.toggle()
            if node.isExpanded { expand(&node) }
            return true
        }
        guard var children = node.children else { return false }
        for index in children.indices where toggle(url, in: &children[index]) {
            node.children = children
            return true
        }
        return false
    }

    /// The tree flattened to visible rows, which is what an outline view renders.
    public var visibleNodes: [Node] {
        guard let root else { return [] }
        var result: [Node] = []
        Self.appendVisible(root, to: &result)
        return result
    }

    private static func appendVisible(_ node: Node, to result: inout [Node]) {
        result.append(node)
        guard node.isExpanded, let children = node.children else { return }
        for child in children { appendVisible(child, to: &result) }
    }

    /// The highlighted row, as a path.
    public var currentFolderPath: String? { currentFolder?.path }
}
