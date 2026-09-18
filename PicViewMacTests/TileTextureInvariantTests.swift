import XCTest
import Metal
@testable import PicViewMac

/// The residency-invariant tests: one upload per tile, no stale resurrection after a variant
/// switch, a protected set that actually protects, split instrumentation, and byte accounting that
/// matches the driver.
///
/// Each guard test runs twice: once with the fault injection that restores the pre-fix behaviour —
/// which must *fail* the invariant, proving the test detects the bug rather than merely passing —
/// and once on the shipping path.
final class TileTextureInvariantTests: XCTestCase {
    private var device: MTLDevice!
    private var renderer: MetalImageRenderer!

    override func setUpWithError() throws {
        device = try XCTUnwrap(MTLCreateSystemDefaultDevice(), "no Metal device")
        renderer = try XCTUnwrap(MetalImageRenderer(device: device))
    }

    override func tearDown() {
        renderer = nil
        device = nil
    }

    private func tile(x: Int, y: Int = 0, size: Int = 64, path: String = "/tmp/inv.png") throws -> NativeTile {
        let key = NativeTileKey(sourcePath: path, tileSize: size, x: x, y: y)
        return NativeTile(key: key,
                          sourceRect: CGRect(x: x * size, y: y * size, width: size, height: size),
                          image: try XCTUnwrap(renderer.encodedTileImage(width: size, height: size)))
    }

    private func key(_ tile: NativeTile) -> MetalImageRenderer.TileTextureKey {
        MetalImageRenderer.TileTextureKey(tile: tile.key, variant: .baseOnly)
    }

    /// What this renderer bills one 64×64 base tile: the driver's `allocatedSize`, which is
    /// page-rounded and therefore larger than the 16 KiB surface.
    private func billedTileBytes(_ subject: NativeTile) throws -> Int {
        let texture = try XCTUnwrap(renderer.prepareTexture(for: subject, variant: .baseOnly))
        return MetalImageRenderer.byteCost(of: texture)
    }

    // MARK: - A: one upload per tile, however many callers race

    /// The draw path and the warm queue ask for the same tile. Held open by the hook, the second
    /// caller must find the key in flight: no second upload, no second accounting, one entry.
    func testConcurrentRequestsForOneTileUploadItOnce() throws {
        let subject = try tile(x: 0)

        // Fault injection first: without the in-flight check the second caller uploads the tile a
        // second time and the cache bills two textures for one entry.
        renderer.setDebugLegacyDuplicateUpload(true)
        let duplicated = try uploadTwiceConcurrently(subject)
        XCTAssertEqual(duplicated.creations, 2,
                       "the bug the in-flight check prevents: both callers upload the tile")
        XCTAssertEqual(duplicated.resident, 1, "one key, so one entry")
        XCTAssertEqual(duplicated.bytes, 2 * duplicated.perTileBytes,
                       "and the same texture is billed twice")
        XCTAssertFalse(duplicated.lruConsistent,
                       "the old path also appends the key to the LRU twice")

        // The fixed path.
        renderer = try XCTUnwrap(MetalImageRenderer(device: device))
        renderer.setDebugLegacyDuplicateUpload(false)
        let fixed = try uploadTwiceConcurrently(subject)
        XCTAssertEqual(fixed.creations, 1, "one texture created, whoever asks first")
        XCTAssertEqual(fixed.uploads, 1, "and counted once")
        XCTAssertEqual(fixed.resident, 1)
        XCTAssertEqual(fixed.foregroundSkips, 1, "the loser of the race is told to draw the proxy")
        XCTAssertEqual(fixed.bytes, fixed.perTileBytes, "bytes are billed for one resident entry")
        XCTAssertTrue(fixed.lruConsistent)
    }

    private struct ConcurrentUploadOutcome {
        var resident: Int
        var uploads: Int
        var creations: Int
        var perTileBytes: Int
        var foregroundSkips: Int
        var bytes: Int
        var lruConsistent: Bool
    }

    /// Runs one background upload held open by the hook, asks the main thread for the same tile
    /// while it is in flight, then lets it finish.
    private func uploadTwiceConcurrently(_ subject: NativeTile) throws -> ConcurrentUploadOutcome {
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        var firstCall = true
        let guardLock = NSLock()
        renderer.setBeforeUploadHook {
            guardLock.lock()
            let isFirst = firstCall
            firstCall = false
            guardLock.unlock()
            guard isFirst else { return }
            entered.signal()
            _ = release.wait(timeout: .now() + 10)
        }
        DispatchQueue.global(qos: .userInitiated).async { [renderer] in
            _ = renderer?.prepareTexture(for: subject, variant: .baseOnly, fromBackground: true)
            finished.signal()
        }
        XCTAssertEqual(entered.wait(timeout: .now() + 10), .success,
                       "the background upload must reach the hook")
        // The foreground caller arrives while the upload is in flight.
        let foreground = renderer.prepareTexture(for: subject, variant: .baseOnly)
        release.signal()
        XCTAssertEqual(finished.wait(timeout: .now() + 20), .success)
        renderer.setBeforeUploadHook(nil)
        if let foreground {
            // Either outcome is legal for the caller; what matters is what the cache holds.
            XCTAssertNotNil(foreground)
        }
        let diagnostics = renderer.tileTextureDiagnostics()
        return ConcurrentUploadOutcome(
            resident: diagnostics.resident,
            uploads: diagnostics.foregroundUploads + diagnostics.backgroundUploads,
            creations: diagnostics.textureCreations,
            perTileBytes: try billedTileBytes(try tile(x: 90, path: "/tmp/probe.png")),
            foregroundSkips: diagnostics.inFlightSkips,
            bytes: diagnostics.bytes,
            lruConsistent: diagnostics.lruIsConsistent)
    }

    // MARK: - B: a stale upload must not resurrect a dropped variant

    /// A mipmapped upload held open while the variant policy switches to base-only. Completing
    /// afterwards must not insert the mipmapped texture back into the cache.
    func testUploadInFlightDuringVariantSwitchIsDiscarded() throws {
        let subject = try tile(x: 1)
        let mipKey = MetalImageRenderer.TileTextureKey(tile: subject.key, variant: .mipmapped)

        // Fault injection: without the generation check the stale texture lands in the cache and is
        // billed, so the GPU holds the flavour the policy just dropped.
        renderer.setDebugDisableGenerationCheck(true)
        let resurrected = try switchVariantDuringUpload(subject, key: mipKey)
        XCTAssertTrue(resurrected.residentAfterDrop,
                      "the bug the generation check prevents: a dropped variant comes back")
        XCTAssertGreaterThan(resurrected.bytesAfterDrop, 0)

        renderer = try XCTUnwrap(MetalImageRenderer(device: device))
        renderer.setDebugDisableGenerationCheck(false)
        let fixed = try switchVariantDuringUpload(subject, key: mipKey)
        XCTAssertFalse(fixed.residentAfterDrop, "the stale texture never enters the cache")
        XCTAssertEqual(fixed.bytesAfterDrop, 0, "and is never billed")
        XCTAssertEqual(fixed.staleVariantDiscarded, 1, "it is reported as discarded")
        XCTAssertTrue(fixed.lruConsistent)
    }

    private struct VariantSwitchOutcome {
        var residentAfterDrop: Bool
        var bytesAfterDrop: Int
        var staleVariantDiscarded: Int
        var lruConsistent: Bool
    }

    private func switchVariantDuringUpload(_ subject: NativeTile,
                                          key mipKey: MetalImageRenderer.TileTextureKey) throws -> VariantSwitchOutcome {
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        renderer.setBeforeUploadHook {
            entered.signal()
            _ = release.wait(timeout: .now() + 10)
        }
        DispatchQueue.global(qos: .userInitiated).async { [renderer] in
            _ = renderer?.prepareTexture(for: subject, variant: .mipmapped, fromBackground: true)
            finished.signal()
        }
        XCTAssertEqual(entered.wait(timeout: .now() + 10), .success)
        // The policy switches while the upload is in flight.
        renderer.dropTileTextures(of: .mipmapped)
        release.signal()
        XCTAssertEqual(finished.wait(timeout: .now() + 20), .success)
        renderer.setBeforeUploadHook(nil)
        let diagnostics = renderer.tileTextureDiagnostics()
        return VariantSwitchOutcome(residentAfterDrop: renderer.debugHasTexture(mipKey),
                                    bytesAfterDrop: diagnostics.bytes,
                                    staleVariantDiscarded: diagnostics.staleVariantDiscarded,
                                    lruConsistent: diagnostics.lruIsConsistent)
    }

    // MARK: - C: the protected set

    /// Visible tiles survive budget pressure; unprotecting them makes them evictable again.
    func testProtectedTilesSurviveEvictionAndAreEvictableAfterUnprotecting() throws {
        let size = 64
        let perTile = MetalImageRenderer.textureBytes(width: size, height: size, mipmapped: false)
        renderer.tileTextureBudget = perTile * 2
        let visible = [try tile(x: 0), try tile(x: 1)]
        renderer.setProtectedTileKeys(Set(visible.map { $0.key }))
        for subject in visible { XCTAssertNotNil(renderer.prepareTexture(for: subject, variant: .baseOnly)) }
        // Far more warm tiles than the budget: none may displace the protected ones.
        for x in 2..<12 { _ = renderer.prepareTexture(for: try tile(x: x), variant: .baseOnly) }
        for subject in visible {
            XCTAssertTrue(renderer.debugHasTexture(key(subject)),
                          "a visible tile is never evicted for a warm one")
        }
        XCTAssertGreaterThanOrEqual(renderer.tileTextureDiagnostics().bytes, perTile * 2)
        // With the protection released the budget applies again.
        renderer.setProtectedTileKeys([])
        XCTAssertLessThanOrEqual(renderer.tileTextureDiagnostics().bytes,
                                 renderer.tileTextureDiagnostics().budget,
                                 "unprotected entries are evictable down to the budget")
        XCTAssertTrue(renderer.tileTextureDiagnostics().lruIsConsistent)
    }

    /// The setter is safe to call from the main thread while the upload queue evicts.
    func testProtectedSetIsSynchronisedWithConcurrentUploads() throws {
        let size = 64
        renderer.tileTextureBudget = MetalImageRenderer.textureBytes(width: size, height: size,
                                                                    mipmapped: false) * 4
        let tiles = try (0..<24).map { try tile(x: $0) }
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async { [renderer] in
            for subject in tiles {
                _ = renderer?.prepareTexture(for: subject, variant: .baseOnly, fromBackground: true)
            }
            done.signal()
        }
        // Hammer the setter the way the viewer does: every plan publication replaces the set.
        for round in 0..<400 {
            let window = Array(tiles[(round % 12)..<min(round % 12 + 8, tiles.count)])
            renderer.setProtectedTileKeys(Set(window.map { $0.key }))
        }
        XCTAssertEqual(done.wait(timeout: .now() + 30), .success)
        renderer.setProtectedTileKeys([])
        let diagnostics = renderer.tileTextureDiagnostics()
        XCTAssertTrue(diagnostics.lruIsConsistent)
        XCTAssertLessThanOrEqual(diagnostics.bytes, diagnostics.budget)
    }

    // MARK: - D: instrumentation, split by caller

    func testHitsAreCountedPerCaller() throws {
        let subject = try tile(x: 0)
        _ = renderer.prepareTexture(for: subject, variant: .baseOnly, fromBackground: true)
        var diagnostics = renderer.tileTextureDiagnostics()
        XCTAssertEqual(diagnostics.backgroundUploads, 1)
        XCTAssertEqual(diagnostics.foregroundUploads, 0)
        _ = renderer.prepareTexture(for: subject, variant: .baseOnly, fromBackground: true)
        diagnostics = renderer.tileTextureDiagnostics()
        XCTAssertEqual(diagnostics.backgroundHits, 1)
        XCTAssertEqual(diagnostics.foregroundHits, 0,
                       "a warm-queue hit is not a draw-path hit")
        _ = renderer.prepareTexture(for: subject, variant: .baseOnly)
        diagnostics = renderer.tileTextureDiagnostics()
        XCTAssertEqual(diagnostics.foregroundHits, 1)
        XCTAssertEqual(diagnostics.backgroundHits, 1)
    }

    /// Re-publicating the warm set must not queue a tile that is resident, in flight or waiting.
    func testWarmQueueEnqueuesEachTileOnce() throws {
        let tiles = try (0..<6).map { try tile(x: $0) }
        renderer.warmTilesInBackground(tiles, variant: .baseOnly)
        renderer.warmTilesInBackground(tiles, variant: .baseOnly)
        renderer.warmTilesInBackground(tiles, variant: .baseOnly)
        XCTAssertEqual(renderer.tileTextureDiagnostics().duplicateWarmSkips, 12,
                       "the second and third publications are skipped, six tiles each")
        let deadline = Date().addingTimeInterval(20)
        while renderer.tileTextureDiagnostics().resident < 6, Date() < deadline {
            usleep(20_000)
        }
        let diagnostics = renderer.tileTextureDiagnostics()
        XCTAssertEqual(diagnostics.resident, 6)
        XCTAssertEqual(diagnostics.backgroundUploads, 6, "each tile uploaded exactly once")
        XCTAssertEqual(diagnostics.queuedWarm, 0)
        XCTAssertTrue(diagnostics.lruIsConsistent)
    }

    // MARK: - E: billed bytes match the driver

    /// `MTLTexture.allocatedSize` is what the cache bills; the estimate stays for planning. This
    /// test reports the measured difference and holds the accounting invariant.
    func testBilledBytesMatchAllocatedSize() throws {
        let baseTile = try tile(x: 0)
        let base = try XCTUnwrap(renderer.prepareTexture(for: baseTile, variant: .baseOnly))
        let mipSource = try tile(x: 1)
        let mipmapped = try XCTUnwrap(renderer.prepareTexture(for: mipSource, variant: .mipmapped))
        // The tile size production actually uses, whose surface is already page-aligned.
        let productionTile = try tile(x: 2, size: 512)
        let production = try XCTUnwrap(renderer.prepareTexture(for: productionTile, variant: .baseOnly))
        let edgeImage = try XCTUnwrap(renderer.encodedTileImage(width: 512, height: 37))
        let edgeKey = NativeTileKey(sourcePath: "/tmp/edge.png", tileSize: 512, x: 0, y: 0)
        let edge = NativeTile(key: edgeKey, sourceRect: CGRect(x: 0, y: 0, width: 512, height: 37),
                              image: edgeImage)
        let edgeTexture = try XCTUnwrap(renderer.prepareTexture(for: edge, variant: .baseOnly))

        let report = """
        BILLED 64x64 base   allocated=\(base.allocatedSize) surface=\(64 * 64 * 4) levels=\(base.mipmapLevelCount)
        BILLED 64x64 mip    allocated=\(mipmapped.allocatedSize) estimate=\(MetalImageRenderer.textureBytes(width: 64, height: 64, mipmapped: true)) \
        levels=\(mipmapped.mipmapLevelCount)
        BILLED 512x37 edge  allocated=\(edgeTexture.allocatedSize) surface=\(512 * 37 * 4)
        BILLED 512x512      allocated=\(production.allocatedSize) surface=\(512 * 512 * 4)
        """
        FileHandle.standardError.write(Data((report + "\n").utf8))

        let perEntry = renderer.debugEntryCosts()
        XCTAssertEqual(perEntry.values.reduce(0, +), renderer.tileTextureDiagnostics().bytes,
                       "sum(entry cost) == gpuTextureBytes")
        // Walk the entries and compare against the driver's own figure for the same texture.
        for (entryKey, cost) in perEntry {
            let texture: MTLTexture
            if entryKey == key(baseTile) { texture = base }
            else if entryKey == MetalImageRenderer.TileTextureKey(tile: mipSource.key, variant: .mipmapped) {
                texture = mipmapped
            } else if entryKey == MetalImageRenderer.TileTextureKey(tile: productionTile.key, variant: .baseOnly) {
                texture = production
            } else { texture = edgeTexture }
            XCTAssertEqual(cost, MetalImageRenderer.byteCost(of: texture))
            XCTAssertGreaterThanOrEqual(cost, texture.width * texture.height * 4,
                                        "never bill less than the base surface")
            XCTAssertGreaterThanOrEqual(texture.allocatedSize, texture.width * texture.height * 4)
        }
        // Measured: the driver bills a page-rounded allocation. At 64 px the mip chain fits inside
        // that padding, so the mipmapped flavour costs no more than the base one there; at the
        // production 512 px the surface is already page-aligned and the two coincide.
        XCTAssertGreaterThanOrEqual(mipmapped.allocatedSize, base.allocatedSize)
        XCTAssertGreaterThanOrEqual(production.allocatedSize, 512 * 512 * 4)
    }

}
