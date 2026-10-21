import AppKit

@MainActor
enum FolderAccessPanel {
    private static var selecting = false

    static func choose(store: FolderAccessStore, for window: NSWindow?, initialDirectory: URL? = nil,
                       replacing id: UUID? = nil, covering requested: URL? = nil,
                       authorizing authorizationDirectory: URL? = nil,
                       completion: @escaping (URL) -> Void) {
        guard !selecting else { return }
        selecting = true
        let panel = NSOpenPanel()
        panel.title = authorizationDirectory == nil
            ? (requested == nil ? "添加访问文件夹" : "恢复文件夹访问") : "授权用户文件夹"
        panel.prompt = authorizationDirectory == nil ? "选择文件夹" : "授权并继续"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.directoryURL = initialDirectory
        panel.message = authorizationDirectory.map { "请选择用户文件夹“\($0.path)”以授权访问。确认后将加入授权文件夹列表，并继续打开图片。" }
            ?? requested.map { "请选择“\($0.path)”或它的上级文件夹，随后重试读取。" }
            ?? "选择后保存访问记录，启动时尝试恢复。完全磁盘访问由系统单独管理。"
        let handler: (NSApplication.ModalResponse) -> Void = { response in
            selecting = false
            guard response == .OK, let url = panel.url else { return }
            if let requested, !FolderAccessStore.covers(url, requested) {
                let message = authorizationDirectory.map { "请选择用户文件夹“\($0.path)”，当前浏览位置未改变。" }
                    ?? "请选择原文件夹或其上级文件夹，当前浏览位置未改变。"
                showError(message, for: window)
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
final class FolderAccessViewController: NSViewController {
    let store: FolderAccessStore
    let list: FolderAccessListView
    var table: NSTableView { list.table }
    var addButton: NSButton { list.addButton }
    var removeButton: NSButton { list.removeButton }
    var reselectButton: NSButton { list.reselectButton }
    var openButton: NSButton { list.openButton }
    private let promptCheckbox = NSButton(checkboxWithTitle: "读取失败时提示授权", target: nil, action: nil)

    init(store: FolderAccessStore) {
        self.store = store
        self.list = FolderAccessListView(store: store)
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 680, height: 520))
        let introduction = NSTextField(wrappingLabelWithString: "管理由你选择的文件夹，启动后恢复记录并检查读取状态。记录可访问不代表已开启完全磁盘访问。")
        introduction.font = .systemFont(ofSize: 12)
        introduction.textColor = .secondaryLabelColor
        promptCheckbox.target = self; promptCheckbox.action = #selector(togglePrompt(_:))
        promptCheckbox.state = AppSettings.shared.promptForFolderAccess ? .on : .off
        let guide = NSButton(title: "系统权限指南…", target: self, action: #selector(showGuide))
        guide.bezelStyle = .rounded
        let note = NSTextField(wrappingLabelWithString: "移除只清除应用记录，不删除文件，也不撤销系统权限。失效的记录可重新选择；关闭提示仍保留手动恢复入口。")
        note.font = .systemFont(ofSize: 11); note.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [introduction, promptCheckbox, list, guide, note])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -20),
            list.widthAnchor.constraint(equalTo: stack.widthAnchor),
            introduction.widthAnchor.constraint(equalTo: stack.widthAnchor),
            note.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }
    func refresh() {
        loadViewIfNeeded()
        promptCheckbox.state = AppSettings.shared.promptForFolderAccess ? .on : .off
        list.refresh()
    }
    @objc private func togglePrompt(_ sender: NSButton) { AppSettings.shared.promptForFolderAccess = sender.state == .on }
    @objc private func showGuide() { FolderAccessPanel.showSystemGuide(for: view.window) }
}
