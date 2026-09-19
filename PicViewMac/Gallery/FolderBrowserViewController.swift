import AppKit

/// Everything the folder browser needs from the image viewer, and nothing else.
///
/// The two modes share these four things and are otherwise independent — the spec's requirement
/// that they must not share a presentation hierarchy is what this protocol makes checkable: the
/// browser cannot reach the canvas, the dock or the drawer through it.
@MainActor
protocol FolderBrowserHost: AnyObject {
    /// The one folder session both modes read.
    var session: FolderSession { get }
    /// Asks for a thumbnail for a gallery item. The pipeline and its cache are shared with the
    /// drawer, so a thumbnail already decoded for one mode is a cache hit in the other.
    func requestGalleryThumbnail(for item: FolderItem, index: Int,
                                 maxPixelSize: Int, completion: @escaping (Int, CGImage?) -> Void)
    /// Cancels any in-flight gallery thumbnails: the browser is going away.
    func cancelGalleryThumbnails()
    /// A folder was chosen in the tree.
    func openFolder(_ url: URL)
    /// The browser wants to leave.
    func leaveFolderBrowser()
    /// A gallery item was opened.
    func openGalleryItem(at index: Int)
    /// The browser's own settings surface: layout kind and thumbnail size are per-window session
    /// state, not app preferences, so they live with the window that is showing them.
    var galleryLayoutKind: GalleryLayoutKind { get set }
    var galleryThumbnailSize: CGFloat { get set }
}

/// The folder browser's behaviour: it owns the view, the folder tree, the sort wiring and the
/// thumbnail requests, and leaves the folder session to the host.
@MainActor
final class FolderBrowserViewController {

    let view: FolderBrowserView
    /// Weak, not `unowned`: the browser's views outlive the viewer when a window closes — its
    /// container is in the viewer's hierarchy, and a callback queued before the teardown can still
    /// run afterwards. An `unowned` reference in that window is a fatal error waiting for the right
    /// timing (observed: "Attempted to read an unowned reference but the object was already
    /// destroyed" during a test that left and re-entered the browser).
    private weak var host: FolderBrowserHost?
    private let tree = FolderTreeModel()

    /// Thumbnails requested since the browser opened, for the acceptance runner.
    private(set) var thumbnailRequestCount = 0
    /// Requests dropped because the drag had moved on before they were issued.
    private(set) var thumbnailRequestsCoalesced = 0
    private var pendingResolutionWorkItem: DispatchWorkItem?

    init(host: FolderBrowserHost) {
        self.host = host
        self.view = FolderBrowserView()
        wire()
    }

    // MARK: - Wiring

    private func wire() {
        view.onBack = { [weak self] in self?.host?.leaveFolderBrowser() }
        view.onLayoutChanged = { [weak self] kind in
            guard let self, let host = self.host else { return }
            host.galleryLayoutKind = kind
            self.view.gallery.setLayoutKind(kind)
            self.view.update(layout: kind, thumbnailSize: host.galleryThumbnailSize,
                             sortKey: AppSettings.shared.sortKey,
                             sortDirection: AppSettings.shared.sortDirection,
                             folderName: host.session.directory?.lastPathComponent,
                             position: host.session.positionDescription)
            self.requestVisibleThumbnails()
        }
        view.onThumbnailSizeChanged = { [weak self] size in
            guard let self, let host = self.host else { return }
            // Live reflow: geometry only, no decode. The grid follows the slider; the sharper
            // thumbnails wait for it to settle.
            host.galleryThumbnailSize = size
            self.view.gallery.setThumbnailSize(size)
        }
        view.onThumbnailSizeSettled = { [weak self] size in
            self?.scheduleThumbnailResolution(for: size)
        }
        view.onSortKeyChanged = { [weak self] key in
            guard let self, let host = self.host else { return }
            // The one sort order, shared with the image viewer: writing it here is what makes the
            // gallery's order and the viewer's next/previous order the same order.
            AppSettings.shared.sortKey = key
            host.session.resortSharedOrder()
            self.reloadFromSession()
        }
        view.onSortDirectionChanged = { [weak self] direction in
            guard let self, let host = self.host else { return }
            AppSettings.shared.sortDirection = direction
            host.session.resortSharedOrder()
            self.reloadFromSession()
        }
        view.onFolderChosen = { [weak self] url in
            self?.host?.openFolder(url)
        }
        view.onFolderToggled = { [weak self] url in
            guard let self else { return }
            self.tree.toggle(url)
            self.view.treeSidebar.update(nodes: self.tree.visibleNodes,
                                         currentPath: self.tree.currentFolderPath)
        }
        view.gallery.onThumbnailNeeded = { [weak self] index, item in
            self?.requestThumbnail(for: item, index: index)
        }
        view.gallery.onSelectionChanged = { [weak self] index in
            // A single click selects, and may move the session: the spec allows the sync, and it is
            // what makes Return / double-click open the item the user is looking at.
            self?.select(index)
        }
        view.gallery.onItemOpened = { [weak self] index in
            guard let self, let host = self.host else { return }
            self.select(index)
            host.openGalleryItem(at: index)
        }
    }

    // MARK: - Session

    /// Rebuilds the gallery and the tree from the session. Called when the browser appears and after
    /// any change to the folder or the sort.
    func reload() {
        guard let host else { return }
        let items = host.session.items
        // Only a list that actually *changed* invalidates the requests made against the old one:
        // a new folder, a re-sort, a rescan that added or removed files. The same list arriving
        // again — which is what the dimension probe's fill produces a moment after entering the
        // browser — must not cancel in-flight decodes and re-request the window, or a small folder
        // asks for its thumbnails twice (measured: 48 requests for 40 items).
        let urls = items.map(\.url)
        if urls != lastRequestedURLs {
            // The generation bump makes every pending completion's guard fail, and the host cancels
            // the decode tasks, so nothing from before this line can land in the gallery after it.
            folderGeneration += 1
            pending.removeAll()
            host.cancelGalleryThumbnails()
            lastRequestedURLs = urls
        }
        let aspects = items.map { item -> CGFloat in
            guard let size = item.pixelSize, size.height > 0 else { return 1 }
            return size.width / size.height
        }
        noteMissingDimensions(items)
        view.update(layout: host.galleryLayoutKind, thumbnailSize: host.galleryThumbnailSize,
                    sortKey: AppSettings.shared.sortKey,
                    sortDirection: AppSettings.shared.sortDirection,
                    folderName: host.session.directory?.lastPathComponent,
                    position: host.session.positionDescription)
        view.gallery.rebuild(items: items, aspects: aspects,
                             currentIndex: host.session.currentIndex,
                             layoutKind: host.galleryLayoutKind,
                             thumbnailSize: host.galleryThumbnailSize)
        let folder = host.session.directory ?? host.session.currentItem?.url.deletingLastPathComponent()
        if let folder { tree.focus(on: folder) }
        view.treeSidebar.update(nodes: tree.visibleNodes, currentPath: tree.currentFolderPath)
        requestVisibleThumbnails()
    }

    /// The URL list the in-flight requests belong to, so a re-published identical list keeps them.
    private var lastRequestedURLs: [URL] = []

    private func reloadFromSession() {
        reload()
    }

    /// The session's current item moved from outside the gallery — a keyboard next/previous, a
    /// delete, a rescan. The gallery's highlight and the toolbar's position follow, because there is
    /// one index and two views of it.
    func syncSelectionFromSession() {
        guard let host else { return }
        view.gallery.setCurrentIndex(host.session.currentIndex)
        view.update(layout: host.galleryLayoutKind, thumbnailSize: host.galleryThumbnailSize,
                    sortKey: AppSettings.shared.sortKey,
                    sortDirection: AppSettings.shared.sortDirection,
                    folderName: host.session.directory?.lastPathComponent,
                    position: host.session.positionDescription)
    }

    /// Starts the header probes the adaptive layout needs, once per folder.
    ///
    /// Layout B's whole point is that a wide image gets a wide item, and that cannot be decided from
    /// a filename. The probe reads only the image header (tens of bytes), so a folder's worth of
    /// them is cheap, and it runs off the main actor — but it is *not* run for a folder whose items
    /// already have their sizes, and not twice for the same folder.
    private func noteMissingDimensions(_ items: [FolderItem]) {
        let missing = items.filter { $0.pixelSize == nil }
        guard !missing.isEmpty, dimensionsWorkItem == nil else { return }
        let itemCount = items.count
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                guard let host = self.host else { return }
                let filled = await FolderScanner.fillDimensions(host.session.items)
                self.dimensionsWorkItem = nil
                // The folder may have moved on while the probe ran.
                guard filled.count == itemCount, filled.map(\.url) == host.session.items.map(\.url)
                else { return }
                var updated = host.session.items
                for index in updated.indices where updated[index].pixelSize == nil {
                    updated[index].pixelSize = filled[index].pixelSize
                }
                host.session.replaceItemsPreservingCurrent(updated)
                self.reload()
            }
        }
        dimensionsWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: work)
    }

    private var dimensionsWorkItem: DispatchWorkItem?

    /// Selection: one click selects and syncs the session's index, which is also what the info HUD
    /// and the dock's position readout show. The spec's "may update FolderSession.currentIndex" is
    /// taken as yes, because otherwise the two modes could disagree about the current image.
    func select(_ index: Int) {
        guard let host else { return }
        host.session.select(index: index)
        view.gallery.setCurrentIndex(index)
        view.update(layout: host.galleryLayoutKind, thumbnailSize: host.galleryThumbnailSize,
                    sortKey: AppSettings.shared.sortKey,
                    sortDirection: AppSettings.shared.sortDirection,
                    folderName: host.session.directory?.lastPathComponent,
                    position: host.session.positionDescription)
    }

    /// Escape and Back both leave; the browser reports Escape through the same path the Back button
    /// uses so there is one behaviour, not two.
    func handleEscape() {
        host?.leaveFolderBrowser()
    }

    // MARK: - Thumbnails

    /// One in-flight request: its generation and the resolution it asked for. The generation is
    /// what makes a stale completion detectable — an older, lower-resolution request superseded by
    /// the slider, or any request from a previous folder, must apply nothing.
    private struct PendingRequest {
        let generation: Int
        let maxPixelSize: Int
    }

    /// In-flight requests by path, so the same item is not asked for twice at a given resolution.
    private var pending: [String: PendingRequest] = [:]
    /// Monotonic per-request generation; a completion applies only if it is the newest request
    /// for its path.
    private var requestGeneration = 0
    /// Bumped on every reload. A completion captured before a reload can never land after it.
    private var folderGeneration = 0

    /// Asks for a thumbnail for one item, if the gallery's window does not already have something
    /// good enough (same source version, sharp enough for the current slider).
    private func requestThumbnail(for item: FolderItem, index: Int) {
        guard let host else { return }
        let pixels = Int(GalleryLayout.clampThumbnailSize(host.galleryThumbnailSize) * 2)
        requestThumbnail(for: item, index: index, maxPixelSize: pixels)
    }

    private func requestThumbnail(for item: FolderItem, index: Int, maxPixelSize: Int) {
        guard let host else { return }
        let path = item.url.path
        let identity = SourceFileIdentity.read(at: item.url)
        // Good enough already: the same file, decoded at a resolution at least this sharp.
        if let delivered = view.gallery.deliveredThumbnail(for: item.url),
           delivered.pixelSize >= maxPixelSize, delivered.versionToken == identity.versionToken {
            return
        }
        // Stale (the file changed) or too small (the slider grew): it must never be served again,
        // so forget it and ask for a fresh, sharper one.
        view.gallery.dropDelivered(for: item.url)
        if let inFlight = pending[path], inFlight.maxPixelSize >= maxPixelSize { return }
        requestGeneration += 1
        let generation = requestGeneration
        let folderGenerationAtRequest = folderGeneration
        pending[path] = PendingRequest(generation: generation, maxPixelSize: maxPixelSize)
        thumbnailRequestCount += 1
        host.requestGalleryThumbnail(for: item, index: index, maxPixelSize: maxPixelSize) {
            [weak self] _, image in
            guard let self else { return }
            // Only the newest request for this file may apply. A lower-resolution completion that
            // arrives after the slider moved on, or any completion from a previous folder, is
            // dropped — it must not overwrite the sharper or newer pixels.
            guard self.folderGeneration == folderGenerationAtRequest,
                  self.pending[path]?.generation == generation else { return }
            self.pending[path] = nil
            guard let image else { return }
            self.view.gallery.noteDelivered(image, pixelSize: maxPixelSize,
                                            versionToken: identity.versionToken, for: item.url)
            self.view.gallery.updateThumbnail(for: item.url, image: image)
        }
    }

    /// Asks for the thumbnails the visible window needs: the cells on screen plus a small prefetch
    /// band above and below. Called once per rebuild rather than per scroll event: scrolling into
    /// new territory materializes the cells that appeared, and each materialized cell asks for its
    /// own thumbnail. The request count is a function of the viewport, never of the folder size.
    private func requestVisibleThumbnails() {
        guard let host else { return }
        let pixels = Int(GalleryLayout.clampThumbnailSize(host.galleryThumbnailSize) * 2)
        let items = view.gallery.items
        for index in view.gallery.thumbnailWindowIndexes.sorted()
        where items.indices.contains(index) {
            requestThumbnail(for: items[index], index: index, maxPixelSize: pixels)
        }
    }

    /// The slider settled. A sharper thumbnail is worth requesting only now, and only for the
    /// visible items — a decode per slider pixel would be the "full decode on every mouse move" the
    /// spec forbids. Items already delivered at a sharp-enough tier are not asked for again, and
    /// items requested at a lower tier are superseded: their pending completion is replaced, so it
    /// can never overwrite the sharper result.
    private func scheduleThumbnailResolution(for size: CGFloat) {
        pendingResolutionWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                // Whatever was in flight at the old tier is superseded; the window is asked for
                // again at the new size, and per-item tier guards decide who actually re-decodes.
                self.thumbnailRequestsCoalesced += 1
                self.requestVisibleThumbnails()
                _ = size
            }
        }
        pendingResolutionWorkItem = work
        // A short settle window: the drag is over, so this is not a per-event cost.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    /// Cancels work when the browser is leaving.
    func teardown() {
        pendingResolutionWorkItem?.cancel()
        pendingResolutionWorkItem = nil
        dimensionsWorkItem?.cancel()
        dimensionsWorkItem = nil
        pending.removeAll()
        host?.cancelGalleryThumbnails()
    }

    // MARK: - Test access

    var visibleNodesForTesting: [FolderTreeModel.Node] { tree.visibleNodes }
    var treeEnumerationCountForTesting: Int { tree.enumerationCount }
}
