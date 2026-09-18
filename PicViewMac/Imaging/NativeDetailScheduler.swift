import CoreGraphics
import Foundation

/// Runs the tile passes.
///
/// One pass at a time, because a pass is a full traversal of the compressed stream and two
/// of them would compete for the same resource to produce the same rows. Requests describe
/// what the viewport needs; the scheduler decides whether that means "the running pass
/// already covers it" (nothing to do), "queue it for after this pass" (a small pan — the
/// inflate is already paid for, so cutting it short wastes it), or "cancel and restart"
/// (a jump to somewhere else, or the viewport no longer wanting native detail at all).
public actor NativeDetailScheduler {
    /// Called on a background queue for every tile that is decoded, so the viewer can
    /// publish it without polling.
    public var onTile: (@Sendable (NativeTile) -> Void)?
    /// Called when a pass ends, successfully or not.
    public var onPassFinished: (@Sendable (NativeDetailStats) -> Void)?

    private let provider: NativeTileProviding
    public let cache: NativeTileCache
    private let gutter: Int
    private let tileSize: Int

    private var generation = 0
    private var passTask: Task<Void, Never>?
    private var runningPlan: NativeTilePlan?
    private var pendingPlan: NativeTilePlan?
    /// Colour space of the source as ImageIO interpreted it, applied to every tile.
    private var colorSpace: CGColorSpace?
    private var runningSource: URL?
    private var inFlightKeys: Set<NativeTileKey> = []
    private var stats = NativeDetailStats()

    public init(provider: NativeTileProviding = PNGNativeTileProvider(),
                cache: NativeTileCache = NativeTileCache(),
                tileSize: Int = 512,
                gutter: Int = 1) {
        self.provider = provider
        self.cache = cache
        self.tileSize = tileSize
        self.gutter = gutter
    }

    public func setOnTile(_ handler: @escaping @Sendable (NativeTile) -> Void) {
        onTile = handler
    }

    /// Asks for the tiles a viewport needs. Safe to call on every geometry change.
    public func request(plan: NativeTilePlan, source: URL, pageIndex: Int = 0,
                        colorSpace: CGColorSpace? = nil) {
        self.colorSpace = colorSpace
        let visibleKeys = Set(plan.visible.map { key($0, source: source, pageIndex: pageIndex) })
        cache.pin(visibleKeys)

        if let running = runningPlan, let runningSource, runningSource == source {
            let covered = Set(running.allCoordinates.map { key($0, source: source, pageIndex: pageIndex) })
            let missing = visibleKeys.subtracting(covered)
            if missing.isEmpty {
                pendingPlan = nil          // the running pass already covers this viewport
                return
            }
            // A small move: let the pass finish (its inflate is already spent) and follow up.
            let overlap = visibleKeys.intersection(covered)
            if !overlap.isEmpty || running.visible.isEmpty {
                pendingPlan = plan
                return
            }
        }
        start(plan: plan, source: source, pageIndex: pageIndex)
    }

    /// Drops native detail entirely: zoomed out, animated, or the image changed.
    public func stopAndPurge() {
        generation += 1
        passTask?.cancel()
        passTask = nil
        runningPlan = nil
        pendingPlan = nil
        runningSource = nil
        inFlightKeys.removeAll()
        cache.removeAll()
    }

    /// Keeps what is already decoded but stops work: used when a decode level is replaced,
    /// so the tiles that are still correct stay on screen.
    public func cancelPasses() {
        generation += 1
        passTask?.cancel()
        passTask = nil
        runningPlan = nil
        pendingPlan = nil
        runningSource = nil
    }

    public func statistics() -> NativeDetailStats {
        var snapshot = stats
        snapshot.cachedTiles = cache.count
        snapshot.cachedBytes = cache.byteCount
        snapshot.evictions = cache.evictionCount
        return snapshot
    }

    public func cachedTiles(for plan: NativeTilePlan, source: URL, pageIndex: Int = 0) -> [NativeTile] {
        plan.visible.compactMap { cache.tile(for: key($0, source: source, pageIndex: pageIndex)) }
    }

    private func key(_ coordinate: TileCoordinate, source: URL, pageIndex: Int) -> NativeTileKey {
        NativeTileKey(sourcePath: source.path, pageIndex: pageIndex,
                      x: coordinate.x, y: coordinate.y)
    }

    private func start(plan: NativeTilePlan, source: URL, pageIndex: Int) {
        generation += 1
        let token = generation
        passTask?.cancel()
        runningPlan = plan
        runningSource = source
        pendingPlan = nil
        let provider = self.provider
        let cache = self.cache
        let gutter = self.gutter

        let wanted = plan.allCoordinates.map { key($0, source: source, pageIndex: pageIndex) }
        inFlightKeys = Set(wanted.filter { cache.tile(for: $0) == nil })

        let counter = TileCounter()
        passTask = Task.detached(priority: .utility) { [weak self] in
            guard let scheduler = self else { return }
            let cancelFlag = CancelFlag()
            var failure: String?
            do {
                let space = await self?.currentColorSpace() ?? nil
                try provider.produce(plan: plan, source: source, pageIndex: pageIndex,
                                     gutter: gutter, colorSpace: space,
                                     shouldCancel: { cancelFlag.isSet || Task.isCancelled },
                                     onTile: { tile in
                                         // Called on the pass's thread, once per tile: the
                                         // cache is lock-protected and the actor is only
                                         // entered to publish.
                                         counter.increment()
                                         cache.store(tile)
                                         Task { await scheduler.deliver(tile, token: token) }
                                     })
            } catch {
                failure = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            cancelFlag.set()
            await scheduler.passEnded(token: token, produced: counter.value, failure: failure)
        }
    }

    /// Actor-isolated read so the pass's thread gets a Sendable value.
    private func currentColorSpace() -> CGColorSpace? { colorSpace }

    private func deliver(_ tile: NativeTile, token: Int) {
        guard token == generation else { return }
        stats.tilesDelivered += 1
        inFlightKeys.remove(tile.key)
        onTile?(tile)
    }

    private func passEnded(token: Int, produced: Int, failure: String?) {
        guard token == generation else { return }
        stats.passes += 1
        stats.lastErrorDescription = failure
        passTask = nil
        let finishedSource = runningSource
        let queued = pendingPlan
        runningPlan = nil
        runningSource = nil
        pendingPlan = nil
        inFlightKeys.removeAll()
        onPassFinished?(statistics())
        if let queued, let finishedSource {
            start(plan: queued, source: finishedSource, pageIndex: 0)
        }
    }
}

/// Counts tiles across the pass's thread and the actor's.
final class TileCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}

/// A cancellation flag the decode loop can read from another thread. `ps_step` is called in
/// a tight loop, so this is a lock and a bool, not an actor hop.
final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isSet: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    func set() {
        lock.lock(); cancelled = true; lock.unlock()
    }
}
