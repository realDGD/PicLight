import XCTest
import AppKit
@testable import PicViewMac

/// Native-detail lifecycle: what happens to the plan, the pass and the resident textures when there
/// is no image to show detail for any more.
///
/// Two paths used to clear only the draw list: the missing current item and an unusable warm plan.
/// The scheduler's pass kept running and its textures stayed resident for an image nobody was
/// looking at, which is what these tests pin down.
@MainActor
final class NativeDetailLifecycleTests: XCTestCase {

    private let fixtureName = "oversized-detail.png"

    override func setUp() async throws {
        try await super.setUp()
        TestAppKit.ensureApplication()
    }

    private struct Probe: DimensionProbing {
        let longEdge: Int
        /// The fixture is oversized and never gets a file-based thumbnail; every other file in the
        /// folder is small, so its thumbnail really loads. Tests need both behaviours.
        let oversizedFixture: URL

        func longEdge(of url: URL) async -> Int? {
            url.lastPathComponent == oversizedFixture.lastPathComponent ? longEdge : 64
        }
    }

    private func proxyBitmap(width: Int, height: Int) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                bytesPerRow: width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    @discardableResult
    private func pump(until condition: () -> Bool, timeout: TimeInterval = 25) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return condition()
    }

    private func makeViewer() throws -> (ViewerViewController, ViewerWindowController, NativeTileCache) {
        guard FileManager.default.fileExists(atPath: Fixtures.url(fixtureName).path) else {
            throw XCTSkip("fixture missing")
        }
        let decoder = CountingDecoder(payload: proxyBitmap(width: 2048, height: 78),
                                      document: .still,
                                      pixelSize: CGSize(width: 8448, height: 320))
        let cache = NativeTileCache(totalCostLimit: 64 * 1024 * 1024)
        let scheduler = NativeDetailScheduler(cache: cache, tileSize: 512)
        let viewer = ViewerViewController(decoder: decoder, thumbnails: ThumbnailPipeline(),
                                          probe: Probe(longEdge: 8448,
                                                       oversizedFixture: Fixtures.url(fixtureName)),
                                          nativeDetail: scheduler)
        let controller = ViewerWindowController(viewer: viewer)
        TestAppKit.presentOffScreen(controller)
        _ = viewer.view
        viewer.open(url: Fixtures.url(fixtureName))
        return (viewer, controller, cache)
    }

    /// A. With no current item the whole native-detail state must go: plan, draw list, resident
    /// textures, CPU cache and the running pass.
    func testMissingCurrentItemClearsTheWholeNativeDetailState() throws {
        let (viewer, controller, cache) = try makeViewer()
        defer { controller.close() }
        XCTAssertTrue(pump(until: { viewer.viewerState.currentImage != nil }))
        viewer.perform(.zoomActualPixels)
        XCTAssertTrue(pump(until: { viewer.detailPlanForTesting != nil }), "detail must be active")
        XCTAssertTrue(pump(until: { viewer.nativeDetailDiagnostics().cpuCacheTiles > 0 }),
                      "the pass must have produced tiles")

        // The last item disappears: the session is emptied and the image load re-runs.
        viewer.session.setItems([], preferredIdentity: nil)
        viewer.reloadCurrentImageForTesting()
        XCTAssertTrue(pump(until: { viewer.detailPlanForTesting == nil }, timeout: 10),
                      "the plan must be cleared")
        XCTAssertTrue(pump(until: { viewer.canvasNativeTilesForTesting.isEmpty }, timeout: 10))
        XCTAssertTrue(pump(until: { viewer.publishedResidentKeysForTesting.isEmpty }, timeout: 10))
        XCTAssertEqual(viewer.residentKeysForTesting.count, 0,
                       "the renderer must hold no textures for an image that is gone")
        // stopAndPurge is asynchronous: wait for it rather than sampling immediately.
        XCTAssertTrue(pump(until: { viewer.nativeDetailDiagnostics().cpuCacheTiles == 0 }, timeout: 10),
                      "the CPU tile cache must be purged")
        XCTAssertEqual(cache.count, 0)
        XCTAssertEqual(viewer.nativeDetailDiagnostics().visibleTiles, 0)
        XCTAssertEqual(viewer.nativeDetailDiagnostics().warmTiles, 0)
        // And an arrival from the abandoned pass must not schedule a publication.
        let runs = viewer.publicationDiagnostics().publicationRuns
        viewer.nativeTileArrived()
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        XCTAssertEqual(viewer.publicationDiagnostics().publicationRuns, runs,
                       "a stale arrival must not publish once the plan is gone")
    }

    /// B. An unusable warm plan is a reason to disable native detail, not just to draw nothing.
    func testAnUnusableWarmPlanClearsThePreviousPlan() throws {
        let (viewer, controller, cache) = try makeViewer()
        defer { controller.close() }
        XCTAssertTrue(pump(until: { viewer.viewerState.currentImage != nil }))
        viewer.perform(.zoomActualPixels)
        XCTAssertTrue(pump(until: { viewer.detailPlanForTesting != nil }))
        XCTAssertTrue(pump(until: { viewer.nativeDetailDiagnostics().cpuCacheTiles > 0 }))

        // A degenerate viewport: zero-sized, so the warm plan cannot be built.
        var viewport = viewer.canvasViewportForTesting
        viewport.zoomScale = 0
        viewer.canvasViewportForTesting = viewport
        viewer.reloadCurrentImageForTesting()
        XCTAssertTrue(pump(until: { viewer.detailPlanForTesting == nil }, timeout: 10),
                      "an unusable plan must clear the previous one")
        XCTAssertTrue(pump(until: { viewer.nativeDetailDiagnostics().cpuCacheTiles == 0 }, timeout: 10),
                      "and stop the pass whose tiles nobody can use")
        XCTAssertEqual(cache.count, 0)
        XCTAssertTrue(pump(until: { viewer.publishedResidentKeysForTesting.isEmpty }, timeout: 10))
        XCTAssertEqual(viewer.residentKeysForTesting.count, 0)
    }

    /// H. Disabling native detail with an empty plan is enough for arrivals to stop publishing.
    func testArrivalsDoNotPublishWithoutAPlan() throws {
        let (viewer, controller, _) = try makeViewer()
        defer { controller.close() }
        XCTAssertTrue(pump(until: { viewer.viewerState.currentImage != nil }))
        viewer.perform(.zoomToFit)          // the proxy resolves the screen: no native detail
        XCTAssertTrue(pump(until: { viewer.detailPlanForTesting == nil }, timeout: 10))
        let runs = viewer.publicationDiagnostics().publicationRuns
        for _ in 0..<20 { viewer.nativeTileArrived() }
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        XCTAssertEqual(viewer.publicationDiagnostics().publicationRuns, runs,
                       "arrivals without a plan must not publish")
    }

    /// C. A queued retry is consumed by *any* completion, including a successful one. The request
    /// used here is for another file in the folder, whose thumbnail really loads, so the completion
    /// takes the success branch the previous version returned from without consuming the queue.
    func testASuccessfulRequestConsumesTheQueuedRetry() throws {
        let (viewer, controller, _) = try makeViewer()
        defer { controller.close() }
        XCTAssertTrue(pump(until: { viewer.viewerState.currentImage != nil }))
        let other = try XCTUnwrap(viewer.session.items.first(where: {
            $0.url.lastPathComponent != fixtureName
        }), "the fixture folder must hold more than one file")

        let gate = PauseGate()
        viewer.thumbnailPauseHook = gate.hookAll
        viewer.requestThumbnailForTesting(other)          // starts, and suspends in the gate
        XCTAssertTrue(pump(until: { gate.suspendedCount >= 1 }, timeout: 15),
                      "the request must be running")
        viewer.requestThumbnailForTesting(other)          // queued behind it
        let queued = viewer.thumbnailRequestDiagnostics().retryQueued
        XCTAssertEqual(queued, 1, "the second request queues a retry instead of starting")

        gate.releaseAll()
        XCTAssertTrue(pump(until: { viewer.thumbnailRequestDiagnostics().active == 0 }, timeout: 15))
        _ = pump(until: { false }, timeout: 0.3)
        XCTAssertEqual(viewer.thumbnailRequestDiagnostics().retryQueued, 0,
                       "every completion consumes the queued retry, successful or not")
        XCTAssertLessThanOrEqual(viewer.thumbnailRequestDiagnostics().maxConcurrentPerURL, 1,
                                 "and the one-request-per-URL invariant holds")
        viewer.thumbnailPauseHook = nil
    }

    /// D. How large the thumbnail cache actually gets: no budget exists, so this measures the real
    /// growth rather than asserting a limit that is not implemented.
    func testThumbnailCacheGrowthIsMeasured() throws {
        let (viewer, controller, _) = try makeViewer()
        defer { controller.close() }
        XCTAssertTrue(pump(until: { viewer.viewerState.currentImage != nil }))

        // Visit files through the real path (the drawer's own request machinery).
        for _ in 0..<25 {
            viewer.perform(.nextImage)
            guard pump(until: { viewer.viewerState.currentImage != nil }, timeout: 8) else { break }
            _ = pump(until: { viewer.thumbnailRequestDiagnostics().active == 0 }, timeout: 8)
        }
        let bytes = viewer.thumbnailCacheBytesForTesting
        FileHandle.standardError.write(Data((
            "THUMBCACHE entries=\(viewer.thumbnailCacheCountForTesting) bytes=\(bytes) "
            + "(w*h*4 per entry)\n").utf8))
        XCTAssertGreaterThan(viewer.thumbnailCacheCountForTesting, 0,
                             "visiting files must populate the cache")
    }

    /// F. Does an update that produces the same plan and source cost anything? Measured rather than
    /// assumed: the generation is bumped unconditionally, but what matters is whether that starts a
    /// request, a traversal or a visible fallback.
    func testRepeatedIdenticalPlanUpdateIsMeasured() throws {
        let (viewer, controller, _) = try makeViewer()
        defer { controller.close() }
        XCTAssertTrue(pump(until: { viewer.viewerState.currentImage != nil }))
        viewer.perform(.zoomActualPixels)
        XCTAssertTrue(pump(until: { viewer.detailPlanForTesting != nil }))
        XCTAssertTrue(pump(until: { !viewer.canvasNativeTilesForTesting.isEmpty }, timeout: 20))
        // Let the first publication settle.
        _ = pump(until: { viewer.publicationDiagnostics().pendingPublications == 0 }, timeout: 5)

        let generationBefore = viewer.publicationDiagnostics().generation
        let requestsBefore = viewer.requestSnapshotsForTesting.count
        let planBefore = viewer.detailPlanForTesting?.plan.decodeRect
        let tilesBefore = viewer.canvasNativeTilesForTesting.count
        var sawEmptyCanvas = false

        // The same viewport, assigned again: the shape a duplicated layout or viewport callback has.
        for _ in 0..<3 {
            viewer.canvasViewportForTesting = viewer.canvasViewportForTesting
            let deadline = Date().addingTimeInterval(1.2)
            while Date() < deadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.05))
                if viewer.canvasNativeTilesForTesting.isEmpty { sawEmptyCanvas = true }
            }
        }
        let generationAfter = viewer.publicationDiagnostics().generation
        let requestsAfter = viewer.requestSnapshotsForTesting.count
        let generationDelta = generationAfter - generationBefore
        let requestDelta = requestsAfter - requestsBefore
        let planStable = viewer.detailPlanForTesting?.plan.decodeRect == planBefore
        let tilesAfter = viewer.canvasNativeTilesForTesting.count
        let line = "SAMEPLAN generationDelta=" + String(generationDelta)
            + " requestDelta=" + String(requestDelta)
            + " planStable=" + String(planStable)
            + " tilesBefore=" + String(tilesBefore)
            + " tilesAfter=" + String(tilesAfter)
            + " sawEmptyCanvas=" + String(sawEmptyCanvas) + "\n"
        FileHandle.standardError.write(Data(line.utf8))
    }
}
