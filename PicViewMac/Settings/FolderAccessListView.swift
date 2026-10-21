import AppKit

/// The same live records and actions in the settings pane and standalone manager.
@MainActor
final class FolderAccessListView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    let store: FolderAccessStore
    let table = NSTableView()
    let addButton = NSButton(title: "添加…", target: nil, action: nil)
    let removeButton = NSButton(title: "移除记录", target: nil, action: nil)
    let reselectButton = NSButton(title: "重新选择…", target: nil, action: nil)
    let openButton = NSButton(title: "浏览文件夹", target: nil, action: nil)
    let statusLabel = NSTextField(wrappingLabelWithString: "")
    var onLayoutChanged: (() -> Void)?
    private let compact: Bool
    private var displayedIDs: [UUID] = []
    private var refreshTask: Task<Void, Never>?

    init(store: FolderAccessStore = .shared, compact: Bool = false) {
        self.store = store
        self.compact = compact
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let folder = NSTableColumn(identifier: .init("folder"))
        folder.title = "已选择文件夹"; folder.width = compact ? 246 : 450; folder.minWidth = 140
        let status = NSTableColumn(identifier: .init("status"))
        status.title = "读取状态"; status.width = compact ? 84 : 130; status.minWidth = 80
        table.addTableColumn(folder); table.addTableColumn(status)
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        table.rowHeight = compact ? 26 : 46
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = false
        if compact { table.headerView = nil }
        table.dataSource = self; table.delegate = self
        table.setAccessibilityLabel("授权文件夹")
        table.target = self; table.doubleAction = #selector(openFolder)
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.documentView = table
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let refresh = NSButton(title: compact ? "" : "刷新状态", target: self, action: #selector(refreshAction))
        if compact {
            addButton.title = ""; addButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "添加文件夹")
            removeButton.title = ""; removeButton.image = NSImage(systemSymbolName: "minus", accessibilityDescription: "移除记录")
            refresh.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "刷新状态")
            openButton.title = "浏览"
        }
        addButton.setAccessibilityLabel("添加文件夹")
        removeButton.setAccessibilityLabel("移除文件夹记录")
        refresh.setAccessibilityLabel("刷新文件夹状态")
        for (button, action) in [(addButton, #selector(addFolder)), (removeButton, #selector(removeFolder)),
                                 (reselectButton, #selector(reselectFolder)), (openButton, #selector(openFolder))] {
            button.target = self; button.action = action
        }
        for button in [addButton, removeButton, refresh, reselectButton, openButton] {
            button.bezelStyle = .rounded
            button.controlSize = compact ? .small : .regular
        }
        let buttons = NSStackView(views: [addButton, removeButton, refresh, reselectButton, openButton])
        buttons.spacing = compact ? 4 : 8
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.maximumNumberOfLines = 2
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let stack = NSStackView(views: [scroll, buttons, statusLabel])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.widthAnchor.constraint(equalTo: widthAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: compact ? 150 : 140),
            statusLabel.widthAnchor.constraint(equalTo: widthAnchor),
        ])
        NotificationCenter.default.addObserver(self, selector: #selector(recordsChanged),
                                               name: FolderAccessStore.didChangeNotification, object: store)
        reload()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func refresh() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            guard let self else { return }
            await store.refresh()
            if !Task.isCancelled { reload() }
        }
    }
    func numberOfRows(in tableView: NSTableView) -> Int { store.records.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard store.records.indices.contains(row) else { return nil }
        let record = store.records[row]
        if tableColumn?.identifier.rawValue == "status" {
            let label = NSTextField(labelWithString: record.status.title)
            label.font = .systemFont(ofSize: compact ? 11 : 12)
            label.textColor = record.status == .available ? .secondaryLabelColor : .systemOrange
            label.toolTip = record.detail
            return label
        }
        let path = NSTextField(labelWithString: record.path)
        path.font = .systemFont(ofSize: compact ? 12 : 10)
        path.lineBreakMode = .byTruncatingMiddle
        path.toolTip = record.path
        if compact { return path }
        path.textColor = .secondaryLabelColor
        let name = NSTextField(labelWithString: URL(fileURLWithPath: record.path).lastPathComponent)
        name.lineBreakMode = .byTruncatingMiddle
        let cell = NSStackView(views: [name, path])
        cell.orientation = .vertical; cell.alignment = .leading; cell.spacing = 2
        return cell
    }
    func tableViewSelectionDidChange(_ notification: Notification) { updateSelection() }
    private var selectedRecord: FolderAccessRecord? {
        store.records.indices.contains(table.selectedRow) ? store.records[table.selectedRow] : nil
    }
    @objc private func recordsChanged() { reload() }
    private func reload() {
        let id = displayedIDs.indices.contains(table.selectedRow) ? displayedIDs[table.selectedRow] : nil
        displayedIDs = store.records.map(\.id)
        table.reloadData()
        table.deselectAll(nil)
        if let index = store.records.firstIndex(where: { $0.id == id }) {
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        }
        updateSelection()
    }
    private func updateSelection() {
        removeButton.isEnabled = selectedRecord != nil
        reselectButton.isEnabled = selectedRecord != nil
        openButton.isEnabled = selectedRecord?.status == .available
        let text = selectedRecord.map { $0.detail.isEmpty ? $0.path : $0.detail }
            ?? store.storageError ?? (store.records.isEmpty ? "尚未添加文件夹。" : "已保存 \(store.records.count) 个文件夹；双击可浏览。")
        let changed = statusLabel.stringValue != text
        statusLabel.stringValue = text; statusLabel.toolTip = text
        if changed { onLayoutChanged?() }
    }
    @objc func addFolder() {
        FolderAccessPanel.choose(store: store, for: window) { [weak self] url in self?.select(url) }
    }
    @objc func removeFolder() { if let record = selectedRecord { store.remove(record.id) } }
    @objc func reselectFolder() {
        guard let record = selectedRecord else { return }
        FolderAccessPanel.choose(store: store, for: window,
                                 initialDirectory: URL(fileURLWithPath: record.path), replacing: record.id) { [weak self] url in self?.select(url) }
    }
    private func select(_ url: URL) {
        if let index = store.records.firstIndex(where: { $0.path == FolderAccessStore.canonicalPath(url) }) {
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        }
    }
    @objc func openFolder() {
        guard let record = selectedRecord, record.status == .available else { return }
        NSApp.sendAction(#selector(AppDelegate.openAuthorizedFolder(_:)), to: NSApp.delegate,
                         from: URL(fileURLWithPath: record.path) as NSURL)
    }
    @objc private func refreshAction() { refresh() }
}
