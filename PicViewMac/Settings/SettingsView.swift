import AppKit

/// Native settings window covering the spec defaults table plus W2 shortcut
/// customization. Conflicting shortcuts are rejected, never silently overridden.
///
/// The window follows the reference software's settings window: a strip of icon
/// tabs (通用 / 看图 / 高级 / 快捷键 / …), the viewer pane split into sub-tabs,
/// and a height that adapts to the pane being shown. Width stays fixed, and the
/// user still cannot resize it — a pane is laid out for one width.
@MainActor
public final class SettingsWindowController: NSWindowController {
    /// The default content size, used before the first pane is laid out.
    public static let contentSize = NSSize(width: SettingsMetrics.windowWidth,
                                           height: SettingsMetrics.minPaneHeight)

    private var toolbarController: SettingsToolbarController?

    public convenience init() {
        let controller = SettingsViewController()
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: Self.contentSize),
                              styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.title = SettingsViewController.paneTitles.first ?? "设置"
        controller.preferredContentSize = Self.contentSize
        window.contentViewController = controller
        window.isReleasedWhenClosed = false
        window.contentMinSize = Self.contentSize
        window.contentMaxSize = Self.contentSize
        window.setContentSize(Self.contentSize)
        window.center()
        self.init(window: window)
        toolbarController = SettingsToolbarController(controller: controller, window: window)
        controller.onPreferredHeightChange = { [weak self] height in
            self?.applyContentHeight(height)
        }
    }

    public override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        let controller = window?.contentViewController as? SettingsViewController
        controller?.refreshForPresentation()
        // Re-apply after the first presentation too: the cache statistics can
        // change a label's height, and the window must still fit the pane.
        applyContentHeight(controller?.preferredContentHeight() ?? Self.contentSize.height)
    }

    /// The size the window contents actually occupy, for the fixed-size test.
    public var contentSizeForTesting: NSSize {
        window?.contentView?.bounds.size ?? .zero
    }

    /// Apply one complete layout before drawing. An asynchronous window animator can
    /// stretch the old content while the new pane is already visible, leaving the
    /// category strip halfway down the window until the animation catches up.
    private func applyContentHeight(_ height: CGFloat) {
        guard let window else { return }
        let size = NSSize(width: SettingsMetrics.windowWidth, height: height)
        let current = window.contentView?.bounds.size ?? .zero
        if abs(current.height - height) > 0.5 || abs(current.width - size.width) > 0.5 {
            var target = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
            target.origin = NSPoint(x: window.frame.minX, y: window.frame.maxY - target.height)
            // Do not momentarily set a minimum larger than the old maximum (or the
            // reverse). That lets AppKit clamp to an intermediate size before ours.
            window.contentMinSize = .zero
            window.contentMaxSize = NSSize(width: size.width, height: max(current.height, height))
            window.contentViewController?.preferredContentSize = size
            window.setFrame(target, display: false, animate: false)
        }
        window.contentMinSize = size
        window.contentMaxSize = size
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
    }

}

final class SettingsViewController: NSViewController, NSTokenFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {

    /// Top-level panes, in the order the tab strip shows them.
    static let paneTitles = ["通用", "看图", "高级", "快捷键", "格式关联", "关于"]
    /// Sub-tabs of the 看图 pane, mirroring the reference window.
    static let viewerSubTitles = ["一般", "外观", "浏览", "打开", "鼠标", "翻页"]

    static let tabSymbols = [
        "gearshape", "photo.on.rectangle.angled", "slider.horizontal.3",
        "command", "checkmark.seal", "info.circle",
    ]

    private let settings = AppSettings.shared
    private let shortcuts = ShortcutStore.shared
    private let fileAssociationController: FileAssociationViewController

    // Controls whose state is written to AppSettings.
    private var sortPopup = NSPopUpButton()
    private var sortDirectionPopup = NSPopUpButton()
    private var openBehaviorPopup = NSPopUpButton()
    private var sizingPopup = NSPopUpButton()
    private var titlebarPopup = NSPopUpButton()
    private var wheelPopup = NSPopUpButton()
    private var swipePopup = NSPopUpButton()
    private var doubleClickPopup = NSPopUpButton()
    private var appearancePopup = NSPopUpButton()
    private var dockDisplayPopup = NSPopUpButton()
    private var navigationDisplayPopup = NSPopUpButton()
    private var dockSurfacePopup = NSPopUpButton()
    private var loopPopup = NSPopUpButton()
    private var deletePopup = NSPopUpButton()
    private var wheelPanPopup = NSPopUpButton()
    private let autoplayCheckbox = NSButton(checkboxWithTitle: "自动播放动画", target: nil, action: nil)
    private let topFilenameCheckbox = NSButton(checkboxWithTitle: "显示顶部文件名", target: nil, action: nil)
    private let minimapCheckbox = NSButton(checkboxWithTitle: "隐藏鸟瞰视图（右下角）", target: nil, action: nil)
    private let loopBrowsingCheckbox = NSButton(checkboxWithTitle: "循环浏览当前文件夹", target: nil, action: nil)
    private let alwaysOnTopCheckbox = NSButton(checkboxWithTitle: "默认置顶看图窗口", target: nil, action: nil)
    private let confirmTrashCheckbox = NSButton(checkboxWithTitle: "移到废纸篓前询问确认", target: nil, action: nil)
    private let quitCheckbox = NSButton(checkboxWithTitle: "所有窗口关闭时退出", target: nil, action: nil)
    private let promptFolderCheckbox = NSButton(checkboxWithTitle: "提示授权文件夹读取权限", target: nil, action: nil)
    let folderList = FolderAccessListView(compact: true)
    private let associationHint = NSTextField(wrappingLabelWithString: "")
    private var conflictLabel = NSTextField(labelWithString: "")
    private var shortcutButtons: [ViewerCommand: NSButton] = [:]
    let shortcutTable = NSTableView()
    private let shortcutCommands = ViewerCommand.allCases

    private let paneContainer = NSView()
    private var panes: [String: NSView] = [:]
    private var viewerSubPanes: [String: SettingsPaneView] = [:]
    private var displayedPane: NSView?
    private var displayedViewerSubPane: NSView?
    private let viewerCard = SettingsCardView()
    private let viewerCategoryBar = SettingsCategoryBar(titles: SettingsViewController.viewerSubTitles)

    private let cacheDiskLabel = NSTextField(labelWithString: "正在读取缓存…")
    private let cacheMemoryLabel = NSTextField(labelWithString: "")
    private let sensitivitySlider = NSSlider(value: 0.0015, minValue: 0.0001, maxValue: 0.02,
                                             target: nil, action: nil)
    private let sensitivityLabel = NSTextField(labelWithString: "")
    private let exclusionsField = NSTokenField()
    private var cacheRefreshTask: Task<Void, Never>?

    private(set) var selectedPaneTitle = SettingsViewController.paneTitles.first ?? "通用"
    private(set) var selectedViewerSubTitle = SettingsViewController.viewerSubTitles.first ?? "一般"

    /// Asked for the window height this pane needs. The window controller owns
    /// the frame; the view controller only says how tall it has to be.
    var onPreferredHeightChange: ((CGFloat) -> Void)?
    var onSelectedPaneChange: ((String) -> Void)?

    init(fileAssociationController: FileAssociationViewController = FileAssociationViewController()) {
        self.fileAssociationController = fileAssociationController
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: - View lifecycle

    override func loadView() {
        let size = SettingsWindowController.contentSize
        let root = NSView(frame: NSRect(origin: .zero, size: size))
        paneContainer.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(paneContainer)
        NSLayoutConstraint.activate([
            paneContainer.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            paneContainer.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            paneContainer.topAnchor.constraint(equalTo: root.topAnchor),
            paneContainer.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        folderList.onLayoutChanged = { [weak self] in
            guard let self, self.selectedPaneTitle == "看图" else { return }
            self.announceHeight()
        }
        buildPanes()
        view = root
        selectPane(0, announce: false)
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        view.window?.title = selectedPaneTitle
    }

    private func buildPanes() {
        panes["通用"] = generalPane()
        panes["看图"] = viewerPane()
        panes["高级"] = advancedPane()
        panes["快捷键"] = shortcutPane()
        addChild(fileAssociationController)
        panes["格式关联"] = fileAssociationController.view
        panes["关于"] = aboutPane()
    }

    // MARK: - Pane switching

    private func show(_ pane: NSView) {
        displayedPane?.removeFromSuperview()
        displayedPane = pane
        pane.translatesAutoresizingMaskIntoConstraints = false
        paneContainer.addSubview(pane)
        NSLayoutConstraint.activate([
            pane.leadingAnchor.constraint(equalTo: paneContainer.leadingAnchor),
            pane.trailingAnchor.constraint(equalTo: paneContainer.trailingAnchor),
            pane.topAnchor.constraint(equalTo: paneContainer.topAnchor),
            pane.bottomAnchor.constraint(equalTo: paneContainer.bottomAnchor),
        ])
    }

    private func selectPane(_ index: Int, announce: Bool = true) {
        guard Self.paneTitles.indices.contains(index) else { return }
        let title = Self.paneTitles[index]
        selectedPaneTitle = title
        onSelectedPaneChange?(title)
        guard let pane = panes[title] else { return }
        show(pane)
        view.window?.title = title
        switch title {
        case "看图": showViewerSubPane(); if selectedViewerSubTitle == "打开" { folderList.refresh() }
        case "高级": refreshCacheStatistics()
        case "快捷键": refreshShortcutButtons()
        case "格式关联": fileAssociationController.refreshStatus()
        default: break
        }
        if announce { announceHeight() }
    }

    /// Re-reads every control from the current settings, so a value changed
    /// elsewhere (folder window, menu command) is not shown stale.
    func refreshForPresentation() {
        quitCheckbox.state = settings.quitAfterLastWindowClosed ? .on : .off
        confirmTrashCheckbox.state = settings.confirmBeforeTrash ? .on : .off
        promptFolderCheckbox.state = settings.promptForFolderAccess ? .on : .off
        autoplayCheckbox.state = settings.autoplayAnimations ? .on : .off
        topFilenameCheckbox.state = settings.showTopFilename ? .on : .off
        minimapCheckbox.state = settings.hideMinimap ? .on : .off
        loopBrowsingCheckbox.state = settings.loopBrowsing ? .on : .off
        alwaysOnTopCheckbox.state = settings.defaultAlwaysOnTop ? .on : .off
        sortPopup.selectItem(at: ImageSortKey.allCases.firstIndex(of: settings.sortKey) ?? 0)
        sortDirectionPopup.selectItem(at: SortDirection.allCases.firstIndex(of: settings.sortDirection) ?? 0)
        openBehaviorPopup.selectItem(at: OpenBehavior.allCases.firstIndex(of: settings.openBehavior) ?? 0)
        sizingPopup.selectItem(at: WindowSizingPolicy.allCases.firstIndex(of: settings.windowSizing) ?? 0)
        titlebarPopup.selectItem(at: TitlebarBehavior.allCases.firstIndex(of: settings.titlebar) ?? 0)
        dockDisplayPopup.selectItem(at: ChromeDisplayPolicy.allCases.firstIndex(of: settings.dockDisplayPolicy) ?? 0)
        navigationDisplayPopup.selectItem(at: ChromeDisplayPolicy.allCases.firstIndex(of: settings.navigationDisplayPolicy) ?? 0)
        dockSurfacePopup.selectItem(at: DockSurface.allCases.firstIndex(of: settings.dockSurface) ?? 0)
        wheelPopup.selectItem(at: WheelMode.allCases.firstIndex(of: settings.wheelMode) ?? 0)
        wheelPanPopup.selectItem(at: WheelPanDirection.allCases.firstIndex(of: settings.wheelPanDirection) ?? 0)
        swipePopup.selectItem(at: SwipeMode.allCases.firstIndex(of: settings.swipeMode) ?? 0)
        doubleClickPopup.selectItem(at: DoubleClickMode.allCases.firstIndex(of: settings.doubleClickMode) ?? 0)
        appearancePopup.selectItem(at: ViewerAppearanceMode.allCases.firstIndex(of: settings.appearance) ?? 0)
        loopPopup.selectItem(at: AnimationLoopPreference.allCases.firstIndex(of: settings.animationLoop) ?? 0)
        deletePopup.selectItem(at: DeleteFollowUp.allCases.firstIndex(of: settings.deleteFollowUp) ?? 0)
        sensitivitySlider.doubleValue = settings.wheelZoomSensitivity
        updateSensitivityLabel()
        exclusionsField.objectValue = settings.excludedExtensions.sorted()
        refreshCacheStatistics()
        refreshShortcutButtons()
        if selectedPaneTitle == "看图", selectedViewerSubTitle == "打开" { folderList.refresh() }
        fileAssociationController.refreshStatus()
    }

    // MARK: - Height

    /// Height below the native toolbar. All viewer categories keep one card size.
    func preferredContentHeight() -> CGFloat {
        paneContentHeight(selectedPaneTitle)
    }

    private func paneContentHeight(_ title: String) -> CGFloat {
        let minimum = SettingsMetrics.minPaneHeight
        switch title {
        case "看图":
            let tallest = viewerSubPanes.values.map(\.contentHeight).max() ?? 0
            return max(SettingsMetrics.minViewerPaneHeight,
                       tallest + SettingsMetrics.cardTopInset + SettingsMetrics.cardInset
                           + SettingsMetrics.subTabHeight / 2 + SettingsMetrics.paneInset
                           + SettingsMetrics.viewerTopInset)
        case "格式关联":
            fileAssociationController.view.layoutSubtreeIfNeeded()
            return max(minimum, fileAssociationController.view.fittingSize.height)
        default:
            return max(minimum, (panes[title] as? SettingsPaneView)?.contentHeight ?? minimum)
        }
    }

    private func announceHeight() {
        view.layoutSubtreeIfNeeded()
        onPreferredHeightChange?(preferredContentHeight())
    }

    // MARK: - Testing hooks

    var paneTitlesForTesting: [String] { Self.paneTitles }
    var viewerSubTitlesForTesting: [String] { Self.viewerSubTitles }
    var paneContainerForTesting: NSView { paneContainer }
    var associationController: FileAssociationViewController { fileAssociationController }
    var associationPane: NSView { fileAssociationController.view }

    func selectPane(_ title: String) {
        guard let index = Self.paneTitles.firstIndex(of: title) else { return }
        selectPane(index)
    }

    func selectViewerSubPane(_ title: String) {
        guard let index = Self.viewerSubTitles.firstIndex(of: title) else { return }
        viewerCategoryBar.selectedIndex = index
        selectedViewerSubTitle = title
        showViewerSubPane()
        if title == "打开" { folderList.refresh() }
        announceHeight()
    }

    func viewerSubPaneView(_ title: String) -> NSView? { viewerSubPanes[title] }

    /// The height each pane needs and the height it is given, after selecting
    /// it. `content > available` means a row is clipped.
    func paneContentHeightsForTesting() -> [(title: String, content: CGFloat, available: CGFloat)] {
        loadViewIfNeeded()
        let previous = selectedPaneTitle
        var heights: [(title: String, content: CGFloat, available: CGFloat)] = []
        for title in Self.paneTitles {
            selectPane(title)
            view.layoutSubtreeIfNeeded()
            heights.append((title, paneContentHeight(title), paneContainer.bounds.height))
        }
        selectPane(previous)
        return heights
    }

    /// Every sub-tab's rows and the height the 看图 pane gives them.
    func viewerSubPaneHeightsForTesting() -> [(title: String, content: CGFloat, available: CGFloat)] {
        loadViewIfNeeded()
        selectPane("看图")
        let previous = selectedViewerSubTitle
        var heights: [(title: String, content: CGFloat, available: CGFloat)] = []
        for title in Self.viewerSubTitles {
            selectViewerSubPane(title)
            view.layoutSubtreeIfNeeded()
            let available = (viewerSubPanes[title]?.superview?.bounds.height ?? 0)
            heights.append((title, viewerSubPanes[title]?.contentHeight ?? 0, available))
        }
        selectViewerSubPane(previous)
        return heights
    }

    // MARK: - 通用

    private func generalPane() -> SettingsPaneView {
        let pane = centeredPane(labels: ["应用程序"])
        pane.form.group("应用程序")
        quitCheckbox.state = settings.quitAfterLastWindowClosed ? .on : .off
        quitCheckbox.target = self
        quitCheckbox.action = #selector(toggleQuitAfterLastWindowClosed(_:))
        pane.form.row(nil, control: quitCheckbox)
        pane.form.note("关闭此选项后，应用可在没有窗口时继续运行；点击 Dock 图标可重新打开窗口。")
        return pane
    }

    // MARK: - 看图

    private func viewerPane() -> NSView {
        let pane = NSView(frame: NSRect(x: 0, y: 0, width: SettingsMetrics.windowWidth,
                                        height: SettingsMetrics.minPaneHeight))
        viewerCard.translatesAutoresizingMaskIntoConstraints = false
        pane.addSubview(viewerCard)

        viewerCategoryBar.onSelection = { [weak self] index in self?.viewerSubTabChanged(index) }
        pane.addSubview(viewerCategoryBar)

        for title in Self.viewerSubTitles { viewerSubPanes[title] = viewerSubPane(title) }

        NSLayoutConstraint.activate([
            viewerCard.leadingAnchor.constraint(equalTo: pane.leadingAnchor, constant: SettingsMetrics.paneInset),
            viewerCard.trailingAnchor.constraint(equalTo: pane.trailingAnchor, constant: -SettingsMetrics.paneInset),
            viewerCard.topAnchor.constraint(equalTo: pane.topAnchor,
                                            constant: SettingsMetrics.viewerTopInset + SettingsMetrics.subTabHeight / 2),
            viewerCard.bottomAnchor.constraint(equalTo: pane.bottomAnchor, constant: -SettingsMetrics.paneInset),
            viewerCategoryBar.centerXAnchor.constraint(equalTo: viewerCard.centerXAnchor),
            viewerCategoryBar.centerYAnchor.constraint(equalTo: viewerCard.topAnchor),
            viewerCategoryBar.heightAnchor.constraint(equalToConstant: SettingsMetrics.subTabHeight),
            viewerCategoryBar.widthAnchor.constraint(equalToConstant: SettingsMetrics.subTabWidth),
        ])
        return pane
    }

    private func viewerSubPane(_ title: String) -> SettingsPaneView {
        switch title {
        case "一般": return viewerGeneralPane()
        case "外观": return viewerAppearancePane()
        case "浏览": return viewerBrowsingPane()
        case "打开": return viewerOpenPane()
        case "鼠标": return viewerMousePane()
        default: return viewerPagingPane()
        }
    }

    private func showViewerSubPane() {
        guard selectedPaneTitle == "看图", let pane = viewerSubPanes[selectedViewerSubTitle] else { return }
        guard displayedViewerSubPane !== pane else { return }
        displayedViewerSubPane?.removeFromSuperview()
        displayedViewerSubPane = pane
        viewerCard.addSubview(pane)
        NSLayoutConstraint.activate([
            pane.leadingAnchor.constraint(equalTo: viewerCard.leadingAnchor,
                                          constant: SettingsMetrics.cardSideInset),
            pane.trailingAnchor.constraint(equalTo: viewerCard.trailingAnchor,
                                           constant: -SettingsMetrics.cardSideInset),
            pane.topAnchor.constraint(equalTo: viewerCard.topAnchor, constant: SettingsMetrics.cardTopInset),
            pane.bottomAnchor.constraint(lessThanOrEqualTo: viewerCard.bottomAnchor,
                                         constant: -SettingsMetrics.cardInset),
        ])
    }

    private func viewerSubTabChanged(_ index: Int) {
        guard Self.viewerSubTitles.indices.contains(index) else { return }
        selectedViewerSubTitle = Self.viewerSubTitles[index]
        if selectedViewerSubTitle == "打开" { folderList.refresh() }
        showViewerSubPane()
        announceHeight()
    }

    private func viewerGeneralPane() -> SettingsPaneView {
        let pane = SettingsPaneView(insets: NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0),
                         controlColumnWidth: SettingsMetrics.controlColumnWidth(inCard: true),
                         labelColumnWidth: SettingsMetrics.labelColumnWidth)
        pane.form.group("删除选项")
        confirmTrashCheckbox.state = settings.confirmBeforeTrash ? .on : .off
        confirmTrashCheckbox.target = self
        confirmTrashCheckbox.action = #selector(toggleConfirmTrash(_:))
        pane.form.row(nil, control: confirmTrashCheckbox)
        pane.form.row(nil, control: hint("⌘Delete 始终静默移到废纸篓，不弹确认。"))
        deletePopup = popup(DeleteFollowUp.allCases, title: { $0.localizedName },
                            selected: settings.deleteFollowUp) { [weak self] value in
            self?.settings.deleteFollowUp = value
        }
        pane.form.row("删除后", control: deletePopup)
        pane.form.group("动画")
        autoplayCheckbox.state = settings.autoplayAnimations ? .on : .off
        autoplayCheckbox.target = self
        autoplayCheckbox.action = #selector(toggleAutoplay(_:))
        pane.form.row(nil, control: autoplayCheckbox)
        loopPopup = popup(AnimationLoopPreference.allCases, title: { $0.localizedName },
                          selected: settings.animationLoop) { [weak self] value in
            self?.settings.animationLoop = value
        }
        pane.form.row("动画循环", control: loopPopup)
        pane.form.note("动画设置只影响 GIF 等动图文件内部的帧；切换文件请使用“循环浏览”。")
        return pane
    }

    private func viewerAppearancePane() -> SettingsPaneView {
        let pane = SettingsPaneView(insets: NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0),
                         controlColumnWidth: SettingsMetrics.controlColumnWidth(inCard: true),
                         labelColumnWidth: SettingsMetrics.labelColumnWidth)
        pane.form.group("查看外观")
        titlebarPopup = popup(TitlebarBehavior.allCases, title: { $0.localizedName },
                              selected: settings.titlebar) { [weak self] in self?.settings.titlebar = $0 }
        pane.form.row("顶栏", control: titlebarPopup)
        dockDisplayPopup = popup(ChromeDisplayPolicy.allCases, title: { $0.localizedName },
                                 selected: settings.dockDisplayPolicy) { [weak self] in
            self?.settings.dockDisplayPolicy = $0
        }
        pane.form.row("底栏", control: dockDisplayPopup)
        navigationDisplayPopup = popup(ChromeDisplayPolicy.allCases, title: { $0.localizedName },
                                       selected: settings.navigationDisplayPolicy) { [weak self] in
            self?.settings.navigationDisplayPolicy = $0
        }
        pane.form.row("翻页箭头", control: navigationDisplayPopup)
        topFilenameCheckbox.state = settings.showTopFilename ? .on : .off
        topFilenameCheckbox.target = self
        topFilenameCheckbox.action = #selector(toggleTopFilename(_:))
        pane.form.row(nil, control: topFilenameCheckbox)
        minimapCheckbox.state = settings.hideMinimap ? .on : .off
        minimapCheckbox.target = self
        minimapCheckbox.action = #selector(toggleMinimap(_:))
        pane.form.row(nil, control: minimapCheckbox)
        pane.form.note("“显示 / 隐藏 / 自动”中的自动沿用当前悬停与空闲规则；没有图片时不显示这些覆盖控件。")
        pane.form.group("材质")
        appearancePopup = popup(ViewerAppearanceMode.allCases, title: { $0.localizedName },
                                selected: settings.appearance) { [weak self] in self?.settings.appearance = $0 }
        pane.form.row("查看器外观", control: appearancePopup)
        dockSurfacePopup = popup(DockSurface.allCases, title: { $0.localizedName },
                                 selected: settings.dockSurface) { [weak self] in self?.settings.dockSurface = $0 }
        pane.form.row("工具栏材质", control: dockSurfacePopup)
        pane.form.note("默认跟随系统。macOS 14–15 使用 AppKit 原生材质；macOS 26 及以上由系统原生 Liquid Glass 呈现，"
                       + "不使用手绘仿制效果。系统开启“降低透明度”“降低动态效果”时会自动减少材质与转场。")
        return pane
    }

    private func viewerBrowsingPane() -> SettingsPaneView {
        let pane = SettingsPaneView(insets: NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0),
                         controlColumnWidth: SettingsMetrics.controlColumnWidth(inCard: true),
                         labelColumnWidth: SettingsMetrics.labelColumnWidth)
        pane.form.group("窗口大小")
        sizingPopup = popup(WindowSizingPolicy.allCases, title: { $0.localizedName },
                            selected: settings.windowSizing) { [weak self] value in
            self?.settings.windowSizing = value
        }
        pane.form.row(nil, control: sizingPopup)
        pane.form.group("浏览顺序")
        sortPopup = popup(ImageSortKey.allCases, title: { $0.localizedName },
                          selected: settings.sortKey) { [weak self] value in
            self?.settings.sortKey = value
        }
        sortDirectionPopup = popup(SortDirection.allCases, title: { $0.localizedName },
                                   selected: settings.sortDirection) { [weak self] value in
            self?.settings.sortDirection = value
        }
        pane.form.row(nil, control: NSStackView(views: [sortPopup, sortDirectionPopup]))
        pane.form.group("辅助选项")
        loopBrowsingCheckbox.state = settings.loopBrowsing ? .on : .off
        loopBrowsingCheckbox.target = self
        loopBrowsingCheckbox.action = #selector(toggleLoopBrowsing(_:))
        pane.form.row(nil, control: loopBrowsingCheckbox)
        alwaysOnTopCheckbox.state = settings.defaultAlwaysOnTop ? .on : .off
        alwaysOnTopCheckbox.target = self
        alwaysOnTopCheckbox.action = #selector(toggleAlwaysOnTop(_:))
        pane.form.row(nil, control: alwaysOnTopCheckbox)
        pane.form.note("置顶默认值只影响新开的窗口；当前窗口用“窗口 → 窗口置顶”切换。")
        return pane
    }

    private func viewerOpenPane() -> SettingsPaneView {
        let pane = SettingsPaneView(insets: NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0),
                         controlColumnWidth: SettingsMetrics.controlColumnWidth(inCard: true),
                         labelColumnWidth: SettingsMetrics.labelColumnWidth)
        pane.form.group("打开方式")
        openBehaviorPopup = popup(OpenBehavior.allCases, title: { $0.localizedName },
                                  selected: settings.openBehavior) { [weak self] value in
            self?.settings.openBehavior = value
        }
        pane.form.row(nil, control: openBehaviorPopup)
        pane.form.note("“新窗口”每次打开都新建窗口；“复用当前窗口”使用最前面的看图窗口。")
        pane.form.group("打开选项")
        promptFolderCheckbox.state = settings.promptForFolderAccess ? .on : .off
        promptFolderCheckbox.target = self
        promptFolderCheckbox.action = #selector(togglePromptForFolderAccess(_:))
        pane.form.row(nil, control: promptFolderCheckbox)
        pane.form.note("关闭后不再自动提示，读取失败的错误状态和手动恢复入口仍然保留。")
        pane.form.group("排除扩展名")
        exclusionsField.tokenizingCharacterSet = CharacterSet(charactersIn: ",，;；、 \n\t")
        exclusionsField.placeholderString = "输入扩展名后按回车，例如：gif"
        exclusionsField.font = .systemFont(ofSize: 12)
        exclusionsField.usesSingleLineMode = false
        exclusionsField.cell?.wraps = true
        exclusionsField.cell?.isScrollable = false
        exclusionsField.delegate = self
        exclusionsField.objectValue = settings.excludedExtensions.sorted()
        exclusionsField.setAccessibilityLabel("排除的扩展名")
        exclusionsField.heightAnchor.constraint(greaterThanOrEqualToConstant: 60).isActive = true
        exclusionsField.widthAnchor.constraint(
            equalToConstant: SettingsMetrics.controlColumnWidth(inCard: true)).isActive = true
        pane.form.row(nil, control: exclusionsField)
        pane.form.note("逗号、空格或回车分隔；忽略大小写和前导点号。目录扫描时过滤，直接打开的文件仍可查看。")
        pane.form.group("授权文件夹")
        pane.form.row(nil, control: folderList, alignment: .top)
        pane.form.note("添加或重新选择后保存访问记录；移除记录不会删除文件。")
        pane.form.group("系统权限")
        pane.form.row(nil, control: actionButton("完全磁盘访问指南…") { [weak self] in
            FolderAccessPanel.showSystemGuide(for: self?.view.window)
        })
        pane.form.note("完全磁盘访问由 macOS 系统设置管理，选择文件夹不会授予整块磁盘权限。")

        return pane
    }

    private func viewerMousePane() -> SettingsPaneView {
        let pane = SettingsPaneView(insets: NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0),
                         controlColumnWidth: SettingsMetrics.controlColumnWidth(inCard: true),
                         labelColumnWidth: SettingsMetrics.labelColumnWidth)
        pane.form.group("鼠标左键")
        doubleClickPopup = popup(DoubleClickMode.allCases, title: localizedDoubleClick,
                                 selected: settings.doubleClickMode) { [weak self] value in
            self?.settings.doubleClickMode = value
        }
        pane.form.row("双击", control: doubleClickPopup)
        pane.form.group("鼠标滚轮")
        wheelPopup = popup(WheelMode.allCases, title: localizedWheel,
                           selected: settings.wheelMode) { [weak self] value in
            self?.settings.wheelMode = value
        }
        pane.form.row(nil, control: wheelPopup)
        wheelPanPopup = popup(WheelPanDirection.allCases, title: { $0.localizedName },
                              selected: settings.wheelPanDirection) { [weak self] value in
            self?.settings.wheelPanDirection = value
        }
        pane.form.row("平移方向", control: wheelPanPopup)
        sensitivitySlider.doubleValue = settings.wheelZoomSensitivity
        sensitivitySlider.target = self
        sensitivitySlider.action = #selector(changeSensitivity(_:))
        sensitivitySlider.setAccessibilityLabel("滚轮缩放灵敏度")
        // The caption, value and reset button share this row. Let the slider
        // yield a few points instead of making AppKit widen the whole window.
        let preferredSliderWidth = sensitivitySlider.widthAnchor.constraint(equalToConstant: 170)
        preferredSliderWidth.priority = .defaultLow
        preferredSliderWidth.isActive = true
        sensitivitySlider.widthAnchor.constraint(greaterThanOrEqualToConstant: 100).isActive = true
        sensitivityLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        updateSensitivityLabel()
        let resetSensitivity = actionButton("默认") { [weak self] in
            guard let self else { return }
            self.settings.wheelZoomSensitivity = 0.0015
            self.sensitivitySlider.doubleValue = self.settings.wheelZoomSensitivity
            self.updateSensitivityLabel()
        }
        pane.form.row("图片缩放灵敏度",
                      control: NSStackView(views: [sensitivitySlider, sensitivityLabel, resetSensitivity]))
        pane.form.note("缩放始终以指针位置为中心；数值越小，同样的滚动距离缩放越慢。")
        return pane
    }

    private func viewerPagingPane() -> SettingsPaneView {
        let pane = SettingsPaneView(insets: NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0),
                         controlColumnWidth: SettingsMetrics.controlColumnWidth(inCard: true),
                         labelColumnWidth: SettingsMetrics.labelColumnWidth)
        pane.form.group("触控板")
        swipePopup = popup(SwipeMode.allCases, title: localizedSwipe,
                           selected: settings.swipeMode) { [weak self] value in
            self?.settings.swipeMode = value
        }
        pane.form.row("横向滑动", control: swipePopup)
        return pane
    }

    // MARK: - 高级

    private func advancedPane() -> SettingsPaneView {
        let pane = centeredPane(labels: ["缩略图缓存"])
        pane.form.group("缩略图缓存")
        cacheDiskLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        cacheMemoryLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        cacheMemoryLabel.textColor = .secondaryLabelColor
        pane.form.row(nil, control: cacheDiskLabel)
        pane.form.row(nil, control: cacheMemoryLabel)
        let clear = NSButton(title: "清除", target: self, action: #selector(clearCache(_:)))
        clear.bezelStyle = .rounded
        clear.setAccessibilityLabel("清除缩略图缓存")
        pane.form.row(nil, control: NSStackView(views: [
            clear,
            actionButton("在访达中显示") { ThumbnailCacheService.shared.revealInFinder() },
        ]))
        pane.form.note("清空内存与磁盘上的缩略图，继续浏览时按需重新生成；不会删除原图。")
        return pane
    }

    // MARK: - 快捷键

    private func shortcutPane() -> SettingsPaneView {
        let pane = SettingsPaneView()
        for (id, title, width) in [("action", "操作", CGFloat(260)), ("key", "键值", CGFloat(160)),
                                   ("type", "类型", CGFloat(80))] {
            let column = NSTableColumn(identifier: .init(id))
            column.title = title; column.width = width; column.minWidth = id == "action" ? 160 : 70
            shortcutTable.addTableColumn(column)
        }
        shortcutTable.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        shortcutTable.usesAlternatingRowBackgroundColors = true
        shortcutTable.rowHeight = 30
        shortcutTable.dataSource = self; shortcutTable.delegate = self
        shortcutTable.setAccessibilityLabel("快捷键列表")
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.documentView = shortcutTable
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.heightAnchor.constraint(equalToConstant: 400).isActive = true
        pane.form.fullWidthControl(scroll)
        conflictLabel.textColor = .systemRed
        conflictLabel.font = .systemFont(ofSize: 11)
        pane.form.fullWidthNote("点击键值录制快捷键；冲突时不写入。系统快捷键保持固定。")
        pane.form.fullWidthControl(NSStackView(views: [
            actionButton("全部清空") { [weak self] in
                self?.shortcuts.clearAll(); self?.refreshShortcutButtons()
            },
            actionButton("恢复默认") { [weak self] in
                self?.shortcuts.restoreDefaults(); self?.refreshShortcutButtons()
            },
        ]))
        pane.form.fullWidthControl(conflictLabel)
        return pane
    }

    func numberOfRows(in tableView: NSTableView) -> Int { shortcutCommands.count }
    func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        guard shortcutCommands.indices.contains(row) else { return nil }
        let command = shortcutCommands[row]
        switch column?.identifier.rawValue {
        case "key":
            let button = NSButton(title: shortcutDisplay(command), target: self, action: #selector(captureShortcut(_:)))
            button.identifier = .init(command.rawValue)
            button.bezelStyle = .rounded
            button.isEnabled = !command.isFixedSystemShortcut
            button.setAccessibilityLabel("\(command.localizedTitle)的快捷键")
            shortcutButtons[command] = button
            return button
        case "type":
            let label = NSTextField(labelWithString: command.isFixedSystemShortcut ? "系统" : "自定义")
            label.textColor = .secondaryLabelColor
            return centeredTableCell(label)
        default: return centeredTableCell(NSTextField(labelWithString: command.localizedTitle))
        }
    }

    private func centeredTableCell(_ label: NSTextField) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.textField = label
        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byTruncatingTail
        cell.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }
    private func shortcutDisplay(_ command: ViewerCommand) -> String {
        switch command {
        case .open: return "⌘O"
        case .close: return "⌘W"
        case .settings: return "⌘,"
        case .copyImage: return "⌘C"
        case .toggleFullScreen: return "⌃⌘F"
        default: return shortcuts.shortcut(for: command)?.displayString ?? "未设置"
        }
    }

    // MARK: - 关于

    private func aboutPane() -> SettingsPaneView {
        let pane = centeredPane(labels: ["构建信息", "说明"])
        let header = NSStackView(views: [appIconView(), appNameLabel(), appVersionLabel()])
        header.orientation = .vertical
        header.alignment = .centerX
        header.spacing = 4
        pane.form.stack.addArrangedSubview(header)
        header.widthAnchor.constraint(equalTo: pane.form.stack.widthAnchor).isActive = true
        pane.form.stack.setCustomSpacing(SettingsMetrics.groupSpacing, after: header)
        pane.form.group("构建信息")
        pane.form.row("版本", control: valueLabel(Self.bundleValue("CFBundleShortVersionString") ?? "开发构建"))
        pane.form.row("构建号", control: valueLabel(Self.bundleValue("CFBundleVersion") ?? "未打包"))
        pane.form.row("标识符", control: valueLabel(Self.bundleValue("CFBundleIdentifier") ?? "未打包运行"))
        pane.form.row("系统要求", control: valueLabel("macOS 14 或更高版本"))
        pane.form.group("说明")
        pane.form.fullWidthNote("PicLight 是原生 macOS 图片查看器，支持文件夹浏览与网格视图。")
        return pane
    }

    /// Short panes center the actual form, rather than reserving a viewer-sized
    /// empty label column on the left.
    private func centeredPane(labels: [String]) -> SettingsPaneView {
        let font = NSFont.systemFont(ofSize: 12)
        let labelWidth = ceil(labels.map { ($0 as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0)
        let controlWidth = SettingsMetrics.controlColumnWidth(inCard: false)
        let sideInset = (SettingsMetrics.windowWidth - labelWidth - SettingsMetrics.labelSpacing - controlWidth) / 2
        return SettingsPaneView(insets: NSEdgeInsets(top: SettingsMetrics.paneInset, left: sideInset,
                                                     bottom: SettingsMetrics.paneInset, right: sideInset),
                                controlColumnWidth: controlWidth, labelColumnWidth: labelWidth)
    }

    private static func bundleValue(_ key: String) -> String? {
        (Bundle.main.object(forInfoDictionaryKey: key) as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    private func appIconView() -> NSImageView {
        let view = NSImageView()
        view.image = NSApp.applicationIconImage
        view.imageScaling = .scaleProportionallyUpOrDown
        view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            view.widthAnchor.constraint(equalToConstant: 64),
            view.heightAnchor.constraint(equalToConstant: 64),
        ])
        return view
    }

    private func appNameLabel() -> NSTextField {
        let label = NSTextField(labelWithString: "PicLight")
        label.font = .systemFont(ofSize: 15, weight: .semibold)
        return label
    }

    private func appVersionLabel() -> NSTextField {
        let version = Self.bundleValue("CFBundleShortVersionString") ?? "开发构建"
        let build = Self.bundleValue("CFBundleVersion")
        let label = NSTextField(labelWithString: build.map { "版本 \(version)（Build \($0)）" } ?? "版本 \(version)")
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        return label
    }

    private func valueLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 12)
        return label
    }

    // MARK: - Actions

    @objc private func toggleQuitAfterLastWindowClosed(_ sender: NSButton) {
        settings.quitAfterLastWindowClosed = sender.state == .on
    }

    @objc private func toggleConfirmTrash(_ sender: NSButton) {
        settings.confirmBeforeTrash = sender.state == .on
    }

    @objc private func togglePromptForFolderAccess(_ sender: NSButton) {
        settings.promptForFolderAccess = sender.state == .on
    }

    @objc private func toggleLoopBrowsing(_ sender: NSButton) {
        settings.loopBrowsing = sender.state == .on
    }

    @objc private func toggleAlwaysOnTop(_ sender: NSButton) {
        settings.defaultAlwaysOnTop = sender.state == .on
    }

    @objc private func toggleMinimap(_ sender: NSButton) {
        settings.hideMinimap = sender.state == .on
    }

    @objc private func changeSensitivity(_ sender: NSSlider) {
        settings.wheelZoomSensitivity = sender.doubleValue
        updateSensitivityLabel()
    }

    private func updateSensitivityLabel() {
        sensitivityLabel.stringValue = String(format: "%.1f×", settings.wheelZoomSensitivity / 0.0015)
    }

    private func refreshShortcutButtons() {
        conflictLabel.stringValue = ""
        for (command, button) in shortcutButtons {
            button.title = shortcutDisplay(command)
        }
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
        cacheDiskLabel.stringValue = "磁盘：\(stats.diskCount) 张 · "
            + ByteCountFormatter.string(fromByteCount: Int64(stats.diskBytes), countStyle: .file)
        cacheMemoryLabel.stringValue = "内存：\(stats.memoryCount) 张 · "
            + ByteCountFormatter.string(fromByteCount: Int64(stats.memoryBytes), countStyle: .memory)
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
        guard let raw = sender.identifier?.rawValue, let command = ViewerCommand(rawValue: raw),
              !command.isFixedSystemShortcut else { return }
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

    // MARK: - Excluded extensions

    func controlTextDidChange(_ obj: Notification) { saveExclusions() }
    func controlTextDidEndEditing(_ obj: Notification) {
        saveExclusions()
        exclusionsField.objectValue = settings.excludedExtensions.sorted()
    }

    private func saveExclusions() {
        let tokens = (exclusionsField.objectValue as? [String]) ?? []
        let normalized = AppSettings.normalizeExcludedExtensions(tokens.joined(separator: ","))
        guard normalized != settings.excludedExtensions else { return }
        settings.excludedExtensions = normalized
    }

    // MARK: - Helpers

    private func localizedWheel(_ mode: WheelMode) -> String {
        switch mode {
        case .zoom: return "缩放图片"
        case .pan: return "在图片内移动"
        case .navigate: return "左右翻页"
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

    private func hint(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        return label
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
