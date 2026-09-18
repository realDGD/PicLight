import XCTest
import AppKit
import CoreGraphics
import Metal
@testable import PicViewMac
import PicPNGStream

/// The three sets a tile can be in, and the transitions between them.
///
/// The previous implementation published visible+warm as the *draw list* and computed the warm set
/// as the difference against that same list, so the warm set was always empty and the background
/// uploader never ran. These tests exist to make that failure impossible to reintroduce: they check
/// the draw list, the resident set and the GPU cache separately, and they check that a pan onto a
/// warm tile is a cache hit rather than an upload.
@MainActor
final class WarmResidencyTests: XCTestCase {

    private let fixtureName = "oversized-detail.png"

    override func setUp() async throws {
        try await super.setUp()
        TestAppKit.ensureApplication()
    }

    private struct Probe: DimensionProbing {
        let longEdge: Int
        func longEdge(of url: URL) async -> Int? { longEdge }
    }

    private func proxyBitmap(width: Int, height: Int) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    private func pump(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    @discardableResult
    private func pump(until condition: () -> Bool, timeout: TimeInterval = 25) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return condition()
    }

    private func makeViewer() throws -> (ViewerViewController, ViewerWindowController,
                                         NativeTileCache, NativeDetailScheduler) {
        guard FileManager.default.fileExists(atPath: Fixtures.url(fixtureName).path) else {
            throw XCTSkip("fixture missing")
        }
        let decoder = CountingDecoder(payload: proxyBitmap(width: 2048, height: 78),
                                      document: .still,
                                      pixelSize: CGSize(width: 8448, height: 320))
        let cache = NativeTileCache(totalCostLimit: 64 * 1024 * 1024)
        let scheduler = NativeDetailScheduler(cache: cache, tileSize: 512)
        let viewer = ViewerViewController(decoder: decoder, thumbnails: ThumbnailPipeline(),
                                          probe: Probe(longEdge: 8448), nativeDetail: scheduler)
        let controller = ViewerWindowController(viewer: viewer)
        TestAppKit.presentOffScreen(controller)
        _ = viewer.view
        viewer.open(url: Fixtures.url(fixtureName))
        return (viewer, controller, cache, scheduler)
    }

    /// Case A: the canvas draws the visible tiles; the renderer holds visible + warm.
    func testTheDrawListIsTheVisibleSetAndTheGpuCacheHoldsTheWarmSetToo() throws {
        let (viewer, controller, cache, _) = try makeViewer()
        defer { controller.close() }
        XCTAssertTrue(pump(until: { viewer.viewerState.currentImage != nil }))
        viewer.perform(.zoomActualPixels)
        XCTAssertTrue(pump(until: { viewer.nativeDetailDiagnostics().warmTiles > 0 }),
                      "a 100 % view of an 8448-pixel source must warm tiles beyond the viewport")

        // The warm tiles must be uploaded (or queued) without being drawn: it takes a moment for the
        // background queue to catch up.
        XCTAssertTrue(pump(until: { viewer.nativeDetailDiagnostics().gpuResidentTiles
                                    >= viewer.nativeDetailDiagnostics().visibleTiles }),
                      "warm textures must become resident")
        let diagnostics = viewer.nativeDetailDiagnostics()
        XCTAssertGreaterThan(diagnostics.visibleTiles, 0)
        XCTAssertGreaterThan(diagnostics.warmTiles, 0, "the warm set is not empty any more")
        XCTAssertGreaterThan(diagnostics.gpuResidentTiles, diagnostics.visibleTiles,
                             "GPU residency must exceed the draw list")
        XCTAssertGreaterThan(diagnostics.gpuBackgroundUploads, 0,
                             "the background uploader must actually run")
        XCTAssertGreaterThan(cache.count, diagnostics.visibleTiles,
                             "the CPU cache holds more than the viewport")

        // And the draw list really is only the visible tiles.
        let drawn = Set(viewer.canvasNativeTilesForTesting.map { $0.key })
        let visibleKeys = Set((viewer.detailPlanForTesting?.plan.visible ?? []).map {
            NativeTileKey(sourcePath: Fixtures.url(fixtureName).path, tileSize: 512, x: $0.x, y: $0.y)
        })
        XCTAssertTrue(drawn.isSubset(of: visibleKeys),
                      "only visible tiles may reach canvas.nativeTiles (drawn \(drawn.count), "
                      + "visible \(visibleKeys.count))")
        XCTAssertEqual(drawn.count, diagnostics.visibleTiles)
    }

    /// Case B: panning one viewport makes previously-warm tiles visible without re-uploading them.
    func testPanningOntoWarmTilesIsAGpuCacheHit() throws {
        let (viewer, controller, _, _) = try makeViewer()
        defer { controller.close() }
        XCTAssertTrue(pump(until: { viewer.viewerState.currentImage != nil }))
        viewer.perform(.zoomActualPixels)
        XCTAssertTrue(pump(until: { viewer.nativeDetailDiagnostics().gpuWarmTiles > 0 }))
        XCTAssertTrue(pump(until: { viewer.nativeDetailDiagnostics().gpuBackgroundUploads > 0 }))

        let before = viewer.nativeDetailDiagnostics()
        let beforePlan = viewer.detailPlanForTesting?.plan.decodeRect
        // Half a viewport in x: comfortably inside the warm margin, which is what the warm area
        // exists for.
        var viewport = viewer.canvasViewportForTesting
        let visibleWidth = viewer.canvasViewportForTesting.zoomScale > 0
            ? viewer.canvas.bounds.width / viewer.canvasViewportForTesting.zoomScale : 0
        viewport.normalizedCenter = CGPoint(x: viewport.normalizedCenter.x
                                            + (visibleWidth * 0.5 / 8448.0),
                                            y: viewport.normalizedCenter.y)
        viewer.canvasViewportForTesting = viewport
        // Wait for the *plan* to change: the debounce is 220 ms and the previous version of this test
        // read the diagnostics before it fired, which made the before/after snapshots identical.
        XCTAssertTrue(pump(until: {
            viewer.detailPlanForTesting?.plan.decodeRect != beforePlan
        }, timeout: 5), "the pan must produce a new plan")
        _ = pump(until: { false }, timeout: 0.6)   // let the new plan's tiles be published
        let after = viewer.nativeDetailDiagnostics()

        // The tiles now drawn were warm before: residency grew by roughly the new visible tiles,
        // not by the whole viewport being re-fetched.
        XCTAssertGreaterThan(after.visibleTiles, 0)
        let cacheHits = after.gpuCacheHits - before.gpuCacheHits
        if cacheHits == 0 {
            FileHandle.standardError.write(Data((
                "PANDIAG before visible=\(before.visibleTiles) warm=\(before.warmTiles) "
                + "resident=\(before.gpuResidentTiles) uploads=\(before.gpuUploads) hits=\(before.gpuCacheHits)\n"
                + "PANDIAG after  visible=\(after.visibleTiles) warm=\(after.warmTiles) "
                + "resident=\(after.gpuResidentTiles) uploads=\(after.gpuUploads) hits=\(after.gpuCacheHits)\n"
                + "PANDIAG bg=\(after.gpuBackgroundUploads) sync=\(after.gpuSynchronousUploads)\n").utf8))
        }
        XCTAssertGreaterThan(cacheHits, 0, "panning onto warm tiles must be a cache hit")
        // The claim is about the *draw* path: a cold pan uploads every tile it draws, so if any
        // drawn tile was already resident the synchronous upload count must be below the visible
        // count. Background warm uploads for the new plan are counted separately and are expected.
        let synchronousUploads = after.gpuSynchronousUploads - before.gpuSynchronousUploads
        XCTAssertLessThan(synchronousUploads, after.visibleTiles,
                          "not every drawn tile may need an upload (\(synchronousUploads) sync "
                          + "uploads for \(after.visibleTiles) visible tiles)")
        XCTAssertGreaterThan(after.gpuUploads, 0)
    }

    /// Every decoded tile asks for a publication, and a publication walks the whole warm set. The
    /// burst test pins the contract: a hundred arrivals inside one run-loop turn must produce far
    /// fewer than a hundred publications, without delaying the progressive display.
    func testBurstOfTileArrivalsProducesFarFewerPublications() throws {
        let (viewer, controller, _, _) = try makeViewer()
        defer { controller.close() }
        XCTAssertTrue(pump(until: { viewer.viewerState.currentImage != nil }))
        viewer.perform(.zoomActualPixels)
        XCTAssertTrue(pump(until: { viewer.detailPlanForTesting != nil }))
        viewer.resetPublicationDiagnostics()

        // A burst: the provider decodes tiles as fast as it can, and each arrival lands here.
        for _ in 0..<100 { viewer.nativeTileArrived() }
        XCTAssertTrue(pump(until: { viewer.publicationDiagnostics().publicationRuns > 0 }, timeout: 5))
        _ = pump(until: { false }, timeout: 0.2)
        let diagnostics = viewer.publicationDiagnostics()
        let mainMS = String(format: "%.1f", diagnostics.mainThreadPublicationMS)
        let parts = ["PUBDIAG",
                     "arrivals=" + String(diagnostics.tileArrivals),
                     "requests=" + String(diagnostics.publicationRequests),
                     "runs=" + String(diagnostics.publicationRuns),
                     "coalesced=" + String(diagnostics.publicationCoalesced),
                     "visibleMaterialized=" + String(diagnostics.visibleTilesMaterialized),
                     "warmMaterialized=" + String(diagnostics.warmTilesMaterialized),
                     "warmSubmitted=" + String(diagnostics.warmSubmissionCount),
                     "maxPending=" + String(diagnostics.maxPendingPublications),
                     "mainMS=" + mainMS]
        FileHandle.standardError.write(Data((parts.joined(separator: " ") + "\n").utf8))
        // The live pass also delivers arrivals of its own, so this is a lower bound.
        XCTAssertGreaterThanOrEqual(diagnostics.tileArrivals, 100)
        XCTAssertLessThanOrEqual(diagnostics.publicationRuns, 12,
                                 "a burst must coalesce, not publish 100 times "
                                 + "(runs \(diagnostics.publicationRuns))")
        XCTAssertGreaterThan(diagnostics.publicationCoalesced, 0,
                             "arrivals absorbed by a pending publication are counted")
        XCTAssertLessThanOrEqual(diagnostics.maxPendingPublications, 1,
                                 "never more than one publication in flight")
    }

    /// Progressive display: the first tiles must reach the screen while the pass is still running,
    /// not after it finishes.
    func testPublicationsHappenDuringThePassNotAfterIt() throws {
        let (viewer, controller, _, _) = try makeViewer()
        defer { controller.close() }
        XCTAssertTrue(pump(until: { viewer.viewerState.currentImage != nil }))
        viewer.perform(.zoomActualPixels)
        XCTAssertTrue(pump(until: { viewer.detailPlanForTesting != nil }))
        XCTAssertTrue(pump(until: { viewer.publicationDiagnostics().publicationRuns >= 2 }, timeout: 20),
                      "the pass must publish more than once while tiles arrive")
        XCTAssertTrue(pump(until: { viewer.canvasNativeTilesForTesting.count > 0 }, timeout: 20),
                      "visible tiles must be published progressively")
        let diagnostics = viewer.publicationDiagnostics()
        XCTAssertGreaterThan(diagnostics.visibleTilesMaterialized, 0)
        XCTAssertGreaterThan(diagnostics.warmSubmissionCount, 0, "warm tiles are handed over")
        // Coalescing must stay well inside a frame budget.
        XCTAssertLessThanOrEqual(viewer.publicationCoalescingInterval, 0.02,
                                 "the interval may not become a debounce")
    }

    /// Publication hands the uploader only the tiles that are newly warm: re-submitting the whole
    /// warm set on every publication is what made the work quadratic.
    func testPublicationSubmitsOnlyNewlyWarmTiles() throws {
        let (viewer, controller, _, _) = try makeViewer()
        defer { controller.close() }
        XCTAssertTrue(pump(until: { viewer.viewerState.currentImage != nil }))
        viewer.perform(.zoomActualPixels)
        XCTAssertTrue(pump(until: { viewer.publicationDiagnostics().warmSubmissionCount > 0 },
                           timeout: 20))
        // Let the pass settle, then publish again with an unchanged warm set.
        _ = pump(until: { false }, timeout: 1.0)
        let before = viewer.publicationDiagnostics()
        viewer.nativeTileArrived()
        XCTAssertTrue(pump(until: {
            viewer.publicationDiagnostics().publicationRuns > before.publicationRuns
        }, timeout: 5))
        let after = viewer.publicationDiagnostics()
        XCTAssertEqual(after.warmSubmissionCount, before.warmSubmissionCount,
                       "a publication whose warm set did not change submits nothing")
    }

    /// The drawer asks for its thumbnails before the current item's bitmap exists, and for an
    /// oversized file that request is answered by the oversized policy with a placeholder. Nothing
    /// asked again: measured on the investigation image, exactly one request in the whole session
    /// (`requests=1` after 34 s) and a permanently empty row.
    ///
    /// The before-state evidence is that measurement; this test guards the retry that fixes it.
    func testCurrentItemThumbnailArrivesAfterTheBitmapPublishes() throws {
        let (viewer, controller, _, _) = try makeViewer()
        defer { controller.close() }
        XCTAssertTrue(pump(until: { viewer.viewerState.currentImage != nil }))
        let url = Fixtures.url(fixtureName)
        XCTAssertTrue(pump(until: { viewer.hasCachedThumbnailForTesting(url) }, timeout: 10),
                      "the current item's thumbnail must arrive once its bitmap exists")
        XCTAssertGreaterThan(viewer.thumbnailRequestCount, 0,
                             "and the request must have been made from the current-item preview")
    }

    /// The cache count is the cache count: the old property reported the *drawn* tile count, so a
    /// warm plan looked like it had no cached tiles at all.
    func testCacheCountForTestingIsTheCacheNotTheDrawList() throws {
        let (viewer, controller, cache, _) = try makeViewer()
        defer { controller.close() }
        XCTAssertTrue(pump(until: { viewer.viewerState.currentImage != nil }))
        viewer.perform(.zoomActualPixels)
        XCTAssertTrue(pump(until: { viewer.nativeDetailDiagnostics().warmTiles > 0 }),
                      "the plan must warm tiles beyond the viewport")
        XCTAssertTrue(pump(until: { viewer.nativeDetailDiagnostics().cpuCacheTiles > 0 }))
        let diagnostics = viewer.nativeDetailDiagnostics()
        XCTAssertEqual(viewer.nativeDetailCacheCountForTesting, cache.count,
                       "the property must read the cache")
        XCTAssertEqual(viewer.nativeDetailCacheCountForTesting, diagnostics.cpuCacheTiles)
        XCTAssertGreaterThanOrEqual(diagnostics.cpuCacheTiles, diagnostics.visibleTiles)
    }

    /// The budget the policy plans against is the budget the cache enforces.
    func testThePolicyBudgetIsTheCacheBudget() throws {
        let (viewer, controller, cache, scheduler) = try makeViewer()
        defer { controller.close() }
        XCTAssertEqual(viewer.nativeDetailCPUBudgetBytes, cache.totalCostLimit,
                       "the policy plans against the cache's budget, not a second number")
        XCTAssertEqual(scheduler.cacheCostLimit, cache.totalCostLimit)
        // And the default scheduler uses the budget the sweep chose, so an app that takes the
        // defaults gets the nine-grid at 1.0 and 2.0.
        let defaultScheduler = NativeDetailScheduler()
        XCTAssertEqual(defaultScheduler.cacheCostLimit, 256 * 1024 * 1024)
    }

    /// Texture variants are part of the GPU cache identity: a mipmapped tile and a base-only tile
    /// are different entries, and switching the policy drops the other flavour.
    func testTextureVariantsAreSeparateCacheEntries() throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let renderer = MetalImageRenderer(device: device) else {
            throw XCTSkip("no Metal device")
        }
        let image = try XCTUnwrap(renderer.encodedTileImage(width: 64, height: 64))
        let key = NativeTileKey(sourcePath: "/tmp/x.png", tileSize: 64, x: 0, y: 0)
        let tile = NativeTile(key: key, sourceRect: CGRect(x: 0, y: 0, width: 64, height: 64),
                              image: image)
        let base = try XCTUnwrap(renderer.prepareTexture(for: tile, variant: .baseOnly))
        let diagnosticAfterBase = renderer.tileTextureDiagnostics()
        let mipmapped = try XCTUnwrap(renderer.prepareTexture(for: tile, variant: .mipmapped))
        let diagnosticAfterMip = renderer.tileTextureDiagnostics()

        XCTAssertFalse(base === mipmapped, "the two variants are different textures")
        XCTAssertEqual(diagnosticAfterMip.resident, 2, "both flavours are cached separately")
        XCTAssertGreaterThan(diagnosticAfterMip.bytes, diagnosticAfterBase.bytes,
                             "a mip chain costs more than the base level")
        // Real allocation accounting: a 64×64 mipmapped tile is 16 KiB + a third.
        XCTAssertEqual(MetalImageRenderer.textureBytes(width: 64, height: 64, mipmapped: false),
                       64 * 64 * 4)
        XCTAssertEqual(MetalImageRenderer.textureBytes(width: 64, height: 64, mipmapped: true),
                       64 * 64 * 4 * 4 / 3)

        renderer.dropTileTextures(of: .baseOnly)
        XCTAssertEqual(renderer.tileTextureDiagnostics().resident, 1,
                       "switching variant drops the other flavour")
    }

    private func tileForBilling(_ renderer: MetalImageRenderer, x: Int) throws -> NativeTile {
        NativeTile(key: NativeTileKey(sourcePath: "/tmp/billing.png", tileSize: 64, x: x, y: 0),
                   sourceRect: CGRect(x: x * 64, y: 0, width: 64, height: 64),
                   image: try XCTUnwrap(renderer.encodedTileImage(width: 64, height: 64)))
    }

    /// A tile the user just looked at survives a pan away and back (LRU by use, not insertion).
    func testGpuCacheIsLruByUse() throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let renderer = MetalImageRenderer(device: device) else {
            throw XCTSkip("no Metal device")
        }
        // The budget is built from the *billed* cost, which is what the cache compares against.
        let probe = try XCTUnwrap(renderer.prepareTexture(for: try tileForBilling(renderer, x: 80),
                                                          variant: .baseOnly))
        renderer.tileTextureBudget = 3 * MetalImageRenderer.byteCost(of: probe)
        func tile(_ x: Int) throws -> NativeTile {
            NativeTile(key: NativeTileKey(sourcePath: "/tmp/y.png", tileSize: 64, x: x, y: 0),
                       sourceRect: CGRect(x: x * 64, y: 0, width: 64, height: 64),
                       image: try XCTUnwrap(renderer.encodedTileImage(width: 64, height: 64)))
        }
        let first = try tile(0)
        _ = renderer.prepareTexture(for: first, variant: .baseOnly)
        for x in 1...2 { _ = renderer.prepareTexture(for: try tile(x), variant: .baseOnly) }
        // Touch the oldest so it is the most recently used, then force eviction.
        let hitsBefore = renderer.tileTextureDiagnostics().foregroundHits
        _ = renderer.prepareTexture(for: first, variant: .baseOnly)
        XCTAssertEqual(renderer.tileTextureDiagnostics().foregroundHits, hitsBefore + 1)
        _ = renderer.prepareTexture(for: try tile(3), variant: .baseOnly)
        XCTAssertEqual(renderer.tileTextureDiagnostics().resident, 3, "the budget holds three tiles")
        // The tile that was *not* touched most recently must be the one that went.
        let survivor = renderer.prepareTexture(for: first, variant: .baseOnly)
        XCTAssertNotNil(survivor, "the recently used tile survives")
        XCTAssertEqual(renderer.tileTextureDiagnostics().foregroundHits, hitsBefore + 2,
                       "and it is a hit, not a re-upload")
    }

    /// The direction hint reaches the plan from the real viewport movement, and only reorders.
    func testTheDirectionHintComesFromViewportTravel() throws {
        let (viewer, controller, _, _) = try makeViewer()
        defer { controller.close() }
        XCTAssertTrue(pump(until: { viewer.viewerState.currentImage != nil }))
        viewer.perform(.zoomActualPixels)
        XCTAssertTrue(pump(until: { viewer.nativeDetailDiagnostics().warmTiles > 0 }))
        XCTAssertEqual(viewer.lastDetailDirectionHint.dx, 0, accuracy: 0.001,
                       "no travel yet, no hint")

        let before = viewer.detailPlanForTesting?.plan.ring ?? []
        var viewport = viewer.canvasViewportForTesting
        // Move the viewport well to the right in source space.
        viewport.normalizedCenter = CGPoint(x: min(0.9, viewport.normalizedCenter.x + 0.1),
                                            y: viewport.normalizedCenter.y)
        viewer.canvasViewportForTesting = viewport
        XCTAssertTrue(pump(until: { viewer.lastDetailDirectionHint.dx > 0.5 }, timeout: 5),
                      "rightward travel must produce a rightward hint, got "
                      + "\(viewer.lastDetailDirectionHint)")
        let after = viewer.detailPlanForTesting?.plan.ring ?? []
        XCTAssertFalse(after.isEmpty)
        _ = before
        // With a rightward hint the first warm tile to be asked for is on the right of the viewport
        // centre — ordering, not geometry: the same tiles are warm either way.
        let visibleRect = NativeTilePlanner.visibleSourceRect(viewport: viewer.viewerState.viewport,
                                                              sourcePixelSize: CGSize(width: 8448, height: 320),
                                                              viewSize: viewer.canvasViewForTesting.bounds.size)
        let first = try XCTUnwrap(after.first)
        let firstRect = NativeTilePlanner.sourceRect(for: first, tileSize: 512,
                                                     sourcePixelSize: CGSize(width: 8448, height: 320))
        XCTAssertGreaterThan(firstRect.midX, visibleRect.midX,
                             "a rightward hint orders the right-hand side first")
    }
}

private extension ViewerViewController {
    var canvas: ImageCanvasView { canvasViewForTesting }
}
