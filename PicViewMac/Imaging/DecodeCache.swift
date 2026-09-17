import Foundation
import CoreGraphics

/// Cost-based cache for decoded heads and animation frames. Cost is the real
/// decoded byte size (`bytesPerRow × height`) so an 8K image evicts a thumbnail
/// long before a folder of small images would.
public final class DecodeCache: @unchecked Sendable {
    private let cache = NSCache<NSString, CacheEntry>()
    private let lock = NSLock()
    private var currentURL: URL?

    public init(totalCostLimit: Int = 384 * 1024 * 1024) {
        cache.totalCostLimit = totalCostLimit
        cache.countLimit = 24

        NotificationCenter.default.addObserver(
            forName: .decodeCacheMemoryPressure, object: nil, queue: nil
        ) { [weak self] _ in
            // Memory pressure purges everything except the image on screen.
            self?.purge(keeping: self?.currentURL)
        }
    }

    public func setCurrent(_ url: URL?) {
        lock.lock(); defer { lock.unlock() }
        currentURL = url
    }

    public func head(for url: URL) -> DecodedImageHead? {
        lock.lock(); defer { lock.unlock() }
        return (cache.object(forKey: Self.headKey(url)) as? HeadEntry)?.head
    }

    public func store(head: DecodedImageHead, for url: URL) {
        lock.lock(); defer { lock.unlock() }
        let entry = HeadEntry(head)
        cache.setObject(entry, forKey: Self.headKey(url), cost: Self.cost(of: head.image))
    }

    public func frame(for url: URL, index: Int) -> DecodedFrame? {
        lock.lock(); defer { lock.unlock() }
        return (cache.object(forKey: Self.frameKey(url, index)) as? FrameEntry)?.frame
    }

    public func store(frame: DecodedFrame, for url: URL) {
        lock.lock(); defer { lock.unlock() }
        if frame.index == 0 { return }
        let entry = FrameEntry(frame)
        cache.setObject(entry, forKey: Self.frameKey(url, frame.index), cost: Self.cost(of: frame.image))
    }

    /// Memory pressure keeps only the currently shown image.
    public func purge(keeping url: URL?) {
        lock.lock(); defer { lock.unlock() }
        guard let url else { cache.removeAllObjects(); return }
        let keep = Self.headKey(url)
        let kept = cache.object(forKey: keep)
        cache.removeAllObjects()
        if let kept { cache.setObject(kept, forKey: keep, cost: 0) }
    }

    /// Cost is the real decoded byte size of one frame, per the spec:
    /// `bytesPerRow × height`.
    static func cost(of image: CGImage) -> Int {
        image.bytesPerRow * image.height
    }

    private static func headKey(_ url: URL) -> NSString { "head:\(url.path)" as NSString }
    private static func frameKey(_ url: URL, _ index: Int) -> NSString {
        "frame:\(url.path):\(index)" as NSString
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
