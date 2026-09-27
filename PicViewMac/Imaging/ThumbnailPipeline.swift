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
    /// How many decodes run at once. Each one is a file read plus a decode; a folder of large images
    /// would otherwise start as many as there are visible cells and thrash the disk. An async gate,
    /// not a `DispatchSemaphore`: blocking a cooperative-pool thread is exactly what an `await` here
    /// must not do.
    static let decodeGate = AsyncGate(limit: 4)

    /// - Parameter diskCache: the persistent store, or nil for an in-memory-only pipeline. The app
    ///   passes `.default`; tests leave it out, so a thumbnail stored by one test can never make
    ///   another test's "this file was decoded" assertion false.
    public init(cacheLimit: Int = 600, diskCache: ThumbnailDiskCache? = nil) {
        cache.countLimit = cacheLimit
        cache.totalCostLimit = 48 * 1024 * 1024
        cache.delegate = accounting
        self.diskCache = diskCache
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
            if let onDisk = diskCache?.thumbnail(forKey: cacheKey) {
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
        lock.lock(); paths.removeAll(); previews = 0; hits = 0; running = 0; peak = 0; lock.unlock()
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

    static func noteDecodeStarted() {
        lock.lock(); running += 1; peak = max(peak, running); lock.unlock()
    }

    static func noteDecodeFinished() {
        lock.lock(); running = max(0, running - 1); lock.unlock()
    }
}
