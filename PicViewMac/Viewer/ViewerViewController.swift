import AppKit
import ImageIO

/// Owns one viewer: canvas, hover chrome, drawer, minimap, decode pipeline and
/// command handling. Hover UI lives inside this single window.
@MainActor
public final class ViewerViewController: NSViewController, ViewerCommandHandling {
    public let session = FolderSession()
    public let viewerState = ViewerState()

    public var onTitleChanged: ((String?) -> Void)?

    private let canvas = ImageCanvasView()
    private let topBar = TopHoverBarView()
    private let bottomBar = BottomInfoBarView(style: .chrome)
    private let drawer = ThumbnailDrawerView(style: .drawer)
    private let minimap = NavigatorView(style: .chrome)
    private let errorLabel = NSTextField(labelWithString: "")

    private let coordinator = DecodeCoordinator()
    private let thumbnails = ThumbnailPipeline()
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

    public override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 960, height: 680))
        root.wantsLayer = true
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
        startChromeTimer()
        if let window = view.window {
            window.acceptsMouseMovedEvents = true
            topBar.attachStandardButtons(from: window)
            applyAppearance()
        }
    }

    // MARK: - Wiring

    private func configureCallbacks() {
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
        drawer.onPointerEntered = { [weak self] in
            guard let self else { return }
            self.hover.pointerEnteredDrawer(at: Date().timeIntervalSinceReferenceDate)
        }
        drawer.onPointerExited = { [weak self] in
            guard let self else { return }
            self.hover.pointerExitedDrawer(at: Date().timeIntervalSinceReferenceDate)
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
        let directory = url.deletingLastPathComponent()
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
            self.session.setItems(sorted, preferredIdentity: FileIdentity(url: url))
            self.session.select(url: url)
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
            viewerState.apply(error: "")
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
        }
    }

    private func renderEmptyState() {
        canvas.image = nil
        errorLabel.stringValue = session.items.isEmpty ? "此文件夹中没有支持的图像" : ""
        errorLabel.isHidden = session.items.isEmpty == false
    }

    private func refreshCanvas() {
        canvas.image = viewerState.currentImage
        canvas.refit()
        if viewerState.viewport.zoomScale == 1 || viewerState.currentImage == nil {
            canvas.setZoomToFit()
        }
        viewerState.viewport = canvas.viewport
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
        let duration = AccessibilityAppearance.chromeFadeDuration
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            topBar.animator().alphaValue = snapshot.top ? 1 : 0
            bottomBar.animator().alphaValue = snapshot.bottom ? 1 : 0
            drawer.animator().alphaValue = snapshot.drawer ? 1 : 0
            minimap.animator().alphaValue = snapshot.minimap ? 1 : 0
            if let window = view.window {
                for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                    window.standardWindowButton(button)?.animator().alphaValue = snapshot.top ? 1 : 0
                }
            }
        }
        topBar.isHidden = false
        bottomBar.isHidden = false
        drawer.isHidden = !snapshot.drawer && duration == 0
        minimap.isHidden = !snapshot.minimap && duration == 0
        if !AccessibilityAppearance.reduceMotion {
            drawer.isHidden = false
            minimap.isHidden = false
        }
    }

    // MARK: - Pointer zones

    public override func mouseMoved(with event: NSEvent) {
        handlePointer(at: event.locationInWindow)
    }

    public override func mouseExited(with event: NSEvent) {
        let now = Date().timeIntervalSinceReferenceDate
        hover.pointerExitedTop(at: now)
        hover.pointerExitedDrawer(at: now)
    }

    private func handlePointer(at windowPoint: NSPoint) {
        let now = Date().timeIntervalSinceReferenceDate
        let point = view.convert(windowPoint, from: nil)
        hover.pointerMoved(at: now)

        if point.y >= view.bounds.height - TopHoverBarView.height {
            hover.pointerEnteredTop(at: now)
        } else {
            hover.pointerExitedTop(at: now)
        }

        // ~12 px invisible left-edge hot zone.
        if point.x <= ThumbnailDrawerView.hotZoneWidth {
            hover.pointerEnteredLeftEdge(at: now)
        } else if hover.drawerVisible,
                  point.x <= (drawerWidthConstraint?.constant ?? 0) {
            hover.pointerEnteredDrawer(at: now)
        } else {
            hover.pointerExitedDrawer(at: now)
        }
        hover.update(at: now)
        applyChromeVisibility()
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

    private func moveCurrentToTrash() {
        guard let item = session.currentItem else { return }
        var resulting: NSURL?
        do {
            try FileManager.default.trashItem(at: item.url, resultingItemURL: &resulting)
        } catch {
            // Non-modal failure: keep the current item and stay usable.
            errorLabel.stringValue = "无法移到废纸篓：\(error.localizedDescription)"
            errorLabel.isHidden = false
            return
        }
        errorLabel.isHidden = true
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

    private func refreshMinimap() {
        guard let image = viewerState.currentImage else {
            minimap.image = nil
            return
        }
        minimap.image = image
        minimap.visibleNormalizedRect = canvas.viewport.visibleNormalizedRect(
            imagePixels: canvas.imagePixelSize, viewPoints: canvas.bounds.size
        )
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
    }

    var chromeSnapshot: ChromeSnapshot {
        ChromeSnapshot(
            top: hover.snapshot.top, bottom: hover.snapshot.bottom,
            drawer: hover.snapshot.drawer, minimap: hover.snapshot.minimap,
            drawerRows: drawer.visibleRowCount,
            canvasFrame: canvas.frame,
            zoomScale: canvas.viewport.zoomScale,
            fitScale: canvas.viewport.fitScale
        )
    }

    /// Drives the same pointer-zone logic the real mouse events use.
    func simulatePointer(atWindowPoint point: NSPoint) {
        handlePointer(at: point)
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
