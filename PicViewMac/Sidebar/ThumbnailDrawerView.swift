import AppKit

/// Left-edge overlay drawer. It overlays the image and never reflows the canvas,
/// so opening it cannot change canvas frame or zoom state. Rows are virtualized
/// by `NSTableView`, so a folder with thousands of images stays responsive.
public final class ThumbnailDrawerView: MaterialHostView {
    public static let minimumWidth: CGFloat = 180
    public static let maximumWidth: CGFloat = 220
    /// Edge strip that reveals the unpinned drawer. Wide enough to hit without
    /// aiming, narrow enough that it never feels like part of the image.
    public static let hotZoneWidth: CGFloat = 24

    public var onSelect: ((Int) -> Void)?
    /// Toggles the pinned state; the drawer never decides this itself.
    public var onTogglePin: (() -> Void)?
    /// Asks the owner to produce a thumbnail for a row that just became visible.
    public var onThumbnailNeeded: ((Int, FolderItem) -> Void)?
    public var thumbnailProvider: ((FolderItem) -> CGImage?)?

    private let scrollView = NSScrollView()
    private let tableView = NSTableView()
    private let pinButton = NSButton()
    private let headerStrip = NSView()
    private var items: [FolderItem] = []
    private var currentIndex: Int?
    private var isApplyingSelectionProgrammatically = false

    public var filenameMode: ThumbnailFilenameMode = .hover {
        didSet { tableView.reloadData() }
    }

    public override init(style: Style = .drawer) {
        super.init(style: style)
        translatesAutoresizingMaskIntoConstraints = false
        material = .hudWindow

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.verticalScrollElasticity = .allowed
        scrollView.horizontalScrollElasticity = .none
        scrollView.scrollerStyle = .overlay

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("thumbnail"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.backgroundColor = .clear
        tableView.selectionHighlightStyle = .none
        tableView.rowHeight = ThumbnailCellView.rowHeight
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.allowsMultipleSelection = false
        tableView.allowsEmptySelection = true
        tableView.style = .plain
        tableView.dataSource = self
        tableView.delegate = self

        scrollView.documentView = tableView

        headerStrip.translatesAutoresizingMaskIntoConstraints = false
        pinButton.image = NSImage(systemSymbolName: "pin", accessibilityDescription: "固定左栏")
        pinButton.imagePosition = .imageOnly
        pinButton.isBordered = false
        pinButton.bezelStyle = .texturedRounded
        pinButton.toolTip = "固定左栏"
        pinButton.target = self
        pinButton.action = #selector(togglePin)
        pinButton.translatesAutoresizingMaskIntoConstraints = false
        headerStrip.addSubview(pinButton)

        addSubview(scrollView)
        addSubview(headerStrip)
        NSLayoutConstraint.activate([
            headerStrip.leadingAnchor.constraint(equalTo: leadingAnchor),
            headerStrip.trailingAnchor.constraint(equalTo: trailingAnchor),
            headerStrip.topAnchor.constraint(equalTo: topAnchor),
            headerStrip.heightAnchor.constraint(equalToConstant: 30),

            pinButton.trailingAnchor.constraint(equalTo: headerStrip.trailingAnchor, constant: -8),
            pinButton.centerYAnchor.constraint(equalTo: headerStrip.centerYAnchor),
            pinButton.widthAnchor.constraint(equalToConstant: 22),
            pinButton.heightAnchor.constraint(equalToConstant: 20),

            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: headerStrip.bottomAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: - Content

    public func rebuild(items: [FolderItem], currentIndex: Int?) {
        self.items = items
        self.currentIndex = currentIndex
        tableView.reloadData()
        applySelection()
    }

    public func updateThumbnail(at index: Int, image: CGImage) {
        guard items.indices.contains(index) else { return }
        guard let cell = tableView.view(atColumn: 0, row: index, makeIfNecessary: false)
            as? ThumbnailCellView else { return }
        cell.setThumbnail(image)
    }

    public func setCurrentIndex(_ index: Int?) {
        currentIndex = index
        applySelection()
    }

    /// Keyboard navigation keeps the current row visible without touching the canvas.
    public func scrollCurrentIntoView() {
        guard let currentIndex, items.indices.contains(currentIndex) else { return }
        tableView.scrollRowToVisible(currentIndex)
    }

    public var visibleRowCount: Int { items.count }

    /// Reflects the pinned state; the drawer only reports that it was tapped.
    public func setPinned(_ pinned: Bool) {
        pinButton.image = NSImage(systemSymbolName: pinned ? "pin.fill" : "pin",
                                 accessibilityDescription: pinned ? "取消固定左栏" : "固定左栏")
        pinButton.toolTip = pinned ? "取消固定左栏" : "固定左栏"
        pinButton.contentTintColor = pinned ? .controlAccentColor : nil
    }

    @objc private func togglePin() {
        onTogglePin?()
    }

    private func applySelection() {
        guard let currentIndex, items.indices.contains(currentIndex) else {
            isApplyingSelectionProgrammatically = true
            tableView.deselectAll(nil)
            isApplyingSelectionProgrammatically = false
            return
        }
        isApplyingSelectionProgrammatically = true
        tableView.selectRowIndexes(IndexSet(integer: currentIndex), byExtendingSelection: false)
        isApplyingSelectionProgrammatically = false
        let visible = tableView.rows(in: tableView.visibleRect)
        for row in visible.location..<(visible.location + visible.length) {
            (tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? ThumbnailCellView)?
                .setCurrent(row == currentIndex)
        }
    }
}

extension ThumbnailDrawerView: NSTableViewDataSource {
    public func numberOfRows(in tableView: NSTableView) -> Int { items.count }
}

extension ThumbnailDrawerView: NSTableViewDelegate {
    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?,
                          row: Int) -> NSView? {
        guard items.indices.contains(row) else { return nil }
        let cell = (tableView.makeView(withIdentifier: ThumbnailCellView.reuseIdentifier, owner: self)
            as? ThumbnailCellView) ?? ThumbnailCellView(frame: .zero)
        let item = items[row]
        cell.configure(item: item, image: thumbnailProvider?(item),
                       isCurrent: row == currentIndex, filenameMode: filenameMode)
        // The owner fills missing thumbnails in the background.
        if thumbnailProvider?(item) == nil { onThumbnailNeeded?(row, item) }
        return cell
    }

    public func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isApplyingSelectionProgrammatically else { return }
        let row = tableView.selectedRow
        guard row >= 0 else { return }
        onSelect?(row)
    }
}
