import AppKit

/// One row of the sidebar: either a folder of the tree, or the "up one level" action.
///
/// The action needs an identity of its own even when its target is a folder the tree also contains.
/// Sharing the node's identity made AppKit treat the action row and the folder row as one item —
/// and, because the label was chosen by comparing URLs, drew the folder's own row as a second
/// "上一级" (measured: `上一级, 上一级, B, D, C`).
enum FolderSidebarItem: Hashable {
    case up(target: URL)
    case folder(FolderTreeModel.Node)

    var url: URL {
        switch self {
        case let .up(target): return target
        case let .folder(node): return node.url
        }
    }

    var node: FolderTreeModel.Node? {
        if case let .folder(node) = self { return node }
        return nil
    }
}

/// The folder browser's sidebar: a folder tree, in place of the thumbnail drawer.
///
/// `NSOutlineView` is what makes this virtualized and gives disclosure triangles for free. The
/// outline is given the tree's *root* and asks for children as it expands; the flattened
/// `FolderTreeModel.visibleNodes` is deliberately not its input (see `root`).
final class FolderTreeSidebarView: NSView {

    var onFolderChosen: ((URL) -> Void)?
    /// A disclosure click: the URL of the node and whether the user expanded or collapsed it.
    var onFolderExpansionChanged: ((URL, Bool) -> Void)?

    private let scrollView = NSScrollView()
    private let material = MaterialHostView(style: .sidebar)
    private let outline = NSOutlineView()
    private let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("folder"))
    /// The tree's root node, which is what the outline expands from. Deliberately not a flattened
    /// row list: feeding AppKit the flattened rows *and* asking it to expand the same nodes drew
    /// every expanded folder's children twice — measured as six rendered rows for four model rows
    /// (`上一级, A, B, C, B, C`) — and the selection handler's row-to-model mapping then addressed
    /// the wrong row, so the duplicate rows did nothing when clicked.
    private var root: FolderTreeModel.Node?
    private var currentPath: String?

    /// The rows the outline is asked for at the top level: the "up one level" action, then the root.
    private var topLevelItems: [FolderSidebarItem] {
        var items: [FolderSidebarItem] = []
        if let parent = parentOfCurrentFolder {
            items.append(.up(target: parent))
        }
        if let root { items.append(.folder(root)) }
        return items
    }

    /// The parent of the folder being browsed, which is what "上一级" opens.
    private var parentOfCurrentFolder: URL? {
        guard let currentPath else { return nil }
        let folder = URL(fileURLWithPath: currentPath)
        let parent = folder.deletingLastPathComponent()
        return parent.path == folder.path ? nil : parent
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        // A native sidebar look: vibrancy over the browser's own background, the source-list style
        // (rounded selection, proper disclosure triangles) and the standard row metrics. The plain
        // outline with 12 pt labels and a 14 pt icon read as a small, foreign list next to the
        // rest of the window.
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

        // Same as the drawer: the rows must not be drawn under the traffic lights.
        let cap = material.makeSurfaceCap()
        cap.translatesAutoresizingMaskIntoConstraints = false
        addSubview(cap)
        titlebarCap = cap
        titlebarCapHeight = cap.heightAnchor.constraint(equalToConstant: MaterialHostView.titlebarFallbackHeight)
        NSLayoutConstraint.activate([
            cap.leadingAnchor.constraint(equalTo: leadingAnchor),
            cap.trailingAnchor.constraint(equalTo: trailingAnchor),
            cap.topAnchor.constraint(equalTo: topAnchor),
            titlebarCapHeight!,
        ])
    }

    private var titlebarCap: NSView?
    private var titlebarCapHeight: NSLayoutConstraint?

    /// Matches the cap to the window's titlebar; see `ThumbnailDrawerView.alignTitlebarCap`.
    public func alignTitlebarCap(height: CGFloat) {
        titlebarCapHeight?.constant = max(0, height)
        needsLayout = true
    }

    /// The cap, for tests: it is the view that keeps scrolled rows out of the titlebar strip.
    var titlebarCapForTesting: NSView? { titlebarCap }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Replaces the visible rows. The model decides what is visible; this only draws it.
    /// True while the view is mirroring the model's expansion state, so the outline's own
    /// notifications are not mistaken for a user click. Without it, `expandItem` would report
    /// "the user expanded this" and the model would toggle straight back — measured as a tree that
    /// collapsed itself to a single row on the second render.
    private var isApplyingModelState = false

    /// Replaces what the outline shows. The model's *root* is what it is given: the outline is asked
    /// for children as it expands, so a folder's contents appear once, as its children.
    func update(root: FolderTreeModel.Node?, currentPath: String?) {
        self.root = root
        self.currentPath = currentPath
        outline.reloadData()
        // Expanding is the model's business, so the triangle state is mirrored from it rather than
        // owned here — and mirrored down the tree, because the outline only knows about the levels
        // the model already read.
        isApplyingModelState = true
        applyExpansion(of: root, ancestorsVisible: true)
        isApplyingModelState = false
        // Programmatic selection, so the change notification it raises is not mistaken for the user
        // clicking a folder: that mistake made the browser rescan the folder it was already in and
        // discard the one the user had just chosen.
        isApplyingModelState = true
        if let currentPath, let row = row(forPath: currentPath) {
            outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        } else {
            outline.deselectAll(nil)
        }
        isApplyingModelState = false
    }

    /// Mirrors the model's expansion state into the outline, depth first.
    ///
    /// `ancestorsVisible` is what keeps a collapsed ancestor collapsed: the model remembers that a
    /// folder deep inside was expanded, and telling the outline to expand it would expand the
    /// ancestor above it as well — undoing the user's collapse.
    private func applyExpansion(of node: FolderTreeModel.Node?, ancestorsVisible: Bool) {
        guard let node else { return }
        if ancestorsVisible {
            // The outline's items are `FolderSidebarItem` wrappers, so the question and the command
            // have to be asked in the same currency: a bare `Node` is not an item the outline knows,
            // and asking about it made every expansion a no-op.
            let item = FolderSidebarItem.folder(node)
            if node.isExpanded, !outline.isItemExpanded(item) {
                outline.expandItem(item)
            } else if !node.isExpanded, outline.isItemExpanded(item) {
                outline.collapseItem(item)
            }
        }
        for child in node.children ?? [] {
            applyExpansion(of: child, ancestorsVisible: ancestorsVisible && node.isExpanded)
        }
    }

    /// The row an item is rendered at, by path. Asked of the outline rather than of a flattened
    /// array: those two stopped agreeing the moment an expanded folder's children were drawn, and
    /// the row-to-item mismatch is what made clicks land on nothing.
    ///
    /// A folder row wins over the up action when both point at the same folder: the highlight
    /// belongs on the folder the tree contains, not on a shortcut to it.
    private func row(forPath path: String) -> Int? {
        var actionRow: Int?
        for row in 0..<outline.numberOfRows {
            guard let item = outline.item(atRow: row) as? FolderSidebarItem else { continue }
            switch item {
            case let .folder(node) where node.url.path == path:
                return row
            case .up where item.url.path == path:
                actionRow = actionRow ?? row
            default:
                continue
            }
        }
        return actionRow
    }

    /// The folder the "up one level" action opens, for tests.
    var upRowPath: String? { parentOfCurrentFolder?.path }

    /// The label a row renders.
    private func displayName(for item: FolderSidebarItem) -> String {
        switch item {
        case .up: return "上一级"
        case let .folder(node): return node.name
        }
    }

    /// How many rows the outline is rendering right now. Read from the outline, not from a model
    /// array: what is on screen is the outline's answer, and the two can only differ by a bug.
    var visibleRowCount: Int { outline.numberOfRows }

    /// The row the model says is current, for tests.
    var selectedPath: String? { currentPath }

    var outlineView: NSOutlineView { outline }

    /// The row that carried the selection before the change, so it can be repainted without it.
    private var lastSelectedRow = -1

    /// Whether the tree draws over the native sidebar material, for tests.
    var usesSidebarMaterialForTesting: Bool {
        material.isSidebarMaterial
            && material.superview === self
    }

    /// The rendered label for a row, for tests that check the tree shows what it should.
    func renderedName(at row: Int) -> String? {
        guard let item = outline.item(atRow: row) as? FolderSidebarItem else { return nil }
        return displayName(for: item)
    }

    /// The cell a row is actually drawn with, for tests about how a row looks — the selected row's
    /// colours are what the folder sidebar got wrong.
    func cellViewForTesting(at row: Int) -> FolderTreeCellView? {
        outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? FolderTreeCellView
    }
}

extension FolderTreeSidebarView: NSOutlineViewDataSource {
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if item == nil { return topLevelItems.count }
        // The model's own children, which are nil for a collapsed node. Returning 0 is what keeps a
        // collapsed folder from being enumerated.
        return (item as? FolderSidebarItem)?.node?.children?.count ?? 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if item == nil {
            return topLevelItems.indices.contains(index) ? topLevelItems[index]
                : FolderSidebarItem.up(target: URL(fileURLWithPath: "/"))
        }
        guard let node = (item as? FolderSidebarItem)?.node, let children = node.children,
              children.indices.contains(index) else {
            return FolderSidebarItem.up(target: URL(fileURLWithPath: "/"))
        }
        return FolderSidebarItem.folder(children[index])
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? FolderSidebarItem)?.node?.hasChildren ?? false
    }
}

extension FolderTreeSidebarView: NSOutlineViewDelegate {
    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?,
                     item: Any) -> NSView? {
        guard let row = item as? FolderSidebarItem else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("FolderTreeCell")
        let cell = outlineView.makeView(withIdentifier: identifier, owner: self) as? FolderTreeCellView
            ?? FolderTreeCellView(identifier: identifier)
        cell.configure(name: displayName(for: row),
                       isCurrent: row.node != nil && row.url.path == currentPath,
                       isSelected: outlineView.selectedRowIndexes.contains(
                        outlineView.row(forItem: item)),
                       symbol: row.node == nil ? "arrow.up" : "folder")
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        // Repaint the rows whose selected state changed. A cell's colours are set when it is built, so
        // without this the row that just lost the selection would keep the selected colours (and the
        // new one would keep the accent label the selection hides).
        defer { repaintSelectionChange() }
        guard !isApplyingModelState else { return }
        let row = outline.selectedRow
        // The clicked *item*, not a row index into a model array: rows and model entries are only
        // the same list while nothing is expanded, and every expanded folder breaks that.
        guard row >= 0, let item = outline.item(atRow: row) as? FolderSidebarItem else { return }
        onFolderChosen?(item.url)
    }

    /// Rebuilds the two rows a selection change affects, so their colours follow the selection.
    private func repaintSelectionChange() {
        let rows = IndexSet([lastSelectedRow, outline.selectedRow].filter { $0 >= 0 })
        lastSelectedRow = outline.selectedRow
        guard !rows.isEmpty else { return }
        outline.reloadData(forRowIndexes: rows, columnIndexes: IndexSet(integer: 0))
    }


    /// A disclosure click is a request to expand or collapse, and the model owns that decision: the
    /// view reports it and re-renders whatever the model says afterwards.
    ///
    /// Reported whether or not the children were already loaded: the model's `isExpanded` is what
    /// the next render mirrors, so a real click has to reach it every time.
    func outlineViewItemDidExpand(_ notification: Notification) {
        guard !isApplyingModelState else { return }
        guard let item = notification.userInfo?["NSObject"] as? FolderSidebarItem,
              let node = item.node else { return }
        onFolderExpansionChanged?(node.url, true)
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        guard !isApplyingModelState else { return }
        guard let item = notification.userInfo?["NSObject"] as? FolderSidebarItem,
              let node = item.node, node.isExpanded else { return }
        onFolderExpansionChanged?(node.url, false)
    }
}

/// One row of the folder tree.
final class FolderTreeCellView: NSTableCellView {
    private let label = NSTextField(labelWithString: "")
    private let icon = NSImageView()
    /// Whether this row is the folder being browsed, which is drawn with the accent colour.
    private var isCurrentRow = false
    /// Whether this row carries the selection, which overrides that accent.
    private var isSelectedRow = false

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

    func configure(name: String, isCurrent: Bool, isSelected: Bool = false,
                   symbol: String = "folder") {
        label.stringValue = name
        isCurrentRow = isCurrent
        isSelectedRow = isSelected
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .regular))
        applyColors()
    }

    /// The table view sets this for the selected row; the sidebar also passes the selection in
    /// explicitly, because a cell's colours are decided when it is configured.
    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { applyColors() }
    }

    /// A selected row's background *is* the accent colour, so the folder being browsed — drawn with
    /// an accent label — vanished into its own highlight, leaving the highlighted row with nothing
    /// but an icon (reported from the folder sidebar). A selected row uses the selected-content
    /// colours; an unselected row keeps the accent for the folder being browsed.
    private func applyColors() {
        label.font = .systemFont(ofSize: 13, weight: isCurrentRow ? .semibold : .regular)
        guard isSelectedRow || backgroundStyle == .emphasized else {
            label.textColor = isCurrentRow ? .controlAccentColor : .labelColor
            icon.contentTintColor = isCurrentRow ? .controlAccentColor : .secondaryLabelColor
            return
        }
        label.textColor = .selectedMenuItemTextColor
        icon.contentTintColor = .selectedMenuItemTextColor
    }

    var renderedName: String { label.stringValue }

    /// The colours actually in force, for tests: the selected state is what the user reported.
    var labelColorForTesting: NSColor? { label.textColor }
    var iconTintForTesting: NSColor? { icon.contentTintColor }
}
