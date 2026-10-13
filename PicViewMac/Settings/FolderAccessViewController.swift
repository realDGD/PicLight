import AppKit

@MainActor
enum FolderAccessPanel {
    private static var selecting = false

    static func choose(store: FolderAccessStore, for window: NSWindow?, initialDirectory: URL? = nil,
                       replacing id: UUID? = nil, covering requested: URL? = nil,
                       completion: @escaping (URL) -> Void) {
        guard !selecting else { return }
        selecting = true
        let panel = NSOpenPanel()
        panel.title = requested == nil ? "添加访问文件夹" : "恢复文件夹访问"
        panel.prompt = "选择文件夹"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.directoryURL = initialDirectory
        panel.message = requested.map { "请选择“\($0.path)”或它的上级文件夹，随后重试读取。" }
            ?? "选择后保存访问记录，启动时尝试恢复。完全磁盘访问由系统单独管理。"
        let handler: (NSApplication.ModalResponse) -> Void = { response in
            selecting = false
            guard response == .OK, let url = panel.url else { return }
            if let requested, !FolderAccessStore.covers(url, requested) {
                showError("请选择原文件夹或其上级文件夹，当前浏览位置未改变。", for: window)
                return
            }
            Task {
                do {
                    _ = try await store.add(url, replacing: id)
                    completion(url)
                } catch is CancellationError {
                    // A record removed while the operation was pending is not recreated.
                } catch { showError("无法保存文件夹访问记录：\(error.localizedDescription)", for: window) }
            }
        }
        if let window, window.attachedSheet == nil { panel.beginSheetModal(for: window, completionHandler: handler) }
        else { panel.begin(completionHandler: handler) }
    }

    static func showError(_ text: String, for window: NSWindow?) {
        let alert = NSAlert()
        alert.messageText = "文件夹访问"
        alert.informativeText = text
        alert.addButton(withTitle: "好")
        if let window, window.attachedSheet == nil { alert.beginSheetModal(for: window) { _ in } }
        else { alert.runModal() }
    }

    static func showSystemGuide(for window: NSWindow?) {
        let alert = NSAlert()
        alert.messageText = "完全磁盘访问由 macOS 管理"
        alert.informativeText = "选择文件夹与完全磁盘访问是两种不同的访问范围。\n\n如所需目录仍被系统限制，可打开系统设置 → 隐私与安全性 → 完全磁盘访问，使用 + 添加正在使用的 PicLight.app，然后完全退出并重新打开应用。\n\n应用不会自动授予或撤销该权限；磁盘未挂载或文件自身权限不足也需要分别处理。"
        alert.addButton(withTitle: "打开系统设置")
        alert.addButton(withTitle: "关闭")
        let handler: (NSApplication.ModalResponse) -> Void = { response in
            if response == .alertFirstButtonReturn {
                NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
            }
        }
        if let window, window.attachedSheet == nil { alert.beginSheetModal(for: window, completionHandler: handler) }
        else { handler(alert.runModal()) }
    }
}

@MainActor
final class FolderAccessWindowController: NSWindowController {
    init(store: FolderAccessStore = .shared) {
        let controller = FolderAccessViewController(store: store)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 520),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "文件夹授权"
        window.contentMinSize = NSSize(width: 620, height: 500)
        window.contentViewController = controller
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        (window?.contentViewController as? FolderAccessViewController)?.refresh()
    }
}

@MainActor
final class FolderAccessViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    let store: FolderAccessStore
    let table = NSTableView()
    let addButton = NSButton(title: "添加…", target: nil, action: nil)
    let removeButton = NSButton(title: "移除记录", target: nil, action: nil)
    let reselectButton = NSButton(title: "重新选择…", target: nil, action: nil)
    let openButton = NSButton(title: "浏览文件夹", target: nil, action: nil)
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let promptCheckbox = NSButton(checkboxWithTitle: "读取失败时提示授权", target: nil, action: nil)
    private var refreshTask: Task<Void, Never>?
    private var displayedIDs: [UUID] = []

    init(store: FolderAccessStore) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 680, height: 520))
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -20),
        ])
        let introduction = NSTextField(wrappingLabelWithString: "管理由你选择的文件夹，启动后恢复记录并检查读取状态。记录可访问不代表已开启完全磁盘访问。")
        introduction.font = .systemFont(ofSize: 12)
        introduction.textColor = .secondaryLabelColor
        stack.addArrangedSubview(introduction)
        introduction.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        promptCheckbox.state = AppSettings.shared.promptForFolderAccess ? .on : .off
        promptCheckbox.target = self; promptCheckbox.action = #selector(togglePrompt(_:))
        stack.addArrangedSubview(promptCheckbox)

        let folder = NSTableColumn(identifier: .init("folder"))
        folder.title = "已选择文件夹"; folder.width = 460; folder.minWidth = 340
        let status = NSTableColumn(identifier: .init("status"))
        status.title = "读取状态"; status.width = 140; status.minWidth = 120
        table.addTableColumn(folder); table.addTableColumn(status)
        table.rowHeight = 46
        table.dataSource = self; table.delegate = self
        table.setAccessibilityLabel("文件夹访问记录")
        table.allowsMultipleSelection = false
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.documentView = table
        scroll.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(scroll)
        scroll.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 140).isActive = true
        let refreshButton = NSButton(title: "刷新状态", target: self, action: #selector(refreshAction))
        let guide = NSButton(title: "系统权限指南…", target: self, action: #selector(showGuide))
        addButton.target = self; addButton.action = #selector(addFolder)
        removeButton.target = self; removeButton.action = #selector(removeFolder)
        reselectButton.target = self; reselectButton.action = #selector(reselectFolder)
        openButton.target = self; openButton.action = #selector(openFolder)
        let buttons = NSStackView(views: [addButton, removeButton, reselectButton, openButton, refreshButton])
        buttons.spacing = 8
        for button in [addButton, removeButton, reselectButton, openButton, refreshButton, guide] { button.bezelStyle = .rounded }
        stack.addArrangedSubview(buttons)
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        stack.addArrangedSubview(statusLabel)
        statusLabel.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        stack.addArrangedSubview(guide)
        let note = NSTextField(wrappingLabelWithString: "移除只清除应用记录，不删除文件，也不撤销系统权限。失效的记录可重新选择；关闭提示仍保留错误和手动恢复入口。")
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        stack.addArrangedSubview(note)
        note.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        NotificationCenter.default.addObserver(self, selector: #selector(recordsChanged),
                                               name: FolderAccessStore.didChangeNotification, object: store)
        reload()
    }

    func refresh() {
        loadViewIfNeeded()
        promptCheckbox.state = AppSettings.shared.promptForFolderAccess ? .on : .off
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            guard let self else { return }
            await self.store.refresh()
            guard !Task.isCancelled else { return }
            self.reload()
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { store.records.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard store.records.indices.contains(row) else { return nil }
        let record = store.records[row]
        if tableColumn?.identifier.rawValue == "status" {
            let label = NSTextField(labelWithString: record.status.title)
            label.textColor = record.status == .available ? .secondaryLabelColor : .systemOrange
            label.toolTip = record.detail
            return label
        }
        let name = NSTextField(labelWithString: URL(fileURLWithPath: record.path).lastPathComponent)
        let path = NSTextField(labelWithString: record.path)
        path.font = .systemFont(ofSize: 10)
        path.textColor = .secondaryLabelColor
        path.lineBreakMode = .byTruncatingMiddle
        name.lineBreakMode = .byTruncatingMiddle
        let cell = NSStackView(views: [name, path])
        cell.orientation = .vertical; cell.alignment = .leading; cell.spacing = 2
        cell.toolTip = record.path
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
        statusLabel.stringValue = selectedRecord.map { $0.detail.isEmpty ? $0.path : $0.detail }
            ?? store.storageError ?? (store.records.isEmpty ? "尚未添加文件夹；点击“添加…”选择。" : "已保存 \(store.records.count) 个文件夹。")
    }

    @objc private func addFolder() {
        FolderAccessPanel.choose(store: store, for: view.window) { [weak self] url in self?.select(url) }
    }
    @objc private func removeFolder() { if let record = selectedRecord { store.remove(record.id) } }
    @objc private func reselectFolder() {
        guard let record = selectedRecord else { return }
        FolderAccessPanel.choose(store: store, for: view.window,
                                 initialDirectory: URL(fileURLWithPath: record.path), replacing: record.id) { [weak self] url in self?.select(url) }
    }
    private func select(_ url: URL) {
        if let index = store.records.firstIndex(where: { $0.path == FolderAccessStore.canonicalPath(url) }) {
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        }
    }
    @objc private func openFolder() {
        guard let record = selectedRecord else { return }
        NSApp.sendAction(#selector(AppDelegate.openAuthorizedFolder(_:)), to: NSApp.delegate,
                         from: URL(fileURLWithPath: record.path) as NSURL)
    }
    @objc private func refreshAction() { refresh() }
    @objc private func togglePrompt(_ sender: NSButton) { AppSettings.shared.promptForFolderAccess = sender.state == .on }
    @objc private func showGuide() { FolderAccessPanel.showSystemGuide(for: view.window) }
}
