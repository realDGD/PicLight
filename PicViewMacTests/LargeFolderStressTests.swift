import XCTest
import CoreGraphics
import AppKit
@testable import PicViewMac

/// Counting decoder: records every decode request so tests can prove that a
/// folder is never eagerly decoded and that thumbnail work stays bounded.
final class CountingDecoder: ImageDecoding, @unchecked Sendable {
    /// What the fake source looks like: an animation or a multi-page document.
    enum Document {
        case animation(frameCount: Int)
        case multiPage(pageCount: Int)
        case still
    }

    /// A serial queue guards the counters: `NSLock` is not usable from async
    /// contexts, and these calls happen inside decode tasks.
    private let queue = DispatchQueue(label: "picviewmac.tests.countingdecoder")
    private var requests: [String] = []
    private var budgets: [Int?] = []
    private var headRequests = 0
    private var frameRequests = 0

    let payload: CGImage
    let delay: TimeInterval
    let document: Document
    /// What the fake source claims to be, so a test can exercise the oversized path
    /// without a real 48000-pixel file.
    let pixelSize: CGSize

    init(payload: CGImage = FakeDecoder.pixel, delay: TimeInterval = 0,
         document: Document = .animation(frameCount: 3),
         pixelSize: CGSize = CGSize(width: 64, height: 48)) {
        self.payload = payload
        self.delay = delay
        self.document = document
        self.pixelSize = pixelSize
    }

    private var descriptorShape: (frameCount: Int, pageCount: Int, animated: Bool,
                                 loopCount: Int?, durations: [TimeInterval]) {
        switch document {
        case let .animation(frameCount):
            return (frameCount, 1, true, 0, Array(repeating: 0.1, count: frameCount))
        case let .multiPage(pageCount):
            return (1, pageCount, false, nil, [])
        case .still:
            return (1, 1, false, nil, [])
        }
    }

    private func withState<T>(_ body: (inout [String], inout [Int?], inout Int, inout Int) -> T) -> T {
        queue.sync {
            body(&requests, &budgets, &headRequests, &frameRequests)
        }
    }

    var requestCount: Int { withState { requests, _, _, _ in requests.count } }
    var requestedNames: [String] { withState { requests, _, _, _ in requests } }
    /// The `maxPixelSize` budget of each head decode, in order: how a test sees the
    /// level a resize asked for.
    var requestedBudgets: [Int?] { withState { _, budgets, _, _ in budgets } }
    var headRequestCount: Int { withState { _, _, head, _ in head } }
    var frameRequestCount: Int { withState { _, _, _, frames in frames } }

    func reset() {
        withState { requests, budgets, head, frames in
            requests = []
            budgets = []
            head = 0
            frames = 0
        }
    }

    func inspect(_ url: URL) async throws -> ImageDescriptor {
        ImageDescriptor(sourceURL: url, pixelSize: pixelSize)
    }

    func decodeFirstDisplayableFrame(_ url: URL, target: DecodeTarget) async throws -> DecodedImageHead {
        withState { requests, budgets, head, _ in
            requests.append(url.lastPathComponent)
            budgets.append(target.maxPixelSize)
            head += 1
        }
        if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
        let shape = descriptorShape
        let level = DecodeBudget.level(sourceLongEdge: Int(max(pixelSize.width, pixelSize.height)),
                                       budget: target.maxPixelSize)
        return DecodedImageHead(
            image: payload,
            descriptor: ImageDescriptor(sourceURL: url, pixelSize: pixelSize,
                                        frameCount: shape.frameCount, pageCount: shape.pageCount,
                                        animated: shape.animated, loopCount: shape.loopCount,
                                        frameDurations: shape.durations),
            metadata: ImageMetadata(fileName: url.lastPathComponent),
            level: level
        )
    }

    func decodeRemainingFrames(_ url: URL, descriptor: ImageDescriptor) -> AsyncThrowingStream<DecodedFrame, Error> {
        withState { _, _, _, frames in frames += 1 }
        return AsyncThrowingStream { $0.finish() }
    }

    func decodeFrame(_ url: URL, index: Int, target: DecodeTarget) async throws -> DecodedFrame {
        DecodedFrame(image: payload, index: index, duration: nil)
    }
}

@MainActor
final class LargeFolderStressTests: XCTestCase {

    override func setUp() async throws {
        try await super.setUp()
        TestAppKit.ensureApplication()
    }
    /// Deterministic 10,000-file folder used by several checks below.
    private func makeLargeFolder(count: Int = 10_000) throws -> URL {
        let directory = try Fixtures.makeScratchDirectory("large-\(count)")
        if FileManager.default.fileExists(atPath: directory.appendingPathComponent("img-\(count - 1).png").path) {
            return directory
        }
        for index in 0..<count {
            try Data([0x89, 0x50, 0x4E, 0x47]).write(
                to: directory.appendingPathComponent("img-\(index).png"))
        }
        let nested = directory.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: nested.appendingPathComponent("deep.png"))
        return directory
    }

    func testTenThousandFileFolderScanSortAndNonRecursion() async throws {
        let directory = try makeLargeFolder()
        defer { try? FileManager.default.removeItem(at: directory) }

        let started = Date()
        let items = try await FolderScanner().scan(directory: directory)
        let scanSeconds = Date().timeIntervalSince(started)
        let sorted = ImageSort.sort(items, by: .filename)

        XCTAssertEqual(items.count, 10_000, "exactly the flat candidates, no nested files")
        XCTAssertFalse(items.contains { $0.displayName == "deep.png" },
                       "scanning must never recurse into subdirectories")
        XCTAssertEqual(sorted.first?.displayName, "img-0.png")
        XCTAssertEqual(sorted.last?.displayName, "img-9999.png")
        XCTAssertTrue(items.allSatisfy { $0.pixelSize == nil },
                      "a scan must not inspect image bodies for dimensions")

        // Recorded for the verification report; no brittle threshold.
        print("METRIC large-folder scan: \(items.count) items in \(String(format: "%.3f", scanSeconds))s")
    }

    func testDimensionSortIsTheOnlyPathThatInspectsImageSizes() async throws {
        let directory = try makeLargeFolder(count: 300)
        defer { try? FileManager.default.removeItem(at: directory) }

        let items = try await FolderScanner().scan(directory: directory)
        XCTAssertTrue(items.allSatisfy { $0.pixelSize == nil })

        // Every other sort keeps them unset.
        for key in [ImageSortKey.filename, .modificationDate, .creationDate, .fileSize] {
            let sorted = ImageSort.sort(items, by: key)
            XCTAssertTrue(sorted.allSatisfy { $0.pixelSize == nil },
                          "\(key) must not trigger dimension inspection")
        }

        // Dimension sorting asks for them explicitly. It needs real images to
        // read, so this half runs on copies of the fixtures.
        let real = try Fixtures.makeScratchDirectory("dimensions")
        defer { try? FileManager.default.removeItem(at: real) }
        for index in 0..<8 {
            try FileManager.default.copyItem(at: Fixtures.url("static.png"),
                                             to: real.appendingPathComponent("real-\(index).png"))
        }
        let realItems = try await FolderScanner().scan(directory: real)
        XCTAssertEqual(realItems.count, 8)
        XCTAssertTrue(realItems.allSatisfy { $0.pixelSize == nil })
        let withDimensions = await FolderScanner.fillDimensions(realItems)
        XCTAssertTrue(withDimensions.allSatisfy { $0.pixelSize == CGSize(width: 64, height: 48) },
                      "dimension sorting is the only path that fills sizes")
    }

    func testViewerOpensALargeFolderWithoutDecodingItEagerly() async throws {
        let directory = try makeLargeFolder(count: 2_000)
        defer { try? FileManager.default.removeItem(at: directory) }

        let decoder = CountingDecoder()
        let controller = ViewerViewController(decoder: decoder)
        _ = controller.view
        controller.open(url: directory.appendingPathComponent("img-1500.png"))

        let deadline = Date().addingTimeInterval(15)
        while controller.session.items.count < 2_000, Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        try? await Task.sleep(nanoseconds: 800_000_000)

        XCTAssertEqual(controller.session.items.count, 2_000)
        XCTAssertEqual(controller.session.currentItem?.displayName, "img-1500.png")

        let requests = decoder.requestedNames
        XCTAssertFalse(requests.isEmpty, "the current image must be decoded")
        XCTAssertLessThanOrEqual(requests.count, 4,
                                 "only current + adjacent neighbours may be decoded, got \(requests)")
        XCTAssertTrue(requests.contains("img-1500.png"))
        print("METRIC decode requests for a 2000-file folder: \(requests.count) (\(requests.joined(separator: ", ")))")
    }

    func testThumbnailRequestsStayBoundedToVisibleRows() async throws {
        let directory = try makeLargeFolder(count: 5_000)
        defer { try? FileManager.default.removeItem(at: directory) }

        let controller = ViewerViewController(decoder: CountingDecoder())
        _ = controller.view
        controller.open(url: directory.appendingPathComponent("img-0.png"))
        let deadline = Date().addingTimeInterval(15)
        while controller.session.items.count < 5_000, Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        try? await Task.sleep(nanoseconds: 600_000_000)

        XCTAssertEqual(controller.chromeSnapshot.drawerRows, 5_000)
        let requested = controller.thumbnailRequestCount
        XCTAssertLessThan(requested, 100,
                          "a 5000-item drawer must only request the rows it shows, got \(requested)")
        print("METRIC thumbnail requests for a 5000-item drawer: \(requested)")
    }

    func testRapidSelectionChangesDoNotAccumulateUnboundedWork() async throws {
        let directory = try makeLargeFolder(count: 500)
        defer { try? FileManager.default.removeItem(at: directory) }

        let decoder = CountingDecoder(delay: 0.01)
        let controller = ViewerViewController(decoder: decoder)
        _ = controller.view
        controller.open(url: directory.appendingPathComponent("img-0.png"))
        let deadline = Date().addingTimeInterval(10)
        while controller.session.items.count < 500, Date() < deadline {
            try? await Task.sleep(nanoseconds: 30_000_000)
        }

        // Jump around quickly, the way a user scrubs the drawer.
        for index in stride(from: 0, to: 400, by: 7) {
            controller.session.select(index: index)
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        try? await Task.sleep(nanoseconds: 1_200_000_000)

        let active = await controller.coordinatorDiagnostics.activeTaskCount
        XCTAssertLessThanOrEqual(active, 3,
                                 "after a scrub only current + neighbours may remain in flight, got \(active)")
        let failures = controller.viewerState.errorMessage
        XCTAssertNil(failures)
        print("METRIC in-flight decode tasks after scrubbing 58 selections: \(active)")
    }
}

/// Rapid switching must never let stale work publish or leak tasks.
final class RapidSwitchCancellationTests: XCTestCase {
    private func url(_ name: String) -> URL { URL(fileURLWithPath: "/tmp/\(name)") }

    func testRapidSwitchingThroughFiveImagesPublishesOnlyTheNewest() async throws {
        let names = ["a.png", "b.png", "c.png", "d.png", "e.png"]
        let decoder = CountingDecoder(delay: 0.05)
        let coordinator = DecodeCoordinator(decoder: decoder)
        let collector = EventCollector()

        for name in names {
            _ = await coordinator.show(item: url(name)) { collector.record($0) }
            try await Task.sleep(nanoseconds: 5_000_000) // switch before the decode finishes
        }
        try await Task.sleep(nanoseconds: 1_500_000_000)

        XCTAssertEqual(collector.publishedNames, ["e.png"],
                       "only the newest image may be published, got \(collector.publishedNames)")
        XCTAssertTrue(decoder.requestedNames.contains("a.png"),
                      "the superseded decode did start, which is the point of the test")
        let active = await coordinator.activeTaskCount
        XCTAssertLessThanOrEqual(active, 3, "obsolete work must be cancelled, not accumulated")
    }

    func testCurrentImageAlwaysOutranksPreloads() async throws {
        let decoder = CountingDecoder(delay: 0.02)
        let coordinator = DecodeCoordinator(decoder: decoder)
        let collector = EventCollector()

        _ = await coordinator.show(item: url("current.png"),
                                   previous: url("prev.png"), next: url("next.png"),
                                   direction: .forward) { collector.record($0) }
        try await Task.sleep(nanoseconds: 900_000_000)

        XCTAssertEqual(collector.publishedNames.first, "current.png",
                       "the current image must be published before any preload work")
        XCTAssertEqual(collector.publishedNames.filter { $0 == "current.png" }.count, 1,
                       "preloads must never publish to the UI")
    }

    func testFiveHundredForwardAndBackwardStepsStayBoundedAndCorrect() async throws {
        let items = (0..<500).map { FolderItem(url: URL(fileURLWithPath: "/tmp/f\($0).jpg")) }
        let session = await MainActor.run { FolderSession(items: items) }
        let decoder = CountingDecoder()
        let coordinator = DecodeCoordinator(decoder: decoder)

        await MainActor.run { session.select(index: 0) }
        for _ in 0..<500 {
            let step = await MainActor.run { () -> (url: URL, previous: URL?, next: URL?)? in
                guard let item = session.goNext(), let index = session.currentIndex else { return nil }
                let previous = index > 0 ? session.items[index - 1].url : nil
                let next = index + 1 < session.items.count ? session.items[index + 1].url : nil
                return (item.url, previous, next)
            }
            if let step {
                _ = await coordinator.show(item: step.url, previous: step.previous, next: step.next,
                                           direction: .forward) { _ in }
            }
        }
        let afterForward = await MainActor.run { session.currentIndex }
        XCTAssertEqual(afterForward, 499, "500 forward steps from index 0 must land on the last item")

        for _ in 0..<500 {
            let step = await MainActor.run { () -> (url: URL, previous: URL?, next: URL?)? in
                guard let item = session.goPrevious(), let index = session.currentIndex else { return nil }
                let previous = index > 0 ? session.items[index - 1].url : nil
                let next = index + 1 < session.items.count ? session.items[index + 1].url : nil
                return (item.url, previous, next)
            }
            if let step {
                _ = await coordinator.show(item: step.url, previous: step.previous, next: step.next,
                                           direction: .backward) { _ in }
            }
        }
        let afterBackward = await MainActor.run { session.currentIndex }
        XCTAssertEqual(afterBackward, 0, "500 backward steps must return to the first item")

        let active = await coordinator.activeTaskCount
        XCTAssertLessThanOrEqual(active, 3, "1000 switches must leave at most current + neighbours in flight")
        print("METRIC decode requests during 1000 rapid switches: \(decoder.requestCount)")
    }

    func testCancellationIsIdempotentAndSafeAtAnyPoint() async throws {
        let decoder = CountingDecoder(delay: 0.03)
        let coordinator = DecodeCoordinator(decoder: decoder)
        _ = await coordinator.show(item: url("x.png"), previous: url("w.png"), next: url("y.png"),
                                   direction: .forward) { _ in }
        await coordinator.cancelAll()
        await coordinator.cancelAll()
        await coordinator.cancelAll()
        try await Task.sleep(nanoseconds: 300_000_000)
        let active = await coordinator.activeTaskCount
        XCTAssertEqual(active, 0, "cancelAll must leave no in-flight work")
    }

    @MainActor
    func testStoppingPlaybackStopsTheAnimationTimer() async throws {
        let directory = try Fixtures.makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.copyItem(at: Fixtures.url("animated-infinite.gif"),
                                         to: directory.appendingPathComponent("a-anim.gif"))
        try FileManager.default.copyItem(at: Fixtures.url("static.png"),
                                         to: directory.appendingPathComponent("b-static.png"))

        let animatedFile = directory.appendingPathComponent("a-anim.gif")
        let staticFile = directory.appendingPathComponent("b-static.png")

        let controller = ViewerViewController()
        _ = controller.view
        controller.open(url: animatedFile)
        let deadline = Date().addingTimeInterval(15)
        while controller.viewerState.currentImage == nil, Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(controller.chromeSnapshot.isAnimationTimerActive,
                      "an animated current image runs an animation timer")

        controller.session.select(url: staticFile)
        let switchDeadline = Date().addingTimeInterval(8)
        while controller.chromeSnapshot.isAnimationTimerActive, Date() < switchDeadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertFalse(controller.chromeSnapshot.isAnimationTimerActive,
                       "switching to a still image must stop the animation timer")
        XCTAssertEqual(controller.viewerState.playback, .staticImage)
    }
}
