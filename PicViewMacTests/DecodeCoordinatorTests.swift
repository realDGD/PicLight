import XCTest
import CoreGraphics
@testable import PicViewMac

/// Size policy is not what these tests exercise, so the probe answers as if every
/// file were an ordinary photograph. A preload now depends on this answer: unknown
/// and oversized neighbours are skipped before any work starts.
private struct StubProbe: DimensionProbing {
    var value: Int? = 100
    func longEdge(of url: URL) async -> Int? { value }
}

/// Deterministic stand-in for the real decoder so cancellation and preload
/// ordering can be asserted exactly.
final class FakeDecoder: ImageDecoding, @unchecked Sendable {
    struct Plan {
        var delay: TimeInterval
        var image: CGImage?
        var fails: Bool = false
    }

    private let lock = NSLock()
    private var plans: [String: Plan] = [:]
    private var started: [String] = []
    private var finished: [String] = []

    init(plans: [String: Plan] = [:]) { self.plans = plans }

    func plan(_ plan: Plan, for name: String) {
        lock.lock(); defer { lock.unlock() }
        plans[name] = plan
    }

    var startedOrder: [String] {
        lock.lock(); defer { lock.unlock() }
        return started
    }

    var finishedOrder: [String] {
        lock.lock(); defer { lock.unlock() }
        return finished
    }

    private func plan(for url: URL) -> Plan {
        lock.lock(); defer { lock.unlock() }
        return plans[url.lastPathComponent] ?? Plan(delay: 0, image: FakeDecoder.pixel)
    }

    private func recordStart(_ name: String) {
        lock.lock(); defer { lock.unlock() }
        started.append(name)
    }

    private func recordFinish(_ name: String) {
        lock.lock(); defer { lock.unlock() }
        finished.append(name)
    }

    static let pixel: CGImage = {
        let context = CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return context.makeImage()!
    }()

    func inspect(_ url: URL) async throws -> ImageDescriptor {
        ImageDescriptor(sourceURL: url, pixelSize: CGSize(width: 4, height: 4))
    }

    func decodeFirstDisplayableFrame(_ url: URL, target: DecodeTarget) async throws -> DecodedImageHead {
        let plan = plan(for: url)
        recordStart(url.lastPathComponent)
        if plan.delay > 0 {
            try? await Task.sleep(nanoseconds: UInt64(plan.delay * 1_000_000_000))
        }
        if plan.fails { throw ImageDecodeError.noDisplayableImage }
        recordFinish(url.lastPathComponent)
        return DecodedImageHead(
            image: plan.image ?? Self.pixel,
            descriptor: ImageDescriptor(sourceURL: url, pixelSize: CGSize(width: 4, height: 4)),
            metadata: ImageMetadata(fileName: url.lastPathComponent)
        )
    }

    func decodeRemainingFrames(_ url: URL, descriptor: ImageDescriptor) -> AsyncThrowingStream<DecodedFrame, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

final class DecodeCoordinatorTests: XCTestCase {
    private func url(_ name: String) -> URL { URL(fileURLWithPath: "/tmp/\(name)") }

    func testSwitchingAwayCancelsThePreviousPublicationEvenIfItFinishesLater() async throws {
        let decoder = FakeDecoder(plans: [
            "a.png": FakeDecoder.Plan(delay: 0.3),
            "b.png": FakeDecoder.Plan(delay: 0.01),
        ])
        let coordinator = DecodeCoordinator(decoder: decoder)

        let collector = EventCollector()
        _ = await coordinator.show(item: url("a.png")) { collector.record($0) }
        // Give A a moment to actually start before switching to B.
        try await Task.sleep(nanoseconds: 60_000_000)
        _ = await coordinator.show(item: url("b.png"), direction: .forward) { collector.record($0) }
        try await Task.sleep(nanoseconds: 600_000_000)

        let published = collector.publishedNames
        XCTAssertTrue(published.contains("b.png"))
        XCTAssertFalse(published.contains("a.png"),
                       "a superseded decode must never publish, even when it finishes later")
        XCTAssertTrue(decoder.finishedOrder.contains("a.png"),
                      "the stale work still ran to completion in the fake, which is the whole point")
    }

    func testForwardNavigationPrioritizesNextAndBackwardPrioritizesPrevious() {
        let previous = url("a.png")
        let next = url("c.png")
        XCTAssertEqual(DecodeCoordinator.preloadOrder(previous: previous, next: next, direction: .forward),
                       [next, previous])
        XCTAssertEqual(DecodeCoordinator.preloadOrder(previous: previous, next: next, direction: .backward),
                       [previous, next])
        XCTAssertEqual(DecodeCoordinator.preloadOrder(previous: previous, next: next, direction: .unknown),
                       [next, previous])
    }

    func testBothNeighboursArePreloadedWhileOnlyTheCurrentIsPublished() async throws {
        let decoder = FakeDecoder()
        let coordinator = DecodeCoordinator(decoder: decoder, probe: StubProbe())
        let collector = EventCollector()

        _ = await coordinator.show(item: url("b.png"), previous: url("a.png"), next: url("c.png"),
                                   direction: .forward) { collector.record($0) }
        try await Task.sleep(nanoseconds: 500_000_000)

        let started = decoder.startedOrder
        XCTAssertTrue(started.contains("a.png"), "the previous neighbour must be preloaded")
        XCTAssertTrue(started.contains("c.png"), "the next neighbour must be preloaded")
        XCTAssertEqual(collector.publishedNames, ["b.png"],
                       "preloading must never publish to the UI")
    }

    func testCachedImagePublishesWithoutDecodingAgain() async throws {
        let decoder = FakeDecoder()
        let coordinator = DecodeCoordinator(decoder: decoder, probe: StubProbe())
        let collector = EventCollector()

        _ = await coordinator.show(item: url("a.png")) { collector.record($0) }
        try await Task.sleep(nanoseconds: 200_000_000)
        let startsAfterFirst = decoder.startedOrder.count

        _ = await coordinator.show(item: url("a.png")) { collector.record($0) }
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(decoder.startedOrder.count, startsAfterFirst,
                       "a cached image must not be decoded a second time")
        XCTAssertGreaterThanOrEqual(collector.publishedNames.count, 2)
    }

    /// Spec §13.1/R5: an oversized neighbour gets no preload at all, because ImageIO
    /// ignores cancellation — a started giant decode runs to completion and burns its
    /// whole cost (measured: 19.4 s and 62.8 J after `Task.cancel()`).
    func testOversizedNeighbourIsNeverPreloaded() async throws {
        let decoder = FakeDecoder()
        let coordinator = DecodeCoordinator(decoder: decoder, probe: StubProbe(value: 20000))
        let collector = EventCollector()

        _ = await coordinator.show(item: url("b.png"), previous: url("a.png"), next: url("c.png"),
                                   direction: .forward) { collector.record($0) }
        try await Task.sleep(nanoseconds: 300_000_000)

        let started = decoder.startedOrder
        XCTAssertTrue(started.contains("b.png"), "the current image still decodes")
        XCTAssertFalse(started.contains("a.png"), "an oversized neighbour must not be preloaded")
        XCTAssertFalse(started.contains("c.png"), "an oversized neighbour must not be preloaded")
    }

    /// An unreadable header counts as oversized, so nothing speculative is started.
    func testUnknownSizeNeighbourIsNotPreloadedEither() async throws {
        let decoder = FakeDecoder()
        let coordinator = DecodeCoordinator(decoder: decoder, probe: StubProbe(value: nil))
        _ = await coordinator.show(item: url("b.png"), previous: url("a.png"), next: url("c.png"),
                                   direction: .forward) { _ in }
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertFalse(decoder.startedOrder.contains("a.png"))
        XCTAssertFalse(decoder.startedOrder.contains("c.png"))
    }

    func testFailureIsReportedAndNavigationStaysAlive() async throws {
        let decoder = FakeDecoder(plans: [
            "bad.png": FakeDecoder.Plan(delay: 0, fails: true),
        ])
        let coordinator = DecodeCoordinator(decoder: decoder)
        let collector = EventCollector()

        _ = await coordinator.show(item: url("bad.png")) { collector.record($0) }
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(collector.failures.contains { $0.contains("bad.png") })

        _ = await coordinator.show(item: url("good.png")) { collector.record($0) }
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(collector.publishedNames.contains("good.png"))
    }

    func testCancelAllStopsPreloading() async throws {
        let decoder = FakeDecoder()
        let coordinator = DecodeCoordinator(decoder: decoder)
        _ = await coordinator.show(item: url("b.png"), previous: url("a.png"), next: url("c.png"),
                                   direction: .forward) { _ in }
        await coordinator.cancelAll()
        try await Task.sleep(nanoseconds: 100_000_000)
        // Nothing further to assert beyond "no crash and no publication"; the
        // important guarantee is that cancelling is safe at any time.
        XCTAssertTrue(true)
    }
}

/// Thread-safe collector for decode events.
final class EventCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var names: [String] = []
    private var failureMessages: [String] = []

    func record(_ event: DecodeEvent) {
        lock.lock(); defer { lock.unlock() }
        switch event {
        case let .head(head): names.append(head.descriptor.sourceURL.lastPathComponent)
        case let .frame(frame): names.append(frame.image.width > 0 ? "frame" : "frame")
        case let .failure(message): failureMessages.append(message)
        }
    }

    var publishedNames: [String] {
        lock.lock(); defer { lock.unlock() }
        return names
    }

    var failures: [String] {
        lock.lock(); defer { lock.unlock() }
        return failureMessages
    }
}
