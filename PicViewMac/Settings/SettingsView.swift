import AppKit

/// Native settings window covering the spec defaults table plus W2 shortcut
/// customization. Conflicting shortcuts are rejected, never silently overridden.
@MainActor
public final class SettingsWindowController: NSWindowController {
    /// The settings window is a fixed 560×560. The four tabs are laid out for that
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

    /// The size the window contents actually occupy, for the fixed-size test.
    public var contentSizeForTesting: NSSize {
        window?.contentView?.bounds.size ?? .zero
    }
}

final class SettingsViewController: NSViewController {
    private let settings = AppSettings.shared
    private let shortcuts = ShortcutStore.shared

    private var sortPopup = NSPopUpButton()
    private var sortDirectionPopup = NSPopUpButton()
    private var openBehaviorPopup = NSPopUpButton()
    private var sizingPopup = NSPopUpButton()
    private var wheelPopup = NSPopUpButton()
    private var swipePopup = NSPopUpButton()
    private var doubleClickPopup = NSPopUpButton()
    private var appearancePopup = NSPopUpButton()
    private var loopPopup = NSPopUpButton()
    private var deletePopup = NSPopUpButton()
    private var autoplayCheckbox = NSButton(checkboxWithTitle: "自动播放动画", target: nil, action: nil)
    private var topFilenameCheckbox = NSButton(checkboxWithTitle: "显示顶部文件名", target: nil, action: nil)
    private var fieldCheckboxes: [BottomInfoField: NSButton] = [:]
    private var conflictLabel = NSTextField(labelWithString: "")
    private var shortcutButtons: [ViewerCommand: NSButton] = [:]
    private let tabView = NSTabView()
    /// One entry per tab, in tab order: the vertical stack that holds its rows.
    private var tabStacks: [NSStackView] = []

    /// Tab labels with the height their rows need and the height the tab gives them,
    /// for the fixed-size check. `content > available` means a row is clipped.
    func tabContentHeightsForTesting() -> [(title: String, content: CGFloat, available: CGFloat)] {
        loadViewIfNeeded()
        view.layoutSubtreeIfNeeded()
        let previous = tabView.selectedTabViewItem
        var heights: [(title: String, content: CGFloat, available: CGFloat)] = []
        for (index, item) in tabView.tabViewItems.enumerated() {
            guard let container = item.view else { continue }
            tabView.selectTabViewItem(item)
            container.layoutSubtreeIfNeeded()
            let stack = tabStacks.indices.contains(index) ? tabStacks[index] : nil
            heights.append((item.label, stack?.fittingSize.height ?? 0, container.bounds.height))
        }
        if let previous { tabView.selectTabViewItem(previous) }
        return heights
    }

    override func loadView() {
        let size = SettingsWindowController.contentSize
        let root = NSView(frame: NSRect(origin: .zero, size: size))
        tabStacks.removeAll()
        tabView.translatesAutoresizingMaskIntoConstraints = false
        tabView.addTabViewItem(tab(title: "浏览", content: browseTab()))
        tabView.addTabViewItem(tab(title: "交互", content: interactionTab()))
        tabView.addTabViewItem(tab(title: "外观", content: appearanceTab()))
        tabView.addTabViewItem(tab(title: "快捷键", content: shortcutTab()))
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
        stack.addArrangedSubview(separator())
        stack.addArrangedSubview(sectionTitle("底部信息字段"))
        for field in BottomInfoField.allCases {
            let checkbox = NSButton(checkboxWithTitle: field.localizedName, target: self,
                                    action: #selector(toggleBottomField(_:)))
            checkbox.identifier = NSUserInterfaceItemIdentifier(field.rawValue)
            checkbox.state = settings.bottomFields.contains(field) ? .on : .off
            fieldCheckboxes[field] = checkbox
            stack.addArrangedSubview(checkbox)
        }
        let note = NSTextField(wrappingLabelWithString: "v0.1 只浏览当前文件夹，不递归子文件夹。")
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
        stack.addArrangedSubview(row("触控板横向滑动", swipePopup))
        stack.addArrangedSubview(row("双击", doubleClickPopup))
        stack.addArrangedSubview(autoplayCheckbox)
        stack.addArrangedSubview(row("动画循环", loopPopup))
        stack.addArrangedSubview(topFilenameCheckbox)
        return wrap(stack)
    }

    private func appearanceTab() -> NSView {
        let stack = verticalStack()
        appearancePopup = popup(ViewerAppearanceMode.allCases, title: { $0.localizedName },
                                selected: settings.appearance) { [weak self] value in
            self?.settings.appearance = value
        }
        stack.addArrangedSubview(row("查看器外观", appearancePopup))
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
        scroll.heightAnchor.constraint(equalToConstant: 380).isActive = true
        stack.addArrangedSubview(scroll)
        stack.addArrangedSubview(conflictLabel)
        let fixed = NSTextField(wrappingLabelWithString:
            "⌘O 打开、⌘W 关闭、⌘, 设置、⌘Q 退出以及原生全屏幕保持系统固定快捷键。")
        fixed.textColor = .secondaryLabelColor
        fixed.font = .systemFont(ofSize: 11)
        stack.addArrangedSubview(fixed)
        return wrap(stack)
    }

    // MARK: - Actions

    @objc private func toggleBottomField(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue, let field = BottomInfoField(rawValue: raw) else { return }
        var fields = settings.bottomFields
        if sender.state == .on {
            if !fields.contains(field) { fields.append(field) }
        } else {
            fields.removeAll { $0 == field }
        }
        settings.bottomFields = fields
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
        tabStacks.append(stack)
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
