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

    /// Points the tree at `folder`: the folder itself is the root, expanded, so the sidebar lists the
    /// directory the gallery is showing and the folders inside it.
    ///
    /// The ancestors are deliberately not built. A tree rooted above the current folder fills the
    /// sidebar with the path the image happens to live on — `/`, `Users`, `dgd`, … — which is not
    /// what the navigator is for: it is for moving around *inside* the folder that is open.
    public func focus(on folder: URL) {
        let standardized = URL(fileURLWithPath: folder.resolvingSymlinksInPath().path)
        currentFolder = standardized
        var node = loadNode(at: standardized)
        node.isExpanded = true
        expand(&node)
        root = node
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
