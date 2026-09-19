import AppKit

/// The folder browser: a toolbar, a folder-tree sidebar and a virtualized gallery of the current
/// folder's images.
///
/// It is a *separate presentation hierarchy* from the image viewer, which the spec requires — the
/// two modes share the folder session, the sort order and the thumbnail cache, and nothing else.
/// Nothing in here touches the canvas, and the canvas is not in this view tree at all.
public final class FolderBrowserView: NSView {

    /// Toolbar controls, in the order the spec lists them.
    public enum ToolbarItem: Equatable {
        case back
        case layout(GalleryLayoutKind)
        case thumbnailSizeSlider
        /// Folder name and position, in the toolbar's middle.
        case folderTitle
        /// Sorting on the right.
        case sortKey
        case sortDirection
    }

    /// Left to right. Declared so the layout is assertable without rendering it.
    public static let toolbarLayout: [ToolbarItem] = [
        .back,
        .layout(.uniformGrid),
        .layout(.adaptiveGrid),
        .thumbnailSizeSlider,
        .folderTitle,
        .sortKey,
        .sortDirection,
    ]

    public var onBack: (() -> Void)?
    public var onLayoutChanged: ((GalleryLayoutKind) -> Void)?
    public var onThumbnailSizeChanged: ((CGFloat) -> Void)?
    public var onThumbnailSizeSettled: ((CGFloat) -> Void)?
    public var onSortKeyChanged: ((ImageSortKey) -> Void)?
    public var onSortDirectionChanged: ((SortDirection) -> Void)?
    /// A folder was chosen in the tree sidebar.
    public var onFolderChosen: ((URL) -> Void)?
    /// A tree row's disclosure triangle was clicked.
    public var onFolderToggled: ((URL) -> Void)?
    /// A gallery item was clicked or double-clicked.
    public var onItemSelected: ((Int) -> Void)?
    public var onItemOpened: ((Int) -> Void)?

    private let toolbar = NSView()
    private let galleryScroll = NSScrollView()
    let gallery = GalleryGridView()
    let treeSidebar = FolderTreeSidebarView()

    private let backButton = DockButton(symbol: "chevron.left", tooltip: "返回图像视图")
    private let uniformButton = DockButton(symbol: "square.grid.2x2", tooltip: "规则网格")
    private let adaptiveButton = DockButton(symbol: "rectangle.grid.1x2", tooltip: "自适应网格")
    private let sizeSlider = NSSlider()
    private let titleLabel = NSTextField(labelWithString: "")
    private let sortKeyPopup = NSPopUpButton()
    private let sortDirectionButton = DockButton(symbol: "arrow.up.arrow.down", tooltip: "排序方向")

    private var sidebarWidthConstraint: NSLayoutConstraint?
    private var sidebarVisibleConstraint: NSLayoutConstraint?
    private var sidebarHiddenConstraint: NSLayoutConstraint?

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        buildToolbar()
        buildBody()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The browser paints its own background instead of relying on what is behind it.
    ///
    /// Every surface here used to be transparent — the tree sidebar's outline, the gallery's scroll
    /// view, the toolbar — so the browser showed whatever the window had underneath. In the merged
    /// top row the image mode's canvas is behind it, and a transparent, only-partly-repainted area
    /// left remnants of the picture on screen. An opaque fill removes the whole class of artefact
    /// and costs one rectangle per redraw.
    public override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()
    }

    public override var isOpaque: Bool { true }

    /// Height of the browser's top bar before it is merged with the titlebar. In the merged row it
    /// becomes exactly as tall as the titlebar, so the row reads as a titlebar instead of as a
    /// thicker band with the controls near its top edge.
    static let defaultToolbarHeight: CGFloat = 44

    // MARK: - Construction

    private func buildToolbar() {
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        toolbar.wantsLayer = true

        backButton.target = self
        backButton.action = #selector(goBack)
        backButton.setAccessibilityLabel("返回图像视图")
        backButton.toolTip = "返回图像视图"

        uniformButton.target = self
        uniformButton.action = #selector(chooseUniform)
        adaptiveButton.target = self
        adaptiveButton.action = #selector(chooseAdaptive)

        sizeSlider.minValue = Double(GalleryLayout.minimumThumbnailSize)
        sizeSlider.maxValue = Double(GalleryLayout.maximumThumbnailSize)
        sizeSlider.doubleValue = Double(GalleryLayout.defaultThumbnailSize)
        sizeSlider.isContinuous = true
        sizeSlider.target = self
        sizeSlider.action = #selector(sliderMoved)
        sizeSlider.translatesAutoresizingMaskIntoConstraints = false
        sizeSlider.widthAnchor.constraint(equalToConstant: 120).isActive = true
        sizeSlider.toolTip = "缩略图大小"
        sizeSlider.setAccessibilityLabel("缩略图大小")

        titleLabel.font = .systemFont(ofSize: 12, weight: .medium)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        for key in ImageSortKey.allCases { sortKeyPopup.addItem(withTitle: key.localizedName) }
        sortKeyPopup.target = self
        sortKeyPopup.action = #selector(sortKeyChanged)
        sortKeyPopup.toolTip = "排序方式"

        sortDirectionButton.target = self
        sortDirectionButton.action = #selector(sortDirectionChanged)
        sortDirectionButton.toolTip = "升序 / 降序"

        let leading = NSStackView(views: [backButton, uniformButton, adaptiveButton, sizeSlider])
        leading.orientation = .horizontal
        leading.spacing = 8
        leading.alignment = .centerY

        let toolbarHeight = toolbar.heightAnchor.constraint(
            equalToConstant: Self.defaultToolbarHeight)
        toolbarHeightConstraint = toolbarHeight
        self.toolbarHeightForBody = toolbarHeight
        let stack = NSStackView(views: [leading, titleLabel, sortKeyPopup, sortDirectionButton])
        stack.orientation = .horizontal
        stack.spacing = 12
        stack.alignment = .centerY
        stack.distribution = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        toolbar.addSubview(stack)
        let leadingInset = stack.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor,
                                                          constant: 12)
        toolbarStackLeadingConstraint = leadingInset
        let stackCenter = stack.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor)
        toolbarStackCenterConstraint = stackCenter
        NSLayoutConstraint.activate([
            leadingInset,
            stack.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor, constant: -12),
            stackCenter,
        ])
    }

    private var toolbarStackLeadingConstraint: NSLayoutConstraint?
    private var toolbarStackCenterConstraint: NSLayoutConstraint?
    private var toolbarHeightConstraint: NSLayoutConstraint?
    /// The same constraint, kept for `buildBody` (both builders run in `init`, and the toolbar's
    /// height belongs to the body's layout).
    private var toolbarHeightForBody: NSLayoutConstraint?

    /// How far the toolbar's own controls start from the window's leading edge.
    ///
    /// In the browser's merged top row the native controls occupy that edge — the traffic lights
    /// and the drawer button beside them — so the toolbar has to begin after them. Zero in every
    /// other presentation.
    func setToolbarLeadingInset(_ inset: CGFloat) {
        toolbarStackLeadingConstraint?.constant = 12 + max(0, inset)
        needsLayout = true
    }

    /// Where the toolbar's first control starts, for tests.
    var toolbarLeadingEdgeForTesting: CGFloat? {
        toolbarStackLeadingConstraint.map { $0.constant - 12 }
    }

    /// Makes the top bar exactly as tall as the titlebar it is merged with.
    ///
    /// The merged row *is* the titlebar, so it should be the titlebar's height: at the default
    /// 44 pt the band was visibly thicker than a titlebar, with the controls sitting near its top
    /// edge and dead space under them. With the bar at the titlebar's own height there is nothing
    /// to offset — the controls centre on the same line as the traffic lights and the drawer
    /// button, which is what the measurements below were for.
    func alignToolbarContent(withTitlebarHeight height: CGFloat) {
        guard height > 0 else {
            toolbarHeightConstraint?.constant = Self.defaultToolbarHeight
            toolbarStackCenterConstraint?.constant = 0
            needsLayout = true
            return
        }
        // Measured when the bar and the toolbar had different heights: a positive constant on this
        // centre constraint moves the stack *down* in the toolbar's coordinate space. With the
        // heights equal the offset is zero, and the constraint is kept for the general case.
        toolbarHeightConstraint?.constant = height
        toolbarStackCenterConstraint?.constant = 0
        needsLayout = true
    }

    /// The height the top bar is currently using, for tests.
    var toolbarHeightForTesting: CGFloat? { toolbarHeightConstraint?.constant }

    /// The alignment offset in force, for tests.
    var toolbarVerticalOffsetForTesting: CGFloat? { toolbarStackCenterConstraint?.constant }

    private func buildBody() {
        galleryScroll.translatesAutoresizingMaskIntoConstraints = false
        // Opaque: the gallery is the browser's own surface, not a window onto the image mode's
        // canvas. A transparent scroll view left the previous image showing through the gaps.
        galleryScroll.drawsBackground = true
        galleryScroll.backgroundColor = .windowBackgroundColor
        galleryScroll.hasVerticalScroller = true
        galleryScroll.autohidesScrollers = true
        galleryScroll.scrollerStyle = .overlay
        galleryScroll.documentView = gallery
        gallery.onSelectionChanged = { [weak self] index in self?.onItemSelected?(index) }
        gallery.onItemOpened = { [weak self] index in self?.onItemOpened?(index) }

        treeSidebar.translatesAutoresizingMaskIntoConstraints = false
        treeSidebar.onFolderChosen = { [weak self] url in self?.onFolderChosen?(url) }
        treeSidebar.onFolderToggled = { [weak self] url in self?.onFolderToggled?(url) }

        addSubview(toolbar)
        addSubview(treeSidebar)
        addSubview(galleryScroll)

        let sidebarWidth = treeSidebar.widthAnchor.constraint(equalToConstant: 200)
        sidebarWidthConstraint = sidebarWidth
        let sidebarVisible = treeSidebar.leadingAnchor.constraint(equalTo: leadingAnchor)
        let sidebarHidden = treeSidebar.leadingAnchor.constraint(equalTo: leadingAnchor,
                                                                 constant: -200)
        sidebarVisibleConstraint = sidebarVisible
        sidebarHiddenConstraint = sidebarHidden
        sidebarHidden.isActive = false

        NSLayoutConstraint.activate([
            toolbar.leadingAnchor.constraint(equalTo: leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: trailingAnchor),
            toolbar.topAnchor.constraint(equalTo: topAnchor),
            toolbarHeightForBody ?? toolbar.heightAnchor.constraint(
                equalToConstant: Self.defaultToolbarHeight),

            sidebarVisible,
            sidebarWidth,
            treeSidebar.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            treeSidebar.bottomAnchor.constraint(equalTo: bottomAnchor),

            galleryScroll.leadingAnchor.constraint(equalTo: treeSidebar.trailingAnchor),
            galleryScroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            galleryScroll.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            galleryScroll.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    // MARK: - State

    public private(set) var layoutKind: GalleryLayoutKind = .uniformGrid

    /// Refreshes everything the toolbar reports. Called whenever the session or the settings change.
    public func update(layout: GalleryLayoutKind, thumbnailSize: CGFloat, sortKey: ImageSortKey,
                       sortDirection: SortDirection, folderName: String?, position: String) {
        layoutKind = layout
        uniformButton.tint = layout == .uniformGrid ? .controlAccentColor : .labelColor
        adaptiveButton.tint = layout == .adaptiveGrid ? .controlAccentColor : .labelColor
        uniformButton.setAccessibilityLabel(layout == .uniformGrid ? "规则网格（当前）" : "规则网格")
        adaptiveButton.setAccessibilityLabel(layout == .adaptiveGrid ? "自适应网格（当前）" : "自适应网格")

        if abs(sizeSlider.doubleValue - Double(thumbnailSize)) > 0.5 {
            sizeSlider.doubleValue = Double(GalleryLayout.clampThumbnailSize(thumbnailSize))
        }
        if let index = ImageSortKey.allCases.firstIndex(of: sortKey) {
            sortKeyPopup.selectItem(at: index)
        }
        sortDirectionButton.setSymbol(sortDirection == .ascending ? "arrow.up" : "arrow.down")
        sortDirectionButton.toolTip = sortDirection == .ascending ? "升序（点击改为降序）" : "降序（点击改为升序）"

        let name = folderName ?? "—"
        titleLabel.stringValue = "\(name)   ·   \(position)"
        titleLabel.toolTip = folderName
    }

    /// Shows or hides the folder-tree sidebar. The browser is a full mode, so the sidebar is part of
    /// it rather than an overlay; the gallery takes the space when it is away.
    public func setSidebarVisible(_ visible: Bool, animated: Bool = false) {
        sidebarVisibleConstraint?.isActive = visible
        sidebarHiddenConstraint?.isActive = !visible
        guard animated else {
            layoutSubtreeIfNeeded()
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = AccessibilityAppearance.chromeFadeDuration
            self.animator().layoutSubtreeIfNeeded()
        }
    }

    public var isSidebarVisible: Bool { sidebarVisibleConstraint?.isActive == true }

    /// The gallery's own scroll view, so the controller can keep the selection in view.
    var galleryScrollView: NSScrollView { galleryScroll }

    // MARK: - Actions

    @objc private func goBack() { onBack?() }
    @objc private func chooseUniform() { onLayoutChanged?(.uniformGrid) }
    @objc private func chooseAdaptive() { onLayoutChanged?(.adaptiveGrid) }

    @objc private func sliderMoved() {
        onThumbnailSizeChanged?(CGFloat(sizeSlider.doubleValue))
    }

    /// Called when the slider's drag ends. The distinction matters: the grid reflows on every tick,
    /// but a sharper thumbnail is only requested once the user has stopped moving — otherwise every
    /// pixel of travel would start a decode.
    public func noteSliderDragEnded() {
        onThumbnailSizeSettled?(CGFloat(sizeSlider.doubleValue))
    }

    @objc private func sortKeyChanged() {
        let index = sortKeyPopup.indexOfSelectedItem
        guard ImageSortKey.allCases.indices.contains(index) else { return }
        onSortKeyChanged?(ImageSortKey.allCases[index])
    }

    @objc private func sortDirectionChanged() {
        let next: SortDirection = sortDirectionButton.symbolName == "arrow.up" ? .descending : .ascending
        onSortDirectionChanged?(next)
    }

    // MARK: - Test access

    var backControl: DockButton { backButton }
    var uniformLayoutControl: DockButton { uniformButton }
    var adaptiveLayoutControl: DockButton { adaptiveButton }
    var thumbnailSizeSlider: NSSlider { sizeSlider }
    var folderTitleLabel: NSTextField { titleLabel }
    var sortKeyControl: NSPopUpButton { sortKeyPopup }
    var sortDirectionControl: DockButton { sortDirectionButton }
    var toolbarViews: [NSView] { [backButton, uniformButton, adaptiveButton, sizeSlider,
                                   titleLabel, sortKeyPopup, sortDirectionButton] }
}
