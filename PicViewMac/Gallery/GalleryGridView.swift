import AppKit

/// One gallery cell: an aspect-fitted thumbnail with its filename under it.
///
/// Pooled and reused by `GalleryGridView`, so a folder with ten thousand images never materializes
/// ten thousand views: only the cells inside the visible rectangle exist, and scrolling hands the
/// ones that left back to the pool.
final class GalleryItemView: NSView {
    private let imageView2 = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let selectionRing = PassthroughView()
    /// Shown while this cell has no thumbnail yet: a plate in the image area with a caption, so a
    /// folder of large pictures reads as "loading" rather than as empty. A 48,000 × 32,000 PNG costs
    /// ImageIO ≈18 s to thumbnail, and a blank cell for that long looks like a broken grid.
    private let loadingPlate = NSView()
    private let loadingLabel = NSTextField(labelWithString: "")

    /// The item this view is currently showing, so a delivery can be matched by identity rather
    /// than by a row number captured when the request started.
    var representedURL: URL?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        imageView2.imageScaling = .scaleProportionallyUpOrDown
        imageView2.translatesAutoresizingMaskIntoConstraints = false

        nameLabel.font = .systemFont(ofSize: 10)
        nameLabel.textColor = .secondaryLabelColor
        nameLabel.lineBreakMode = .byTruncatingMiddle
        nameLabel.alignment = .center
        nameLabel.translatesAutoresizingMaskIntoConstraints = false

        loadingPlate.wantsLayer = true
        loadingPlate.layer?.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.18).cgColor
        loadingPlate.layer?.cornerRadius = 4
        loadingPlate.isHidden = true
        loadingPlate.translatesAutoresizingMaskIntoConstraints = false

        loadingLabel.font = .systemFont(ofSize: 10)
        loadingLabel.textColor = .tertiaryLabelColor
        loadingLabel.alignment = .center
        loadingLabel.lineBreakMode = .byTruncatingMiddle
        loadingLabel.isHidden = true
        loadingLabel.translatesAutoresizingMaskIntoConstraints = false

        selectionRing.wantsLayer = true
        selectionRing.layer?.borderWidth = 2
        selectionRing.layer?.borderColor = NSColor.controlAccentColor.cgColor
        selectionRing.layer?.cornerRadius = 4
        selectionRing.isHidden = true
        selectionRing.translatesAutoresizingMaskIntoConstraints = false

        addSubview(imageView2)
        addSubview(loadingPlate)
        addSubview(loadingLabel)
        addSubview(selectionRing)
        addSubview(nameLabel)
        NSLayoutConstraint.activate([
            imageView2.leadingAnchor.constraint(equalTo: leadingAnchor),
            imageView2.trailingAnchor.constraint(equalTo: trailingAnchor),
            imageView2.topAnchor.constraint(equalTo: topAnchor),
            imageView2.bottomAnchor.constraint(equalTo: bottomAnchor,
                                               constant: -GalleryLayout.filenameSlotHeight),

            loadingPlate.leadingAnchor.constraint(equalTo: leadingAnchor),
            loadingPlate.trailingAnchor.constraint(equalTo: trailingAnchor),
            loadingPlate.topAnchor.constraint(equalTo: topAnchor),
            loadingPlate.bottomAnchor.constraint(equalTo: bottomAnchor,
                                                 constant: -GalleryLayout.filenameSlotHeight),

            loadingLabel.centerXAnchor.constraint(equalTo: loadingPlate.centerXAnchor),
            loadingLabel.centerYAnchor.constraint(equalTo: loadingPlate.centerYAnchor),
            loadingLabel.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 4),
            loadingLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),

            selectionRing.leadingAnchor.constraint(equalTo: leadingAnchor),
            selectionRing.trailingAnchor.constraint(equalTo: trailingAnchor),
            selectionRing.topAnchor.constraint(equalTo: topAnchor),
            selectionRing.bottomAnchor.constraint(equalTo: bottomAnchor,
                                                  constant: -GalleryLayout.filenameSlotHeight),

            nameLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            nameLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            nameLabel.bottomAnchor.constraint(equalTo: bottomAnchor),
            nameLabel.heightAnchor.constraint(equalToConstant: GalleryLayout.filenameSlotHeight),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// - Parameter placeholder: the sentence to show in the image area while there is no thumbnail —
    ///   "载入中…" while one is being made, the oversized sentence when none will be — or nil to show
    ///   nothing (a cell that simply has no picture yet).
    func configure(item: FolderItem, thumbnail: CGImage?, isCurrent: Bool,
                   placeholder: String? = nil) {
        representedURL = item.url
        nameLabel.stringValue = item.displayName
        let showingPlaceholder = thumbnail == nil && placeholder != nil
        loadingPlate.isHidden = !showingPlaceholder
        loadingLabel.isHidden = !showingPlaceholder
        loadingLabel.stringValue = placeholder ?? ""
        // The image fills the cell's image area and fits inside it: `GalleryLayout` decided the
        // cell's *shape*, and scaleProportionallyUpOrDown centres the picture inside it, so a wide
        // adaptive cell and a square uniform slot both letterbox rather than crop.
        imageView2.image = thumbnail.map {
            NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height))
        }
        selectionRing.isHidden = !isCurrent
    }

    var imageSurface: NSView { imageView2 }
    var nameSurface: NSTextField { nameLabel }
    var selectionSurface: NSView { selectionRing }
    /// The thumbnail this cell is currently showing, for tests.
    var imageForTesting: NSImage? { imageView2.image }
    /// The loading placeholder's caption, or nil when the cell is not showing one.
    var loadingCaptionForTesting: String? { loadingLabel.isHidden ? nil : loadingLabel.stringValue }
}

/// One delivered thumbnail: the image, the resolution tier it was actually decoded at, and the
/// source version it belongs to. The tier is what lets a larger slider ask for something sharper
/// instead of blowing up an old small decode, and the version is what lets a file replaced at the
/// same path never be served its predecessor's pixels.
struct DeliveredThumbnail {
    let image: CGImage
    /// The `maxPixelSize` the thumbnail was requested at.
    let pixelSize: Int
    /// `SourceFileIdentity.versionToken` of the file at request time.
    let versionToken: String
}

/// The gallery grid: `NSScrollView`'s document view, laying out rows and recycling cells.
///
/// It computes its geometry from `GalleryLayout` — one pure function shared by both layout kinds and
/// by the tests — and materializes a cell only for the rows intersecting the visible rectangle. That
/// is the virtualization the spec asks for, and it is checkable directly: the number of cells that
/// exist equals the number of cells the layout says are visible, whatever the folder's size.
///
/// It is a plain `NSView` rather than an `NSCollectionView` with a custom layout because a custom
/// `NSCollectionViewLayout` subclass is not usable here: assigning one to a collection view crashes
/// the process on this SDK (measured — a minimal subclass that returns a constant content size and
/// no attributes segfaults on teardown, while `NSCollectionViewFlowLayout` does not).
final class GalleryGridView: NSView {

    var onSelectionChanged: ((Int) -> Void)?
    var onItemOpened: ((Int) -> Void)?
    /// A cell needs its thumbnail. Raised once per item, when the cell is first materialized.
    var onThumbnailNeeded: ((Int, FolderItem) -> Void)?

    private(set) var items: [FolderItem] = []
    private(set) var aspects: [CGFloat] = []
    private(set) var layoutKind: GalleryLayoutKind = .uniformGrid
    private(set) var thumbnailSize: CGFloat = GalleryLayout.defaultThumbnailSize
    private(set) var currentIndex: Int?

    /// Materialized cells, by item index.
    private(set) var visibleCells: [Int: GalleryItemView] = [:]
    /// Cells that scrolled out, waiting to be reused.
    private var reusePool: [GalleryItemView] = []
    /// Thumbnails delivered so far, by path, so a recycled cell is filled immediately.
    ///
    /// This is a *window*, not a folder-wide cache: it holds only what the visible rows and the
    /// prefetch band ask for, and everything outside that window is released on the next layout.
    /// Long-term caching is the `ThumbnailPipeline`'s job (bounded `NSCache`); the gallery is not
    /// a second, unbounded copy of the folder's pixels.
    private var delivered: [String: DeliveredThumbnail] = [:]
    /// Every cell ever created, so a test can prove the total does not grow with the folder.
    private(set) var createdCellCount = 0

    /// The grid is flipped so rows run downwards from the top-left, which is both how the layout
    /// model is written and what a scroll view expects for "start at the top".
    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: - Content

    func rebuild(items: [FolderItem], aspects: [CGFloat], currentIndex: Int?,
                 layoutKind: GalleryLayoutKind, thumbnailSize: CGFloat) {
        // A *different* folder's thumbnails must not survive the switch: the previous folder's
        // pixels would stay strongly referenced here, and a path from it could still be served.
        // A re-publish of the *same* files — a re-sort, or the dimension probe filling sizes in a
        // moment after the browser opens — keeps them, so the window is not re-requested and a
        // small folder does not ask for its thumbnails twice.
        let newPaths = Set(items.map { $0.url.path })
        let oldPaths = Set(self.items.map { $0.url.path })
        let sameFiles = !oldPaths.isEmpty && newPaths == oldPaths
        self.items = items
        self.aspects = aspects
        self.currentIndex = currentIndex
        self.layoutKind = layoutKind
        self.thumbnailSize = GalleryLayout.clampThumbnailSize(thumbnailSize)
        // The geometry belongs to the list that was just replaced.
        contentRevision += 1
        // Everything on screen belongs to the old list.
        for (_, cell) in visibleCells { recycle(cell) }
        visibleCells.removeAll()
        if !sameFiles {
            delivered.removeAll()
            // And the placeholders: another folder's pending requests are not this folder's loading
            // state (the completions are dropped by the browser's own generation check).
            if !loadingPaths.isEmpty {
                loadingPaths.removeAll()
                onLoadingChanged?(0)
            }
            skippedCaptions.removeAll()
        }
        needsLayout = true
    }

    /// What may happen to the scroll position when the selection changes.
    enum SelectionVisibility {
        /// Leave the viewport exactly where it is: a click on a cell that is already visible, a
        /// highlight synced from the session, a list republished with more information.
        case preserveViewport
        /// Bring the selection into sight. The user moved it from outside the grid — "最后一张",
        /// next/previous from the keyboard, a delete that moved on — and a selection the user
        /// cannot see is not a selection (measured: index 199 of 200 with the grid showing 0…15).
        case revealCurrent
    }

    func setCurrentIndex(_ index: Int?, visibility: SelectionVisibility = .preserveViewport) {
        guard index != currentIndex else { return }
        currentIndex = index
        for (itemIndex, cell) in visibleCells where items.indices.contains(itemIndex) {
            cell.configure(item: items[itemIndex], thumbnail: thumbnail(at: itemIndex),
                           isCurrent: itemIndex == index)
        }
        if visibility == .revealCurrent { scrollCurrentIntoView() }
    }

    /// Brings the current item's row into the visible rectangle. A no-op when it is already there.
    func scrollCurrentIntoView() {
        guard let currentIndex, items.indices.contains(currentIndex),
              enclosingScrollView != nil else { return }
        // Both the row geometry and the document frame the scroll happens within belong to the
        // current layout, so the pass runs before the rectangle is asked for.
        layoutSubtreeIfNeeded()
        guard let row = rows.first(where: { $0.cells.contains { $0.index == currentIndex } })
        else { return }
        scrollToVisible(row.frame.insetBy(dx: 0, dy: -GalleryLayout.rowSpacing))
    }

    /// Live reflow: geometry only. No thumbnail is requested and nothing is decoded — that is the
    /// settled handler's job, so dragging the slider cannot cause a decode per pixel.
    func setThumbnailSize(_ size: CGFloat) {
        let clamped = GalleryLayout.clampThumbnailSize(size)
        guard clamped != thumbnailSize else { return }
        thumbnailSize = clamped
        contentRevision += 1
        needsLayout = true
    }

    /// Holds the retention window open for the duration of a slider drag. See
    /// `trimDeliveredToWindow`.
    private(set) var isRetentionPaused = false

    func setRetentionPaused(_ paused: Bool) {
        guard paused != isRetentionPaused else { return }
        isRetentionPaused = paused
        // The drag is over: the window it ended on is what gets retained.
        if !paused { trimDeliveredToWindow() }
    }

    func setLayoutKind(_ kind: GalleryLayoutKind) {
        guard kind != layoutKind else { return }
        layoutKind = kind
        contentRevision += 1
        needsLayout = true
    }

    private func thumbnail(at index: Int) -> CGImage? {
        guard items.indices.contains(index) else { return nil }
        return delivered[items[index].url.path]?.image
    }

    /// Stores a delivered thumbnail. The tier and the source version travel with it, so a later
    /// request can tell "good enough" from "already have, but stale or too small".
    func noteDelivered(_ image: CGImage, pixelSize: Int, versionToken: String, for url: URL) {
        delivered[url.path] = DeliveredThumbnail(image: image, pixelSize: pixelSize,
                                                 versionToken: versionToken)
        if loadingPaths.remove(url.path) != nil { onLoadingChanged?(loadingPaths.count) }
        trimDeliveredToWindow()
    }

    /// Forgets a delivered thumbnail, so a stale or too-small entry can never be served again.
    func dropDelivered(for url: URL) {
        delivered[url.path] = nil
    }

    /// What is delivered for this URL, if anything.
    func deliveredThumbnail(for url: URL) -> DeliveredThumbnail? { delivered[url.path] }

    /// Delivers a thumbnail by identity: the list may have been resorted while the request was in
    /// flight, so an index captured at request time could belong to a different file.
    @discardableResult
    func updateThumbnail(for url: URL, image: CGImage?) -> Bool {
        guard let index = items.firstIndex(where: { $0.url == url }) else { return false }
        loadingPaths.remove(url.path)
        guard let cell = visibleCells[index] else { return false }
        let item = items[index]
        skippedCaptions.removeValue(forKey: url.path)
        cell.configure(item: item, thumbnail: image, isCurrent: index == currentIndex,
                       placeholder: image == nil ? placeholderCaption(for: item) : nil)
        return true
    }

    /// The items whose thumbnail has been asked for and has not arrived. Kept per URL, not per
    /// index: a re-sort while a request is in flight must not move the placeholder to another file.
    private var loadingPaths: Set<String> = []

    /// Whether this item is waiting for its thumbnail.
    func isLoading(_ item: FolderItem) -> Bool { loadingPaths.contains(item.url.path) }

    /// How many visible items are still waiting. The browser shows this as a progress readout, which
    /// is what tells the user a slow folder is working rather than empty.
    var loadingThumbnailCount: Int { loadingPaths.count }

    /// Called after the count changes, so the progress readout follows the deliveries.
    var onLoadingChanged: ((Int) -> Void)?

    /// How many requests have been announced, for tests that prove the loading state was reached at
    /// all (the deliveries for small pictures can land before a test looks).
    private(set) var thumbnailRequestAnnouncementsForTesting = 0

    /// A thumbnail was asked for: show the placeholder until something arrives for this URL.
    func noteThumbnailRequested(for url: URL) {
        guard loadingPaths.insert(url.path).inserted else { return }
        thumbnailRequestAnnouncementsForTesting += 1
        refreshVisibleCell(for: url)
        onLoadingChanged?(loadingPaths.count)
    }

    /// A request finished without an image. The placeholder goes away, so a file that cannot be
    /// thumbnailed does not spin forever.
    func noteThumbnailFailed(for url: URL) {
        guard loadingPaths.remove(url.path) != nil else { return }
        refreshVisibleCell(for: url)
        onLoadingChanged?(loadingPaths.count)
    }

    /// A request was not even started, with the sentence that explains why. The cell keeps a caption
    /// — it is not "loading" any more, but it is also not a mystery.
    func noteThumbnailSkipped(for url: URL, caption: String) {
        loadingPaths.remove(url.path)
        skippedCaptions[url.path] = caption
        refreshVisibleCell(for: url)
        onLoadingChanged?(loadingPaths.count)
    }

    /// What an oversized source's cell says instead of a picture.
    ///
    /// Measured: a 320 px thumbnail of a 48,000 × 32,000 PNG costs ImageIO 18.4 s, and so does a 64 px
    /// one — the whole stream is read whatever is asked. Opening the file produces the thumbnail from
    /// the decoded bitmap, so that is what the cell tells the user to do.
    static let oversizedCaption = "超大图片，打开后生成缩略图"

    /// Cells whose request was skipped, by path, with the sentence they show.
    private var skippedCaptions: [String: String] = [:]

    /// The caption a cell should show for this item, or nil when it should show nothing (yet).
    private func placeholderCaption(for item: FolderItem) -> String? {
        if let skipped = skippedCaptions[item.url.path] { return skipped }
        return isLoading(item) ? Self.loadingCaption(for: item) : nil
    }

    /// Re-draws one visible cell from its current state. Identity, not row number: the list may have
    /// been resorted since the request went out.
    private func refreshVisibleCell(for url: URL) {
        guard let index = items.firstIndex(where: { $0.url == url }),
              let cell = visibleCells[index] else { return }
        let item = items[index]
        cell.configure(item: item, thumbnail: thumbnail(at: index),
                       isCurrent: index == currentIndex,
                       placeholder: placeholderCaption(for: item))
    }

    /// What the placeholder says. A picture whose dimensions are known to be enormous gets its own
    /// sentence: ImageIO needs tens of seconds for those, and "载入中…" would read as a hang.
    static func loadingCaption(for item: FolderItem) -> String {
        guard let size = item.pixelSize, size.width * size.height > 50_000_000 else {
            return "载入中…"
        }
        return "超大图片，正在生成缩略图…"
    }

    /// The cells a layout produces for the current width, for tests.
    func rowsForTesting(containerWidth: CGFloat) -> [GalleryRow] {
        GalleryLayout.rows(for: layoutKind, aspects: aspects, containerWidth: containerWidth,
                           thumbnailSize: thumbnailSize)
    }

    /// The row geometry, recomputed only when one of its inputs changed.
    ///
    /// Every delivered thumbnail asks for it — `trimDeliveredToWindow` needs the window, and the
    /// window's size is also the retention cap — and every layout pass asks for it again. Computing
    /// it each time is work proportional to the *folder*, for geometry that is a function of four
    /// values. Measured in a Debug build: one delivery cost 1.3 ms at 1,000 images and 28.7 ms at
    /// 50,000, and the whole of it was rebuilding rows that had not moved.
    private var rowsCache: (key: RowsKey, rows: [GalleryRow])?

    /// What the geometry depends on: the two layout choices, the width it is computed for, and a
    /// revision counter that the list and the aspects bump. A counter rather than the aspect array:
    /// comparing 50,000 `CGFloat`s is cheap but pointless when the array can only change in one
    /// place.
    private struct RowsKey: Equatable {
        let kind: GalleryLayoutKind
        let thumbnailSize: CGFloat
        let width: CGFloat
        let contentRevision: Int
    }

    /// How many times the whole folder's geometry has actually been computed. Exposed so a test can
    /// tell "the cache answered" from "the geometry was rebuilt and happened to match".
    private(set) var rowsComputationCountForTesting = 0

    /// Bumped by every change to the content the geometry is computed *from*.
    private var contentRevision = 0

    var rows: [GalleryRow] {
        let key = RowsKey(kind: layoutKind, thumbnailSize: thumbnailSize,
                          width: layoutWidth, contentRevision: contentRevision)
        if let rowsCache, rowsCache.key == key { return rowsCache.rows }
        rowsComputationCountForTesting += 1
        let computed = GalleryLayout.rows(for: layoutKind, aspects: aspects,
                                          containerWidth: key.width,
                                          thumbnailSize: thumbnailSize)
        rowsCache = (key, computed)
        return computed
    }

    // MARK: - Layout and recycling

    /// The width the layout is computed for.
    ///
    /// The scroll view's, not this view's: a document view is *not* resized to fit its scroll view,
    /// so reading `bounds.width` here asks a question whose answer depends on the frame this method
    /// is about to set — measured as a gallery that laid out zero rows and created no cells.
    private var layoutWidth: CGFloat {
        if let scrollView = enclosingScrollView {
            let width = scrollView.contentSize.width
            if width > 0 { return width }
        }
        return bounds.width
    }

    /// How many layout passes this grid has run. Exposed so a test can tell "the reflow produced the
    /// right geometry" from "no reflow happened at all" — the two look identical from the frame.
    private(set) var layoutPassCountForTesting = 0

    override func layout() {
        super.layout()
        layoutPassCountForTesting += 1
        let width = layoutWidth
        let rows = self.rows
        let visible = visibleRectForCells
        let contentHeight = GalleryLayout.contentHeight(of: rows)
        if frame.size.height != contentHeight || frame.size.width != width {
            // The document view owns the scrollable area; the scroll view reads this frame.
            setFrameSize(NSSize(width: width, height: contentHeight))
        }

        var wanted: Set<Int> = []
        for row in GalleryLayout.visibleRows(in: visible, of: rows) {
            for cell in row.cells { wanted.insert(cell.index) }
        }

        // Give back the cells that left.
        for (index, cell) in visibleCells where !wanted.contains(index) {
            cell.removeFromSuperview()
            recycle(cell)
            visibleCells[index] = nil
        }
        // Materialize the ones that arrived.
        for row in GalleryLayout.visibleRows(in: visible, of: rows) {
            for cellFrame in row.cells where visibleCells[cellFrame.index] == nil {
                guard items.indices.contains(cellFrame.index) else { continue }
                let cell = dequeueCell()
                cell.frame = cellFrame.frame
                let item = items[cellFrame.index]
                cell.configure(item: item, thumbnail: thumbnail(at: cellFrame.index),
                               isCurrent: cellFrame.index == currentIndex,
                               placeholder: placeholderCaption(for: item))
                addSubview(cell)
                visibleCells[cellFrame.index] = cell
                if thumbnail(at: cellFrame.index) == nil { onThumbnailNeeded?(cellFrame.index, item) }
            }
            // A cell that is already materialized may still have moved (reflow).
            for cellFrame in row.cells {
                visibleCells[cellFrame.index]?.frame = cellFrame.frame
            }
        }
        trimDeliveredToWindow()
    }

    /// The vertical band above and below the visible rectangle that prefetch covers: two rows,
    /// measured at the current thumbnail size.
    private var prefetchBandHeight: CGFloat {
        2 * (thumbnailSize + GalleryLayout.filenameSlotHeight + GalleryLayout.rowSpacing)
    }

    /// The indexes the grid wants thumbnails for right now: visible rows plus a prefetch band
    /// above and below. This is the window the request scope — and the gallery's own delivered
    /// cache — is bounded to. A ten-thousand-image folder asks for this many thumbnails, not ten
    /// thousand.
    var thumbnailWindowIndexes: Set<Int> {
        let windowRect = visibleRectForCells.insetBy(dx: 0, dy: -prefetchBandHeight)
        var result: Set<Int> = []
        for row in GalleryLayout.visibleRows(in: windowRect, of: rows) {
            for cell in row.cells { result.insert(cell.index) }
        }
        return result
    }

    /// Releases every delivered thumbnail that is no longer in the window, but only once the
    /// retained set passes the cap. The gallery's retained images are therefore bounded by a
    /// constant of the viewport, never by the folder's size — while small folders keep their
    /// thumbnails through a reflow.
    private func trimDeliveredToWindow() {
        // A drag in progress must not evict. The cap is a function of the window size, and a
        // reflow that grows the thumbnails shrinks the window — so a mid-drag trim would cut the
        // retained set down to the smaller window and throw away exactly the thumbnails the same
        // drag is about to need again on the way back. The pause lasts only while the pointer is
        // down; the settle lifts it and trims to the window the drag ended on.
        guard !isRetentionPaused else { return }
        // One window, asked for once: it is both what is kept and the number the cap is derived
        // from, and asking twice walked the whole row list twice per delivery.
        let window = thumbnailWindowIndexes
        // No layout yet (or a degenerate one): there is no window to keep, so nothing to evict.
        guard !window.isEmpty else { return }
        guard delivered.count > max(64, window.count * 2) else { return }
        let keep = Set(window.compactMap { index -> String? in
            items.indices.contains(index) ? items[index].url.path : nil
        })
        if delivered.keys.contains(where: { !keep.contains($0) }) {
            delivered = delivered.filter { keep.contains($0.key) }
        }
    }

    /// The rectangle the cells must cover: the enclosing scroll view's visible area, or the whole
    /// bounds when there is no scroll view (which is what the tests and the first layout pass see).
    private var visibleRectForCells: CGRect {
        guard let scrollView = enclosingScrollView else { return bounds }
        let visible = scrollView.documentVisibleRect
        return visible.isEmpty ? bounds : visible
    }

    private func dequeueCell() -> GalleryItemView {
        if let reused = reusePool.popLast() { return reused }
        createdCellCount += 1
        return GalleryItemView(frame: .zero)
    }

    private func recycle(_ cell: GalleryItemView) {
        // Out of the hierarchy, not just out of the bookkeeping: `rebuild` recycles every visible
        // cell and then lays the new list out, and a recycled cell left in the view went on drawing
        // the folder it belonged to — measured as two grids overlapping after a folder was opened
        // from the tree.
        cell.removeFromSuperview()
        cell.representedURL = nil
        reusePool.append(cell)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Two different changes need a layout pass on the document view, and the clip view posts
        // them as two different notifications.
        //
        // Scrolling changes the visible *rectangle* (a bounds change) without a layout pass on the
        // document view, which is what materializes the cells that scrolled in.
        //
        // A *resize* of the content area changes the width every row is computed for — and the clip
        // view does not post a bounds change for it: measured, closing the folder tree produced one
        // `frameDidChangeNotification` and zero bounds notifications. Watching only the bounds is
        // why hiding the tree left the grid laid out for the narrow width: the 200 pt it gave back
        // was never used, because no layout pass ever ran. `layoutWidth` reads the scroll view, so a
        // pass is all that is needed.
        let center = NotificationCenter.default
        center.removeObserver(self, name: NSView.boundsDidChangeNotification, object: nil)
        center.removeObserver(self, name: NSView.frameDidChangeNotification, object: nil)
        guard let scrollView = enclosingScrollView else { return }
        scrollView.contentView.postsBoundsChangedNotifications = true
        scrollView.contentView.postsFrameChangedNotifications = true
        center.addObserver(self, selector: #selector(scrollViewDidScroll),
                           name: NSView.boundsDidChangeNotification,
                           object: scrollView.contentView)
        center.addObserver(self, selector: #selector(contentAreaDidResize),
                           name: NSView.frameDidChangeNotification,
                           object: scrollView.contentView)
    }

    @objc private func scrollViewDidScroll() {
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    /// The scroll view's content area changed size: the row geometry belongs to the old width.
    @objc private func contentAreaDidResize() {
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    // MARK: - Interaction

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let index = index(at: point) else { return }
        onSelectionChanged?(index)
        if event.clickCount == 2 { onItemOpened?(index) }
    }

    private func index(at point: CGPoint) -> Int? {
        for row in rows {
            for cell in row.cells where cell.frame.contains(point) { return cell.index }
        }
        return nil
    }

    // MARK: - Test access

    /// How many cells exist as views right now. This is the number the virtualization contract is
    /// about, and it must not grow with the folder.
    var materializedCellCount: Int { visibleCells.count }
    var visibleIndexes: Set<Int> { Set(visibleCells.keys) }
    var layoutKindForTesting: GalleryLayoutKind { layoutKind }
    var thumbnailSizeForTesting: CGFloat { thumbnailSize }
    var itemCount: Int { items.count }
    func cellForTesting(at index: Int) -> GalleryItemView? { visibleCells[index] }

    /// How many thumbnails the gallery itself is strongly retaining, keyed by path.
    /// The retention audit: this must stay a small window over a large folder.
    var deliveredImageCountForTesting: Int { delivered.count }
    /// The paths of every retained thumbnail, for folder-switch cross-contamination checks.
    var deliveredPathsForTesting: Set<String> { Set(delivered.keys) }
    /// Estimated retained pixel bytes, for the memory audit.
    var retainedThumbnailByteCountForTesting: Int {
        delivered.values.reduce(0) { $0 + $1.image.bytesPerRow * $1.image.height }
    }
    /// The pixel tier a delivered thumbnail was requested at, or nil.
    func deliveredPixelSizeForTesting(_ url: URL) -> Int? { delivered[url.path]?.pixelSize }
}
