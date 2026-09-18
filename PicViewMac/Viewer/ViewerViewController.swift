import AppKit
import ImageIO

/// Owns one viewer: canvas, hover chrome, drawer, minimap, decode pipeline and
/// command handling. Hover UI lives inside this single window.
@MainActor
public final class ViewerViewController: NSViewController, ViewerCommandHandling {
    public let session = FolderSession()
    public let viewerState = ViewerState()

    public var onTitleChanged: ((String?) -> Void)?
    /// Reports the decoded descriptor so the window can apply the configured
    /// window-sizing policy (for example sizing the window to the image).
    public var onDescriptorAvailable: ((ImageDescriptor) -> Void)?

    private let rootView = ViewerRootView()
    private let emptyState = EmptyStateView()
    private let canvas = ImageCanvasView()
    private let toolDock = ViewerToolDockView()
    private let infoCard = ImageInfoCardView()
    private let bottomBar = BottomInfoBarView(style: .hud)
    private let drawer = ThumbnailDrawerView(style: .drawer)
    private let minimap = NavigatorView()
    private let errorLabel = NSTextField(labelWithString: "")

    private let coordinator: DecodeCoordinator
    /// Native-detail tiles: the backend that turns "the proxy is out of resolution here"
    /// into real source pixels (spec §4.1, §16).
    let nativeDetail: NativeDetailScheduler
    private var detailWorkItem: DispatchWorkItem?
    private var detailPlan: NativeTilePlan?
    private var detailSource: URL?
    /// Cached per source: opening a file to ask the question is cheap, but not per frame.
    private var detailCapability: [String: Bool] = [:]
    /// The decode a level upgrade has already started, so a second evaluation cannot start
    /// the same work again while it runs (ImageIO ignores cancellation, so a redundant
    /// start is not free — it is a second full decode).
    private var inFlightLevel: DecodeLevel?
    private let thumbnails: ThumbnailPipeline
    private let probe: DimensionProbing
    private(set) var thumbnailRequestCount = 0
    private let watcher = FolderWatcher()

    private var hover = HoverVisibilityModel()
    private var chromeTimer: Timer?
    private var animationTimer: Timer?
    private let clock = AnimationClock()
    private var drawerWidthConstraint: NSLayoutConstraint?
    // Canvas leading is switched when the drawer is pinned, so every consumer of
    // canvas bounds (fit, zoom, navigator, dock, info card) sees the real area.
    private var canvasLeadingToRoot: NSLayoutConstraint?
    private var canvasLeadingToDrawer: NSLayoutConstraint?
    private var infoCardHeightConstraint: NSLayoutConstraint?
    private var minimapSizeConstraints: [NSLayoutConstraint] = []
    private var isDrawerReservingSpace = false
    private var isInfoCardVisible = false
    private var infoCardSuppressed = false
    private var pendingDirection: NavigationDirection = .unknown
    private var onDemandFrameTask: Task<Void, Never>?
    /// Level of the bitmap currently published, so a resize can tell whether the
    /// canvas has outgrown it. Reset with the image.
    private var displayedLevel: DecodeLevel = .native
    private var resizeUpgradeWorkItem: DispatchWorkItem?
    /// True from the moment a decode for the current item starts until it publishes or
    /// fails. The empty state uses it to say "decoding" instead of blaming the folder.
    private var isDecodingCurrentItem = false

    public private(set) var settings = AppSettings.shared

    /// The decoder and thumbnail pipeline are injectable so tests can drive the
    /// real viewer with a counting or deliberately slow implementation.
    public init(decoder: ImageDecoding = ImageIODecoder(),
                thumbnails: ThumbnailPipeline = ThumbnailPipeline(),
                probe: DimensionProbing = DimensionProbe(),
                nativeDetail: NativeDetailScheduler = NativeDetailScheduler()) {
        // One probe instance is shared with the coordinator so the drawer's
        // oversized decision and the preload decision cannot disagree, and so both
        // reuse a single dimension cache.
        self.coordinator = DecodeCoordinator(decoder: decoder, probe: probe)
        self.thumbnails = thumbnails
        self.probe = probe
        self.nativeDetail = nativeDetail
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Test-facing view of decode work in flight.
    var coordinatorDiagnostics: CoordinatorDiagnostics {
        get async { CoordinatorDiagnostics(activeTaskCount: await coordinator.activeTaskCount) }
    }

    struct CoordinatorDiagnostics {
        let activeTaskCount: Int
    }

    /// Chrome views by name, for hit-testing and layering tests.
    var chromeViewsForTesting: [String: NSView] {
        ["bottomBar": bottomBar, "drawer": drawer, "minimap": minimap,
         "canvas": canvas, "emptyState": emptyState,
         "toolDock": toolDock, "infoCard": infoCard]
    }

    /// Chrome that participates in hover/idle visibility (the titlebar does not:
    /// it is AppKit's and always visible).
    static let hoverChromeNames: Set<String> = ["bottomBar", "drawer", "minimap", "toolDock"]
    /// Usable canvas width the window's minimum size must leave.
    static let minimumCanvasWidth: CGFloat = 320
    /// Breathing room between the tool dock and the canvas edges.
    static let dockCanvasMargin: CGFloat = 28

    /// Re-applies the current hover state without inventing pointer movement.
    func applyChromeVisibilityForTesting() {
        applyChromeVisibility()
    }

    /// The empty-state wording currently in use, or `nil` when it is hidden.
    var emptyStateReasonForTesting: EmptyStateView.Reason? {
        emptyState.isHidden ? nil : emptyState.reason
    }

    /// Sets the canvas viewport directly, for layout tests that need a specific
    /// zoom and focal point.
    var canvasViewportForTesting: ViewportState {
        get { canvas.viewport }
        set { canvas.viewport = newValue; viewerState.viewport = newValue }
    }

    /// Navigator internals, for diagnostics.
    func debugNavigatorReport() {
        print("DIAG   navigator hidden=\(minimap.isHidden) hasPreview=\(minimap.hasPreviewImage) "
            + "previewSize=\(minimap.previewPixelSize) generations=\(minimap.previewGenerationCount) "
            + "normalized=\(minimap.visibleNormalizedRect) hasPath=\(minimap.viewportOverlayLayer.path != nil) "
            + "bounds=\(minimap.bounds.size) canvasPixels=\(canvas.imagePixelSize)")
    }

    /// Reports the drawer's pinned state so the window can reflect it.
    public var onDrawerPinnedChanged: ((Bool) -> Void)?

    /// Opens or closes the drawer: the titlebar button and the ⇧⌘T command both land
    /// here, and the drawer itself no longer carries a pin control.
    public func setDrawerPinned(_ pinned: Bool) {
        let now = Date().timeIntervalSinceReferenceDate
        hover.setDrawerPinned(pinned, at: now)
        hover.update(at: now)
        applyChromeVisibility()
        onDrawerPinnedChanged?(hover.drawerPinned)
    }

    public func toggleDrawerPinned() {
        setDrawerPinned(!hover.drawerPinned)
    }

    /// Whether the drawer is currently held open.
    public var isDrawerPinned: Bool { hover.drawerPinned }

    func toggleDrawerPinForTesting() {
        toggleDrawerPinned()
    }

    public override func loadView() {
        rootView.frame = NSRect(x: 0, y: 0, width: 960, height: 680)
        rootView.wantsLayer = true
        let root = rootView
        view = root

        canvas.translatesAutoresizingMaskIntoConstraints = false
        toolDock.translatesAutoresizingMaskIntoConstraints = false
        infoCard.translatesAutoresizingMaskIntoConstraints = false
        bottomBar.translatesAutoresizingMaskIntoConstraints = false
        drawer.translatesAutoresizingMaskIntoConstraints = false
        minimap.translatesAutoresizingMaskIntoConstraints = false
        errorLabel.translatesAutoresizingMaskIntoConstraints = false

        errorLabel.font = .systemFont(ofSize: 12)
        errorLabel.textColor = .systemRed
        errorLabel.isHidden = true

        root.addSubview(canvas)
        root.addSubview(emptyState)
        root.addSubview(errorLabel)
        root.addSubview(bottomBar)
        root.addSubview(drawer)
        root.addSubview(minimap)
        root.addSubview(toolDock)
        root.addSubview(infoCard)

        let minimapWidth = minimap.widthAnchor.constraint(
            equalToConstant: NavigatorView.defaultSize.width)
        let minimapHeight = minimap.heightAnchor.constraint(
            equalToConstant: NavigatorView.defaultSize.height)
        minimapSizeConstraints = [minimapWidth, minimapHeight]

        let drawerWidth = drawer.widthAnchor.constraint(equalToConstant: ThumbnailDrawerView.minimumWidth)
        drawerWidthConstraint = drawerWidth
        let canvasLeadingToRoot = canvas.leadingAnchor.constraint(equalTo: root.leadingAnchor)
        let canvasLeadingToDrawer = canvas.leadingAnchor.constraint(equalTo: drawer.trailingAnchor)
        self.canvasLeadingToRoot = canvasLeadingToRoot
        self.canvasLeadingToDrawer = canvasLeadingToDrawer

        NSLayoutConstraint.activate([
            canvasLeadingToRoot,
            minimapWidth,
            minimapHeight,
            canvas.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            canvas.topAnchor.constraint(equalTo: root.topAnchor),
            canvas.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            emptyState.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            emptyState.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            emptyState.topAnchor.constraint(equalTo: root.topAnchor),
            emptyState.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            errorLabel.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            errorLabel.centerYAnchor.constraint(equalTo: root.centerYAnchor),

            // The bottom cluster is anchored to the canvas, so pinning the drawer
            // moves it with the image instead of leaving it off-centre.
            bottomBar.leadingAnchor.constraint(equalTo: canvas.leadingAnchor, constant: 14),
            bottomBar.bottomAnchor.constraint(equalTo: canvas.bottomAnchor, constant: -8),
            bottomBar.heightAnchor.constraint(equalToConstant: BottomInfoBarView.height),

            drawer.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            drawer.topAnchor.constraint(equalTo: root.topAnchor),
            drawer.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            drawerWidth,

            // Anchored by its trailing and bottom edges, so following the image
            // aspect grows the navigator up and to the left, never off the corner.
            minimap.trailingAnchor.constraint(equalTo: canvas.trailingAnchor, constant: -14),
            minimap.bottomAnchor.constraint(equalTo: canvas.bottomAnchor, constant: -34),

            toolDock.centerXAnchor.constraint(equalTo: canvas.centerXAnchor),
            toolDock.bottomAnchor.constraint(equalTo: canvas.bottomAnchor,
                                             constant: -ViewerToolDockView.bottomInset),

            infoCard.leadingAnchor.constraint(equalTo: canvas.leadingAnchor, constant: 14),
            infoCard.bottomAnchor.constraint(equalTo: bottomBar.topAnchor, constant: -8),
            infoCard.widthAnchor.constraint(lessThanOrEqualToConstant: ImageInfoCardView.maximumWidth),
        ])
        // The card grows with its content up to a fraction of the canvas.
        infoCardHeightConstraint = infoCard.heightAnchor.constraint(equalToConstant: 0)

        configureCallbacks()
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        session.onItemsChanged = { [weak self] in
            self?.rebuildDrawer()
            self?.refreshBottomBar()
        }
        session.onCurrentChanged = { [weak self] in
            self?.loadCurrentImage()
        }
        applySettings()
        NotificationCenter.default.addObserver(
            forName: AppSettings.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.applySettings() }
        }
    }

    public override func viewDidAppear() {
        super.viewDidAppear()
        refreshEmptyState()
        applyChromeVisibility()
        startChromeTimer()
        if let window = view.window {
            window.acceptsMouseMovedEvents = true
            applyAppearance()
        }
    }

    // MARK: - Wiring

    private func configureCallbacks() {
        // Pointer tracking lives on the root view alone, so hover works no matter
        // which subview is on top and hidden chrome cannot swallow it.
        rootView.onPointerMoved = { [weak self] point in
            self?.handlePointer(atRootPoint: point)
        }
        rootView.onPointerExited = { [weak self] in
            guard let self else { return }
            let now = Date().timeIntervalSinceReferenceDate
            self.hover.pointerExitedDrawer(at: now)
            self.hover.update(at: now)
            self.applyChromeVisibility()
        }

        emptyState.onOpenRequested = {
            NSApp.sendAction(#selector(AppDelegate.openDocument(_:)), to: nil, from: nil)
        }
        emptyState.onFilesDropped = { urls in
            AppEnvironment.shared.fileOpener.open(urls: urls)
        }

        canvas.onNavigate = { [weak self] delta in
            guard let self else { return }
            self.pendingDirection = delta > 0 ? .forward : .backward
            self.perform(delta > 0 ? .nextImage : .previousImage)
        }
        canvas.onViewportChange = { [weak self] viewport in
            guard let self else { return }
            self.viewerState.viewport = viewport
            self.refreshMinimap()
            self.refreshBottomBar()
            // Pan moves the tile window; it never re-evaluates the whole-image level.
            self.scheduleNativeDetailUpdate()
        }
        canvas.onZoomChanged = { [weak self] in
            guard let self else { return }
            self.hover.zoomActivity(at: Date().timeIntervalSinceReferenceDate)
            self.hover.setZoomedIn(self.canvas.viewport.isZoomedIn, at: Date().timeIntervalSinceReferenceDate)
            self.refreshMinimap()
            self.scheduleNativeDetailUpdate()
            // Zooming in is the other way a bitmap becomes undersampled (§9.5), so the
            // same debounced check runs here: sharpening past the 1.5× headroom costs
            // one bounded decode, which is why it waits for the gesture to settle.
            self.scheduleLevelUpgrade()
        }
        canvas.onPointerActivity = { [weak self] in
            guard let self else { return }
            let now = Date().timeIntervalSinceReferenceDate
            self.hover.pointerMoved(at: now)
        }
        canvas.onDoubleClickAction = { [weak self] in
            guard let self else { return }
            self.hover.setImmersive(!self.hover.immersive, at: Date().timeIntervalSinceReferenceDate)
            self.applyChromeVisibility()
        }
        canvas.onGeometryChange = { [weak self] in
            self?.scheduleLevelUpgrade()
            self?.scheduleNativeDetailUpdate()
        }
        Task { [weak self, nativeDetail] in
            await nativeDetail.setOnTile { [weak self] _ in
                Task { @MainActor in self?.nativeTileArrived() }
            }
        }

        toolDock.onCommand = { [weak self] command in
            self?.perform(command)
        }
        infoCard.onClose = { [weak self] in
            self?.setInfoCardVisible(false)
        }
        drawer.onSelect = { [weak self] index in
            guard let self else { return }
            self.pendingDirection = index > (self.session.currentIndex ?? 0) ? .forward : .backward
            self.session.select(index: index)
        }

        minimap.onCenterRequested = { [weak self] center in
            guard let self else { return }
            var viewport = self.canvas.viewport
            viewport.normalizedCenter = center
            viewport.clampCenter(imagePixels: self.canvas.imagePixelSize, viewPoints: self.canvas.bounds.size,
                                 backingScale: self.canvas.backingScale)
            self.canvas.viewport = viewport
        }

        viewerState.onImageChanged = { [weak self] in
            self?.refreshCanvas()
        }
        viewerState.onPlaybackChanged = { [weak self] in
            self?.refreshPlaybackChrome()
        }
    }

    public func applySettings() {
        let settings = AppSettings.shared
        self.settings = settings
        canvas.wheelMode = settings.wheelMode
        canvas.swipeMode = settings.swipeMode
        canvas.doubleClickMode = settings.doubleClickMode
        canvas.backgroundColor = settings.appearance.canvasBackground
        drawer.filenameMode = settings.thumbnailFilenames
        applyAppearance()
        refreshBottomBar()
    }

    private func applyAppearance() {
        guard let window = view.window else { return }
        // Follow System leaves `NSApp.appearance` alone.
        window.appearance = settings.appearance.nsAppearance
    }

    // MARK: - Folder session

    public func open(url: URL) {
        // Scanning resolves symlinks, so the directory is canonicalized once here
        // to keep the opened file and the scanned items speaking the same path
        // spelling (`/tmp` versus `/private/tmp`, symlinked folders).
        let directory = url.deletingLastPathComponent().resolvingSymlinksInPath()
        let canonicalURL = directory.appendingPathComponent(url.lastPathComponent)
        session.setDirectory(directory)
        watcher.onChange = { [weak self] in
            Task { @MainActor in await self?.rescanPreservingCurrent() }
        }
        watcher.start(watching: directory)
        Task { [weak self] in
            guard let self else { return }
            let scanner = FolderScanner()
            let items = (try? await scanner.scan(directory: directory)) ?? []
            let sorted = await self.sortedItems(items)
            self.session.setItems(sorted, preferredIdentity: FileIdentity(url: canonicalURL))
            self.session.select(url: canonicalURL)
        }
    }

    /// Dimension sorting needs a lazy dimension lookup; every other mode sorts
    /// the metadata already collected during the scan.
    private func sortedItems(_ items: [FolderItem]) async -> [FolderItem] {
        let settings = AppSettings.shared
        var working = items
        if settings.sortKey == .dimensions {
            working = await FolderScanner.fillDimensions(working)
        }
        return ImageSort.sort(working, by: settings.sortKey, direction: settings.sortDirection)
    }

    private func rescanPreservingCurrent() async {
        guard let directory = session.directory else { return }
        let scanner = FolderScanner()
        guard let items = try? await scanner.scan(directory: directory) else { return }
        let sorted = await sortedItems(items)
        // The delete-follow-up preference decides what survives a folder change:
        // "smart" follows the file the user was moved to, "stay in place" holds
        // the slot. Both are observable when a rescan re-sorts the list.
        switch settings.deleteFollowUp {
        case .smart:
            session.setItems(sorted, preferredIdentity: session.currentItem?.id)
        case .stayInPlace:
            session.setItems(sorted, preferredIndex: session.currentIndex)
        }
    }

    public func reloadWithCurrentSort() {
        Task { [weak self] in
            guard let self else { return }
            let identity = self.session.currentItem?.id
            let sorted = await self.sortedItems(self.session.items)
            self.session.setItems(sorted, preferredIdentity: identity)
        }
    }

    // MARK: - Decode

    private func loadCurrentImage() {
        guard let item = session.currentItem else {
            viewerState.clearForNewImage()
            viewerState.applyEmptyState()
            canvas.renderImage = nil
            errorLabel.isHidden = true
            onTitleChanged?(nil)
            refreshBottomBar()
            renderEmptyState()
            return
        }

        let index = session.currentIndex ?? 0
        let previous = index > 0 ? session.items[index - 1].url : nil
        let next = index + 1 < session.items.count ? session.items[index + 1].url : nil
        let direction = pendingDirection
        pendingDirection = .unknown

        viewerState.clearForNewImage()
        stopAnimation()
        // Tiles belong to one source: drop them with the image, and stop any pass still
        // reading the previous file.
        detailWorkItem?.cancel()
        detailWorkItem = nil
        detailPlan = nil
        detailSource = nil
        inFlightLevel = nil
        detailCapability.removeAll()
        publishNativeTiles([], residentKeys: [])
        Task { await self.nativeDetail.stopAndPurge() }
        // A pending resize upgrade belongs to the image being replaced.
        resizeUpgradeWorkItem?.cancel()
        resizeUpgradeWorkItem = nil
        displayedLevel = .native
        errorLabel.isHidden = true
        viewerState.errorMessage = nil
        onTitleChanged?(item.displayName)
        drawer.setCurrentIndex(index)
        drawer.scrollCurrentIntoView()
        refreshBottomBar()

        startDecode(url: item.url, previous: previous, next: next,
                    direction: direction, target: currentDecodeTarget())
    }

    /// The initial current-image requirement (spec §5.3, frozen by E1):
    /// `required = ceil(max(canvasW, canvasH) × backingScale × 1.5)`, snapped up to a
    /// bucket and capped at 8192. A canvas that has not been laid out yet has no
    /// requirement to state, so it asks for no budget and the decoder bounds the
    /// source at the ceiling instead; a later resize can only ever ask for a coarser
    /// level, never a finer one, which is why the fallback is the safe direction.
    private func currentDecodeTarget() -> DecodeTarget {
        let canvasPoints = canvas.bounds.size
        guard canvasPoints.width > 0, canvasPoints.height > 0 else { return DecodeTarget() }
        let required = DecodeBudget.requiredLongEdge(canvasPoints: canvasPoints,
                                                     backingScale: canvas.backingScale)
        let level = DecodeLevel.bucket(DecodeBudget.bucket(atLeast: required))
        return DecodeTarget(maxPixelSize: DecodeBudget.pixelBudget(for: level))
    }

    /// Starts a decode without touching the state that describes what is on screen:
    /// used both for a fresh load (which clears first) and for a level upgrade after
    /// a resize, where the current bitmap must keep rendering until the replacement
    /// arrives (§9.5: never blank the canvas).
    private func startDecode(url: URL, previous: URL?, next: URL?,
                             direction: NavigationDirection, target: DecodeTarget) {
        isDecodingCurrentItem = true
        if let size = session.currentItem?.pixelSize, size.width > 0 {
            inFlightLevel = DecodeBudget.level(
                sourceLongEdge: Int(max(size.width, size.height)), budget: target.maxPixelSize)
        }
        // Re-evaluate the placeholder now: the decode has started, so "no image yet"
        // means "decoding", not "nothing here".
        refreshEmptyState()
        Task { [weak self] in
            guard let self else { return }
            _ = await self.coordinator.show(item: url, previous: previous, next: next,
                                            direction: direction, target: target) { event in
                Task { @MainActor in self.handle(event: event) }
            }
        }
    }

    /// Whether the tile backend is the right answer for what is on screen right now.
    private func nativeDetailCoversVisibleRegion() -> Bool {
        guard !viewerState.isAnimated, let descriptor = viewerState.descriptor,
              let bitmap = viewerState.currentImage,
              let url = session.currentItem?.url,
              canServeNativeDetail(url) else { return false }
        let sourceSize = descriptor.displayPixelSize
        return NativeTilePlanner.needsNativeDetail(
            sourceLongEdge: Int(max(sourceSize.width, sourceSize.height)),
            proxyLongEdge: max(bitmap.width, bitmap.height),
            physicalScale: viewerState.viewport.zoomScale * canvas.backingScale)
    }

    /// Whether the tile backend can read this source (PNG, 8-bit, not interlaced). Asked
    /// once per file.
    private func canServeNativeDetail(_ url: URL) -> Bool {
        if let known = detailCapability[url.path] { return known }
        let answer = NativeTileCapability.canServe(url)
        detailCapability[url.path] = answer
        return answer
    }

    /// A level is "already coming" when the bitmap on screen is at least as sharp, or when
    /// a decode for it is in flight. Both cases must not start another decode: the candidate
    /// would either be redundant or a duplicate of work already running.
    private func isLevelAlreadyComing(_ candidate: DecodeLevel) -> Bool {
        if !ResizeUpgradePolicy.isCoarser(candidate, than: displayedLevel) { return true }
        if let inFlightLevel, !ResizeUpgradePolicy.isCoarser(candidate, than: inFlightLevel) {
            return true
        }
        return false
    }

    // MARK: - Native detail (spec §4.1)

    /// Waits for the gesture to settle before asking for tiles: a pass is a full traversal
    /// of the compressed stream, so it must not start for a viewport that is still moving.
    private func scheduleNativeDetailUpdate() {
        detailWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.updateNativeDetail() }
        detailWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22, execute: work)
    }

    /// Recomputes what the viewport needs at native resolution and asks the backend for it.
    private func updateNativeDetail() {
        detailWorkItem = nil
        guard let item = session.currentItem, let descriptor = viewerState.descriptor,
              let bitmap = viewerState.currentImage else {
            publishNativeTiles([], residentKeys: [])
            return
        }
        let sourceSize = descriptor.displayPixelSize
        let sourceLongEdge = Int(max(sourceSize.width, sourceSize.height))
        let proxyLongEdge = max(bitmap.width, bitmap.height)
        let physicalScale = viewerState.viewport.zoomScale * canvas.backingScale

        guard !viewerState.isAnimated,
              canServeNativeDetail(item.url),
              NativeTilePlanner.needsNativeDetail(sourceLongEdge: sourceLongEdge,
                                                  proxyLongEdge: proxyLongEdge,
                                                  physicalScale: physicalScale) else {
            // The proxy resolves everything on screen: drop the tiles and their memory
            // rather than keep a cache the viewport cannot use.
            detailPlan = nil
            detailSource = nil
            publishNativeTiles([], residentKeys: [])
            Task { await self.nativeDetail.stopAndPurge() }
            return
        }

        let visible = NativeTilePlanner.visibleSourceRect(viewport: viewerState.viewport,
                                                          sourcePixelSize: sourceSize,
                                                          viewSize: canvas.bounds.size)
        // Warm plan instead of a one-tile ring: one viewport in each direction, clamped by the
        // CPU tile budget. The sweep (results/warm-strategy-sweep.txt) is what sets the budget —
        // measured, the full nine-grid is 3.38 GiB at physicalScale 0.2 and 150 MiB at 1.0.
        // Where the viewport is travelling, in source space: the tiles on that side are the ones
        // about to enter, so they are ordered first. Derived from the visible rectangle itself, so
        // there is no view-to-source sign ambiguity to get wrong.
        let hint = WarmAreaPolicy.directionHint(from: lastDetailVisibleRect, to: visible)
        lastDetailVisibleRect = visible
        lastDetailDirectionHint = hint
        guard let warmPlan = WarmAreaPolicy.plan(visible: visible, sourcePixelSize: sourceSize,
                                                 tileSize: nativeDetailTileSize,
                                                 cpuBudgetBytes: nativeDetailCPUBudgetBytes,
                                                 margin: WarmAreaPolicy.requestedMargin,
                                                 directionHint: hint) else {
            publishNativeTiles([], residentKeys: [])
            return
        }
        nativeDetailClampedByBudget = warmPlan.clampedByBudget
        // Tiles are minified at the low end of the native-detail range (measured threshold ≈ 0.2),
        // where the D-series mipmap argument applies; magnified tiles skip the chain, which also
        // keeps their upload out of the main thread's way.
        canvas.setTileMipmapsEnabled(physicalScale < 1.0)
        let plan = warmPlan.plan
        detailPlan = plan
        detailSource = item.url
        // Keep what is resident for the *new* plan: publishing empty with an empty resident set here
        // trimmed every texture on each plan update, so a pan re-uploaded tiles that were already on
        // the GPU (measured: 18 uploads for a half-viewport pan whose tiles were all warm).
        publishNativeTiles([], residentKeys: residentKeysForTesting(plan: plan, source: item.url))
        warmTileCount = 0
        let url = item.url
        Task { [weak self] in
            guard let self else { return }
            await self.nativeDetail.request(plan: plan, source: url,
                                            colorSpace: self.viewerState.currentImage?.colorSpace,
                                            orientation: SourceOrientation(
                                                self.viewerState.descriptor?.orientation ?? .up))
            await self.publishCachedTiles(for: plan, source: url)
        }
    }

    /// Publishes what the viewport can use right now — cached visible tiles, so a pan back to a
    /// visited region is sharp immediately — and hands the rest of the plan to the renderer's
    /// background uploader.
    private func publishCachedTiles(for plan: NativeTilePlan, source: URL) async {
        await refreshPublishedSets(for: plan, source: source)
    }

    /// The three sets, explicitly: visible (drawn), warm (resident, not drawn), and the union the
    /// renderer trims its texture cache against. Keeping them separate is the whole point — the
    /// previous version published visible+warm as the draw list *and* computed the warm set as the
    /// difference against that same list, which made it empty and left the background uploader
    /// with nothing to do.
    private func refreshPublishedSets(for plan: NativeTilePlan, source: URL) async {
        let started = Date()
        let visible = await nativeDetail.cachedVisibleTiles(for: plan, source: source)
        let warm = await nativeDetail.cachedWarmTiles(for: plan, source: source)
        let residentKeys = await nativeDetail.residentKeys(for: plan, source: source)
        await MainActor.run {
            self.publicationStats.publicationRuns += 1
            self.publicationStats.visibleTilesMaterialized += visible.count
            self.publicationStats.warmTilesMaterialized += warm.count
            let mainStarted = Date()
            self.publishNativeTiles(visible, residentKeys: residentKeys)
            // Only the tiles that became warm since the last publication: re-offering the whole warm
            // set every time is what made the pass quadratic, and the uploader is the only consumer.
            let newWarm = warm.filter { !self.submittedWarmKeys.contains($0.key) }
            if !newWarm.isEmpty {
                self.canvas.warmTileTextures(newWarm)
                self.publicationStats.warmSubmissionCount += newWarm.count
            }
            self.submittedWarmKeys = Set(warm.map { $0.key })
            self.warmTileCount = warm.count
            self.publicationStats.mainThreadPublicationMS +=
                Date().timeIntervalSince(mainStarted) * 1000
            self.publicationStats.publicationDurationMS +=
                Date().timeIntervalSince(started) * 1000
        }
    }

    private func publishNativeTiles(_ tiles: [NativeTile], residentKeys: Set<NativeTileKey>) {
        if tiles.isEmpty { submittedWarmKeys = [] }
        canvas.nativeTiles = tiles
        // Trim against what is *resident*, not against what is drawn: trimming to the draw set
        // deleted the warm textures the background uploader had just created.
        canvas.trimTileTextures(keeping: residentKeys)
        nativeDetailTileCount = tiles.count
    }

    /// Hands the warm (not yet visible) tiles to the renderer's background uploader, so a pan onto
    /// them is a draw rather than an upload. Bounded by the GPU budget the renderer was given.
    /// Tiles currently drawn, for the acceptance runner and the tests.
    private(set) var nativeDetailTileCount = 0

    /// The tiles the canvas is holding, for tests that need to inspect their pixels.
    var canvasNativeTilesForTesting: [NativeTile] { canvas.nativeTiles }

    /// The canvas itself, for measurements that map view points to source pixels.
    var canvasViewForTesting: ImageCanvasView { canvas }

    /// Measured budget for decoded tiles (results/warm-strategy-sweep.txt): at 0.5 the full
    /// nine-grid is 580 MiB and at 0.2 it is 3.38 GiB, so 256 MiB keeps the nine-grid at 1.0 and
    /// 2.0 while clamping it at 0.5 and 0.2 — where the viewport itself is already hundreds of
    /// megabytes and visible tiles win unconditionally.
    /// The warm-area budget *is* the cache's budget — one number, not two. A policy planning for
    /// 256 MiB while the cache evicted at 192 MiB promised residency it could not deliver.
    var nativeDetailCPUBudgetBytes: Int { nativeDetail.cacheCostLimit }

    /// Set when the last warm plan was clamped by the budget, for tests and the acceptance runner.
    private(set) var nativeDetailClampedByBudget = false

    /// The plan's keys, synchronously: the cache is lock-protected, so the trim target can be
    /// computed without awaiting the scheduler.
    func residentKeysForTesting(plan: NativeTilePlan, source: URL) -> Set<NativeTileKey> {
        Set(plan.allCoordinates.map {
            NativeTileKey(sourcePath: source.path, tileSize: plan.tileSize, x: $0.x, y: $0.y)
        })
    }

    /// The visible source rectangle the last plan was built from, for the direction hint.
    private var lastDetailVisibleRect: CGRect?

    /// The last plan and the hint it was ordered with, for tests.
    var detailPlanForTesting: (plan: NativeTilePlan, hint: CGVector)? {
        guard let detailPlan else { return nil }
        return (detailPlan, lastDetailDirectionHint)
    }

    private(set) var lastDetailDirectionHint: CGVector = .zero

    /// Tiles resident in the backend's cache, synchronously readable for instrumentation.
    /// Real counts for tests and the acceptance runner. The previous version reported the
    /// *published* tile count as the cache count, which hid the difference between drawn and
    /// resident tiles exactly when it mattered.
    struct NativeDetailDiagnostics: Equatable {
        var visibleTiles = 0
        var warmTiles = 0
        var cpuCacheTiles = 0
        var cpuCacheBytes = 0
        var cpuPinnedTiles = 0
        var cpuBudgetBytes = 0
        var gpuResidentTiles = 0
        var gpuWarmTiles = 0
        var gpuTextureBytes = 0
        var gpuBudgetBytes = 0
        /// Total tile uploads, both callers.
        var gpuUploads = 0
        /// Hits on the draw path. Background warm hits are counted separately: mixing them made a
        /// pan look like it had more foreground hits than it did.
        var gpuCacheHits = 0
        var gpuBackgroundHits = 0
        var gpuBackgroundUploads = 0
        /// Uploads on the draw path — the ones the user could wait for.
        var gpuSynchronousUploads = 0
        var gpuInFlight = 0
        var gpuStaleDiscarded = 0
        /// Uploads thrown away because their tile left the plan, and queue entries dropped before
        /// they became textures.
        var gpuStalePlanDiscarded = 0
        var gpuStalePlanSkipped = 0
        /// Textures physically created, entries inserted, and creations dropped as duplicates.
        var gpuPhysicalCreations = 0
        var gpuResidentInsertions = 0
        var gpuDuplicateDiscarded = 0
        var gpuDuplicateWarmSkips = 0
        /// Textures created, counted at creation: the dedup metric that cannot be hidden by a
        /// discarded duplicate.
        var gpuTextureCreations = 0
        var gpuProtectedTiles = 0
        /// Invariant: the GPU LRU mentions each resident entry exactly once.
        var gpuLruConsistent = true
        var clampedByBudget = false
    }

    private(set) var warmTileCount = 0

    /// What one publication costs. The counters exist because "one publication per decoded tile"
    /// makes the pass quadratic: every arrival walks the whole warm set again, and every arrival
    /// retains a fresh copy of the tile arrays while it waits for the main thread.
    struct PublicationDiagnostics: Equatable {
        var tileArrivals = 0
        var publicationRequests = 0
        var publicationRuns = 0
        var publicationCoalesced = 0
        var visibleTilesMaterialized = 0
        var warmTilesMaterialized = 0
        var warmSubmissionCount = 0
        var pendingPublications = 0
        var maxPendingPublications = 0
        var publicationDurationMS = 0.0
        var mainThreadPublicationMS = 0.0
    }

    private(set) var publicationStats = PublicationDiagnostics()
    /// Warm tiles already handed to the uploader, so the next publication submits only the delta.
    private var submittedWarmKeys: Set<NativeTileKey> = []
    private var publicationScheduled = false
    private var publicationDirty = false

    /// How long arrivals are collected before one publication runs. Zero means one run-loop turn:
    /// the progressive display must not be delayed by a debounce.
    var publicationCoalescingInterval: TimeInterval = 0

    /// Measurement switch: with coalescing off, every arrival publishes on its own, which is the
    /// behaviour the coalescing exists to replace. The benchmark turns it off to measure both paths
    /// on one binary.
    var publicationCoalescingEnabled = true

    func publicationDiagnostics() -> PublicationDiagnostics { publicationStats }

    func resetPublicationDiagnostics() {
        publicationStats = PublicationDiagnostics()
    }

    /// Tiles in the backend's CPU cache, as opposed to tiles currently drawn.
    var nativeDetailCacheCountForTesting: Int { nativeDetail.cache.count }

    func nativeDetailDiagnostics() -> NativeDetailDiagnostics {
        var report = NativeDetailDiagnostics()
        report.visibleTiles = nativeDetailTileCount
        report.warmTiles = warmTileCount
        // The cache is a lock-protected class, so its occupancy is readable without awaiting the
        // scheduler — which matters for diagnostics that must not suspend.
        report.cpuCacheTiles = nativeDetail.cache.count
        report.cpuCacheBytes = nativeDetail.cache.byteCount
        report.cpuPinnedTiles = nativeDetail.cache.pinnedKeys.count
        report.cpuBudgetBytes = nativeDetail.cacheCostLimit
        let gpu = canvas.tileTextureDiagnostics()
        report.gpuResidentTiles = gpu.resident
        report.gpuWarmTiles = max(0, gpu.resident - nativeDetailTileCount)
        report.gpuTextureBytes = gpu.bytes
        report.gpuBudgetBytes = gpu.budget
        report.gpuUploads = gpu.foregroundUploads + gpu.backgroundUploads
        report.gpuCacheHits = gpu.foregroundHits
        report.gpuBackgroundHits = gpu.backgroundHits
        report.gpuBackgroundUploads = gpu.backgroundUploads
        report.gpuSynchronousUploads = gpu.foregroundUploads
        report.gpuInFlight = gpu.inFlight
        report.gpuStaleDiscarded = gpu.staleVariantDiscarded
        report.gpuStalePlanDiscarded = gpu.stalePlanDiscarded
        report.gpuStalePlanSkipped = gpu.stalePlanSkipped
        report.gpuPhysicalCreations = gpu.textureCreations
        report.gpuResidentInsertions = gpu.residentInsertions
        report.gpuDuplicateDiscarded = gpu.duplicateDiscarded
        report.gpuDuplicateWarmSkips = gpu.duplicateWarmSkips
        report.gpuTextureCreations = gpu.textureCreations
        report.gpuProtectedTiles = gpu.protectedTiles
        report.gpuLruConsistent = gpu.lruIsConsistent
        report.clampedByBudget = nativeDetailClampedByBudget
        return report
    }

    private var nativeDetailTileSize: Int { 512 }

    // MARK: - Level upgrades (spec §9.5)

    /// Debounced: a resize or a zoom that crosses a bucket boundary costs a full
    /// bounded decode, so it only starts once the gesture has settled, only when
    /// nobody is dragging, and only when the bitmap on screen is undersampled for
    /// the current geometry *and* zoom.
    private func scheduleLevelUpgrade() {
        resizeUpgradeWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.upgradeLevelForCurrentGeometry() }
        resizeUpgradeWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + ResizeUpgradePolicy.debounce, execute: work)
    }

    private func upgradeLevelForCurrentGeometry() {
        resizeUpgradeWorkItem = nil
        guard let item = session.currentItem, let descriptor = viewerState.descriptor else { return }
        // Still moving: wait for the geometry to settle instead of starting a decode
        // the next resize would invalidate.
        guard !canvas.isInteracting else {
            scheduleLevelUpgrade()
            return
        }
        // Animation frames are decoded outside the budget, so a level upgrade would
        // only fight the frame clock.
        guard !viewerState.isAnimated else { return }

        let level = ResizeUpgradePolicy.level(
            current: displayedLevel,
            sourcePixelSize: descriptor.pixelSize,
            canvasPoints: canvas.bounds.size,
            backingScale: canvas.backingScale,
            zoomScale: viewerState.viewport.zoomScale,
            quarterTurns: viewerState.viewport.normalizedQuarterTurns,
            isInteracting: false
        )
        guard let level else { return }
        // When the native-detail backend is serving this viewport, a coarser whole-image
        // level would be a second full traversal of the same stream for pixels the tiles
        // already deliver at higher quality. The proxy stays as the base layer and the
        // tiles sharpen the visible region; the level path resumes as soon as the view no
        // longer needs native detail (zoom out, or an unsupported format).
        if nativeDetailCoversVisibleRegion() { return }
        guard !isLevelAlreadyComing(level) else { return }
        inFlightLevel = level
        let index = session.currentIndex ?? 0
        startDecode(url: item.url,
                    previous: index > 0 ? session.items[index - 1].url : nil,
                    next: index + 1 < session.items.count ? session.items[index + 1].url : nil,
                    direction: .unknown,
                    target: DecodeTarget(maxPixelSize: DecodeBudget.pixelBudget(for: level)))
    }

    private func handle(event: DecodeEvent) {
        switch event {
        case let .head(head):
            viewerState.apply(head: head)
            displayedLevel = head.level
            inFlightLevel = nil
            isDecodingCurrentItem = false
            errorLabel.isHidden = true
            onDescriptorAvailable?(head.descriptor)
            // Once per displayed image, as the navigator's own documentation states.
            regenerateNavigatorPreview()
            if head.descriptor.animated {
                startAnimation(descriptor: head.descriptor, autoplay: settings.autoplayAnimations)
            }
        case let .frame(frame):
            // Streamed frames are animation frames. A multi-page document keeps its
            // first page until the user navigates.
            if viewerState.isAnimated {
                viewerState.apply(frame: frame)
            }
        case let .failure(message):
            isDecodingCurrentItem = false
            inFlightLevel = nil
            viewerState.apply(error: message)
            errorLabel.stringValue = message
            errorLabel.isHidden = message.isEmpty
            refreshEmptyState()
        }
    }

    private func renderEmptyState() {
        canvas.renderImage = nil
        refreshEmptyState()
    }

    /// Shows the welcome/empty UI only when there is genuinely nothing to show:
    /// no decoded image and no error to explain why. A decode in flight is its own
    /// state — an oversized source takes ~16 s, and "this folder has no supported
    /// images" is a different, wrong claim during that window (spec §12). When the
    /// previous image is still on screen there is nothing to explain: it stays until
    /// the replacement is ready.
    private func refreshEmptyState() {
        let hasImage = viewerState.currentImage != nil
        let hasError = !(viewerState.errorMessage ?? "").isEmpty
        guard !hasImage, !hasError else {
            setEmptyState(visible: false)
            return
        }
        if isDecodingCurrentItem {
            guard canvas.renderImage == nil else {
                setEmptyState(visible: false)
                return
            }
            emptyState.apply(reason: .loading)
            setEmptyState(visible: true)
            return
        }
        emptyState.apply(reason: session.directory == nil ? .noImageOpened : .folderHasNoImages)
        setEmptyState(visible: true)
    }

    /// Called by the backend when a tile is decoded.
    ///
    /// One publication per arrival is quadratic: a publication walks the whole warm set, so a pass
    /// of N tiles does about N²/2 tile visits. Arrivals that land while a publication is already
    /// scheduled are absorbed by it, and the state is re-read after it completes, so the display is
    /// still progressive — the first tiles appear while the pass is running, not after it.
    func nativeTileArrived() {
        guard detailPlan != nil, detailSource != nil else { return }
        publicationStats.tileArrivals += 1
        publicationDirty = true
        schedulePublication()
    }

    private func schedulePublication() {
        guard publicationCoalescingEnabled else {
            publicationStats.publicationRequests += 1
            publicationStats.pendingPublications += 1
            publicationStats.maxPendingPublications = max(publicationStats.maxPendingPublications,
                                                         publicationStats.pendingPublications)
            publicationStats.pendingPublications -= 1
            runScheduledPublication()
            return
        }
        guard !publicationScheduled else {
            publicationStats.publicationCoalesced += 1
            return
        }
        publicationScheduled = true
        publicationStats.publicationRequests += 1
        publicationStats.pendingPublications += 1
        publicationStats.maxPendingPublications = max(publicationStats.maxPendingPublications,
                                                     publicationStats.pendingPublications)
        let interval = publicationCoalescingInterval
        let run: () -> Void = { [weak self] in self?.runScheduledPublication() }
        if interval > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + interval, execute: run)
        } else {
            DispatchQueue.main.async(execute: run)
        }
    }

    private func runScheduledPublication() {
        guard let plan = detailPlan, let url = detailSource else {
            finishPublication()
            return
        }
        publicationDirty = false
        Task { [weak self] in
            guard let self else { return }
            await self.refreshPublishedSets(for: plan, source: url)
            self.finishPublication()
        }
    }

    private func finishPublication() {
        guard publicationCoalescingEnabled else { return }
        publicationScheduled = false
        publicationStats.pendingPublications = max(0, publicationStats.pendingPublications - 1)
        // Arrivals that landed while this publication ran are published now, in one more pass.
        if publicationDirty { schedulePublication() }
    }

    private func setEmptyState(visible: Bool) {
        emptyState.isHidden = !visible
        emptyState.alphaValue = visible ? 1 : 0
    }

    private func refreshCanvas() {
        // Publish pixels and geometry together: the bitmap may be a bounded proxy,
        // so the descriptor is what tells the canvas how large the source is.
        if let bitmap = viewerState.currentImage, let descriptor = viewerState.descriptor {
            canvas.renderImage = RenderImage(bitmap: bitmap, descriptor: descriptor)
        } else {
            canvas.renderImage = nil
        }
        canvas.refit()
        if viewerState.viewport.zoomScale == 1 || viewerState.currentImage == nil {
            canvas.setZoomToFit()
        }
        viewerState.viewport = canvas.viewport
        refreshEmptyState()
        // Fixed chrome (dock, bottom bar) follows the presence of an image, so it
        // must be re-evaluated when the image changes rather than only on the next
        // pointer event.
        applyChromeVisibility()
        // `regenerateNavigatorPreview()` is deliberately NOT called here: this runs for
        // every animation frame, and rebuilding a navigator preview (plus its layout
        // pass) per frame starved the display cycle — measured, only 54 of 81 published
        // frames were ever drawn. It runs when the image changes instead, which is what
        // its own documentation already promised.
        refreshMinimap()
        refreshBottomBar()
    }

    // MARK: - Animation

    private func startAnimation(descriptor: ImageDescriptor, autoplay: Bool) {
        let totalPlays: Int?
        switch settings.animationLoop {
        case .followSource:
            totalPlays = descriptor.loopCount == 0 ? nil : descriptor.loopCount
        case .once:
            totalPlays = 1
        case .infinite:
            totalPlays = nil
        }
        clock.start(schedule: AnimationClock.Schedule(durations: descriptor.frameDurations,
                                                      totalPlays: totalPlays),
                    at: Date().timeIntervalSinceReferenceDate)
        viewerState.playback = autoplay ? .playing : .paused
        startAnimationTimer()
        refreshPlaybackChrome()
    }

    private func stopAnimation() {
        clock.stop()
        animationTimer?.invalidate()
        animationTimer = nil
        onDemandFrameTask?.cancel()
        onDemandFrameTask = nil
    }

    private func startAnimationTimer() {
        animationTimer?.invalidate()
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.animationTick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        animationTimer = timer
    }

    private func animationTick() {
        guard viewerState.playback == .playing, let descriptor = viewerState.descriptor else { return }
        let now = Date().timeIntervalSinceReferenceDate
        guard let index = clock.tick(at: now) else { return }
        requestFrame(index: index, descriptor: descriptor)
    }

    private func requestFrame(index: Int, descriptor: ImageDescriptor) {
        guard let url = descriptor.sourceURL as URL? else { return }
        // One decode at a time. Cancelling an in-flight frame decode throws the work
        // away (ImageIO cannot abort mid-stream) and the next tick starts another, so
        // the old code measured 195 decodes for 81 published frames. Skipping the tick
        // instead keeps playback at the rate the decoder can actually sustain.
        if let inFlight = onDemandFrameTask, !inFlight.isCancelled { return }
        onDemandFrameTask = Task { [weak self] in
            guard let self else { return }
            let decoder = ImageIODecoder()
            let frame = try? await decoder.decodeFrame(url, index: index)
            await MainActor.run {
                if let frame, !Task.isCancelled { self.viewerState.apply(frame: frame) }
                self.onDemandFrameTask = nil
            }
        }
    }

    private func refreshPlaybackChrome() {
        toolDock.setAnimated(viewerState.isAnimated, isPlaying: viewerState.playback == .playing)
        refreshInfoCard()
    }

    // MARK: - Drawer

    private func rebuildDrawer() {
        // A drawer rebuild never touches the canvas frame or zoom: it only
        // overlays an existing region, and rows are virtualized.
        drawer.thumbnailProvider = { [weak self] item in self?.thumbnailCache[item.url] }
        drawer.onThumbnailNeeded = { [weak self] index, item in
            self?.requestThumbnail(at: index, for: item)
        }
        drawer.rebuild(items: session.items, currentIndex: session.currentIndex)
    }

    private func requestThumbnail(at index: Int, for item: FolderItem) {
        guard inFlightThumbnails[item.url] == nil, thumbnailCache[item.url] == nil else { return }
        inFlightThumbnails[item.url] = true
        thumbnailRequestCount += 1
        Task { [weak self] in
            guard let self else { return }
            defer { self.inFlightThumbnails[item.url] = nil }
            // `nil` leaves the cell as a placeholder: an oversized neighbour is not
            // worth a full-stream decode for a 300 px cell.
            guard let image = await self.thumbnailImage(for: item) else { return }
            self.thumbnailCache[item.url] = image
            self.drawer.updateThumbnail(at: index, image: image)
        }
    }

    /// Row size for a drawer cell thumbnail.
    static let drawerThumbnailPixelSize = 300

    /// Where a drawer cell's thumbnail comes from.
    ///
    /// The item on screen is served from the bitmap already decoded for the canvas:
    /// re-opening the source for its own cell would re-read the entire compressed
    /// stream (measured 18.7–19.9 s for the investigation image) to fill a cell a few
    /// dozen points wide. Non-current items keep the file-based pipeline, except
    /// oversized ones, which stay placeholders — a 300 px thumbnail of such a file
    /// costs the same whole-stream decode, and a drawer full of them would start one
    /// per visible row.
    /// Internal rather than private so the policy can be tested without a laid-out
    /// drawer: a windowless test never creates cells, so it would never issue a
    /// thumbnail request and could "pass" while proving nothing.
    func thumbnailImage(for item: FolderItem) async -> CGImage? {
        if item.url == session.currentItem?.url, let bitmap = viewerState.currentImage {
            return await thumbnails.preview(from: bitmap, maxPixelSize: Self.drawerThumbnailPixelSize)
        }
        if await probe.isOversized(item.url) { return nil }
        return try? await thumbnails.thumbnail(for: item.url, maxPixelSize: Self.drawerThumbnailPixelSize)
    }

    private var thumbnailCache: [URL: CGImage] = [:]
    private var inFlightThumbnails: [URL: Bool] = [:]

    // MARK: - Chrome visibility

    private func startChromeTimer() {
        chromeTimer?.invalidate()
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tickChrome() }
        }
        RunLoop.main.add(timer, forMode: .common)
        chromeTimer = timer
    }

    private func tickChrome() {
        guard isViewLoaded else { return }
        if hover.update(at: Date().timeIntervalSinceReferenceDate) {
            applyChromeVisibility()
        }
    }

    private func applyChromeVisibility() {
        let snapshot = hover.snapshot
        let immersive = hover.immersive
        // The tool dock is fixed chrome while a viewer is usable; immersive mode
        // takes the overlay chrome away.
        setChrome(toolDock, visible: !immersive && viewerState.currentImage != nil)
        setChrome(bottomBar, visible: !immersive && viewerState.currentImage != nil)
        setChrome(drawer, visible: snapshot.drawer && !immersive)
        setChrome(minimap, visible: snapshot.minimap && !immersive)
        setChrome(infoCard, visible: !immersive && isInfoCardVisible)
        if immersive { infoCardSuppressed = true } else if infoCardSuppressed {
            // Leaving immersive mode restores whatever the user had open.
            infoCardSuppressed = false
        }
        applyDrawerLayout()
    }

    /// Switches the canvas between "full width" and "right of the drawer" and
    /// re-fits around the new area. Because every consumer reads canvas bounds,
    /// nothing else needs to know about the drawer.
    private func applyDrawerLayout() {
        let pinned = hover.drawerPinned
        guard pinned != isDrawerReservingSpace else { return }
        isDrawerReservingSpace = pinned

        // Keep the user's focal point across the re-layout.
        let previousCenter = canvas.viewport.normalizedCenter
        let wasAtFit = canvas.viewport.isAtFit

        canvasLeadingToRoot?.isActive = !pinned
        canvasLeadingToDrawer?.isActive = pinned
        // The canvas minimum has to fit the tool dock: a pinned drawer in a narrow
        // window would otherwise leave a canvas narrower than the dock, which then
        // overflows it and draws across the sidebar.
        let dockWidth = toolDock.fittingSize.width
        let minimumCanvas = max(Self.minimumCanvasWidth, dockWidth + Self.dockCanvasMargin)
        (view.window as? ViewerWindow)?.applyMinimumSize(drawerWidth: pinned ? currentDrawerWidth : 0,
                                                        minimumCanvasWidth: minimumCanvas)
        view.layoutSubtreeIfNeeded()

        var viewport = canvas.viewport
        viewport.fitScale = ViewportState.fitScale(imagePixels: canvas.imagePixelSize,
                                                   viewPoints: canvas.bounds.size)
        if wasAtFit {
            // Fit stays Fit, now measured against the smaller area.
            viewport.zoomScale = viewport.fitScale
            viewport.normalizedCenter = CGPoint(x: 0.5, y: 0.5)
        } else {
            // A manual zoom level is preserved; only its clamping is re-evaluated.
            viewport.normalizedCenter = previousCenter
            viewport.clampCenter(imagePixels: canvas.imagePixelSize,
                                 viewPoints: canvas.bounds.size, backingScale: canvas.backingScale)
        }
        canvas.viewport = viewport
    }

    /// Fade in, or fade out and then leave the hit-testing hierarchy. Leaving
    /// `isHidden = false` with `alphaValue = 0` is what made a hidden drawer keep
    /// swallowing pointer events across its whole width.
    private func setChrome(_ chrome: NSView, visible: Bool) {
        let duration = AccessibilityAppearance.chromeFadeDuration
        if visible {
            chrome.isHidden = false
            guard duration > 0, chrome.alphaValue < 1 else {
                chrome.alphaValue = 1
                return
            }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = duration
                chrome.animator().alphaValue = 1
            }
        } else {
            guard duration > 0, chrome.alphaValue > 0 else {
                chrome.alphaValue = 0
                chrome.isHidden = true
                return
            }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = duration
                chrome.animator().alphaValue = 0
            }
            // Hiding must not depend on the animation callback: it does not run
            // when the window is off screen or the animation is coalesced, which
            // would leave a transparent-but-interactive surface behind. A timed
            // fallback guarantees the surface leaves the hierarchy.
            let hideDeadline = duration + 0.05
            DispatchQueue.main.asyncAfter(deadline: .now() + hideDeadline) { [weak chrome] in
                MainActor.assumeIsolated {
                    // A show may have started in the meantime; only hide if the
                    // surface is still meant to be hidden.
                    guard let chrome, chrome.alphaValue < 0.01 else { return }
                    chrome.isHidden = true
                }
            }
        }
    }

    // MARK: - Pointer zones

    /// Geometry of the hover regions, derived from the live layout so tests and
    /// the app agree on what "the left edge" means.
    var zoneGeometry: ViewerZoneGeometry {
        ViewerZoneGeometry(topBarHeight: 0,
                           hotZoneWidth: ThumbnailDrawerView.hotZoneWidth,
                           drawerWidth: drawerWidthConstraint?.constant ?? ThumbnailDrawerView.minimumWidth)
    }

    /// Drawer hit region in root coordinates. A pinned drawer owns exactly the
    /// space it reserves; an unpinned one is only reachable while it is open.
    var drawerRegion: CGRect {
        CGRect(x: 0, y: 0, width: currentDrawerWidth, height: rootView.bounds.height)
    }

    var currentDrawerWidth: CGFloat {
        drawerWidthConstraint?.constant ?? ThumbnailDrawerView.minimumWidth
    }

    func zone(forRootPoint point: CGPoint) -> ViewerPointerZone {
        zoneGeometry.zone(for: point, in: rootView.bounds,
                          drawerVisible: hover.drawerVisible || hover.drawerPinned,
                          minimapRect: minimap.isHidden ? nil : minimap.frame)
    }

    /// Entry point for pointer movement, whether it came from real AppKit
    /// tracking or from a test driving the same production path.
    func handlePointer(atRootPoint point: CGPoint) {
        let now = Date().timeIntervalSinceReferenceDate
        hover.pointerMoved(at: now)

        switch zone(forRootPoint: point) {
        case .topChrome, .leftEdgeHotZone:
            // No chrome lives at the top any more; the standard titlebar is
            // AppKit's. The left edge is the drawer's trigger region.
            hover.pointerEnteredLeftEdge(at: now)
        case .drawerSurface:
            // Keeping the pointer inside the drawer keeps it open.
            hover.pointerEnteredDrawer(at: now)
        case .minimapSurface:
            hover.zoomActivity(at: now)
        case .canvas:
            hover.pointerExitedDrawer(at: now)
        }

        hover.update(at: now)
        applyChromeVisibility()
    }

    /// Real mouse events arrive at the root view; this stays for the acceptance
    /// runner and for tests that need to drive the same code path.
    func simulatePointer(atWindowPoint point: NSPoint) {
        handlePointer(atRootPoint: rootView.convert(point, from: nil))
    }

    // MARK: - Commands

    public func perform(_ command: ViewerCommand) {
        switch command {
        case .nextImage:
            pendingDirection = .forward
            session.goNext()
        case .previousImage:
            pendingDirection = .backward
            session.goPrevious()
        case .firstImage:
            pendingDirection = .backward
            session.goFirst()
        case .lastImage:
            pendingDirection = .forward
            session.goLast()
        case .zoomToFit:
            canvas.setZoomToFit()
        case .zoomToFitWidth:
            canvas.setZoomToFitWidth()
        case .zoomActualPixels:
            canvas.setZoomToActualPixels()
        case .zoomDoubleFit:
            canvas.toggleFitAndDoubleFit()
        case .rotateClockwise:
            canvas.rotateClockwise()
        case .rotateCounterClockwise:
            canvas.rotateCounterClockwise()
        case .toggleMirror:
            canvas.toggleMirror()
        case .moveToTrash:
            moveCurrentToTrash()
        case .togglePlayback:
            if viewerState.isAnimated {
                viewerState.togglePlayback()
            } else {
                pendingDirection = .forward
                session.goNext()
            }
        case .nextPage:
            goToPage(+1)
        case .previousPage:
            goToPage(-1)
        case .toggleImmersive:
            hover.setImmersive(!hover.immersive, at: Date().timeIntervalSinceReferenceDate)
            viewerState.toggleImmersive()
            applyChromeVisibility()
        case .toggleThumbnailDrawer:
            toggleDrawerPinned()
        case .showImageInfo:
            showImageInfo()
        case .toggleSortDirection:
            let settings = AppSettings.shared
            settings.sortDirection = settings.sortDirection == .ascending ? .descending : .ascending
            reloadWithCurrentSort()
        case .open, .close, .settings, .toggleFullScreen:
            // Handled by the app-level router.
            NSApp.sendAction(#selector(NSDocumentController.newDocument(_:)), to: nil, from: nil)
        }
    }

    private func goToPage(_ delta: Int) {
        guard viewerState.isMultiPage, let descriptor = viewerState.descriptor else { return }
        let next = viewerState.pageIndex + delta
        guard next >= 0, next < descriptor.pageCount else { return }
        viewerState.pageIndex = next
        regenerateNavigatorPreview()
        let url = descriptor.sourceURL
        onDemandFrameTask?.cancel()
        onDemandFrameTask = Task { [weak self] in
            let decoder = ImageIODecoder()
            if let frame = try? await decoder.decodeFrame(url, index: next) {
                await MainActor.run {
                    self?.viewerState.apply(frame: frame)
                    self?.refreshBottomBar()
                }
            }
        }
    }

    /// Non-modal error surface: shown inline, recorded in state, cleared by the
    /// next successful image load.
    private func presentTransientError(_ message: String) {
        viewerState.errorMessage = message
        errorLabel.stringValue = message
        errorLabel.isHidden = false
    }

    private func moveCurrentToTrash() {
        guard let item = session.currentItem else { return }
        var resulting: NSURL?
        do {
            try FileManager.default.trashItem(at: item.url, resultingItemURL: &resulting)
        } catch {
            // A failed Trash keeps the current item and leaves the viewer usable.
            presentTransientError("无法移到废纸篓：\(error.localizedDescription)")
            return
        }
        errorLabel.isHidden = true
        viewerState.errorMessage = nil
        _ = resulting
        switch settings.deleteFollowUp {
        case .smart:
            // Prefer the next image, then the previous one, then empty.
            session.removeCurrentWithSmartSelection(identity: item.id)
        case .stayInPlace:
            // Keep the position in the list rather than following a neighbour.
            session.removeCurrentKeepingPosition(identity: item.id)
        }
    }

    /// Toggles the in-viewer information card. No window is ever created for it.
    private func showImageInfo() {
        guard viewerState.metadata != nil else { return }
        setInfoCardVisible(!isInfoCardVisible)
    }

    func setInfoCardVisible(_ visible: Bool) {
        isInfoCardVisible = visible
        if visible { refreshInfoCard() }
        applyChromeVisibility()
    }

    /// Keeps the card in step with the current image; the card scrolls internally
    /// and is capped to a fraction of the canvas rather than the whole window.
    private func refreshInfoCard() {
        infoCard.update(metadata: viewerState.metadata, descriptor: viewerState.descriptor)
        let maximum = max(80, canvas.bounds.height * ImageInfoCardView.maximumHeightFraction)
        let target = min(maximum, CGFloat(infoCard.rowCount) * 22 + 44)
        infoCardHeightConstraint?.constant = target
        infoCardHeightConstraint?.isActive = isInfoCardVisible
    }

    // MARK: - Chrome refresh

    private func refreshBottomBar() {
        bottomBar.update(fields: settings.bottomFields, session: session,
                         descriptor: viewerState.descriptor, viewport: canvas.viewport,
                         metadata: viewerState.metadata,
                         pageDescription: viewerState.pageDescription)
    }

    /// Viewport-only update: panning and zooming move the rectangle and must never
    /// regenerate the preview bitmap.
    private func refreshMinimap() {
        guard viewerState.currentImage != nil else { return }
        minimap.visibleNormalizedRect = canvas.viewport.visibleNormalizedRect(
            imagePixels: canvas.imagePixelSize, viewPoints: canvas.bounds.size
        )
    }

    /// Image-change update: builds the navigator preview once per displayed image,
    /// as a bounded downsample rather than a re-sample of the full source.
    /// The navigator takes the shape of the image it describes, within clamps so an
    /// extreme aspect does not turn it into a sliver.
    private func applyNavigatorSize(for pixelSize: CGSize) {
        let size = NavigatorView.size(forImagePixels: pixelSize, maximum: NavigatorView.defaultSize)
        guard minimapSizeConstraints.count == 2 else { return }
        minimapSizeConstraints[0].constant = size.width
        minimapSizeConstraints[1].constant = size.height
        view.layoutSubtreeIfNeeded()
    }

    private func regenerateNavigatorPreview() {
        guard let image = viewerState.currentImage, let descriptor = viewerState.descriptor else {
            minimap.setPreviewImage(nil)
            return
        }
        // Source geometry, never the bitmap's own pixels: a bounded proxy is
        // smaller than the source it stands for.
        applyNavigatorSize(for: descriptor.displayPixelSize)
        let maxPixel = NavigatorView.previewPixelSize
        Task { [weak self] in
            guard let self else { return }
            let preview = await self.thumbnails.preview(from: image, maxPixelSize: maxPixel)
            guard !Task.isCancelled else { return }
            self.minimap.setPreviewImage(preview)
            self.refreshMinimap()
        }
    }

    // MARK: - Diagnostics

    /// Read-only chrome state used by the in-app acceptance runner.
    struct ChromeSnapshot {
        var top: Bool
        var bottom: Bool
        var drawer: Bool
        var minimap: Bool
        var drawerRows: Int
        var canvasFrame: NSRect
        var zoomScale: CGFloat
        var fitScale: CGFloat
        /// True when the chrome surfaces are rendered with native Liquid Glass.
        var usesNativeSurface: Bool
        // View references so tests can prove the hover UI lives inside the one
        // viewer window instead of in its own window.
        var canvasView: NSView
        var drawerView: NSView
        var minimapView: NSView
        var topBarView: NSView
        var isAnimationTimerActive: Bool
        /// Number of animation clocks this viewer is driving; must never exceed 1.
        var activeAnimationClocks: Int
    }

    var chromeSnapshot: ChromeSnapshot {
        ChromeSnapshot(
            top: false, bottom: !bottomBar.isHidden,
            drawer: hover.snapshot.drawer, minimap: hover.snapshot.minimap,
            drawerRows: drawer.visibleRowCount,
            canvasFrame: canvas.frame,
            zoomScale: canvas.viewport.zoomScale,
            fitScale: canvas.viewport.fitScale,
            usesNativeSurface: bottomBar.usesNativeGlass || drawer.usesNativeGlass
                || toolDock.usesNativeGlass || infoCard.usesNativeGlass,
            canvasView: canvas,
            drawerView: drawer,
            minimapView: minimap,
            topBarView: toolDock,
            isAnimationTimerActive: animationTimer != nil,
            activeAnimationClocks: animationTimer == nil ? 0 : 1
        )
    }

    func simulateImmersive(_ value: Bool) {
        hover.setImmersive(value, at: Date().timeIntervalSinceReferenceDate)
        applyChromeVisibility()
    }

    func simulateZoomActivity() {
        hover.zoomActivity(at: Date().timeIntervalSinceReferenceDate)
        hover.setZoomedIn(canvas.viewport.isZoomedIn, at: Date().timeIntervalSinceReferenceDate)
        applyChromeVisibility()
    }

    // MARK: - Key handling

    public override func keyDown(with event: NSEvent) {
        if let command = ShortcutStore.shared.command(matching: event) {
            perform(command)
            return
        }
        switch event.keyCode {
        case 53: // Escape leaves immersive mode first, then is ignored.
            if hover.immersive {
                hover.setImmersive(false, at: Date().timeIntervalSinceReferenceDate)
                viewerState.toggleImmersive()
                applyChromeVisibility()
            }
        default:
            super.keyDown(with: event)
        }
    }
}
