import AppKit
import XCTest
@testable import PicViewMac

/// main's older viewer must own the new producer without importing unrelated UI work.
@MainActor
final class AnimationMainIntegrationTests: XCTestCase {
    func testViewerPipelineCanDisableTheLegacyUnboundedFrameStream() async throws {
        let url = Fixtures.url("animation/poster-default.apng")
        let events = EventCollector()
        let coordinator = DecodeCoordinator()
        let task = await coordinator.show(item: url, streamAnimationFrames: false) { events.record($0) }
        await task.value
        XCTAssertEqual(events.publishedNames, [url.lastPathComponent])
        XCTAssertTrue(events.failures.isEmpty)
        await coordinator.cancelAll()
    }

    func testReplacingTheAnimationAtTheSamePathCannotReuseItsOldDescriptor() async throws {
        let directory = try Fixtures.makeScratchDirectory("animation-cache-version")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("replace.png")
        try FileManager.default.copyItem(at: Fixtures.url("animation/poster-default.apng"), to: url)
        let coordinator = DecodeCoordinator()
        let heads = AnimationHeadRecorder()
        let first = await coordinator.show(item: url, streamAnimationFrames: false) { heads.record($0) }
        await first.value
        try FileManager.default.removeItem(at: url)
        try FileManager.default.copyItem(at: Fixtures.url("static.png"), to: url)
        let second = await coordinator.show(item: url, streamAnimationFrames: false) { heads.record($0) }
        await second.value
        XCTAssertEqual(heads.frameCounts, [3, 1], "a replaced file must not retain the animated descriptor")
        await coordinator.cancelAll()
    }

    func testClosingAnUnpresentedWindowStopsAnimationAndInvalidatesPublications() async throws {
        TestAppKit.ensureApplication()
        let controller = ViewerWindowController()
        defer { controller.close() }
        let viewer = controller.viewerViewController
        _ = viewer.view
        viewer.open(url: Fixtures.url("animation/poster-default.apng"))
        let deadline = Date().addingTimeInterval(4)
        while viewer.animationDiagnostics == nil, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNotNil(viewer.animationDiagnostics)
        XCTAssertFalse(controller.window?.isVisible ?? true, "this test must never present a window")
        controller.close()
        XCTAssertNil(viewer.animationDiagnostics)
        XCTAssertNil(viewer.canvasViewForTesting.animationFrame)
        XCTAssertFalse(viewer.chromeSnapshot.isAnimationTimerActive)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(viewer.animationDiagnostics, "a delayed result must not restart a closed viewer")
    }
}

private final class AnimationHeadRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Int] = []
    func record(_ event: DecodeEvent) {
        guard case let .head(head) = event else { return }
        lock.lock(); defer { lock.unlock() }
        values.append(head.descriptor.frameCount)
    }
    var frameCounts: [Int] {
        lock.lock(); defer { lock.unlock() }
        return values
    }
}
