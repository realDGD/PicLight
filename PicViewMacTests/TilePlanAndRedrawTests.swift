import XCTest
import Metal
@testable import PicViewMac

/// Two suspicions about the tile texture cache that the previous audit did not cover:
///
/// A. An upload that was queued for plan A and completes after the user moved to plan B. The
///    variant has not changed, so no generation bump happens, and the texture lands in a cache that
///    has already trimmed it away — taking budget from the tiles the user is actually looking at.
///
/// C. A foreground draw that finds its tile already uploading gets nil and draws the proxy. Nobody
///    asks again until the next user event, so the screen can keep showing the proxy for a tile that
///    is ready.
final class TilePlanAndRedrawTests: XCTestCase {
    private var renderer: MetalImageRenderer!

    override func setUpWithError() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice(), "no Metal device")
        renderer = try XCTUnwrap(MetalImageRenderer(device: device))
    }

    override func tearDown() { renderer = nil }

    private func tile(x: Int, size: Int = 64, path: String = "/tmp/plan.png") throws -> NativeTile {
        let key = NativeTileKey(sourcePath: path, tileSize: size, x: x, y: 0)
        return NativeTile(key: key,
                          sourceRect: CGRect(x: x * size, y: 0, width: size, height: size),
                          image: try XCTUnwrap(renderer.encodedTileImage(width: size, height: size)))
    }

    private func baseKey(_ tile: NativeTile) -> MetalImageRenderer.TileTextureKey {
        MetalImageRenderer.TileTextureKey(tile: tile.key, variant: .baseOnly)
    }

    // MARK: - A: an upload for a plan the user has left

    /// Plan A queues tile X. While X is uploading, the viewer publishes plan B, which does not
    /// contain X. The upload completes: X must not enter the cache.
    func testUploadForATileOutsideTheNewPlanIsDiscarded() throws {
        let x = try tile(x: 0)
        let y = try tile(x: 1)

        // Fault injection first: without the resident-plan check the texture of an abandoned plan
        // lands in the cache and is billed.
        renderer.setDebugDisablePlanCheck(true)
        let resurrected = try uploadDuringPlanChange(x, newPlan: [y.key])
        XCTAssertTrue(resurrected.resident, "the bug the plan check prevents: X comes back")
        XCTAssertGreaterThan(resurrected.bytes, 0, "and it takes budget from the live plan")

        renderer = try XCTUnwrap(MetalImageRenderer(device: MTLCreateSystemDefaultDevice()))
        renderer.setDebugDisablePlanCheck(false)
        let fixed = try uploadDuringPlanChange(x, newPlan: [y.key])
        XCTAssertFalse(fixed.resident, "a tile outside the current plan never enters the cache")
        XCTAssertEqual(fixed.bytes, 0, "and is never billed")
        XCTAssertEqual(fixed.stalePlanDiscarded, 1, "the abandoned upload is reported")
        XCTAssertTrue(fixed.lruConsistent)
        // The live plan still works: a tile that is in the new plan uploads normally.
        let live = try XCTUnwrap(renderer.prepareTexture(for: y, variant: .baseOnly))
        XCTAssertEqual(renderer.tileTextureDiagnostics().resident, 1)
        XCTAssertNotNil(live)
    }

    private struct PlanChangeOutcome {
        var resident: Bool
        var bytes: Int
        var stalePlanDiscarded: Int
        var lruConsistent: Bool
    }

    /// Starts X uploading, holds it open, publishes a new resident set without X, then releases.
    private func uploadDuringPlanChange(_ x: NativeTile,
                                        newPlan: [NativeTileKey]) throws -> PlanChangeOutcome {
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        renderer.setBeforeUploadHook {
            entered.signal()
            _ = release.wait(timeout: .now() + 10)
        }
        DispatchQueue.global(qos: .userInitiated).async { [renderer] in
            _ = renderer?.prepareTexture(for: x, variant: .baseOnly, fromBackground: true)
            finished.signal()
        }
        XCTAssertEqual(entered.wait(timeout: .now() + 10), .success,
                       "the background upload must reach the hook")
        // The user pans: the viewer publishes the new resident set, which trims the cache. X is not
        // in the cache yet — it is in flight — so only the plan check can stop it.
        renderer.trimTileTextures(keeping: Set(newPlan))
        release.signal()
        XCTAssertEqual(finished.wait(timeout: .now() + 20), .success)
        renderer.setBeforeUploadHook(nil)
        let diagnostics = renderer.tileTextureDiagnostics()
        return PlanChangeOutcome(resident: renderer.debugHasTexture(baseKey(x)),
                                 bytes: diagnostics.bytes,
                                 stalePlanDiscarded: diagnostics.stalePlanDiscarded,
                                 lruConsistent: diagnostics.lruIsConsistent)
    }

    /// A tile that is on screen when the plan changes is still protected: a visible tile may never be
    /// discarded by a plan update.
    func testATileInTheNewPlanSurvivesThePlanChange() throws {
        let x = try tile(x: 2)
        let view = try tile(x: 3)
        renderer.setBeforeUploadHook { }
        let outcome = try uploadDuringPlanChange(x, newPlan: [x.key, view.key])
        renderer.setBeforeUploadHook(nil)
        XCTAssertTrue(outcome.resident, "X is in the new plan, so its upload must be kept")
        XCTAssertEqual(outcome.stalePlanDiscarded, 0)
    }

    /// A warm tile that belongs to the new plan must not be skipped just because it was queued by
    /// the previous plan: the predicate is set membership, not queue age.
    func testAPlanChangeDoesNotThrashTilesThatStayInThePlan() throws {
        let tiles = try (0..<8).map { try tile(x: $0) }
        renderer.trimTileTextures(keeping: Set(tiles.map { $0.key }))
        renderer.warmTilesInBackground(tiles, variant: .baseOnly)
        let deadline = Date().addingTimeInterval(10)
        while renderer.tileTextureDiagnostics().resident < 8, Date() < deadline { usleep(20_000) }
        let diagnostics = renderer.tileTextureDiagnostics()
        XCTAssertEqual(diagnostics.resident, 8, "every warm tile was uploaded")
        XCTAssertEqual(diagnostics.stalePlanDiscarded, 0, "and none was thrown away")
        // Re-publishing the same plan does not invalidate anything in flight or resident.
        renderer.trimTileTextures(keeping: Set(tiles.map { $0.key }))
        XCTAssertEqual(renderer.tileTextureDiagnostics().resident, 8)
    }

    /// After the plan is abandoned (detail switched off, viewer publishes an empty set), in-flight
    /// uploads are dropped rather than filling a cache nothing will draw from.
    func testAbandoningThePlanDiscardsInFlightUploads() throws {
        let x = try tile(x: 4)
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        renderer.setBeforeUploadHook { entered.signal(); _ = release.wait(timeout: .now() + 10) }
        DispatchQueue.global(qos: .userInitiated).async { [renderer] in
            _ = renderer?.prepareTexture(for: x, variant: .baseOnly, fromBackground: true)
            finished.signal()
        }
        XCTAssertEqual(entered.wait(timeout: .now() + 10), .success)
        renderer.trimTileTextures(keeping: [])
        release.signal()
        XCTAssertEqual(finished.wait(timeout: .now() + 20), .success)
        renderer.setBeforeUploadHook(nil)
        XCTAssertFalse(renderer.debugHasTexture(baseKey(x)))
        XCTAssertEqual(renderer.tileTextureDiagnostics().bytes, 0)
    }

    // MARK: - C: completion of an upload the draw path was waiting for

    /// The draw path asks for a tile, finds it in flight and draws the proxy instead. When the
    /// upload finishes, the renderer must report that the tile became ready.
    func testCompletionOfAForegroundMissReportsTheTileReady() throws {
        let x = try tile(x: 5)
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        let notifications = Collector<NativeTileKey>()
        renderer.setTextureBecameReadyHandler { key in notifications.append(key) }
        renderer.setBeforeUploadHook { entered.signal(); _ = release.wait(timeout: .now() + 10) }
        DispatchQueue.global(qos: .userInitiated).async { [renderer] in
            _ = renderer?.prepareTexture(for: x, variant: .baseOnly, fromBackground: true)
            finished.signal()
        }
        XCTAssertEqual(entered.wait(timeout: .now() + 10), .success)
        // The draw path arrives while the upload is in flight: nil, and the proxy stays on screen.
        XCTAssertNil(renderer.prepareTexture(for: x, variant: .baseOnly),
                     "the foreground must not block on the main thread")
        release.signal()
        XCTAssertEqual(finished.wait(timeout: .now() + 20), .success)
        renderer.setBeforeUploadHook(nil)
        XCTAssertEqual(notifications.values, [x.key],
                       "the frame that drew the proxy must be told the tile is ready")
        XCTAssertTrue(renderer.debugHasTexture(baseKey(x)))
    }

    /// A tile nobody on the draw path asked for (a pure warm upload) must not cause a repaint: that
    /// would repaint once per warm tile.
    func testAWarmOnlyUploadDoesNotReportReady() throws {
        let x = try tile(x: 6)
        let notifications = Collector<NativeTileKey>()
        renderer.setTextureBecameReadyHandler { key in notifications.append(key) }
        _ = renderer.prepareTexture(for: x, variant: .baseOnly, fromBackground: true)
        XCTAssertTrue(notifications.values.isEmpty,
                      "a warm tile that the draw path never missed needs no repaint")
    }

    /// A foreground *hit* needs no notification either.
    func testAForegroundHitDoesNotReportReady() throws {
        let x = try tile(x: 7)
        _ = renderer.prepareTexture(for: x, variant: .baseOnly, fromBackground: true)
        let notifications = Collector<NativeTileKey>()
        renderer.setTextureBecameReadyHandler { key in notifications.append(key) }
        XCTAssertNotNil(renderer.prepareTexture(for: x, variant: .baseOnly))
        XCTAssertTrue(notifications.values.isEmpty)
    }

    // MARK: - D: statistics semantics

    /// A texture that is created and then discarded must still be counted as created. The previous
    /// counter incremented after the discard guards, so `creations` silently meant "insertions" and
    /// the identity `creations == uploads` could be read as "nothing was ever thrown away".
    func testStatisticsSeparateCreationFromInsertion() throws {
        // Case 1: created, then discarded as a stale variant.
        let stale = try tile(x: 8)
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        renderer.setBeforeUploadHook { entered.signal(); _ = release.wait(timeout: .now() + 10) }
        DispatchQueue.global(qos: .userInitiated).async { [renderer] in
            _ = renderer?.prepareTexture(for: stale, variant: .mipmapped, fromBackground: true)
            finished.signal()
        }
        XCTAssertEqual(entered.wait(timeout: .now() + 10), .success)
        renderer.dropTileTextures(of: .mipmapped)
        release.signal()
        XCTAssertEqual(finished.wait(timeout: .now() + 20), .success)
        renderer.setBeforeUploadHook(nil)

        var diagnostics = renderer.tileTextureDiagnostics()
        XCTAssertEqual(diagnostics.textureCreations, 1,
                       "a texture was created, whatever happened to it afterwards")
        XCTAssertEqual(diagnostics.staleVariantDiscarded, 1)
        XCTAssertEqual(diagnostics.residentInsertions, 0, "and it never became resident")
        XCTAssertEqual(diagnostics.bytes, 0)

        // Case 2: created and inserted.
        _ = renderer.prepareTexture(for: try tile(x: 9), variant: .baseOnly)
        diagnostics = renderer.tileTextureDiagnostics()
        XCTAssertEqual(diagnostics.textureCreations, 2)
        XCTAssertEqual(diagnostics.residentInsertions, 1)
        // The identity the counters exist to make checkable.
        XCTAssertEqual(diagnostics.textureCreations,
                       diagnostics.residentInsertions + diagnostics.staleVariantDiscarded
                       + diagnostics.stalePlanDiscarded + diagnostics.duplicateDiscarded,
                       "creations are accounted for exactly once")
    }

    /// The identity holds on the plan-change path too.
    func testStatisticsIdentityHoldsAcrossAPlanChange() throws {
        let x = try tile(x: 10)
        _ = try uploadDuringPlanChange(x, newPlan: [try tile(x: 11).key])
        let diagnostics = renderer.tileTextureDiagnostics()
        XCTAssertEqual(diagnostics.textureCreations,
                       diagnostics.residentInsertions + diagnostics.staleVariantDiscarded
                       + diagnostics.stalePlanDiscarded + diagnostics.duplicateDiscarded)
        XCTAssertEqual(diagnostics.stalePlanDiscarded, 1)
    }
}

/// A tiny thread-safe collector: the notifications arrive on the upload queue.
final class Collector<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [T] = []
    func append(_ value: T) { lock.lock(); storage.append(value); lock.unlock() }
    var values: [T] { lock.lock(); defer { lock.unlock() }; return storage }
}
