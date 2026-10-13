import AppKit

/// Native settings window covering the spec defaults table plus W2 shortcut
/// customization. Conflicting shortcuts are rejected, never silently overridden.
@MainActor
public final class SettingsWindowController: NSWindowController {
    /// The settings window is a fixed 560×560. The six tabs are laid out for that
    /// size; letting the user resize it only produced clipped rows and a shortcut
    /// list that scrolled out of its box.
    public static let contentSize = NSSize(width: 560, height: 560)

    public convenience init() {
        let controller = SettingsViewController()
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: Self.contentSize),
                              styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.title = "设置"
        controller.preferredContentSize = Self.contentSize
        window.contentViewController = controller
        window.isReleasedWhenClosed = false
        window.contentMinSize = Self.contentSize
        window.contentMaxSize = Self.contentSize
        window.setContentSize(Self.contentSize)
        window.center()
        self.init(window: window)
    }

    public override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        (window?.contentViewController as? SettingsViewController)?.refreshForPresentation()
    }

    /// The size the window contents actually occupy, for the fixed-size test.
    public var contentSizeForTesting: NSSize {
        window?.contentView?.bounds.size ?? .zero
    }
}

final class SettingsViewController: NSViewController, NSTabViewDelegate {
    private let settings = AppSettings.shared
    private let shortcuts = ShortcutStore.shared

    private var sortPopup = NSPopUpButton()
    private var sortDirectionPopup = NSPopUpButton()
    private var openBehaviorPopup = NSPopUpButton()
    private var sizingPopup = NSPopUpButton()
    private var titlebarPopup = NSPopUpButton()
    private var wheelPopup = NSPopUpButton()
    private var swipePopup = NSPopUpButton()
    private var doubleClickPopup = NSPopUpButton()
    private var appearancePopup = NSPopUpButton()
    private var loopPopup = NSPopUpButton()
    private var deletePopup = NSPopUpButton()
    private var autoplayCheckbox = NSButton(checkboxWithTitle: "自动播放动画", target: nil, action: nil)
    private var topFilenameCheckbox = NSButton(checkboxWithTitle: "显示顶部文件名", target: nil, action: nil)
    private var conflictLabel = NSTextField(labelWithString: "")
    private var shortcutButtons: [ViewerCommand: NSButton] = [:]
    private let tabView = NSTabView()
    private let fileAssociationController: FileAssociationViewController
    private let cacheDiskLabel = NSTextField(labelWithString: "正在读取缓存…")
    private let cacheMemoryLabel = NSTextField(labelWithString: "")
    private let sensitivitySlider = NSSlider(value: 0.0015, minValue: 0.0001, maxValue: 0.02,
                                             target: nil, action: nil)
    private let sensitivityLabel = NSTextField(labelWithString: "")
    private let exclusionsField = NSTextField()
    private var cacheRefreshTask: Task<Void, Never>?

    init(fileAssociationController: FileAssociationViewController = FileAssociationViewController()) {
        self.fileAssociationController = fileAssociationController
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Tab labels with the height their rows need and the height the tab gives them,
    /// for the fixed-size check. `content > available` means a row is clipped.
    func tabContentHeightsForTesting() -> [(title: String, content: CGFloat, available: CGFloat)] {
        loadViewIfNeeded()
        view.layoutSubtreeIfNeeded()
        let previous = tabView.selectedTabViewItem
        var heights: [(title: String, content: CGFloat, available: CGFloat)] = []
        for item in tabView.tabViewItems {
            guard let container = item.view else { continue }
            tabView.selectTabViewItem(item)
            container.layoutSubtreeIfNeeded()
            let stack = container.subviews.compactMap { $0 as? NSStackView }.first
            heights.append((item.label, stack?.fittingSize.height ?? 0, container.bounds.height))
        }
        if let previous { tabView.selectTabViewItem(previous) }
        return heights
    }

    override func loadView() {
        let size = SettingsWindowController.contentSize
        let root = NSView(frame: NSRect(origin: .zero, size: size))
        // NSTabView lays out its tab labels as each item is added, before Auto Layout
        // runs. Give that first pass the same valid bounds as the finished window.
        tabView.frame = root.bounds.insetBy(dx: 12, dy: 12)
        tabView.translatesAutoresizingMaskIntoConstraints = false
        tabView.addTabViewItem(tab(title: "浏览", content: browseTab()))
        tabView.addTabViewItem(tab(title: "交互", content: interactionTab()))
        tabView.addTabViewItem(tab(title: "外观", content: appearanceTab()))
        tabView.addTabViewItem(tab(title: "快捷键", content: shortcutTab()))
        addChild(fileAssociationController)
        tabView.addTabViewItem(tab(title: "格式关联", content: fileAssociationController.view))
        tabView.addTabViewItem(tab(title: "文件与缓存", content: filesTab()))
        tabView.delegate = self
        root.addSubview(tabView)
        NSLayoutConstraint.activate([
            tabView.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            tabView.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            tabView.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            tabView.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
        ])
        view = root
    }

    private func tab(title: String, content: NSView) -> NSTabViewItem {
        let item = NSTabViewItem(identifier: title)
        item.label = title
        item.view = content
        return item
    }

    // MARK: - Tabs

    private func browseTab() -> NSView {
        let stack = verticalStack()
        // There is no filename preference any more: the drawer always shows names,
        // so a control that could hide them was only a way to lose them.
        sortPopup = popup(ImageSortKey.allCases, title: { $0.localizedName },
                          selected: settings.sortKey) { [weak self] value in
            self?.settings.sortKey = value
        }
        sortDirectionPopup = popup(SortDirection.allCases, title: { $0.localizedName },
                                   selected: settings.sortDirection) { [weak self] value in
            self?.settings.sortDirection = value
        }
        openBehaviorPopup = popup(OpenBehavior.allCases, title: { $0.localizedName },
                                  selected: settings.openBehavior) { [weak self] value in
            self?.settings.openBehavior = value
        }
        sizingPopup = popup(WindowSizingPolicy.allCases, title: { $0.localizedName },
                            selected: settings.windowSizing) { [weak self] value in
            self?.settings.windowSizing = value
        }
        deletePopup = popup(DeleteFollowUp.allCases, title: { $0.localizedName },
                            selected: settings.deleteFollowUp) { [weak self] value in
            self?.settings.deleteFollowUp = value
        }
        stack.addArrangedSubview(row("排序方式", sortPopup))
        stack.addArrangedSubview(row("排序方向", sortDirectionPopup))
        stack.addArrangedSubview(row("打开文件", openBehaviorPopup))
        stack.addArrangedSubview(row("窗口大小", sizingPopup))
        stack.addArrangedSubview(row("删除后", deletePopup))
        stack.addArrangedSubview(checkbox("循环浏览当前文件夹", selected: settings.loopBrowsing) { [weak self] in
            self?.settings.loopBrowsing = $0
        })
        stack.addArrangedSubview(checkbox("关闭最后一个窗口后退出", selected: settings.quitAfterLastWindowClosed) { [weak self] in
            self?.settings.quitAfterLastWindowClosed = $0
        })
        stack.addArrangedSubview(checkbox("新窗口默认置顶", selected: settings.defaultAlwaysOnTop) { [weak self] in
            self?.settings.defaultAlwaysOnTop = $0
        })
        stack.addArrangedSubview(checkbox("移到废纸篓前询问（⌘Delete 始终直接删除）", selected: settings.confirmBeforeTrash) { [weak self] in
            self?.settings.confirmBeforeTrash = $0
        })
        let note = NSTextField(wrappingLabelWithString: "只浏览当前文件夹，不递归子文件夹。置顶默认值只影响新窗口。")
        note.textColor = .secondaryLabelColor
        note.font = .systemFont(ofSize: 11)
        stack.addArrangedSubview(note)
        return wrap(stack)
    }

    private func interactionTab() -> NSView {
        let stack = verticalStack()
        wheelPopup = popup(WheelMode.allCases, title: localizedWheel, selected: settings.wheelMode) { [weak self] value in
            self?.settings.wheelMode = value
        }
        swipePopup = popup(SwipeMode.allCases, title: localizedSwipe, selected: settings.swipeMode) { [weak self] value in
            self?.settings.swipeMode = value
        }
        doubleClickPopup = popup(DoubleClickMode.allCases, title: localizedDoubleClick,
                                 selected: settings.doubleClickMode) { [weak self] value in
            self?.settings.doubleClickMode = value
        }
        autoplayCheckbox.state = settings.autoplayAnimations ? .on : .off
        autoplayCheckbox.target = self
        autoplayCheckbox.action = #selector(toggleAutoplay)
        topFilenameCheckbox.state = settings.showTopFilename ? .on : .off
        topFilenameCheckbox.target = self
        topFilenameCheckbox.action = #selector(toggleTopFilename)
        loopPopup = popup(AnimationLoopPreference.allCases, title: { $0.localizedName },
                          selected: settings.animationLoop) { [weak self] value in
            self?.settings.animationLoop = value
        }

        stack.addArrangedSubview(row("鼠标滚轮", wheelPopup))
        let wheelPanPopup = popup(WheelPanDirection.allCases, title: { $0.localizedName },
                                  selected: settings.wheelPanDirection) { [weak self] in
            self?.settings.wheelPanDirection = $0
        }
        stack.addArrangedSubview(row("滚轮平移方向", wheelPanPopup))
        sensitivitySlider.doubleValue = settings.wheelZoomSensitivity
        sensitivitySlider.target = self
        sensitivitySlider.action = #selector(changeSensitivity(_:))
        sensitivitySlider.setAccessibilityLabel("滚轮缩放灵敏度")
        sensitivitySlider.widthAnchor.constraint(equalToConstant: 190).isActive = true
        sensitivityLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        updateSensitivityLabel()
        let resetSensitivity = actionButton("默认") { [weak self] in
            guard let self else { return }
            self.settings.wheelZoomSensitivity = 0.0015
            self.sensitivitySlider.doubleValue = self.settings.wheelZoomSensitivity
            self.updateSensitivityLabel()
        }
        stack.addArrangedSubview(row("缩放灵敏度", NSStackView(views: [sensitivitySlider, sensitivityLabel, resetSensitivity])))
        stack.addArrangedSubview(row("触控板横向滑动", swipePopup))
        stack.addArrangedSubview(row("双击", doubleClickPopup))
        stack.addArrangedSubview(row("", autoplayCheckbox))
        stack.addArrangedSubview(row("动画循环", loopPopup))
        stack.addArrangedSubview(row("", topFilenameCheckbox))
        return wrap(stack)
    }

    private func appearanceTab() -> NSView {
        let stack = verticalStack()
        appearancePopup = popup(ViewerAppearanceMode.allCases, title: { $0.localizedName },
                                selected: settings.appearance) { [weak self] value in
            self?.settings.appearance = value
        }
        stack.addArrangedSubview(row("查看器外观", appearancePopup))
        titlebarPopup = popup(TitlebarBehavior.allCases, title: { $0.localizedName },
                              selected: settings.titlebar) { [weak self] in self?.settings.titlebar = $0 }
        stack.addArrangedSubview(row("标题栏", titlebarPopup))
        stack.addArrangedSubview(row("底部工具栏", popup(ChromeDisplayPolicy.allCases, title: { $0.localizedName },
            selected: settings.dockDisplayPolicy) { [weak self] in self?.settings.dockDisplayPolicy = $0 }))
        stack.addArrangedSubview(row("翻页箭头", popup(ChromeDisplayPolicy.allCases, title: { $0.localizedName },
            selected: settings.navigationDisplayPolicy) { [weak self] in self?.settings.navigationDisplayPolicy = $0 }))
        let dockSurfacePopup = popup(DockSurface.allCases, title: { $0.localizedName },
                                     selected: settings.dockSurface) { [weak self] in self?.settings.dockSurface = $0 }
        stack.addArrangedSubview(row("工具栏材质", dockSurfacePopup))
        stack.addArrangedSubview(checkbox("隐藏缩放导航缩略图", selected: settings.hideMinimap) { [weak self] in
            self?.settings.hideMinimap = $0
        })
        let note = NSTextField(wrappingLabelWithString: """
        默认跟随系统。macOS 14–15 使用 AppKit 原生材质；macOS 26 及以上由系统原生 Liquid Glass 呈现，\
        不使用手绘仿制效果。系统开启“降低透明度”“降低动态效果”时会自动减少材质与转场。
        """)
        note.textColor = .secondaryLabelColor
        note.font = .systemFont(ofSize: 11)
        note.preferredMaxLayoutWidth = 460
        stack.addArrangedSubview(note)
        return wrap(stack)
    }

    private func shortcutTab() -> NSView {
        let stack = verticalStack()
        conflictLabel.textColor = .systemRed
        conflictLabel.font = .systemFont(ofSize: 11)
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let inner = verticalStack()
        for command in ViewerCommand.allCases where !command.isFixedSystemShortcut {
            let button = NSButton(title: shortcuts.shortcut(for: command)?.displayString ?? "未设置",
                                  target: self, action: #selector(captureShortcut(_:)))
            button.identifier = NSUserInterfaceItemIdentifier(command.rawValue)
            button.bezelStyle = .rounded
            button.widthAnchor.constraint(equalToConstant: 120).isActive = true
            shortcutButtons[command] = button
            inner.addArrangedSubview(row(command.localizedTitle, button))
        }
        scroll.documentView = inner
        inner.widthAnchor.constraint(equalToConstant: 480).isActive = true
        scroll.heightAnchor.constraint(equalToConstant: 330).isActive = true
        stack.addArrangedSubview(scroll)
        stack.addArrangedSubview(NSStackView(views: [
            actionButton("清空自定义快捷键") { [weak self] in
                self?.shortcuts.clearAll(); self?.refreshShortcutButtons()
            },
            actionButton("恢复默认快捷键") { [weak self] in
                self?.shortcuts.restoreDefaults(); self?.refreshShortcutButtons()
            }
        ]))
        stack.addArrangedSubview(conflictLabel)
        let fixed = NSTextField(wrappingLabelWithString:
            "⌘O 打开、⌘W 关闭、⌘, 设置、⌘Q 退出以及原生全屏幕保持系统固定快捷键。")
        fixed.textColor = .secondaryLabelColor
        fixed.font = .systemFont(ofSize: 11)
        stack.addArrangedSubview(fixed)
        return wrap(stack)
    }

    private func filesTab() -> NSView {
        let stack = verticalStack()
        stack.addArrangedSubview(sectionTitle("浏览过滤"))
        exclusionsField.placeholderString = "例如：gif, webp, .heic"
        exclusionsField.stringValue = settings.excludedExtensions.sorted().joined(separator: ", ")
        exclusionsField.target = self
        exclusionsField.action = #selector(saveExclusions(_:))
        exclusionsField.setAccessibilityLabel("排除的扩展名")
        exclusionsField.widthAnchor.constraint(equalToConstant: 300).isActive = true
        let apply = actionButton("应用过滤") { [weak self] in
            guard let self else { return }; self.saveExclusions(self.exclusionsField)
        }
        stack.addArrangedSubview(row("排除扩展名", exclusionsField))
        stack.addArrangedSubview(apply)
        stack.addArrangedSubview(note("多个扩展名用逗号或空格分隔；直接打开的文件仍可查看。"))
        stack.addArrangedSubview(separator())
        stack.addArrangedSubview(sectionTitle("缩略图缓存"))
        stack.addArrangedSubview(cacheDiskLabel)
        stack.addArrangedSubview(cacheMemoryLabel)
        let clear = NSButton(title: "清空缩略图缓存", target: self, action: #selector(clearCache(_:)))
        clear.bezelStyle = .rounded
        stack.addArrangedSubview(NSStackView(views: [clear, actionButton("在 Finder 中打开缓存") {
            ThumbnailCacheService.shared.revealInFinder()
        }]))
        stack.addArrangedSubview(note("清空内存与磁盘缩略图；继续浏览时按需重新生成。不会删除原图。"))
        stack.addArrangedSubview(separator())
        stack.addArrangedSubview(sectionTitle("文件夹访问"))
        stack.addArrangedSubview(NSStackView(views: [actionButton("选择浏览文件夹…") {
            NSApp.sendAction(#selector(AppDelegate.openFolder(_:)), to: NSApp.delegate, from: nil)
        }, actionButton("管理文件夹授权…") {
            NSApp.sendAction(#selector(AppDelegate.showFolderAccess(_:)), to: NSApp.delegate, from: nil)
        }]))
        stack.addArrangedSubview(note("选择文件夹后浏览其中图片。完全磁盘访问权限需前往系统设置 → 隐私与安全性单独开启；此入口不会授予整块磁盘权限。"))
        return wrap(stack)
    }

    // MARK: - Actions

    func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        if tabViewItem?.view === fileAssociationController.view { fileAssociationController.refreshStatus() }
        if tabViewItem?.label == "文件与缓存" { refreshCacheStatistics() }
        if tabViewItem?.label == "快捷键" { refreshShortcutButtons() }
    }

    @objc private func changeSensitivity(_ sender: NSSlider) {
        settings.wheelZoomSensitivity = sender.doubleValue
        updateSensitivityLabel()
    }

    private func updateSensitivityLabel() {
        sensitivityLabel.stringValue = String(format: "%.1f×", settings.wheelZoomSensitivity / 0.0015)
    }

    @objc private func saveExclusions(_ sender: NSTextField) {
        settings.excludedExtensions = AppSettings.normalizeExcludedExtensions(sender.stringValue)
        sender.stringValue = settings.excludedExtensions.sorted().joined(separator: ", ")
    }

    private func refreshShortcutButtons() {
        conflictLabel.stringValue = ""
        for (command, button) in shortcutButtons {
            button.title = shortcuts.shortcut(for: command)?.displayString ?? "未设置"
        }
    }

    func refreshForPresentation() {
        refreshCacheStatistics()
        refreshShortcutButtons()
    }

    private func refreshCacheStatistics() {
        cacheRefreshTask?.cancel()
        cacheRefreshTask = Task { [weak self] in
            let stats = await ThumbnailCacheService.shared.statistics()
            guard let self, !Task.isCancelled else { return }
            self.showCacheStatistics(stats)
        }
    }

    private func showCacheStatistics(_ stats: ThumbnailCacheService.Statistics) {
        cacheDiskLabel.stringValue = "磁盘：\(stats.diskCount) 张 · \(ByteCountFormatter.string(fromByteCount: Int64(stats.diskBytes), countStyle: .file))"
        cacheMemoryLabel.stringValue = "内存：\(stats.memoryCount) 张 · \(ByteCountFormatter.string(fromByteCount: Int64(stats.memoryBytes), countStyle: .memory))"
    }

    @objc private func clearCache(_ sender: NSButton) {
        sender.isEnabled = false
        cacheRefreshTask?.cancel()
        Task { [weak self] in
            await ThumbnailCacheService.shared.clear()
            let stats = await ThumbnailCacheService.shared.statistics()
            self?.showCacheStatistics(stats)
            sender.isEnabled = true
        }
    }

    @objc private func toggleAutoplay(_ sender: NSButton) {
        settings.autoplayAnimations = sender.state == .on
    }

    @objc private func toggleTopFilename(_ sender: NSButton) {
        settings.showTopFilename = sender.state == .on
    }

    @objc private func captureShortcut(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue, let command = ViewerCommand(rawValue: raw) else { return }
        let alert = NSAlert()
        alert.messageText = "为“\(command.localizedTitle)”录制快捷键"
        alert.informativeText = "按下新的组合键。留空表示移除快捷键。"
        let field = ShortcutRecorderField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        field.onCapture = { [weak self] shortcut in
            guard let self else { return }
            if let shortcut, let conflict = self.shortcuts.conflictingCommand(for: shortcut, excluding: command) {
                self.conflictLabel.stringValue = "\(shortcut.displayString) 已被“\(conflict.localizedTitle)”占用，未修改。"
                return
            }
            self.conflictLabel.stringValue = ""
            self.shortcuts.setShortcut(shortcut, for: command)
            sender.title = shortcut?.displayString ?? "未设置"
        }
        alert.accessoryView = field
        alert.addButton(withTitle: "确定")
        alert.runModal()
    }

    // MARK: - Helpers

    private func localizedWheel(_ mode: WheelMode) -> String {
        switch mode {
        case .zoom: return "缩放（以指针为中心）"
        case .pan: return "平移"
        case .navigate: return "切换图像"
        }
    }

    private func localizedSwipe(_ mode: SwipeMode) -> String {
        switch mode {
        case .smart: return "智能（适应时切换，放大时先平移）"
        case .alwaysSwitch: return "总是切换图像"
        case .alwaysPan: return "总是平移"
        case .disabled: return "禁用"
        }
    }

    private func localizedDoubleClick(_ mode: DoubleClickMode) -> String {
        switch mode {
        case .fitDoubleFit: return "适应 ↔ 适应 ×2"
        case .actualPixels: return "实际像素 100%"
        case .toggleImmersive: return "切换沉浸模式"
        case .none: return "没有操作"
        case .closeWindow: return "关闭窗口"
        case .toggleFullScreen: return "全屏窗口"
        case .folderBrowser: return "网格视图"
        }
    }

    private func popup<T: Equatable>(_ values: [T], title: (T) -> String, selected: T,
                                     onChange: @escaping (T) -> Void) -> NSPopUpButton {
        let popup = NSPopUpButton()
        for value in values { popup.addItem(withTitle: title(value)) }
        popup.selectItem(at: values.firstIndex(of: selected) ?? 0)
        let handler = PopupHandler(values: values, onChange: onChange)
        popup.target = handler
        popup.action = #selector(PopupHandler.handle(_:))
        popupHandlers.append(handler)
        return popup
    }

    private var popupHandlers: [AnyObject] = []

    private func actionButton(_ title: String, action: @escaping () -> Void) -> NSButton {
        let button = NSButton(title: title, target: nil, action: nil)
        button.bezelStyle = .rounded
        let handler = ControlAction { _ in action() }
        button.target = handler; button.action = #selector(ControlAction.handle(_:))
        popupHandlers.append(handler)
        return button
    }

    private func checkbox(_ title: String, selected: Bool, action: @escaping (Bool) -> Void) -> NSButton {
        let button = NSButton(checkboxWithTitle: title, target: nil, action: nil)
        button.state = selected ? .on : .off
        let handler = ControlAction { sender in
            guard let button = sender as? NSButton else { return }; action(button.state == .on)
        }
        button.target = handler; button.action = #selector(ControlAction.handle(_:))
        popupHandlers.append(handler)
        return button
    }

    private func note(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.preferredMaxLayoutWidth = 460
        return label
    }

    private func row(_ title: String, _ control: NSView) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.alignment = .right
        label.widthAnchor.constraint(equalToConstant: 130).isActive = true
        let stack = NSStackView(views: [label, control])
        stack.orientation = .horizontal
        stack.spacing = 10
        return stack
    }

    private func sectionTitle(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        return label
    }

    private func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        return box
    }

    private func verticalStack() -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }

    private func wrap(_ stack: NSStackView) -> NSView {
        let container = NSView()
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor),
        ])
        return container
    }
}

@MainActor
private final class PopupHandler: NSObject {
    private let values: [Any]
    private let onChange: (Any) -> Void

    init<T>(values: [T], onChange: @escaping (T) -> Void) {
        self.values = values
        self.onChange = { value in
            if let typed = value as? T { onChange(typed) }
        }
    }

    @objc func handle(_ sender: NSPopUpButton) {
        let index = sender.indexOfSelectedItem
        guard values.indices.contains(index) else { return }
        onChange(values[index])
    }
}

/// Minimal recorder so users can press a combination instead of typing it.
final class ShortcutRecorderField: NSView {
    var onCapture: ((ShortcutDefinition?) -> Void)?
    private let label = NSTextField(labelWithString: "按下快捷键…")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        window?.makeFirstResponder(self)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            onCapture?(nil)
            label.stringValue = "已清除"
            return
        }
        if let shortcut = ShortcutDefinition(event: event) {
            label.stringValue = shortcut.displayString
            onCapture?(shortcut)
        }
    }
}

@MainActor
private final class ControlAction: NSObject {
    private let action: (Any) -> Void
    init(_ action: @escaping (Any) -> Void) { self.action = action }
    @objc func handle(_ sender: Any) { action(sender) }
}
