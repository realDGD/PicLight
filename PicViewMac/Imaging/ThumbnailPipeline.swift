import Foundation
import CoreGraphics
import ImageIO

/// Downsampling thumbnails through ImageIO. An 8K source is never fully decoded
/// just to fill a ~150 px drawer cell, and the EXIF transform is applied here.
public actor ThumbnailPipeline {
    private let cache = NSCache<NSString, CGImageBox>()
    private var inFlight: [String: Task<CGImage?, Never>] = [:]
    /// The cache's real occupancy — `NSCache` does not report it, so the delegate is counted.
    private let accounting = ThumbnailCacheAccounting()
    /// Decoded thumbnails, kept between launches. The memory cache dies with the process; a
    /// 1.5-gigapixel PNG (48,000 × 32,000, measured on a real file) costs ImageIO ≈18 s to thumbnail
    /// *whatever* the target size or subsampling factor, so that cost has to be paid once ever rather
    /// than once per visit.
    private let diskCache: ThumbnailDiskCache?
    /// macOS's thumbnail cache: the cascade's third leg, consulted only where a decode is expensive.
    private let quickLook: QuickLookThumbnailProviding?
    /// Requests already left running after their budget expired, so a folder of huge files cannot
    /// pile up one per cell.
    private var lateQuickLookRequests: Set<String> = []
    /// How many decodes run at once. Each one is a file read plus a decode; a folder of large images
    /// would otherwise start as many as there are visible cells and thrash the disk. An async gate,
    /// not a `DispatchSemaphore`: blocking a cooperative-pool thread is exactly what an `await` here
    /// must not do.
    static let decodeGate = AsyncGate(limit: 4)

    /// - Parameter diskCache: the persistent store, or nil for an in-memory-only pipeline. The app
    ///   passes `.default`; tests leave it out, so a thumbnail stored by one test can never make
    ///   another test's "this file was decoded" assertion false.
    public init(cacheLimit: Int = 600, diskCache: ThumbnailDiskCache? = nil,
                quickLook: QuickLookThumbnailProviding? = nil) {
        cache.countLimit = cacheLimit
        cache.totalCostLimit = 48 * 1024 * 1024
        cache.delegate = accounting
        self.diskCache = diskCache
        self.quickLook = quickLook
    }

    /// How long macOS's thumbnail cache gets before the caller stops waiting.
    ///
    /// Measured: 23 ms from the system cache, 20.7 s when it has to generate one from a 1.9 GB PNG.
    /// The budget has to sit between those, and near the cheap end: the whole point is to avoid a
    /// wait, not to trade one for a shorter one.
    public static let quickLookBudget: TimeInterval = 0.4

    /// The system's own thumbnail for this file, if it has one within `budget`.
    ///
    /// A request that outlives its budget is *not* cancelled: when it finally answers, the result is
    /// put into the memory and disk caches, so the next look at that folder is instant. That is how a
    /// folder of huge files fills itself in without the user opening each one.
    public func systemThumbnail(for url: URL, maxPixelSize: Int,
                                budget: TimeInterval = ThumbnailPipeline.quickLookBudget) async -> CGImage? {
        guard let quickLook else { return nil }
        let identity = SourceFileIdentity.read(at: url)
        let cacheKey = "\(identity.versionToken)|\(maxPixelSize)"

        let image = await Self.timeBoxedQuickLook(quickLook, url: url, maxPixelSize: maxPixelSize,
                                                  budget: budget) { [weak self] late in
            guard let self else { return }
            Task { await self.keepLateQuickLook(late, forKey: cacheKey, url: url,
                                                maxPixelSize: maxPixelSize) }
        }
        guard let image, let fitted = Self.fitting(image, maxPixelSize: maxPixelSize),
              Self.isSharpEnough(fitted, forRequest: maxPixelSize) else {
            return nil
        }
        // Same guard as the disk cache: a thumbnail that is not this file's shape cannot be this
        // file's picture, whatever the system handed back.
        guard Self.matchesShape(fitted, of: url) else { return nil }
        await remember(fitted, for: url, maxPixelSize: maxPixelSize)
        ThumbnailPipelineMetrics.noteQuickLookHit()
        return fitted
    }

    /// Stores a late answer, so the work the system already did is not thrown away. Bounded to one
    /// in flight per file and size.
    private func keepLateQuickLook(_ image: CGImage, forKey key: String, url: URL,
                                   maxPixelSize: Int) async {
        lateQuickLookRequests.remove(key)
        guard let fitted = Self.fitting(image, maxPixelSize: maxPixelSize),
              Self.isSharpEnough(fitted, forRequest: maxPixelSize),
              Self.matchesShape(fitted, of: url) else { return }
        await remember(fitted, for: url, maxPixelSize: maxPixelSize)
        ThumbnailPipelineMetrics.noteQuickLookLateArrival()
    }

    /// Waits for the system's answer, but no longer than `budget`. A later answer goes to `onLate`.
    static func timeBoxedQuickLook(_ source: QuickLookThumbnailProviding, url: URL, maxPixelSize: Int,
                                   budget: TimeInterval,
                                   onLate: @escaping @Sendable (CGImage) -> Void) async -> CGImage? {
        await withCheckedContinuation { continuation in
            let once = ResumeOnce()
            source.requestLowQualityThumbnail(for: url, maxPixelSize: maxPixelSize) { image in
                guard let image else {
                    once.resume(continuation, with: nil)
                    return
                }
                if !once.resume(continuation, with: image) { onLate(image) }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + budget) {
                once.resume(continuation, with: nil)
            }
        }
    }

    /// Scales a system thumbnail down to what was asked for. A warm system cache answers with
    /// whatever size it stored — measured: 2048 × 1365 for a 320 px request — and holding that per
    /// cell would cost megabytes for a picture that will be drawn 150 points wide.
    static func fitting(_ image: CGImage, maxPixelSize: Int) -> CGImage? {
        let longEdge = max(image.width, image.height)
        guard maxPixelSize > 0 else { return nil }
        if longEdge <= maxPixelSize { return image }
        let scale = CGFloat(maxPixelSize) / CGFloat(longEdge)
        let width = max(1, Int((CGFloat(image.width) * scale).rounded()))
        let height = max(1, Int((CGFloat(image.height) * scale).rounded()))
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    /// Whether a system thumbnail is sharp enough for the size that was asked for.
    ///
    /// The grid decides how big a cell is; a thumbnail smaller than the cell is drawn *upscaled* by
    /// `NSImageView`, which is exactly the blur the slider must not produce. macOS's cache holds
    /// whatever it stored for the file — measured: a 2048 × 1365 answer for a 320 px request (fine,
    /// scaled down) but a folder browsed in Finder at icon size can hold a 128 px one — so an answer
    /// below the request is refused. A quarter under is allowed: a 1.33× stretch is not visible in a
    /// photo grid, and refusing it would trade a slightly soft cell for no cell at all.
    ///
    /// This only ever applies to the oversized path, where the alternative is the placeholder.
    static func isSharpEnough(_ image: CGImage, forRequest maxPixelSize: Int) -> Bool {
        guard maxPixelSize > 0 else { return false }
        let longEdge = max(image.width, image.height)
        return CGFloat(longEdge) >= CGFloat(maxPixelSize) * 0.75
    }

    /// Whether an image has the shape the file at this URL does — the guard that keeps another
    /// picture's pixels out of a cell.
    static func matchesShape(_ image: CGImage, of url: URL) -> Bool {
        guard let size = ImageHeaderProbe.pixelSize(of: url), size.height > 0, image.height > 0
        else { return true }
        let expected = size.width / size.height
        let actual = CGFloat(image.width) / CGFloat(image.height)
        let tolerance: CGFloat = 0.02
        return abs(actual - expected) <= expected * tolerance
            || abs(actual - 1 / expected) <= (1 / expected) * tolerance
    }

    public func thumbnail(for url: URL, maxPixelSize: Int) async throws -> CGImage {
        // The cache key is the file's identity, not its path: a file replaced at the same path is
        // a different file, and the old pixels must never be served for it. The identity is one
        // `stat`; the decode it guards is orders of magnitude more expensive.
        let identity = SourceFileIdentity.read(at: url)
        let key = "\(identity.versionToken)|\(maxPixelSize)" as NSString
        if let cached = cache.object(forKey: key) { return cached.image }

        if let existing = inFlight[key as String] {
            if let image = await existing.value { return image }
        }

        let cacheKey = key as String
        let diskCache = self.diskCache
        let task = Task.detached(priority: .utility) { () -> CGImage? in
            // The source's shape, read from the image header: one cheap read that makes a wrongly
            // stored entry detectable (see `ThumbnailDiskCache.thumbnail(forKey:expectedAspect:)`).
            let expectedAspect = ImageHeaderProbe.pixelSize(of: url).flatMap { size -> CGFloat? in
                size.height > 0 ? size.width / size.height : nil
            }
            if let onDisk = diskCache?.thumbnail(forKey: cacheKey, expectedAspect: expectedAspect) {
                ThumbnailPipelineMetrics.noteDiskCacheHit()
                return onDisk
            }
            // A bounded number of decodes at a time: the gate is held only around the decode itself.
            await Self.decodeGate.acquire()
            ThumbnailPipelineMetrics.noteDecodeStarted()
            let decoded = Self.makeThumbnail(url: url, maxPixelSize: maxPixelSize)
            ThumbnailPipelineMetrics.noteDecodeFinished()
            await Self.decodeGate.release()
            if let decoded {
                diskCache?.store(decoded, forKey: cacheKey)
            }
            return decoded
        }
        inFlight[cacheKey] = task
        let image = await task.value
        inFlight[cacheKey] = nil
        guard let image else { throw ImageDecodeError.noDisplayableImage }
        let cost = image.bytesPerRow * image.height
        cache.setObject(CGImageBox(image), forKey: key, cost: cost)
        accounting.noteInsert(cost: cost)
        return image
    }

    /// Remembers an image the caller derived from pixels it already had, under the same key a decode
    /// would use — so the next request for this file and size is a cache hit, and the disk copy
    /// survives the launch.
    public func remember(_ image: CGImage?, for url: URL, maxPixelSize: Int) {
        guard let image else { return }
        let identity = SourceFileIdentity.read(at: url)
        let key = "\(identity.versionToken)|\(maxPixelSize)"
        let cost = image.bytesPerRow * image.height
        cache.setObject(CGImageBox(image), forKey: key as NSString, cost: cost)
        accounting.noteInsert(cost: cost)
        diskCache?.store(image, forKey: key)
    }

    /// Downsamples an already-decoded image for the navigator preview. This is a
    /// resample of pixels the viewer already holds, not a second decoder, and it
    /// runs off the main actor.
    public func preview(from image: CGImage, maxPixelSize: Int) async -> CGImage? {
        ThumbnailPipelineMetrics.notePreview()
        return await Task.detached(priority: .utility) {
            let width = image.width
            let height = image.height
            guard width > 0, height > 0, maxPixelSize > 0 else { return nil }
            let scale = min(1, CGFloat(maxPixelSize) / CGFloat(max(width, height)))
            let targetWidth = max(1, Int((CGFloat(width) * scale).rounded()))
            let targetHeight = max(1, Int((CGFloat(height) * scale).rounded()))
            guard let context = CGContext(
                data: nil, width: targetWidth, height: targetHeight,
                bitsPerComponent: 8, bytesPerRow: 0,
                space: image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return nil }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
            return context.makeImage()
        }.value
    }

    public func cancelAll() {
        for task in inFlight.values { task.cancel() }
        inFlight.removeAll()
    }

    public func purge() {
        cache.removeAllObjects()
        accounting.reset()
    }

    /// Forgets the on-disk copies as well. Tests use it to prove a second decode really is a second
    /// decode; the app has no reason to call it.
    public func purgeDiskCache() {
        diskCache?.removeAll()
    }

    public var diskCacheDirectory: URL? { diskCache?.directory }

    /// How many thumbnails the cache is actually holding right now. The effective-memory audit:
    /// the pipeline is the bounded cache authority, and this is its real occupancy.
    public var retainedImageCount: Int { accounting.snapshot.count }
    /// The real cost (bytes) the cache is currently holding.
    public var retainedImageBytes: Int { accounting.snapshot.cost }

    static func makeThumbnail(url: URL, maxPixelSize: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        ThumbnailPipelineMetrics.noteFileDecode(url)
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

/// An async counting gate: at most `limit` holders at a time, first come first served.
///
/// A slot is handed straight to the next waiter on release rather than decremented and re-acquired,
/// so the count cannot drift.
actor AsyncGate {
    private let limit: Int
    private var inUse = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) { self.limit = max(1, limit) }

    func acquire() async {
        if inUse < limit {
            inUse += 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty {
            inUse = max(0, inUse - 1)
        } else {
            waiters.removeFirst().resume()
        }
    }

    var inUseForTesting: Int { inUse }
}

/// `NSCache` needs class values; `CGImage` is immutable so boxing is safe.
final class CGImageBox: @unchecked Sendable {
    let image: CGImage
    init(_ image: CGImage) { self.image = image }
}

/// Counts what `NSCache` is actually holding. `NSCache` evicts lazily and silently, so the
/// effective-memory numbers come from its delegate: every eviction is counted back out. The
/// delegate is called from whichever thread evicts, so the counters are locked.
final class ThumbnailCacheAccounting: NSObject, NSCacheDelegate, @unchecked Sendable {
    private let lock = NSLock()
    nonisolated(unsafe) private var count = 0
    nonisolated(unsafe) private var cost = 0

    func noteInsert(cost: Int) {
        lock.lock(); defer { lock.unlock() }
        count += 1
        self.cost += cost
    }

    func reset() {
        lock.lock(); defer { lock.unlock() }
        count = 0
        cost = 0
    }

    func cache(_ cache: NSCache<AnyObject, AnyObject>, willEvictObject obj: Any) {
        lock.lock(); defer { lock.unlock() }
        count = max(0, count - 1)
        if let box = obj as? CGImageBox {
            cost = max(0, cost - box.image.bytesPerRow * box.image.height)
        }
    }

    var snapshot: (count: Int, cost: Int) {
        lock.lock(); defer { lock.unlock() }
        return (count, cost)
    }
}

/// Counting seams for the large-image tests and diagnostics.
///
/// Separate from the actor so the counters stay plain process-wide values: what the
/// drawer-safety tests assert is "this file was never read from disk" and "this
/// bitmap was resampled from one already in hand", not actor state.
public enum ThumbnailPipelineMetrics {
    // Drawer cells are filled by several concurrent tasks, so these counters need a
    // lock: an unsynchronised `Set` insert from two threads corrupts the set (this
    // crashed the drawer-safety test with an unrecognised-selector exception before
    // the lock was added).
    private static let lock = NSLock()
    nonisolated(unsafe) private static var paths: Set<String> = []
    nonisolated(unsafe) private static var previews = 0
    nonisolated(unsafe) private static var hits = 0
    nonisolated(unsafe) private static var quickLook = 0
    nonisolated(unsafe) private static var lateArrivals = 0
    nonisolated(unsafe) private static var running = 0
    nonisolated(unsafe) private static var peak = 0

    /// Files whose thumbnail was actually decoded from disk.
    public static var decodedFilePaths: Set<String> {
        lock.lock(); defer { lock.unlock() }
        return paths
    }

    /// Resamples of an already-decoded bitmap (navigator, current drawer cell).
    public static var previewCount: Int {
        lock.lock(); defer { lock.unlock() }
        return previews
    }

    /// Thumbnails macOS's own cache answered with.
    public static var quickLookHits: Int {
        lock.lock(); defer { lock.unlock() }
        return quickLook
    }

    /// Answers that arrived after their budget, and were kept for the next look.
    public static var quickLookLateArrivals: Int {
        lock.lock(); defer { lock.unlock() }
        return lateArrivals
    }

    /// Thumbnails that came from the disk cache instead of the decoder.
    public static var diskCacheHits: Int {
        lock.lock(); defer { lock.unlock() }
        return hits
    }

    /// Decodes running right now, and the most that ever ran at once. The bound is what keeps a
    /// folder of large images from starting one decode per visible cell.
    public static var decodePeak: Int {
        lock.lock(); defer { lock.unlock() }
        return peak
    }

    public static func reset() {
        lock.lock()
        paths.removeAll(); previews = 0; hits = 0; running = 0; peak = 0
        quickLook = 0; lateArrivals = 0
        lock.unlock()
    }

    static func noteFileDecode(_ url: URL) {
        lock.lock(); paths.insert(url.path); lock.unlock()
    }

    static func notePreview() {
        lock.lock(); previews += 1; lock.unlock()
    }

    static func noteDiskCacheHit() {
        lock.lock(); hits += 1; lock.unlock()
    }

    static func noteQuickLookHit() {
        lock.lock(); quickLook += 1; lock.unlock()
    }

    static func noteQuickLookLateArrival() {
        lock.lock(); lateArrivals += 1; lock.unlock()
    }

    static func noteDecodeStarted() {
        lock.lock(); running += 1; peak = max(peak, running); lock.unlock()
    }

    static func noteDecodeFinished() {
        lock.lock(); running = max(0, running - 1); lock.unlock()
    }
}
