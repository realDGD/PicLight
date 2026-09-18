import XCTest
import AppKit
@testable import PicViewMac

/// The *direct* publication path — `updateNativeDetail` → `nativeDetail.request` → publish — as
/// opposed to the scheduled path driven by tile arrivals.
///
/// Two suspicions about it: the publication generation is read when the task runs rather than
/// captured when the plan is created (so an old plan can inherit the new plan's generation and pass
/// the guard), and the source metadata (`colorSpace`, `orientation`) is read inside the task (so an
/// old source's request can carry the new source's metadata). A hook suspends the task before it
/// reads anything, which is how these are made deterministic rather than timing-dependent.
@MainActor
final class DirectRequestGenerationTests: XCTestCase {

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
    private func pump(until condition: () -> Bool, timeout: TimeInterval = 30) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return condition()
    }

    private func makeViewer() throws -> (ViewerViewController, ViewerWindowController) {
        guard FileManager.default.fileExists(atPath: Fixtures.url(fixtureName).path) else {
            throw XCTSkip("fixture missing")
        }
        let decoder = CountingDecoder(payload: proxyBitmap(width: 2048, height: 78),
                                      document: .still,
                                      pixelSize: CGSize(width: 8448, height: 320))
        let scheduler = NativeDetailScheduler(cache: NativeTileCache(totalCostLimit: 64 * 1024 * 1024),
                                              tileSize: 512)
        let viewer = ViewerViewController(decoder: decoder, thumbnails: ThumbnailPipeline(),
                                          probe: Probe(longEdge: 8448), nativeDetail: scheduler)
        let controller = ViewerWindowController(viewer: viewer)
        TestAppKit.presentOffScreen(controller)
        _ = viewer.view
        viewer.open(url: Fixtures.url(fixtureName))
        return (viewer, controller)
    }

    /// A. The plan is replaced while a direct request is still pending. Its publication must not
    /// apply: it would put the abandoned plan's tiles on the canvas and hand the renderer the
    /// abandoned resident set.
    func testDirectPublicationForAnAbandonedPlanIsDiscarded() throws {
        let (viewer, controller) = try makeViewer()
        defer { controller.close() }
        XCTAssertTrue(pump(until: { viewer.viewerState.currentImage != nil }))
        viewer.perform(.zoomActualPixels)
        XCTAssertTrue(pump(until: { viewer.detailPlanForTesting != nil }))

        // Hold the next direct request before it reads anything.
        let gate = PauseGate()
        viewer.directRequestPauseHook = gate.hook
        viewer.nativeTileArrived()                 // a publication path that also triggers a plan
        viewer.perform(.zoomActualPixels)          // force another updateNativeDetail
        XCTAssertTrue(pump(until: { gate.hasEntered }), "the direct request must be pending")
        let planBefore = viewer.detailPlanForTesting?.plan.decodeRect

        // The user pans while that request is pending: a new plan and a new generation.
        viewer.panForTesting(byViewports: 1.0)
        XCTAssertTrue(pump(until: { viewer.detailPlanForTesting?.plan.decodeRect != planBefore }),
                      "the pan must produce a new plan")
        _ = pump(until: { !viewer.canvasNativeTilesForTesting.isEmpty }, timeout: 10)
        let currentVisible = Set((viewer.detailPlanForTesting?.plan.visible ?? []).map {
            NativeTileKey(sourcePath: Fixtures.url(fixtureName).path, tileSize: 512, x: $0.x, y: $0.y)
        })
        let currentResident = viewer.residentKeysForTesting(plan: viewer.detailPlanForTesting!.plan,
                                                           source: Fixtures.url(fixtureName))

        // Let the abandoned request finish and publish.
        gate.release()
        _ = pump(until: { false }, timeout: 1.5)

        let drawn = Set(viewer.canvasNativeTilesForTesting.map { $0.key })
        XCTAssertTrue(drawn.isSubset(of: currentVisible),
                      "the abandoned plan's tiles reached the canvas: \(drawn.count) drawn, "
                      + "\(currentVisible.count) in the current plan")
        XCTAssertTrue(viewer.publishedResidentKeysForTesting.isSubset(of: currentResident),
                      "the abandoned publication handed the renderer a resident set from the "
                      + "previous plan")
        XCTAssertGreaterThanOrEqual(viewer.staleDirectPublicationDiscards + viewer.staleDirectRequestSkips, 1,
                                    "the abandoned direct request is accounted for")
    }

    /// B. A request for source A must never carry source B's metadata. The fixture folder holds many
    /// files, so switching the current item changes both the source and the descriptor.
    func testAPendingRequestDoesNotPickUpTheNewSourceMetadata() throws {
        let (viewer, controller) = try makeViewer()
        defer { controller.close() }
        XCTAssertTrue(pump(until: { viewer.viewerState.currentImage != nil }))
        viewer.perform(.zoomActualPixels)
        XCTAssertTrue(pump(until: { viewer.detailPlanForTesting != nil }))
        // The first request already ran, so the snapshot holds the source and metadata of A.
        let sourceA = try XCTUnwrap(viewer.requestSnapshotsForTesting.last?.source)
        let orientationA = viewer.requestSnapshotsForTesting.last?.orientation

        let gate = PauseGate()
        viewer.directRequestPauseHook = gate.hook
        viewer.perform(.zoomActualPixels)
        XCTAssertTrue(pump(until: { gate.hasEntered }), "the direct request must be pending")

        // Switch to another file while the request is pending.
        viewer.perform(.nextImage)
        XCTAssertTrue(pump(until: { viewer.currentItemURLForTesting != sourceA }, timeout: 15),
                      "the current item must change")
        gate.release()
        _ = pump(until: { false }, timeout: 1.0)

        let mismatched = viewer.requestSnapshotsForTesting.filter {
            $0.source == sourceA && $0.orientation != orientationA
        }
        XCTAssertTrue(mismatched.isEmpty,
                      "a request for the old source ran with the new source's metadata "
                      + "(\(mismatched.count) of \(viewer.requestSnapshotsForTesting.count) "
                      + "requests)")
    }

    /// C. After the plan is dropped (native detail no longer needed), a pending request must not
    /// restart a pass for the abandoned plan.
    func testAPendingRequestIsDroppedWhenThePlanIsCleared() throws {
        let (viewer, controller) = try makeViewer()
        defer { controller.close() }
        XCTAssertTrue(pump(until: { viewer.viewerState.currentImage != nil }))
        viewer.perform(.zoomActualPixels)
        XCTAssertTrue(pump(until: { viewer.detailPlanForTesting != nil }))

        let gate = PauseGate()
        viewer.directRequestPauseHook = gate.hook
        viewer.perform(.zoomActualPixels)
        XCTAssertTrue(pump(until: { gate.hasEntered }), "the direct request must be pending")

        // Drop the plan the way the "proxy resolves everything" path does.
        viewer.perform(.zoomToFit)
        XCTAssertTrue(pump(until: { viewer.detailPlanForTesting == nil }, timeout: 15),
                      "the plan must be cleared")
        let canvasBefore = viewer.canvasNativeTilesForTesting.count
        gate.release()
        _ = pump(until: { false }, timeout: 1.0)

        XCTAssertEqual(viewer.canvasNativeTilesForTesting.count, canvasBefore,
                       "a dropped plan's request published tiles")
        XCTAssertTrue(viewer.publishedResidentKeysForTesting.isEmpty,
                      "and left textures resident for a plan nobody wants")
        XCTAssertGreaterThanOrEqual(viewer.staleDirectRequestSkips + viewer.staleDirectPublicationDiscards, 1)
    }

    /// The direct path still publishes for the current plan (the gates must not block everything).
    func testADirectPublicationForTheCurrentPlanStillApplies() throws {
        let (viewer, controller) = try makeViewer()
        defer { controller.close() }
        XCTAssertTrue(pump(until: { viewer.viewerState.currentImage != nil }))
        viewer.perform(.zoomActualPixels)
        XCTAssertTrue(pump(until: { viewer.detailPlanForTesting != nil }))
        XCTAssertTrue(pump(until: { !viewer.canvasNativeTilesForTesting.isEmpty }, timeout: 20),
                      "the direct publication must put tiles on the canvas")
        XCTAssertEqual(viewer.staleDirectRequestSkips, 0)
        XCTAssertEqual(viewer.staleDirectPublicationDiscards, 0)
    }
}
