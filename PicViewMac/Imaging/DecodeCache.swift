import Foundation
import CoreGraphics

/// Decode identity: the same file can be decoded natively, at several bounded
/// levels, on several pages. One value carries all of it so a lookup, a store and
/// the memory-pressure purge all agree on what "the current entry" means.
///
/// Do not spell a key by concatenating strings anywhere else: `DecodeCache` is the
/// only place that knows how identity maps onto `NSCache` keys.
public struct DecodeCacheKey: Hashable, Sendable {
    public let url: URL
    public let pageIndex: Int
    public let level: DecodeLevel

    public init(url: URL, pageIndex: Int = 0, level: DecodeLevel) {
        self.url = url
        self.pageIndex = pageIndex
        self.level = level
    }
}

/// Cost-based cache for decoded heads and animation frames. Cost is the real
/// decoded byte size (`bytesPerRow × height`) so an 8K image evicts a thumbnail
/// long before a folder of small images would.
///
/// The budget is the *bitmap cache* limit chosen by the B-series benchmark
/// (768 MiB). It is not a whole-app memory ceiling: the current image also owns a
/// mipmapped Metal texture, and the composed working set is validated separately.
/// `NSCache` owns eviction and does not report what it retains, so this type
/// deliberately exposes its budget instead of inventing a retained-cost number.
public final class DecodeCache: @unchecked Sendable {
    private let cache = NSCache<NSString, CacheEntry>()
    private let lock = NSLock()
    private var currentKey: DecodeCacheKey?

    public init(totalCostLimit: Int = 768 * 1024 * 1024) {
        cache.totalCostLimit = totalCostLimit
        cache.countLimit = 24

        NotificationCenter.default.addObserver(
            forName: .decodeCacheMemoryPressure, object: nil, queue: nil
        ) { [weak self] _ in
            // Memory pressure purges everything except the image on screen.
            self?.purge(keeping: self?.currentKey)
        }
    }

    /// The bitmap-cache budget in bytes.
    public var budgetBytes: Int { cache.totalCostLimit }

    /// The entry the cache must protect from purges — url + page + level, so a
    /// purge keeps the bitmap that is actually on screen rather than another level
    /// of the same file.
    public func setCurrent(_ key: DecodeCacheKey?) {
        lock.lock(); defer { lock.unlock() }
        currentKey = key
    }

    public func head(for key: DecodeCacheKey) -> DecodedImageHead? {
        lock.lock(); defer { lock.unlock() }
        return (cache.object(forKey: Self.nsKey(key)) as? HeadEntry)?.head
    }

    public func store(head: DecodedImageHead, for key: DecodeCacheKey) {
        lock.lock(); defer { lock.unlock() }
        let entry = HeadEntry(head)
        cache.setObject(entry, forKey: Self.nsKey(key), cost: Self.cost(of: head.image))
    }

    public func frame(for key: DecodeCacheKey, index: Int) -> DecodedFrame? {
        lock.lock(); defer { lock.unlock() }
        return (cache.object(forKey: Self.nsKey(key, frame: index)) as? FrameEntry)?.frame
    }

    public func store(frame: DecodedFrame, for key: DecodeCacheKey) {
        lock.lock(); defer { lock.unlock() }
        if frame.index == 0 { return }
        let entry = FrameEntry(frame)
        cache.setObject(entry, forKey: Self.nsKey(key, frame: frame.index),
                        cost: Self.cost(of: frame.image))
    }

    /// Memory pressure keeps only the entry for `key` (the image on screen).
    public func purge(keeping key: DecodeCacheKey?) {
        lock.lock(); defer { lock.unlock() }
        guard let key else { cache.removeAllObjects(); return }
        let keep = Self.nsKey(key)
        let kept = cache.object(forKey: keep)
        cache.removeAllObjects()
        if let kept { cache.setObject(kept, forKey: keep, cost: 0) }
    }

    /// Cost is the real decoded byte size of one frame, per the spec:
    /// `bytesPerRow × height`.
    static func cost(of image: CGImage) -> Int {
        image.bytesPerRow * image.height
    }

    // MARK: - Key spelling (the only place identity becomes a string)

    private static func nsKey(_ key: DecodeCacheKey) -> NSString {
        "head:\(key.url.path):p\(key.pageIndex):l\(key.level.token)" as NSString
    }

    private static func nsKey(_ key: DecodeCacheKey, frame index: Int) -> NSString {
        "frame:\(key.url.path):p\(key.pageIndex):l\(key.level.token):f\(index)" as NSString
    }
}

private class CacheEntry: NSObject {}
private final class HeadEntry: CacheEntry {
    let head: DecodedImageHead
    init(_ head: DecodedImageHead) { self.head = head }
}
private final class FrameEntry: CacheEntry {
    let frame: DecodedFrame
    init(_ frame: DecodedFrame) { self.frame = frame }
}

extension Notification.Name {
    static let decodeCacheMemoryPressure = Notification.Name("com.picviewmac.decodecache.memorypressure")
}
