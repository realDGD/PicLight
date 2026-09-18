import XCTest
import AppKit
@testable import PicViewMac

/// The native-detail lifecycle: a late cleanup must never take down the pass that replaced it, and
/// the branch-coverage questions the previous round left open.
@MainActor
final class LifecycleEpochTests: XCTestCase {

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
                                bytesPerRow: width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
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

    private func makeViewer(cacheBudget: Int = 64 * 1024 * 1024) throws
        -> (ViewerViewController, ViewerWindowController, NativeTileCache) {
        guard FileManager.default.fileExists(atPath: Fixtures.url(fixtureName).path) else {
            throw XCTSkip("fixture missing")
        }
        let decoder = CountingDecoder(payload: proxyBitmap(width: 2048, height: 78),
                                      document: .still,
                                      pixelSize: CGSize(width: 8448, height: 320))
        let cache = NativeTileCache(totalCostLimit: cacheBudget)
        let scheduler = NativeDetailScheduler(cache: cache, tileSize: 512)
        let viewer = ViewerViewController(decoder: decoder, thumbnails: ThumbnailPipeline(),
                                          probe: Probe(longEdge: 8448), nativeDetail: scheduler)
        let controller = ViewerWindowController(viewer: viewer)
        TestAppKit.presentOffScreen(controller)
        _ = viewer.view
        viewer.open(url: Fixtures.url(fixtureName))
        return (viewer, controller, cache)
    }

    // MARK: - A: the scheduler's lifecycle contract

    /// The defect: a cleanup created before a new request, delivered after it, wiped the new pass.
    /// The epoch makes that impossible — the deterministic test drives the scheduler directly,
    /// because the ordering inside the viewer is a property of unstructured tasks and must not be
    /// simulated with sleeps.
    func testAnOlderPurgeCannotStopANewerRequest() async throws {
        let scheduler = NativeDetailScheduler(cache: NativeTileCache(totalCostLimit: 32 * 1024 * 1024),
                                              tileSize: 512)
        let source = Fixtures.url(fixtureName)
        let planA = try XCTUnwrap(NativeTilePlanner.plan(sourceRect: CGRect(x: 0, y: 0, width: 2048,
                                                                          height: 512),
                                                        sourcePixelSize: CGSize(width: 8448, height: 320),
                                                        tileSize: 512, ring: 0))
        let planB = try XCTUnwrap(NativeTilePlanner.plan(sourceRect: CGRect(x: 2048, y: 0, width: 2048,
                                                                           height: 512),
                                                         sourcePixelSize: CGSize(width: 8448, height: 320),
                                                         tileSize: 512, ring: 0))
        // Plan A, then the clear that belongs to it, then plan B — with the clear delivered late.
        await scheduler.request(plan: planA, source: source, epoch: 1)
        await scheduler.request(plan: planB, source: source, epoch: 3)
        await scheduler.stopAndPurge(epoch: 2)          // the late cleanup of epoch 2

        let survived = await scheduler.runningPlanForTesting
        XCTAssertNotNil(survived,
                        "the pass for the newer epoch must survive the older cleanup")
        let ignored = await scheduler.lifecycleIgnoredStale
        XCTAssertEqual(ignored, 1,
                       "and the late cleanup is accounted for")
        // A cleanup that really is the newest still stops everything.
        await scheduler.stopAndPurge(epoch: 4)
        let afterRealClear = await scheduler.runningPlanForTesting
        XCTAssertNil(afterRealClear)
    }

    /// And the viewer's own clear-then-zoom-in sequence ends with the new plan alive.
    func testImmediateReEnableAfterADisableKeepsTheNewPlan() throws {
        let (viewer, controller, _) = try makeViewer()
        defer { controller.close() }
        XCTAssertTrue(pump(until: { viewer.viewerState.currentImage != nil }))
        viewer.perform(.zoomActualPixels)
        XCTAssertTrue(pump(until: { viewer.detailPlanForTesting != nil }))

        viewer.perform(.zoomToFit)                          // disable: schedules a purge
        XCTAssertTrue(pump(until: { viewer.detailPlanForTesting == nil }, timeout: 10))
        viewer.perform(.zoomActualPixels)                   // re-enable immediately
        XCTAssertTrue(pump(until: { viewer.detailPlanForTesting != nil }, timeout: 15),
                      "the new plan must be established")
        // Give any late purge every chance to arrive.
        _ = pump(until: { false }, timeout: 1.5)
        XCTAssertNotNil(viewer.detailPlanForTesting,
                        "a late purge must not clear the plan that replaced it")
        XCTAssertTrue(pump(until: { viewer.nativeDetailDiagnostics().cpuCacheTiles > 0 }, timeout: 20),
                      "and the new pass must still produce tiles")
        XCTAssertFalse(viewer.publishedResidentKeysForTesting.isEmpty,
                       "with its textures resident")
    }

    // MARK: - B: did the previous test actually reach the branch it claimed?

    /// The previous round's test drove `loadCurrentImage`, which clears unconditionally — so it
    /// proved that path, not the unusable-warm-plan branch. This one calls the real detail update
    /// directly, with a viewport whose visible rectangle is under a pixel, and checks the branch
    /// counter.
    func testUnusableWarmPlanBranchIsActuallyReached() throws {
        let (viewer, controller, cache) = try makeViewer()
        defer { controller.close() }
        XCTAssertTrue(pump(until: { viewer.viewerState.currentImage != nil }))
        viewer.perform(.zoomActualPixels)
        XCTAssertTrue(pump(until: { viewer.detailPlanForTesting != nil }))
        XCTAssertTrue(pump(until: { viewer.nativeDetailDiagnostics().cpuCacheTiles > 0 }))
        XCTAssertEqual(viewer.warmPlanNilCleanups, 0, "nothing has hit the branch yet")

        // Native detail is still wanted (a huge magnification), but the visible rectangle is smaller
        // than a pixel, so no warm plan can be built.
        var viewport = viewer.canvasViewportForTesting
        viewport.zoomScale = 10_000_000
        viewer.canvasViewportForTesting = viewport
        viewer.updateNativeDetailForTesting()

        XCTAssertEqual(viewer.warmPlanNilCleanups, 1,
                       "the unusable-warm-plan branch must actually run")
        XCTAssertNil(viewer.detailPlanForTesting, "and it must clear the plan")
        XCTAssertTrue(pump(until: { viewer.nativeDetailDiagnostics().cpuCacheTiles == 0 }, timeout: 10),
                      "and stop the pass whose tiles nobody can use")
        XCTAssertEqual(cache.count, 0)
        XCTAssertTrue(pump(until: { viewer.publishedResidentKeysForTesting.isEmpty }, timeout: 10))
    }

    // MARK: - D: diagnostics

    /// A clamped flag that survives the clear reports a budget problem for a plan that is gone.
    func testClampedByBudgetIsResetWhenNativeDetailIsCleared() throws {
        // A budget far below what the warm plan needs, so the plan really is clamped.
        let (viewer, controller, _) = try makeViewer(cacheBudget: 128 * 1024)
        defer { controller.close() }
        XCTAssertTrue(pump(until: { viewer.viewerState.currentImage != nil }))
        viewer.perform(.zoomActualPixels)
        viewer.updateNativeDetailForTesting()
        XCTAssertTrue(pump(until: { viewer.nativeDetailDiagnostics().clampedByBudget }, timeout: 15),
                      "the plan must be clamped by the budget for this test to mean anything")

        viewer.perform(.zoomToFit)                 // disable → clearNativeDetail()
        XCTAssertTrue(pump(until: { viewer.detailPlanForTesting == nil }, timeout: 10))
        XCTAssertFalse(viewer.nativeDetailDiagnostics().clampedByBudget,
                       "a cleared plan cannot be clamped by a budget")
    }
}
