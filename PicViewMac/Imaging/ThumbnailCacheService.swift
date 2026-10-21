import AppKit

/// One disk store for the app, with independent pipelines for each viewer's lifecycle.
@MainActor
public final class ThumbnailCacheService {
    public static let shared = ThumbnailCacheService()
    public static let didClearNotification = Notification.Name("com.piclight.thumbnail-cache-cleared")
    private let diskCache: ThumbnailDiskCache?
    private var pipelines: [WeakPipeline] = []

    public init(diskCache: ThumbnailDiskCache? = .default) { self.diskCache = diskCache }

    public func makePipeline() -> ThumbnailPipeline {
        let pipeline = ThumbnailPipeline(diskCache: diskCache, quickLook: SystemQuickLookThumbnails())
        pipelines.removeAll { $0.value == nil }
        pipelines.append(WeakPipeline(pipeline))
        return pipeline
    }

    public struct Statistics: Sendable {
        public let diskCount: Int
        public let diskBytes: Int
        public let memoryCount: Int
        public let memoryBytes: Int
    }

    public func statistics() async -> Statistics {
        let disk = diskCache
        let diskStats = await Task.detached(priority: .utility) {
            (disk?.entryCount ?? 0, disk?.byteCount ?? 0)
        }.value
        var count = 0, bytes = 0
        for pipeline in pipelines.compactMap(\.value) {
            count += await pipeline.retainedImageCount
            bytes += await pipeline.retainedImageBytes
        }
        return Statistics(diskCount: diskStats.0, diskBytes: diskStats.1,
                          memoryCount: count, memoryBytes: bytes)
    }

    public func clear() async {
        let disk = diskCache
        await Task.detached(priority: .utility) { disk?.removeAll() }.value
        for pipeline in pipelines.compactMap(\.value) { await pipeline.purge() }
        NotificationCenter.default.post(name: Self.didClearNotification, object: self)
    }

    public func revealInFinder() {
        guard let directory = diskCache?.directory else { return }
        NSWorkspace.shared.open(directory)
    }

    private final class WeakPipeline {
        weak var value: ThumbnailPipeline?
        init(_ value: ThumbnailPipeline) { self.value = value }
    }
}
