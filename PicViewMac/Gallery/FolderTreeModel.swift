import Foundation

/// The folder browser's sidebar, as a lazy tree rooted at the folder the gallery is showing.
///
/// The spec is explicit that the whole disk must not be walked: children are enumerated when a node
/// is first expanded and then kept, and nothing below a collapsed node is ever read. The tree is
/// rooted at the image's own folder — its parent folders are not part of it, so the sidebar shows
/// the folder being browsed and what is inside it, not the path it happens to live on.
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

    /// Points the tree at `folder`, and remembers which folder that is.
    ///
    /// The root is *not* re-set every time the focus moves. Descending inside the tree — clicking a
    /// subfolder row, opening a folder from the gallery, a rescan — keeps the root where the user
    /// started and only moves the highlight, so the sidebar does not rewrite itself under the
    /// pointer, and every expansion the user made survives. Measured before: opening a subfolder
    /// rebuilt the tree with the subfolder as the root, so the list of rows changed on every
    /// descent and a refresh thrown by the dimension probe collapsed what had been expanded.
    ///
    /// The one thing that moves the root is going *above* it — the "上一级" row of the root, or a
    /// folder opened from somewhere else entirely. There the tree grows upward to the new folder,
    /// which is what makes the up row a way out rather than a dead end.
    /// - Parameter reveal: whether the tree may *expand* to show the folder. Navigation passes true;
    ///   a refresh (a rescan, a re-sort, a lazy size fill) passes false, because a periodic update
    ///   must not re-open a node the user collapsed. The highlight always follows.
    public func focus(on folder: URL, reveal shouldReveal: Bool = true) {
        let target = URL(fileURLWithPath: folder.resolvingSymlinksInPath().path)
        currentFolder = target
        guard var tree = root else {
            adoptRoot(target)
            return
        }
        guard Self.isInside(target, root: tree.url) else {
            // Above (or beside) the root: the tree grows upward, and the subtree that was there is
            // hung back on its own row so nothing the user loaded or expanded is thrown away.
            adoptRoot(target, preserving: tree)
            return
        }
        guard shouldReveal else { return }
        expand(&tree)
        _ = reveal(target, in: &tree)
        root = tree
    }

    /// Replaces the root outright. Used when a folder outside the current tree is opened.
    public func setRoot(_ url: URL) {
        currentFolder = URL(fileURLWithPath: url.resolvingSymlinksInPath().path)
        adoptRoot(currentFolder ?? url)
    }

    /// A folder is inside a subtree when it is the subtree's own folder or below it. Compared by
    /// path components, so `/a/bc` is not treated as being inside `/a/b`.
    static func isInside(_ url: URL, root: URL) -> Bool {
        if url.path == root.path { return true }
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        return url.path.hasPrefix(prefix)
    }

    /// Makes `folder` the root: the folder itself is the root row, expanded, so the sidebar lists the
    /// directory the gallery is showing and the folders inside it.
    ///
    /// The ancestors are deliberately not built. A tree rooted above the current folder fills the
    /// sidebar with the path the image happens to live on — `/`, `Users`, `dgd`, … — which is not
    /// what the navigator is for: it is for moving around *inside* the folder that is open.
    private func adoptRoot(_ folder: URL, preserving oldRoot: Node? = nil) {
        var node = loadNode(at: folder)
        node.isExpanded = true
        expand(&node)
        if let oldRoot, Self.isInside(oldRoot.url, root: folder) {
            attach(oldRoot, under: &node)
        }
        root = node
    }

    /// Hangs an already-loaded subtree back on the row it belongs to, keeping its children and its
    /// expansion state. Returns without doing anything when the subtree is not below `node`.
    private func attach(_ subtree: Node, under node: inout Node) {
        if node.url == subtree.url {
            node = subtree
            return
        }
        guard Self.isInside(subtree.url, root: node.url), var children = node.children else { return }
        for index in children.indices where Self.isInside(subtree.url, root: children[index].url) {
            attach(subtree, under: &children[index])
            node.children = children
            return
        }
    }

    /// Expands the chain from `node` down to `target`, so the focused folder is visible inside the
    /// tree rather than replacing it. Returns whether `target` was found in this subtree.
    private func reveal(_ target: URL, in node: inout Node) -> Bool {
        if node.url == target {
            // The focused folder is expanded, so what is inside it is on screen without a click.
            node.isExpanded = true
            expand(&node)
            return true
        }
        guard Self.isInside(target, root: node.url) else { return false }
        guard var children = node.children else { return false }
        node.isExpanded = true
        for index in children.indices where Self.isInside(target, root: children[index].url) {
            if reveal(target, in: &children[index]) {
                node.children = children
                return true
            }
        }
        return false
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

    /// Sets the expansion of the node at `url`, wherever it is in the tree.
    ///
    /// Explicit rather than a flip: the view reports what AppKit did ("this item was expanded"), and
    /// a repeated notification of the same state must not collapse the node the model just opened —
    /// which is exactly what a toggle did when a disclosure click and a programmatic expand arrived
    /// together.
    public func setExpanded(_ expanded: Bool, for url: URL) {
        guard var tree = root else { return }
        guard setExpanded(expanded, for: url, in: &tree) else { return }
        root = tree
    }

    private func setExpanded(_ expanded: Bool, for url: URL, in node: inout Node) -> Bool {
        if node.url == url {
            node.isExpanded = expanded
            if expanded { expand(&node) }
            return true
        }
        guard var children = node.children else { return false }
        for index in children.indices where setExpanded(expanded, for: url, in: &children[index]) {
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
