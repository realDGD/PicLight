import XCTest
import AppKit
@testable import PicViewMac

/// A queued plan belongs to a page as much as to a viewport. The queued pass used to
/// restart on page 0, so a small pan on page 2 quietly decoded page 0 — the viewport was
/// covered, the pixels were the wrong ones.
@MainActor
final class PendingPageIndexTests: XCTestCase {

    override func setUp() async throws {
        try await super.setUp()
        TestAppKit.ensureApplication()
    }

    /// Records the page every pass is asked to decode, then blocks. Blocking is the point:
    /// the running pass must not finish on its own, because the whole scenario is "a second
    /// request arrives while the first pass is still running".
    private final class RecordingProvider: NativeTileProviding, @unchecked Sendable {
        private let lock = NSLock()
        private var pages: [Int] = []
        private let gate = DispatchSemaphore(value: 0)

        var recordedPages: [Int] {
            lock.lock(); defer { lock.unlock() }
            return pages
        }

        /// Lets every blocked call return.
        func release() {
            for _ in 0..<8 { gate.signal() }
        }

        func produce(plan: NativeTilePlan, source: URL, pageIndex: Int, gutter: Int,
                     colorSpace: CGColorSpace?, orientation: SourceOrientation,
                     shouldCancel: @Sendable () -> Bool,
                     onTile: @Sendable (NativeTile) -> Void) throws {
            lock.lock()
            pages.append(pageIndex)
            lock.unlock()
            // Bounded, so a failing assertion cannot strand a cooperative thread.
            _ = gate.wait(timeout: .now() + 4)
        }
    }

    private func plan(x: CGFloat, pixelSize: CGSize = CGSize(width: 8448, height: 320))
        throws -> NativeTilePlan {
        try XCTUnwrap(NativeTilePlanner.plan(sourceRect: CGRect(x: x, y: 0, width: 2048, height: 512),
                                             sourcePixelSize: pixelSize, tileSize: 512, ring: 0))
    }

    /// Waits for a detached pass to reach the provider. Not a sleep: the condition is the
    /// evidence that the pass started.
    private func waitForPasses(_ provider: RecordingProvider, count: Int,
                               timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while provider.recordedPages.count < count, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        return provider.recordedPages.count >= count
    }

    // MARK: - The queued pass keeps the queued page

    func testAQueuedPlanRestartsOnItsOwnPageNotTheFirstOne() async throws {
        let provider = RecordingProvider()
        defer { provider.release() }
        let scheduler = NativeDetailScheduler(provider: provider,
                                              cache: NativeTileCache(totalCostLimit: 8 * 1024 * 1024),
                                              tileSize: 512)
        let source = URL(fileURLWithPath: "/tmp/multi-page.png")
        let planA = try plan(x: 0)
        let planB = try plan(x: 1024)          // overlaps A, reaches past it: a small pan

        await scheduler.request(plan: planA, source: source, pageIndex: 3, epoch: 1)
        XCTAssertTrue(waitForPasses(provider, count: 1), "the first pass must be running")

        await scheduler.request(plan: planB, source: source, pageIndex: 3, epoch: 2)
        let queued = await scheduler.pendingPlanForTesting
        let queuedPage = await scheduler.runningPageIndexForTesting
        XCTAssertEqual(queued, planB, "a small pan on page 3 queues behind the running pass")
        XCTAssertEqual(queuedPage, 3)
        XCTAssertEqual(provider.recordedPages, [3], "and does not start a second pass yet")

        // The producer stops without emitting anything, so the pass ends and the queued
        // plan takes over.
        let token = await scheduler.passTokenForTesting
        await scheduler.noteProducerFinishedForTesting(token: token, produced: 0)
        let running = await scheduler.runningPlanForTesting
        let runningPage = await scheduler.runningPageIndexForTesting
        XCTAssertEqual(running, planB, "the queued plan is what runs next")
        XCTAssertEqual(runningPage, 3, "and it runs on its own page")
        XCTAssertTrue(waitForPasses(provider, count: 2), "the queued pass reaches the provider")
        XCTAssertEqual(provider.recordedPages, [3, 3],
                       "page 0 was never decoded, on either pass")
    }

    /// The same scenario with page 0, so the test cannot pass by accident: page 0 is both
    /// the correct answer here and the old hardcoded value.
    func testAPageZeroQueueStillReportsPageZero() async throws {
        let provider = RecordingProvider()
        defer { provider.release() }
        let scheduler = NativeDetailScheduler(provider: provider,
                                              cache: NativeTileCache(totalCostLimit: 8 * 1024 * 1024),
                                              tileSize: 512)
        let source = URL(fileURLWithPath: "/tmp/single-page.png")

        await scheduler.request(plan: try plan(x: 0), source: source, pageIndex: 0, epoch: 1)
        XCTAssertTrue(waitForPasses(provider, count: 1))
        await scheduler.request(plan: try plan(x: 1024), source: source, pageIndex: 0, epoch: 2)
        let token = await scheduler.passTokenForTesting
        await scheduler.noteProducerFinishedForTesting(token: token, produced: 0)
        XCTAssertTrue(waitForPasses(provider, count: 2))
        XCTAssertEqual(provider.recordedPages, [0, 0])
    }

    /// A request for a *different* page is not a small pan: it replaces the running pass
    /// outright, and the queued plan it discards must not come back.
    func testARequestForAnotherPageCancelsTheQueuedPlan() async throws {
        let provider = RecordingProvider()
        defer { provider.release() }
        let scheduler = NativeDetailScheduler(provider: provider,
                                              cache: NativeTileCache(totalCostLimit: 8 * 1024 * 1024),
                                              tileSize: 512)
        let source = URL(fileURLWithPath: "/tmp/multi-page.png")

        await scheduler.request(plan: try plan(x: 0), source: source, pageIndex: 3, epoch: 1)
        XCTAssertTrue(waitForPasses(provider, count: 1))
        await scheduler.request(plan: try plan(x: 1024), source: source, pageIndex: 3, epoch: 2)
        let queuedBefore = await scheduler.pendingPlanForTesting
        XCTAssertNotNil(queuedBefore, "queued behind page 3")

        // The viewer asks for another page while the first is still running.
        await scheduler.request(plan: try plan(x: 0), source: source, pageIndex: 5, epoch: 3)
        let queuedAfter = await scheduler.pendingPlanForTesting
        let runningPage = await scheduler.runningPageIndexForTesting
        XCTAssertNil(queuedAfter, "a jump to another page replaces the queue rather than keeping it")
        XCTAssertEqual(runningPage, 5)
        XCTAssertTrue(waitForPasses(provider, count: 2))
        XCTAssertEqual(provider.recordedPages, [3, 5],
                       "the queued page-3 plan must never run after the pass moved to page 5")
    }
}
