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
    /// How the file's pixels relate to canonical source space.
    private var orientation: SourceOrientation = .up
    private var runningSource: URL?
    /// The plan the scheduler is currently running a pass for, for tests of the lifecycle contract.
    var runningPlanForTesting: NativeTilePlan? { runningPlan }
    private var inFlightKeys: Set<NativeTileKey> = []
    private var stats = NativeDetailStats()

    /// The CPU tile budget the warm-area policy must be clamped against. One number, kept here:
    /// a policy that plans for 256 MiB while the cache evicts at 192 MiB promises residency it
    /// cannot deliver (measured at 0.5, where the plan filled the budget and the cache started
    /// dropping the outermost warm tiles). `nonisolated` because the cache is already a
    /// lock-protected class and the policy runs on the main actor.
    public nonisolated var cacheCostLimit: Int { cache.totalCostLimit }

    public init(provider: NativeTileProviding = PNGNativeTileProvider(),
                cache: NativeTileCache = NativeTileCache(totalCostLimit: 256 * 1024 * 1024),
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
    /// Numbered by the viewer: every clear and every request takes the next value, and the scheduler
    /// applies an operation only when it is newer than the last one it applied.
    ///
    /// Without it an unstructured `stopAndPurge` task — created by a clear, delivered only after a
    /// later request — wiped the pass that had replaced it, because the actor sees two unrelated
    /// messages with no way to tell which belongs to the newer plan.
    private var lifecycleEpoch: UInt64 = 0
    /// Tiles from a cancelled pass that arrived after the token changed, dropped before they could
    /// be stored.
    private(set) var staleDecodedTilesDiscarded = 0
    /// Acceptance work still queued for the running pass. A pass is not finished until its producer
    /// has stopped *and* every tile it emitted has been accepted: the per-tile actor entries are
    /// unstructured tasks, so their arrival order relative to `passEnded` is not guaranteed.
    private var passOutstanding: TileCounter?
    private var producerFinishedToken: Int?
    private var producerProduced = 0
    private var producerFailure: String?
    /// Tiles the provider emitted for the last finished pass, counted on the provider thread.
    private(set) var lastPassProduced = 0
    private(set) var lastPassAccepted = 0
    /// Test-only: records that the pass emitted a tile, the way the provider callback does.
    func noteEmittedTileForTesting() { passOutstanding?.increment() }

    /// Test-only: the provider has stopped emitting.
    func noteProducerFinishedForTesting(token: Int, produced: Int) {
        if let outstanding = passOutstanding {
            producerFinished(token: token, produced: produced, outstanding: outstanding, failure: nil)
        }
    }

    /// Test-only: the plan waiting behind the running pass.
    var pendingPlanForTesting: NativeTilePlan? { pendingPlan }

    /// Test-only: how many tiles the last finished pass accepted.
    var lastPassAcceptedForTesting: Int { lastPassAccepted }

    /// The pass token, for tests that need to hand a tile to the validation path.
    var passTokenForTesting: Int { generation }

    /// Runs the tile-acceptance path directly, so a test can present a tile from a stale token
    /// without having to race a real pass for one.
    func acceptDecodedTileForTesting(_ tile: NativeTile, token: Int) async {
        acceptDecodedTile(tile, token: token, outstanding: passOutstanding ?? TileCounter())
    }

    /// The metadata the running pass was started with, for tests of the snapshot contract.
    private(set) var runningMetadataForTesting: (colorSpace: CGColorSpace?, orientation: SourceOrientation)?
    /// Operations dropped because a newer one had already been applied.
    private(set) var lifecycleIgnoredStale = 0

    public func request(plan: NativeTilePlan, source: URL, pageIndex: Int = 0,
                        colorSpace: CGColorSpace? = nil,
                        orientation: SourceOrientation = .up, epoch: UInt64) {
        guard epoch > lifecycleEpoch else {
            lifecycleIgnoredStale += 1
            return
        }
        lifecycleEpoch = epoch
        applyRequest(plan: plan, source: source, pageIndex: pageIndex,
                     colorSpace: colorSpace, orientation: orientation)
    }

    /// Unnumbered request: takes the next epoch itself, so callers that do not track the lifecycle
    /// (tests, one-off probes) keep the old behaviour.
    public func request(plan: NativeTilePlan, source: URL, pageIndex: Int = 0,
                        colorSpace: CGColorSpace? = nil,
                        orientation: SourceOrientation = .up) {
        lifecycleEpoch += 1
        applyRequest(plan: plan, source: source, pageIndex: pageIndex,
                     colorSpace: colorSpace, orientation: orientation)
    }

    private func applyRequest(plan: NativeTilePlan, source: URL, pageIndex: Int,
                              colorSpace: CGColorSpace?, orientation: SourceOrientation) {
        self.colorSpace = colorSpace
        self.orientation = orientation
        // Tiles belong to one source. When the request is for a different one, the previous source's
        // tiles are dropped instead of being cached out of budget until something else evicts them;
        // a request for the same source keeps them, so a disable → re-enable stays warm.
        if let previous = runningSource, previous != source {
            cache.purge(exceptSourcePath: source.path)
        } else if runningSource == nil {
            cache.purge(exceptSourcePath: source.path)
        }
        let visibleKeys = Set(plan.visible.map {
            key($0, tileSize: plan.tileSize, source: source, pageIndex: pageIndex)
        })
        cache.pin(visibleKeys)

        if let running = runningPlan, let runningSource, runningSource == source {
            let covered = Set(running.allCoordinates.map {
                key($0, tileSize: running.tileSize, source: source, pageIndex: pageIndex)
            })
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

    /// Numbered clear: ignored when a newer operation has already been applied, which is what keeps
    /// a late cleanup from killing the pass that replaced it.
    public func stopAndPurge(epoch: UInt64) {
        guard epoch > lifecycleEpoch else {
            lifecycleIgnoredStale += 1
            return
        }
        lifecycleEpoch = epoch
        applyStopAndPurge()
    }

    /// Drops native detail entirely: zoomed out, animated, or the image changed.
    public func stopAndPurge() {
        lifecycleEpoch += 1
        applyStopAndPurge()
    }

    private func applyStopAndPurge() {
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

    /// Tiles a plan wants that are already decoded, in the plan's order. `visibleOnly` keeps the
    /// canvas's draw list to what is actually on screen while the rest stays warm.
    public func cachedTiles(for plan: NativeTilePlan, source: URL, pageIndex: Int = 0) -> [NativeTile] {
        tiles(for: plan.allCoordinates, plan: plan, source: source, pageIndex: pageIndex)
    }

    /// What is on screen. The draw list comes from here and nowhere else: a warm tile that reaches
    /// the canvas is a warm tile being drawn, which is not what "resident" means.
    public func cachedVisibleTiles(for plan: NativeTilePlan, source: URL,
                                   pageIndex: Int = 0) -> [NativeTile] {
        tiles(for: plan.visible, plan: plan, source: source, pageIndex: pageIndex)
    }

    /// The rest of the plan: decoded, kept, and *not* drawn. This is the set the renderer warms in
    /// the background, so a pan onto it is a draw rather than an upload.
    public func cachedWarmTiles(for plan: NativeTilePlan, source: URL,
                                pageIndex: Int = 0) -> [NativeTile] {
        tiles(for: plan.ring, plan: plan, source: source, pageIndex: pageIndex)
    }

    /// Keys of the whole plan, so the renderer trims its texture cache against what is *resident*
    /// rather than against what happens to be drawn this frame.
    public func residentKeys(for plan: NativeTilePlan, source: URL,
                             pageIndex: Int = 0) -> Set<NativeTileKey> {
        Set(plan.allCoordinates.map { key($0, tileSize: plan.tileSize, source: source,
                                          pageIndex: pageIndex) })
    }

    private func tiles(for coordinates: [TileCoordinate], plan: NativeTilePlan, source: URL,
                       pageIndex: Int) -> [NativeTile] {
        coordinates.compactMap {
            cache.tile(for: key($0, tileSize: plan.tileSize, source: source, pageIndex: pageIndex))
        }
    }

    /// The grid size is taken from the plan being asked about, not from the scheduler's own
    /// default: a plan built with another tile size would otherwise look up keys that cannot exist
    /// (this project has already paid once for a tile-size key collision).
    private func key(_ coordinate: TileCoordinate, tileSize: Int, source: URL,
                     pageIndex: Int) -> NativeTileKey {
        NativeTileKey(sourcePath: source.path, pageIndex: pageIndex,
                      tileSize: tileSize, x: coordinate.x, y: coordinate.y)
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
        // Captured here, on the actor, while this request is the current one. The pass used to read
        // them from the actor when it started, so a pass for source A that started after a request
        // for source B decoded A with B's orientation and colour space.
        let passColorSpace = colorSpace
        let passOrientation = orientation
        runningMetadataForTesting = (passColorSpace, passOrientation)

        let wanted = plan.allCoordinates.map {
            key($0, tileSize: plan.tileSize, source: source, pageIndex: pageIndex)
        }
        inFlightKeys = Set(wanted.filter { cache.tile(for: $0) == nil })

        let counter = TileCounter()
        let outstanding = TileCounter()
        passOutstanding = outstanding
        producerFinishedToken = nil
        passAccepted = 0
        passTask = Task.detached(priority: .utility) { [weak self] in
            guard let scheduler = self else { return }
            let cancelFlag = CancelFlag()
            var failure: String?
            do {
                try provider.produce(plan: plan, source: source, pageIndex: pageIndex,
                                     gutter: gutter, colorSpace: passColorSpace,
                                     orientation: passOrientation,
                                     shouldCancel: { cancelFlag.isSet || Task.isCancelled },
                                     onTile: { tile in
                                         // Called on the pass's thread, once per tile. The tile is
                                         // handed to the actor, which validates the token *before*
                                         // storing it, and the outstanding counter is raised here so
                                         // the pass cannot be declared finished while this tile is
                                         // still queued for acceptance.
                                         counter.increment()
                                         outstanding.increment()
                                         Task {
                                             await scheduler.acceptDecodedTile(
                                                 tile, token: token, outstanding: outstanding)
                                         }
                                     })
            } catch {
                failure = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            cancelFlag.set()
            await scheduler.producerFinished(token: token, produced: counter.value,
                                             outstanding: outstanding, failure: failure)
        }
    }

    /// Validates the pass token, then stores and publishes. The order matters: the previous version
    /// stored the tile and only then checked the token, so tiles from a cancelled pass entered the
    /// CPU cache even though they were never shown.
    private func acceptDecodedTile(_ tile: NativeTile, token: Int, outstanding: TileCounter) {
        outstanding.decrement()
        defer { maybeFinishPass() }
        guard token == generation else {
            // A real invalidation: this pass was superseded before its tail arrived.
            staleDecodedTilesDiscarded += 1
            return
        }
        passAccepted += 1
        cache.store(tile)
        // `deliver` owns the rest (in-flight bookkeeping, stats, the publish callback).
        deliver(tile, token: token)
    }

    private func deliver(_ tile: NativeTile, token: Int) {
        guard token == generation else { return }
        stats.tilesDelivered += 1
        inFlightKeys.remove(tile.key)
        onTile?(tile)
    }

    /// Called when the producer is done and when each acceptance completes. The pass finishes only
    /// when both are true, so a pending plan cannot start — and invalidate the tail tiles that were
    /// already decoded — before they have been accepted.
    private func maybeFinishPass() {
        guard let token = producerFinishedToken, let outstanding = passOutstanding,
              outstanding.value == 0 else { return }
        producerFinishedToken = nil
        passOutstanding = nil
        let produced = producerProduced
        let failure = producerFailure
        producerProduced = 0
        producerFailure = nil
        lastPassProduced = produced
        lastPassAccepted = passAccepted
        passAccepted = 0
        passEnded(token: token, produced: produced, failure: failure)
    }

    private var passAccepted = 0

    /// The producer has stopped emitting. The pass may still have tiles queued for acceptance.
    private func producerFinished(token: Int, produced: Int, outstanding: TileCounter,
                                  failure: String?) {
        guard token == generation else { return }
        producerFinishedToken = token
        producerProduced = produced
        producerFailure = failure
        maybeFinishPass()
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
    func decrement() { lock.lock(); count -= 1; lock.unlock() }
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
