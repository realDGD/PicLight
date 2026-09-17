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
    private let topBar = TopHoverBarView()
    private let bottomBar = BottomInfoBarView(style: .chrome)
    private let drawer = ThumbnailDrawerView(style: .drawer)
    private let minimap = NavigatorView()
    private let errorLabel = NSTextField(labelWithString: "")

    private let coordinator: DecodeCoordinator
    private let thumbnails: ThumbnailPipeline
    private(set) var thumbnailRequestCount = 0
    private let watcher = FolderWatcher()
    private let infoWindow = ImageInfoWindowController()

    private var hover = HoverVisibilityModel()
    private var chromeTimer: Timer?
    private var animationTimer: Timer?
    private let clock = AnimationClock()
    private var drawerWidthConstraint: NSLayoutConstraint?
    private var pendingDirection: NavigationDirection = .unknown
    private var onDemandFrameTask: Task<Void, Never>?

    public private(set) var settings = AppSettings.shared

    /// The decoder and thumbnail pipeline are injectable so tests can drive the
    /// real viewer with a counting or deliberately slow implementation.
    public init(decoder: ImageDecoding = ImageIODecoder(),
                thumbnails: ThumbnailPipeline = ThumbnailPipeline()) {
        self.coordinator = DecodeCoordinator(decoder: decoder)
        self.thumbnails = thumbnails
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
        ["topBar": topBar, "bottomBar": bottomBar, "drawer": drawer,
         "minimap": minimap, "canvas": canvas, "emptyState": emptyState]
    }

    /// Re-applies the current hover state without inventing pointer movement.
    func applyChromeVisibilityForTesting() {
        applyChromeVisibility()
    }

    /// The empty-state wording currently in use, or `nil` when it is hidden.
    var emptyStateReasonForTesting: EmptyStateView.Reason? {
        emptyState.isHidden ? nil : emptyState.reason
    }

    /// Drives the pin button the way the drawer's button does.
    func toggleDrawerPinForTesting() {
        let now = Date().timeIntervalSinceReferenceDate
        hover.setDrawerPinned(!hover.drawerPinned, at: now)
        hover.update(at: now)
        applyChromeVisibility()
    }

    public override func loadView() {
        rootView.frame = NSRect(x: 0, y: 0, width: 960, height: 680)
        rootView.wantsLayer = true
        let root = rootView
        view = root

        canvas.translatesAutoresizingMaskIntoConstraints = false
        topBar.translatesAutoresizingMaskIntoConstraints = false
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
        root.addSubview(topBar)
        root.addSubview(bottomBar)
        root.addSubview(drawer)
        root.addSubview(minimap)

        let drawerWidth = drawer.widthAnchor.constraint(equalToConstant: ThumbnailDrawerView.minimumWidth)
        drawerWidthConstraint = drawerWidth

        NSLayoutConstraint.activate([
            canvas.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            canvas.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            canvas.topAnchor.constraint(equalTo: root.topAnchor),
            canvas.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            emptyState.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            emptyState.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            emptyState.topAnchor.constraint(equalTo: root.topAnchor),
            emptyState.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            errorLabel.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            errorLabel.centerYAnchor.constraint(equalTo: root.centerYAnchor),

            topBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            topBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            topBar.topAnchor.constraint(equalTo: root.topAnchor),
            topBar.heightAnchor.constraint(equalToConstant: TopHoverBarView.height),

            bottomBar.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            bottomBar.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -10),
            bottomBar.heightAnchor.constraint(equalToConstant: BottomInfoBarView.height),

            drawer.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            drawer.topAnchor.constraint(equalTo: root.topAnchor),
            drawer.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            drawerWidth,

            minimap.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
            minimap.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -44),
            minimap.widthAnchor.constraint(equalToConstant: NavigatorView.defaultSize.width),
            minimap.heightAnchor.constraint(equalToConstant: NavigatorView.defaultSize.height),
        ])

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
            topBar.attachStandardButtons(from: window)
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
            self.hover.pointerExitedTop(at: now)
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
        }
        canvas.onZoomChanged = { [weak self] in
            guard let self else { return }
            self.hover.zoomActivity(at: Date().timeIntervalSinceReferenceDate)
            self.hover.setZoomedIn(self.canvas.viewport.isZoomedIn, at: Date().timeIntervalSinceReferenceDate)
            self.refreshMinimap()
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

        topBar.onCommand = { [weak self] command in
            self?.perform(command)
        }
        drawer.onSelect = { [weak self] index in
            guard let self else { return }
            self.pendingDirection = index > (self.session.currentIndex ?? 0) ? .forward : .backward
            self.session.select(index: index)
        }
        drawer.onTogglePin = { [weak self] in
            guard let self else { return }
            let now = Date().timeIntervalSinceReferenceDate
            self.hover.setDrawerPinned(!self.hover.drawerPinned, at: now)
            self.hover.update(at: now)
            self.applyChromeVisibility()
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
        topBar.setFilename(session.currentItem?.displayName, visible: settings.showTopFilename)
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
        session.setItems(sorted, preferredIdentity: session.currentItem?.id)
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
            canvas.image = nil
            errorLabel.isHidden = true
            topBar.setFilename(nil, visible: false)
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
        errorLabel.isHidden = true
        viewerState.errorMessage = nil
        topBar.setFilename(item.displayName, visible: settings.showTopFilename)
        onTitleChanged?(item.displayName)
        drawer.setCurrentIndex(index)
        drawer.scrollCurrentIntoView()
        refreshBottomBar()

        let target = DecodeTarget()
        let url = item.url
        Task { [weak self] in
            guard let self else { return }
            _ = await self.coordinator.show(item: url, previous: previous, next: next,
                                            direction: direction, target: target) { event in
                Task { @MainActor in self.handle(event: event) }
            }
        }
    }

    private func handle(event: DecodeEvent) {
        switch event {
        case let .head(head):
            viewerState.apply(head: head)
            errorLabel.isHidden = true
            onDescriptorAvailable?(head.descriptor)
            if head.descriptor.animated {
                startAnimation(descriptor: head.descriptor, autoplay: settings.autoplayAnimations)
            }
        case let .frame(frame):
            if let descriptor = viewerState.descriptor, !descriptor.animated {
                viewerState.apply(frame: frame)
            }
        case let .failure(message):
            viewerState.apply(error: message)
            errorLabel.stringValue = message
            errorLabel.isHidden = message.isEmpty
            refreshEmptyState()
        }
    }

    private func renderEmptyState() {
        canvas.image = nil
        refreshEmptyState()
    }

    /// Shows the welcome/empty UI only when there is genuinely nothing to show:
    /// no decoded image and no error to explain why.
    private func refreshEmptyState() {
        let hasImage = viewerState.currentImage != nil
        let hasError = !(viewerState.errorMessage ?? "").isEmpty
        guard !hasImage, !hasError else {
            setEmptyState(visible: false)
            return
        }
        emptyState.apply(reason: session.directory == nil ? .noImageOpened : .folderHasNoImages)
        setEmptyState(visible: true)
    }

    private func setEmptyState(visible: Bool) {
        emptyState.isHidden = !visible
        emptyState.alphaValue = visible ? 1 : 0
    }

    private func refreshCanvas() {
        canvas.image = viewerState.currentImage
        canvas.refit()
        if viewerState.viewport.zoomScale == 1 || viewerState.currentImage == nil {
            canvas.setZoomToFit()
        }
        viewerState.viewport = canvas.viewport
        refreshEmptyState()
        regenerateNavigatorPreview()
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
        onDemandFrameTask?.cancel()
        onDemandFrameTask = Task { [weak self] in
            guard let self else { return }
            let decoder = ImageIODecoder()
            if let frame = try? await decoder.decodeFrame(url, index: index) {
                guard !Task.isCancelled else { return }
                await MainActor.run { self.viewerState.apply(frame: frame) }
            }
        }
    }

    private func refreshPlaybackChrome() {
        topBar.setAnimated(viewerState.isAnimated, isPlaying: viewerState.playback == .playing)
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
            guard let image = try? await self.thumbnails.thumbnail(for: item.url, maxPixelSize: 300) else { return }
            self.thumbnailCache[item.url] = image
            self.drawer.updateThumbnail(at: index, image: image)
        }
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
        setChrome(topBar, visible: snapshot.top)
        setChrome(bottomBar, visible: snapshot.bottom)
        setChrome(drawer, visible: snapshot.drawer)
        setChrome(minimap, visible: snapshot.minimap)
        drawer.setPinned(hover.drawerPinned)
        fadeStandardButtons(visible: snapshot.top)
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
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = duration
                chrome.animator().alphaValue = 0
            }, completionHandler: { [weak self, weak chrome] in
                guard let chrome else { return }
                MainActor.assumeIsolated {
                    // A show may have started while the fade-out ran; only hide if
                    // the surface is still meant to be hidden.
                    guard chrome.alphaValue < 0.01 else { return }
                    chrome.isHidden = true
                    _ = self
                }
            })
        }
    }

    /// The traffic lights are the window's own standard buttons, so they can only
    /// be faded; hover detection never depends on them.
    private func fadeStandardButtons(visible: Bool) {
        guard let window = view.window else { return }
        let duration = AccessibilityAppearance.chromeFadeDuration
        let buttons = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton]
            .compactMap { window.standardWindowButton($0) }
        guard duration > 0 else {
            buttons.forEach { $0.alphaValue = visible ? 1 : 0 }
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            buttons.forEach { $0.animator().alphaValue = visible ? 1 : 0 }
        }
    }

    // MARK: - Pointer zones

    /// Geometry of the hover regions, derived from the live layout so tests and
    /// the app agree on what "the left edge" means.
    var zoneGeometry: ViewerZoneGeometry {
        ViewerZoneGeometry(topBarHeight: TopHoverBarView.height,
                           hotZoneWidth: ThumbnailDrawerView.hotZoneWidth,
                           drawerWidth: drawerWidthConstraint?.constant ?? ThumbnailDrawerView.minimumWidth)
    }

    func zone(forRootPoint point: CGPoint) -> ViewerPointerZone {
        zoneGeometry.zone(for: point, in: rootView.bounds,
                          drawerVisible: hover.drawerVisible,
                          minimapRect: minimap.isHidden ? nil : minimap.frame)
    }

    /// Entry point for pointer movement, whether it came from real AppKit
    /// tracking or from a test driving the same production path.
    func handlePointer(atRootPoint point: CGPoint) {
        let now = Date().timeIntervalSinceReferenceDate
        hover.pointerMoved(at: now)

        switch zone(forRootPoint: point) {
        case .topChrome:
            hover.pointerEnteredTop(at: now)
        case .leftEdgeHotZone:
            hover.pointerEnteredLeftEdge(at: now)
            hover.pointerExitedTop(at: now)
        case .drawerSurface:
            // Keeping the pointer inside the drawer keeps it open.
            hover.pointerEnteredDrawer(at: now)
            hover.pointerExitedTop(at: now)
        case .minimapSurface:
            hover.zoomActivity(at: now)
            hover.pointerExitedTop(at: now)
        case .canvas:
            hover.pointerExitedTop(at: now)
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
            let now = Date().timeIntervalSinceReferenceDate
            if hover.drawerVisible {
                hover.pointerExitedDrawer(at: now)
            } else {
                hover.pointerEnteredDrawer(at: now)
            }
            hover.update(at: now)
            applyChromeVisibility()
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
        if settings.deleteFollowUp == .smart {
            session.removeCurrentWithSmartSelection(identity: item.id)
        } else {
            session.removeCurrentWithSmartSelection(identity: item.id)
        }
    }

    private func showImageInfo() {
        guard let metadata = viewerState.metadata else { return }
        infoWindow.show(metadata: metadata, descriptor: viewerState.descriptor, relativeTo: view.window)
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
    private func regenerateNavigatorPreview() {
        guard let image = viewerState.currentImage else {
            minimap.setPreviewImage(nil)
            return
        }
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
            top: hover.snapshot.top, bottom: hover.snapshot.bottom,
            drawer: hover.snapshot.drawer, minimap: hover.snapshot.minimap,
            drawerRows: drawer.visibleRowCount,
            canvasFrame: canvas.frame,
            zoomScale: canvas.viewport.zoomScale,
            fitScale: canvas.viewport.fitScale,
            usesNativeSurface: topBar.usesNativeGlass || bottomBar.usesNativeGlass || drawer.usesNativeGlass,
            canvasView: canvas,
            drawerView: drawer,
            minimapView: minimap,
            topBarView: topBar,
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
