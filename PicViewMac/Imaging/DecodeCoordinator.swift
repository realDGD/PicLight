import Foundation
import CoreGraphics

public enum NavigationDirection: Sendable {
    case forward
    case backward
    case unknown
}

public enum DecodeEvent: Sendable {
    case head(DecodedImageHead)
    case frame(DecodedFrame)
    case failure(String)
}

/// Serializes decode work, keeps only current + neighbours and cancels stale
/// work with generation tokens so a slow decode can never overwrite a newer one.
public actor DecodeCoordinator {
    private let decoder: ImageDecoding
    private let probe: DimensionProbing
    private var generation = 0
    private var currentTask: Task<Void, Never>?
    private var preloadTasks: [String: Task<Void, Never>] = [:]

    private let cache = DecodeCache()

    public init(decoder: ImageDecoding = ImageIODecoder(),
                probe: DimensionProbing = DimensionProbe()) {
        self.decoder = decoder
        self.probe = probe
    }

    /// Number of decode tasks currently in flight (current + preloads). Used by
    /// tests to prove that switching images does not accumulate work.
    public var activeTaskCount: Int {
        var count = 0
        if let currentTask, !currentTask.isCancelled { count += 1 }
        count += preloadTasks.count
        return count
    }

    public func nextGeneration() -> Int {
        generation += 1
        return generation
    }

    /// Decodes the requested item and streams head-then-frames. Preloads the
    /// adjacent items at lower priority in the direction of travel.
    /// `async` because the level prediction needs a header probe; callers already
    /// `await` it. The returned task is the current-image work, not the preloads.
    public func show(
        item url: URL,
        previous: URL? = nil,
        next: URL? = nil,
        direction: NavigationDirection = .unknown,
        target: DecodeTarget = .fullResolution,
        onEvent: @escaping @Sendable (DecodeEvent) -> Void
    ) async -> Task<Void, Never> {
        currentTask?.cancel()
        let token = nextGeneration()
        let decoder = self.decoder
        let cache = self.cache
        let pageIndex = target.pageIndex
        // Predict the level with a cheap header probe so the lookup key matches what
        // the decoder will produce. A wrong prediction costs one extra decode — never
        // a wrong bitmap, because the store key uses the level that was produced.
        let predicted = DecodeBudget.level(sourceLongEdge: await probe.longEdge(of: url),
                                           budget: target.maxPixelSize)
        let lookupKey = DecodeCacheKey(url: url, pageIndex: pageIndex, level: predicted)
        self.currentKey = lookupKey
        cache.setCurrent(lookupKey)

        if let cached = cache.head(for: lookupKey) {
            onEvent(.head(cached))
            await schedulePreload(previous: previous, next: next, direction: direction, target: target)
            return Task {}
        }

        let task = Task(priority: .userInitiated) {
            do {
                let head = try await decoder.decodeFirstDisplayableFrame(url, target: target)
                guard !Task.isCancelled, self.isCurrent(token) else { return }
                let storeKey = DecodeCacheKey(url: url, pageIndex: pageIndex, level: head.level)
                cache.store(head: head, for: storeKey)
                self.currentKey = storeKey
                cache.setCurrent(storeKey)
                onEvent(.head(head))

                // Pages of a multi-page document are not animation frames; they are
                // decoded only when the user asks for one.
                guard head.descriptor.animated else { return }
                let stream = decoder.decodeRemainingFrames(url, descriptor: head.descriptor)
                for try await frame in stream {
                    guard !Task.isCancelled, self.isCurrent(token) else { return }
                    cache.store(frame: frame, for: storeKey)
                    onEvent(.frame(frame))
                }
            } catch {
                // Corrupt files keep navigation alive; the UI shows a compact error
                // that names the file so the user knows which image is unreadable.
                if !Task.isCancelled, self.isCurrent(token) {
                    let reason = (error as? LocalizedError)?.errorDescription
                        ?? error.localizedDescription
                    onEvent(.failure("无法解码 \(url.lastPathComponent)：\(reason)"))
                }
            }
        }
        currentTask = task
        await schedulePreload(previous: previous, next: next, direction: direction, target: target)
        return task
    }

    private func isCurrent(_ token: Int) -> Bool { token == generation }

    /// Neighbour preload order is a pure decision so it can be tested exactly:
    /// forward navigation prioritizes the next image, backward the previous one.
    public static func preloadOrder(previous: URL?, next: URL?,
                                    direction: NavigationDirection) -> [URL] {
        let ordered: [URL?]
        switch direction {
        case .backward: ordered = [previous, next]
        case .forward, .unknown: ordered = [next, previous]
        }
        return ordered.compactMap { $0 }
    }

    private func schedulePreload(previous: URL?, next: URL?, direction: NavigationDirection,
                                 target: DecodeTarget) async {
        let wanted = Set(Self.preloadOrder(previous: previous, next: next, direction: direction)
            .map(\.path))
        // Neighbours that are no longer wanted are cancelled immediately, so
        // rapid switching cannot pile up obsolete preload work.
        for (path, task) in preloadTasks where !wanted.contains(path) {
            task.cancel()
            preloadTasks[path] = nil
        }

        for url in Self.preloadOrder(previous: previous, next: next, direction: direction) {
            guard preloadTasks[url.path] == nil else { continue }
            // Oversized (and unreadable) neighbours are skipped *before* any work
            // starts. ImageIO ignores task cancellation — a started giant decode runs
            // to completion and burns its whole cost (measured: 19.4 s and 62.8 J
            // after `Task.cancel()`), so the only safe way to avoid it is not to
            // begin it.
            let longEdge = await probe.longEdge(of: url)
            guard !OversizedPolicy.isOversized(sourceLongEdge: longEdge) else { continue }
            let level = DecodeBudget.level(sourceLongEdge: longEdge, budget: target.maxPixelSize)
            let key = DecodeCacheKey(url: url, pageIndex: target.pageIndex, level: level)
            guard cache.head(for: key) == nil else { continue }
            preloadTasks[url.path] = Task(priority: .utility) {
                await self.runPreload(url: url, target: target)
            }
        }
    }

    /// Actor-isolated so the bookkeeping entry is cleared as soon as the work
    /// ends, without spawning yet another task to do it.
    private func runPreload(url: URL, target: DecodeTarget) async {
        defer { preloadTasks[url.path] = nil }
        guard let head = try? await decoder.decodeFirstDisplayableFrame(url, target: target) else { return }
        guard !Task.isCancelled else { return }
        // Store under the level that was produced, so an exact-level lookup by the
        // later navigation hits.
        cache.store(head: head, for: DecodeCacheKey(url: url, pageIndex: target.pageIndex, level: head.level))
    }

    public func cancelAll() {
        currentTask?.cancel()
        for task in preloadTasks.values { task.cancel() }
        preloadTasks.removeAll()
    }

    /// The identity the cache must protect, so a purge keeps the on-screen level.
    public private(set) var currentKey: DecodeCacheKey?

    public func purgeCache(keeping key: DecodeCacheKey?) { cache.purge(keeping: key) }

    /// Purges everything except the entry the last `show` put on screen.
    public func purgeCacheKeepingCurrent() { cache.purge(keeping: currentKey) }
}
