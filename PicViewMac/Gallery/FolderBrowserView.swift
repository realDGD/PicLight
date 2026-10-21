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
    public var onFolderExpansionChanged: ((URL, Bool) -> Void)?
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
    private let sizeSlider = ThumbnailSizeSlider()

    /// The sizes the uniform grid can take, ascending: one per column count that fills the row
    /// exactly. Empty in the adaptive layout (and when the window is too narrow for any level), where
    /// the slider stays continuous.
    private var sizeLevels: [CGFloat] = []

    /// The size the slider represents, in points. In stepped mode `sizeSlider`'s value is an *index*
    /// into `sizeLevels`, so the two cannot be read from each other.
    private var sliderSize: CGFloat = GalleryLayout.defaultThumbnailSize

    /// The width the gallery lays its rows out for, matching `GalleryGridView.layoutWidth`.
    private var galleryLayoutWidth: CGFloat {
        let width = galleryScroll.contentSize.width
        return width > 0 ? width : gallery.bounds.width
    }
    private let titleLabel = NSTextField(labelWithString: "")
    /// "缩略图 3 / 12" while the visible cells are waiting for their pictures, and nothing at all when
    /// they are not. A folder of large images spends seconds per thumbnail (ImageIO needs ≈18 s for a
    /// 48,000 × 32,000 PNG), and without this the grid just looks empty.
    private let thumbnailProgressLabel = NSTextField(labelWithString: "")
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

        sizeSlider.isContinuous = true
        sizeSlider.target = self
        sizeSlider.action = #selector(sliderMoved)
        sizeSlider.translatesAutoresizingMaskIntoConstraints = false
        sizeSlider.widthAnchor.constraint(equalToConstant: 120).isActive = true
        sizeSlider.toolTip = "缩略图大小"
        sizeSlider.setAccessibilityLabel("缩略图大小")
        // The slider's own cell tracks the pointer, so the control's `mouseUp` never runs after a
        // drag; the tracking loop returns from `mouseDown`, which is where the drag really ends.
        sizeSlider.onTrackingEnded = { [weak self] in self?.noteSliderDragEnded() }

        titleLabel.font = .systemFont(ofSize: 12, weight: .medium)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        thumbnailProgressLabel.font = .systemFont(ofSize: 11)
        thumbnailProgressLabel.textColor = .tertiaryLabelColor
        thumbnailProgressLabel.isHidden = true
        thumbnailProgressLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        thumbnailProgressLabel.translatesAutoresizingMaskIntoConstraints = false

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
        let stack = NSStackView(views: [leading, titleLabel, thumbnailProgressLabel,
                                        sortKeyPopup, sortDirectionButton])
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
    private var nativeControlsInset: CGFloat = 0

    /// How far the toolbar's own controls start from the window's leading edge.
    ///
    /// In the browser's merged top row the native controls occupy that edge — the traffic lights
    /// and the drawer button beside them — so the toolbar has to begin after them. Zero in every
    /// other presentation.
    func setToolbarLeadingInset(_ inset: CGFloat) {
        nativeControlsInset = max(0, inset)
        updateToolbarLeadingInset()
    }

    private func updateToolbarLeadingInset() {
        let sidebarWidth = isSidebarVisible ? sidebarWidthConstraint?.constant ?? 200 : 0
        toolbarStackLeadingConstraint?.constant = 12 + max(sidebarWidth, nativeControlsInset)
        updateToolbarVisibility()
        needsLayout = true
    }

    private func updateToolbarVisibility() {
        let leading = toolbarStackLeadingConstraint?.constant ?? 12
        let width = min(bounds.width, window?.frame.width ?? bounds.width)
        let available = width - leading - 12
        // Keep navigation, layout and sorting available even at the smallest window size.
        let essential = 3 * CGFloat(26) + 2 * CGFloat(8)
            + sortKeyPopup.fittingSize.width + CGFloat(26) + 2 * CGFloat(12)
        sizeSlider.isHidden = available < essential + 128
        titleLabel.isHidden = available < essential + 220
        thumbnailProgressLabel.isHidden = thumbnailProgressLabel.stringValue.isEmpty
            || available < essential + 340
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
        let headerHeight = height > 0 ? height : Self.defaultToolbarHeight
        treeSidebar.reserveHeader(height: headerHeight)
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
        treeSidebar.onFolderExpansionChanged = { [weak self] url, expanded in
            self?.onFolderExpansionChanged?(url, expanded)
        }

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
            treeSidebar.topAnchor.constraint(equalTo: topAnchor),
            treeSidebar.bottomAnchor.constraint(equalTo: bottomAnchor),

            galleryScroll.leadingAnchor.constraint(equalTo: treeSidebar.trailingAnchor),
            galleryScroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            galleryScroll.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            galleryScroll.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        updateToolbarLeadingInset()
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

        refreshSizeSteps()
        if abs(sliderSize - thumbnailSize) > 1 {
            setSliderSize(thumbnailSize)
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
        let positions = [sidebarVisibleConstraint, sidebarHiddenConstraint].compactMap { $0 }
        NSLayoutConstraint.deactivate(positions)
        (visible ? sidebarVisibleConstraint : sidebarHiddenConstraint)?.isActive = true
        updateToolbarLeadingInset()
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

    /// Reports how many visible cells are still waiting for a thumbnail.
    ///
    /// `total` is the number of cells on screen: the readout is about what the user is looking at, not
    /// about the folder (whose size has nothing to do with how long the wait is).
    public func updateThumbnailProgress(loading: Int, total: Int) {
        guard loading > 0 else {
            thumbnailProgressLabel.isHidden = true
            thumbnailProgressLabel.stringValue = ""
            return
        }
        thumbnailProgressLabel.stringValue = "缩略图 \(max(0, total - loading)) / \(total)"
        thumbnailProgressLabel.toolTip = "正在载入缩略图，已完成 \(max(0, total - loading)) 张"
        updateToolbarVisibility()
    }

    /// The progress readout's text, or nil when it is hidden, for tests.
    var thumbnailProgressTextForTesting: String? {
        thumbnailProgressLabel.isHidden ? nil : thumbnailProgressLabel.stringValue
    }

    /// Recomputes the uniform grid's size levels for the current width and re-scales the slider.
    ///
    /// Cheap and idempotent, so it can run on every layout pass: it does nothing unless the mode or
    /// the width actually changed the list.
    public func refreshSizeSteps() {
        let levels = layoutKind == .uniformGrid
            ? GalleryLayout.uniformSizeLevels(containerWidth: galleryLayoutWidth)
            : []
        guard levels.count > 1 || sizeLevels.count > 1 || levels != sizeLevels else { return }
        sizeLevels = levels
        let reported = sliderSize
        let wasStepped = sizeSlider.allowsTickMarkValuesOnly
        let isStepped = levels.count > 1
        if isStepped {
            sizeSlider.minValue = 0
            sizeSlider.maxValue = Double(levels.count - 1)
            sizeSlider.numberOfTickMarks = levels.count
            sizeSlider.allowsTickMarkValuesOnly = true
        } else {
            sizeSlider.numberOfTickMarks = 0
            sizeSlider.allowsTickMarkValuesOnly = false
            sizeSlider.minValue = Double(GalleryLayout.minimumThumbnailSize)
            sizeSlider.maxValue = Double(GalleryLayout.maximumThumbnailSize)
        }
        // Snap to a level when the mode or the width changed, so the row fills exactly from the first
        // tick onwards. A drag in progress is not interrupted: the value is already a level's index.
        if wasStepped != isStepped || !isStepped { setSliderSize(sliderSize) }
        // The grid draws the size the slider is on, so a level the slider snapped to has to reach it.
        // A reflow only — no settle here: a window resize must not start decodes for every step.
        if sliderSize != reported {
            lastReportedSize = sliderSize
            onThumbnailSizeChanged?(sliderSize)
        }
    }

    /// The last size this view reported, so a snap is reported once.
    private var lastReportedSize: CGFloat?

    /// Puts the slider on the level nearest to `size` (or on the size itself when continuous).
    private func setSliderSize(_ size: CGFloat) {
        sliderSize = GalleryLayout.clampThumbnailSize(size)
        if sizeLevels.count > 1 {
            let level = GalleryLayout.nearestSizeLevel(to: sliderSize, in: sizeLevels)
            sliderSize = level
            let index = sizeLevels.firstIndex(of: level) ?? 0
            if sizeSlider.doubleValue != Double(index) { sizeSlider.doubleValue = Double(index) }
        } else if sizeSlider.doubleValue != Double(sliderSize) {
            sizeSlider.doubleValue = Double(sliderSize)
        }
    }

    public override func layout() {
        updateToolbarVisibility()
        super.layout()
        refreshSizeSteps()
    }

    @objc private func goBack() { onBack?() }
    @objc private func chooseUniform() { onLayoutChanged?(.uniformGrid) }
    @objc private func chooseAdaptive() { onLayoutChanged?(.adaptiveGrid) }

    @objc private func sliderMoved() {
        if sizeLevels.count > 1 {
            let index = min(max(Int(sizeSlider.doubleValue.rounded()), 0), sizeLevels.count - 1)
            sliderSize = sizeLevels[index]
        } else {
            sliderSize = GalleryLayout.clampThumbnailSize(CGFloat(sizeSlider.doubleValue))
        }
        lastReportedSize = sliderSize
        onThumbnailSizeChanged?(sliderSize)
    }

    /// Called when the slider's drag ends. The distinction matters: the grid reflows on every tick,
    /// but a sharper thumbnail is only requested once the user has stopped moving — otherwise every
    /// pixel of travel would start a decode.
    public func noteSliderDragEnded() {
        onThumbnailSizeSettled?(sliderSize)
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

/// The gallery's size slider, with a real end-of-drag signal.
///
/// `NSSliderCell` runs its own tracking loop inside `mouseDown`, so the control's `mouseUp` never
/// fires after a drag and there is no delegate for "the pointer came up". The loop *returns* from
/// `super.mouseDown`, and that is the drag's end.
///
/// This exists because nothing called `noteSliderDragEnded` at all: the whole settle path — the
/// debounce the spec asks for, `scheduleThumbnailResolution`, the sharper tier a larger slider is
/// supposed to request — was dead code. A drag reflowed the grid live and then never asked for a
/// sharper thumbnail, so the visible thumbnails stayed at whatever tier they happened to be decoded
/// at while the cells were being reflowed.
final class ThumbnailSizeSlider: NSSlider {
    var onTrackingEnded: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        onTrackingEnded?()
    }
}
