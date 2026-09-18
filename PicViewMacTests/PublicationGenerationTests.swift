import XCTest
import AppKit
@testable import PicViewMac

/// The publication state machine above the renderer.
///
/// The renderer refuses to insert a texture whose tile left the plan, but a *publication* that was
/// reading the scheduler when the plan changed applies its result unconditionally: it puts the
/// previous plan's tiles back on the canvas and hands the renderer the previous resident set, which
/// is exactly the state the renderer-side guard exists to prevent. These tests hold a publication
/// open with a hook instead of relying on timing.
@MainActor
final class PublicationGenerationTests: XCTestCase {

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

    private func makeViewer() throws -> (ViewerViewController, ViewerWindowController) {
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
        return (viewer, controller)
    }

    /// A. The plan changes while a publication is between its scheduler reads and its apply.
    func testPublicationForThePreviousPlanIsDiscarded() throws {
        let (viewer, controller) = try makeViewer()
        defer { controller.close() }
        XCTAssertTrue(pump(until: { viewer.viewerState.currentImage != nil }))
        viewer.perform(.zoomActualPixels)
        XCTAssertTrue(pump(until: { viewer.detailPlanForTesting != nil }))

        // Hold the next publication open just before it applies.
        let gate = PauseGate()
        viewer.publicationPauseHook = gate.hook
        viewer.nativeTileArrived()
        XCTAssertTrue(pump(until: { gate.hasEntered }, timeout: 10),
                      "the publication must reach the pause point")

        // The user pans: a new plan is published while the old publication is suspended.
        let planBefore = viewer.detailPlanForTesting?.plan.decodeRect
        viewer.panForTesting(byViewports: 1.0)
        XCTAssertTrue(pump(until: { viewer.detailPlanForTesting?.plan.decodeRect != planBefore },
                           timeout: 30), "the pan must produce a new plan")
        XCTAssertTrue(pump(until: { viewer.publicationDiagnostics().publicationRuns >= 2 }, timeout: 30),
                      "the new plan must publish")
        let tilesAfterPan = Set(viewer.canvasNativeTilesForTesting.map { $0.key })
        let residentAfterPan = viewer.publishedResidentKeysForTesting
        XCTAssertFalse(tilesAfterPan.isEmpty, "the new plan published tiles")

        // Now let the stale publication apply.
        gate.release()
        _ = pump(until: { false }, timeout: 0.8)

        XCTAssertEqual(Set(viewer.canvasNativeTilesForTesting.map { $0.key }), tilesAfterPan,
                       "a publication for the previous plan must not overwrite the canvas")
        XCTAssertEqual(viewer.publishedResidentKeysForTesting, residentAfterPan,
                       "nor hand the renderer the previous resident set")
        XCTAssertGreaterThanOrEqual(viewer.publicationDiagnostics().stalePublicationDiscarded, 1,
                                    "and the drop is counted")
    }

    /// A publication for the current plan still applies (the guard must not block everything).
    func testAPublicationForTheCurrentPlanStillApplies() throws {
        let (viewer, controller) = try makeViewer()
        defer { controller.close() }
        XCTAssertTrue(pump(until: { viewer.viewerState.currentImage != nil }))
        viewer.perform(.zoomActualPixels)
        XCTAssertTrue(pump(until: { viewer.detailPlanForTesting != nil }))
        XCTAssertTrue(pump(until: { !viewer.canvasNativeTilesForTesting.isEmpty }, timeout: 20),
                      "tiles must reach the canvas")
        XCTAssertEqual(viewer.publicationDiagnostics().stalePublicationDiscarded, 0,
                       "nothing was stale, so nothing may be dropped")
    }

    /// E. A stale discard must not wedge the scheduler: the next arrival publishes normally. The
    /// failure this guards against is `publicationScheduled` staying true, after which the new plan
    /// would never publish again.
    func testAStaleDiscardDoesNotBlockTheNextGeneration() throws {
        let (viewer, controller) = try makeViewer()
        defer { controller.close() }
        XCTAssertTrue(pump(until: { viewer.viewerState.currentImage != nil }))
        viewer.perform(.zoomActualPixels)
        XCTAssertTrue(pump(until: { viewer.detailPlanForTesting != nil }))

        let gate = PauseGate()
        viewer.publicationPauseHook = gate.hook
        viewer.nativeTileArrived()
        XCTAssertTrue(pump(until: { gate.hasEntered }, timeout: 10))
        let planBefore = viewer.detailPlanForTesting?.plan.decodeRect
        viewer.panForTesting(byViewports: 1.0)
        XCTAssertTrue(pump(until: { viewer.detailPlanForTesting?.plan.decodeRect != planBefore }, timeout: 30))
        gate.release()
        XCTAssertTrue(pump(until: { viewer.publicationDiagnostics().stalePublicationDiscarded >= 1 },
                           timeout: 30), "the stale publication is discarded")

        // The new plan must still publish after the discard.
        let runsBefore = viewer.publicationDiagnostics().publicationRuns
        viewer.nativeTileArrived()
        XCTAssertTrue(pump(until: {
            viewer.publicationDiagnostics().publicationRuns > runsBefore
                && !viewer.canvasNativeTilesForTesting.isEmpty
        }, timeout: 30), "a stale discard may not stop later publications")
    }

    /// E. Coalescing is unchanged for arrivals inside one generation: many arrivals, few runs.
    func testCoalescingStillHoldsInsideOneGeneration() throws {
        let (viewer, controller) = try makeViewer()
        defer { controller.close() }
        XCTAssertTrue(pump(until: { viewer.viewerState.currentImage != nil }))
        viewer.perform(.zoomActualPixels)
        XCTAssertTrue(pump(until: { viewer.detailPlanForTesting != nil }))
        viewer.resetPublicationDiagnostics()
        for _ in 0..<100 { viewer.nativeTileArrived() }
        XCTAssertTrue(pump(until: { viewer.publicationDiagnostics().publicationRuns > 0 }, timeout: 5))
        _ = pump(until: { false }, timeout: 0.2)
        let diagnostics = viewer.publicationDiagnostics()
        XCTAssertGreaterThanOrEqual(diagnostics.tileArrivals, 100)
        XCTAssertLessThanOrEqual(diagnostics.publicationRuns, 12,
                                 "same-generation arrivals still coalesce (runs "
                                 + "\(diagnostics.publicationRuns))")
        XCTAssertEqual(diagnostics.stalePublicationDiscarded, 0,
                       "no plan change happened, so nothing may be dropped")
    }
}

/// Suspends the first caller until the test releases it. A deterministic stand-in for "the plan
/// changed while the publication was between its scheduler reads and its apply".
final class PauseGate: @unchecked Sendable {
    private let state = DispatchQueue(label: "pause-gate")
    private var continuation: CheckedContinuation<Void, Never>?
    private var used = false
    private var entered = false

    var hook: () async -> Void {
        { [self] in
            let isFirst = state.sync { () -> Bool in
                let first = !used
                used = true
                return first
            }
            guard isFirst else { return }
            await withCheckedContinuation { continuation in
                state.sync {
                    self.continuation = continuation
                    self.entered = true
                }
            }
        }
    }

    /// Non-blocking: the caller must keep the run loop turning, because the publication that reaches
    /// this gate is itself scheduled on the main queue. Blocking the thread here would stop the very
    /// work the test is waiting for.
    var hasEntered: Bool { state.sync { entered } }

    func release() {
        let pending = state.sync { () -> CheckedContinuation<Void, Never>? in
            let value = continuation
            continuation = nil
            return value
        }
        pending?.resume()
    }

    /// Suspends every caller, so a second concurrent request would be visible as a second suspended
    /// call rather than slipping through while the test holds the first.
    private var allContinuations: [CheckedContinuation<Void, Never>] = []
    private var suspended = 0

    var hookAll: () async -> Void {
        { [self] in
            await withCheckedContinuation { continuation in
                state.sync {
                    allContinuations.append(continuation)
                    suspended += 1
                }
            }
        }
    }

    var suspendedCount: Int { state.sync { suspended } }

    func releaseAll() {
        let pending = state.sync { () -> [CheckedContinuation<Void, Never>] in
            let values = allContinuations
            allContinuations = []
            return values
        }
        for continuation in pending { continuation.resume() }
    }
}
