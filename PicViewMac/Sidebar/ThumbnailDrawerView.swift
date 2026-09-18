import AppKit

/// Left-edge overlay drawer. It overlays the image and never reflows the canvas,
/// so opening it cannot change canvas frame or zoom state. Rows are virtualized
/// by `NSTableView`, so a folder with thousands of images stays responsive.
public final class ThumbnailDrawerView: MaterialHostView {
    public static let minimumWidth: CGFloat = 180
    public static let maximumWidth: CGFloat = 220

    public var onSelect: ((Int) -> Void)?
    /// Asks the owner to produce a thumbnail for a row that just became visible.
    public var onThumbnailNeeded: ((Int, FolderItem) -> Void)?
    public var thumbnailProvider: ((FolderItem) -> CGImage?)?

    private let scrollView = NSScrollView()
    private let tableView = NSTableView()

    private var items: [FolderItem] = []
    private var currentIndex: Int?
    private var isApplyingSelectionProgrammatically = false

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

        addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
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

    /// Delivers a thumbnail by identity instead of by the row number captured when the request
    /// started: the items may have been reordered, inserted into, deleted from or reloaded while the
    /// request was in flight, and the old index would then belong to a different file.
    ///
    /// Returns false when the item is no longer in the list, so the caller can count a delivery it
    /// deliberately dropped. The image itself stays in the caller's cache: whenever that URL becomes
    /// visible again the provider serves it from there.
    @discardableResult
    public func updateThumbnail(for url: URL, image: CGImage) -> Bool {
        guard let index = items.firstIndex(where: { $0.url == url }) else { return false }
        updateThumbnail(at: index, image: image)
        return true
    }

    /// The cell for a row, materialized if necessary, for tests of the cell contract as the
    /// drawer's own data source builds it.
    func cellForTesting(row: Int) -> ThumbnailCellView? {
        tableView.view(atColumn: 0, row: row, makeIfNecessary: true) as? ThumbnailCellView
    }

    /// The image a row is showing, for tests of the delivery identity.
    func thumbnailImageForTesting(at index: Int) -> CGImage? {
        guard let cell = tableView.view(atColumn: 0, row: index, makeIfNecessary: true)
            as? ThumbnailCellView else { return nil }
        return (cell.thumbnailImageView as? NSImageView)?.image
            .flatMap { $0.cgImage(forProposedRect: nil, context: nil, hints: nil) }
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
                       isCurrent: row == currentIndex)
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
