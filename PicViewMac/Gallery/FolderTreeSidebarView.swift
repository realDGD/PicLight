import AppKit

/// The folder browser's sidebar: a folder tree, in place of the thumbnail drawer.
///
/// `NSOutlineView` is what makes this virtualized and gives disclosure triangles for free; what it
/// renders is `FolderTreeModel.visibleNodes`, which only contains what has been expanded.
final class FolderTreeSidebarView: NSView {

    var onFolderChosen: ((URL) -> Void)?
    var onFolderToggled: ((URL) -> Void)?

    private let scrollView = NSScrollView()
    private let material = NSVisualEffectView()
    private let outline = NSOutlineView()
    private let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("folder"))
    private var nodes: [FolderTreeModel.Node] = []
    private var currentPath: String?
    /// The synthetic "up one level" row, when the current folder has a parent in the tree.
    ///
    /// The tree is rooted at the folder being browsed, so descending into a child re-roots it —
    /// and without this row there was no way back up: the parent was deliberately not a row.
    private var upRow: FolderTreeModel.Node?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        // A native sidebar look: vibrancy over the browser's own background, the source-list style
        // (rounded selection, proper disclosure triangles) and the standard row metrics. The plain
        // outline with 12 pt labels and a 14 pt icon read as a small, foreign list next to the
        // rest of the window.
        material.material = .sidebar
        material.blendingMode = .withinWindow
        material.state = .followsWindowActiveState
        material.translatesAutoresizingMaskIntoConstraints = false
        addSubview(material)

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay

        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.headerView = nil
        // Clear over the sidebar material: that is what a native sidebar's outline does. The
        // material itself sits on the browser's opaque background, so nothing shows through from
        // the image mode.
        outline.backgroundColor = .clear
        outline.style = .sourceList
        outline.selectionHighlightStyle = .sourceList
        outline.rowHeight = 22
        outline.indentationPerLevel = 12
        outline.dataSource = self
        outline.delegate = self
        outline.autoresizesOutlineColumn = false
        scrollView.documentView = outline
        material.addSubview(scrollView)
        NSLayoutConstraint.activate([
            material.leadingAnchor.constraint(equalTo: leadingAnchor),
            material.trailingAnchor.constraint(equalTo: trailingAnchor),
            material.topAnchor.constraint(equalTo: topAnchor),
            material.bottomAnchor.constraint(equalTo: bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: material.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: material.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: material.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: material.bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Replaces the visible rows. The model decides what is visible; this only draws it.
    /// True while the view is mirroring the model's expansion state, so the outline's own
    /// notifications are not mistaken for a user click. Without it, `expandItem` would report
    /// "the user expanded this" and the model would toggle straight back — measured as a tree that
    /// collapsed itself to a single row on the second render.
    private var isApplyingModelState = false

    func update(nodes: [FolderTreeModel.Node], currentPath: String?) {
        self.currentPath = currentPath
        // A folder that has a parent gets an "up one level" row: the tree is rooted at the folder
        // being browsed, so this is the only way back to where it came from.
        if let currentPath {
            let folder = URL(fileURLWithPath: currentPath)
            let parent = folder.deletingLastPathComponent()
            if parent.path != folder.path {
                upRow = FolderTreeModel.Node(url: parent, hasChildren: false,
                                             isExpanded: false, children: nil)
            } else {
                upRow = nil
            }
        } else {
            upRow = nil
        }
        self.nodes = (upRow.map { [$0] } ?? []) + nodes
        outline.reloadData()
        isApplyingModelState = true
        for node in self.nodes {
            // Expanding is the model's business, so the triangle state is mirrored from it rather
            // than owned here.
            if node.isExpanded, outline.isItemExpanded(node) == false {
                outline.expandItem(node)
            } else if !node.isExpanded, outline.isItemExpanded(node) {
                outline.collapseItem(node)
            }
        }
        isApplyingModelState = false
        // Programmatic selection, so the change notification it raises is not mistaken for the user
        // clicking a folder: that mistake made the browser rescan the folder it was already in and
        // discard the one the user had just chosen.
        isApplyingModelState = true
        if let currentPath, let index = self.nodes.firstIndex(where: { $0.url.path == currentPath }) {
            outline.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        } else {
            outline.deselectAll(nil)
        }
        isApplyingModelState = false
    }

    /// The row the user can click to go back up, for tests.
    var upRowPath: String? { upRow?.url.path }

    /// The label a synthetic row renders, if it is the up row.
    private func displayName(for node: FolderTreeModel.Node) -> String {
        node.url == upRow?.url ? "上一级" : node.name
    }

    var visibleRowCount: Int { nodes.count }

    /// The row the model says is current, for tests.
    var selectedPath: String? { currentPath }

    var outlineView: NSOutlineView { outline }

    /// Whether the tree draws over the native sidebar material, for tests.
    var usesSidebarMaterialForTesting: Bool {
        material.material == .sidebar && material.blendingMode == .withinWindow
            && material.superview === self
    }

    /// The rendered label for a row, for tests that check the tree shows what it should.
    func renderedName(at row: Int) -> String? {
        guard nodes.indices.contains(row) else { return nil }
        return displayName(for: nodes[row])
    }
}

extension FolderTreeSidebarView: NSOutlineViewDataSource {
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if item == nil { return nodes.count }
        // The model's own children, which are nil for a collapsed node. Returning 0 is what keeps a
        // collapsed folder from being enumerated.
        return (item as? FolderTreeModel.Node)?.children?.count ?? 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if item == nil { return nodes[index] }
        guard let node = item as? FolderTreeModel.Node, let children = node.children,
              children.indices.contains(index) else { return FolderTreeModel.Node(
                url: URL(fileURLWithPath: "/"), hasChildren: false, isExpanded: false, children: nil) }
        return children[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? FolderTreeModel.Node)?.hasChildren ?? false
    }
}

extension FolderTreeSidebarView: NSOutlineViewDelegate {
    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?,
                     item: Any) -> NSView? {
        guard let node = item as? FolderTreeModel.Node else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("FolderTreeCell")
        let cell = outlineView.makeView(withIdentifier: identifier, owner: self) as? FolderTreeCellView
            ?? FolderTreeCellView(identifier: identifier)
        let isUpRow = node.url == upRow?.url
        cell.configure(name: displayName(for: node),
                       isCurrent: !isUpRow && node.url.path == currentPath,
                       symbol: isUpRow ? "arrow.up" : "folder")
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !isApplyingModelState else { return }
        let row = outline.selectedRow
        guard nodes.indices.contains(row) else { return }
        onFolderChosen?(nodes[row].url)
    }

    /// A disclosure click is a request to expand or collapse, and the model owns that decision: the
    /// view reports it and re-renders whatever the model says afterwards.
    func outlineViewItemDidExpand(_ notification: Notification) {
        guard !isApplyingModelState else { return }
        guard let node = notification.userInfo?["NSObject"] as? FolderTreeModel.Node else { return }
        if node.children == nil { onFolderToggled?(node.url) }
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        guard !isApplyingModelState else { return }
        guard let node = notification.userInfo?["NSObject"] as? FolderTreeModel.Node else { return }
        if node.isExpanded { onFolderToggled?(node.url) }
    }
}

/// One row of the folder tree.
final class FolderTreeCellView: NSTableCellView {
    private let label = NSTextField(labelWithString: "")
    private let icon = NSImageView()

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier

        icon.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
        icon.contentTintColor = .secondaryLabelColor
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        icon.translatesAutoresizingMaskIntoConstraints = false

        label.font = .systemFont(ofSize: 13)
        label.lineBreakMode = .byTruncatingMiddle
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(icon)
        addSubview(label)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 5),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(name: String, isCurrent: Bool, symbol: String = "folder") {
        label.stringValue = name
        label.font = .systemFont(ofSize: 13, weight: isCurrent ? .semibold : .regular)
        label.textColor = isCurrent ? .controlAccentColor : .labelColor
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .regular))
        icon.contentTintColor = isCurrent ? .controlAccentColor : .secondaryLabelColor
    }

    var renderedName: String { label.stringValue }
}
