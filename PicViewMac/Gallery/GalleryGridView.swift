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

        selectionRing.wantsLayer = true
        selectionRing.layer?.borderWidth = 2
        selectionRing.layer?.borderColor = NSColor.controlAccentColor.cgColor
        selectionRing.layer?.cornerRadius = 4
        selectionRing.isHidden = true
        selectionRing.translatesAutoresizingMaskIntoConstraints = false

        addSubview(imageView2)
        addSubview(selectionRing)
        addSubview(nameLabel)
        NSLayoutConstraint.activate([
            imageView2.leadingAnchor.constraint(equalTo: leadingAnchor),
            imageView2.trailingAnchor.constraint(equalTo: trailingAnchor),
            imageView2.topAnchor.constraint(equalTo: topAnchor),
            imageView2.bottomAnchor.constraint(equalTo: bottomAnchor,
                                               constant: -GalleryLayout.filenameSlotHeight),

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

    func configure(item: FolderItem, thumbnail: CGImage?, isCurrent: Bool) {
        representedURL = item.url
        nameLabel.stringValue = item.displayName
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
        // Everything on screen belongs to the old list.
        for (_, cell) in visibleCells { recycle(cell) }
        visibleCells.removeAll()
        if !sameFiles { delivered.removeAll() }
        needsLayout = true
    }

    func setCurrentIndex(_ index: Int?) {
        guard index != currentIndex else { return }
        currentIndex = index
        for (itemIndex, cell) in visibleCells where items.indices.contains(itemIndex) {
            cell.configure(item: items[itemIndex], thumbnail: thumbnail(at: itemIndex),
                           isCurrent: itemIndex == index)
        }
    }

    /// Live reflow: geometry only. No thumbnail is requested and nothing is decoded — that is the
    /// settled handler's job, so dragging the slider cannot cause a decode per pixel.
    func setThumbnailSize(_ size: CGFloat) {
        let clamped = GalleryLayout.clampThumbnailSize(size)
        guard clamped != thumbnailSize else { return }
        thumbnailSize = clamped
        needsLayout = true
    }

    func setLayoutKind(_ kind: GalleryLayoutKind) {
        guard kind != layoutKind else { return }
        layoutKind = kind
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
        guard let cell = visibleCells[index] else { return false }
        cell.configure(item: items[index], thumbnail: image, isCurrent: index == currentIndex)
        return true
    }

    /// The cells a layout produces for the current width, for tests.
    func rowsForTesting(containerWidth: CGFloat) -> [GalleryRow] {
        GalleryLayout.rows(for: layoutKind, aspects: aspects, containerWidth: containerWidth,
                           thumbnailSize: thumbnailSize)
    }

    var rows: [GalleryRow] {
        GalleryLayout.rows(for: layoutKind, aspects: aspects, containerWidth: bounds.width,
                           thumbnailSize: thumbnailSize)
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

    override func layout() {
        super.layout()
        let width = layoutWidth
        let rows = GalleryLayout.rows(for: layoutKind, aspects: aspects, containerWidth: width,
                                      thumbnailSize: thumbnailSize)
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
                               isCurrent: cellFrame.index == currentIndex)
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

    /// The most thumbnails the gallery keeps before trimming to its window: the window size times
    /// two, with a floor of 64. Above the cap the delivered cache is trimmed to exactly the
    /// window; below it nothing is evicted, so a slider reflow (which re-lays-out without new
    /// decode intent) never churns the retained set and never re-requests.
    private var deliveredRetentionCap: Int { max(64, thumbnailWindowIndexes.count * 2) }

    /// Releases every delivered thumbnail that is no longer in the window, but only once the
    /// retained set passes the cap. The gallery's retained images are therefore bounded by a
    /// constant of the viewport, never by the folder's size — while small folders keep their
    /// thumbnails through a reflow.
    private func trimDeliveredToWindow() {
        let window = thumbnailWindowIndexes
        // No layout yet (or a degenerate one): there is no window to keep, so nothing to evict.
        guard !window.isEmpty else { return }
        guard delivered.count > deliveredRetentionCap else { return }
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
        cell.representedURL = nil
        reusePool.append(cell)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Scrolling changes the visible rectangle without a layout pass on the document view.
        let center = NotificationCenter.default
        center.removeObserver(self, name: NSView.boundsDidChangeNotification, object: nil)
        guard let scrollView = enclosingScrollView else { return }
        scrollView.contentView.postsBoundsChangedNotifications = true
        center.addObserver(self, selector: #selector(scrollViewDidScroll),
                           name: NSView.boundsDidChangeNotification,
                           object: scrollView.contentView)
    }

    @objc private func scrollViewDidScroll() {
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
