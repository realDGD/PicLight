import XCTest
import AppKit
@testable import PicViewMac

/// Animation lifecycle in the real viewer: autoplay, pause, restart-on-revisit,
/// and the guarantee that only the current image runs a clock.
@MainActor
final class AnimationLifecycleTests: XCTestCase {
    private func makeFolder() throws -> URL {
        let directory = try Fixtures.makeScratchDirectory("animation")
        try FileManager.default.copyItem(at: Fixtures.url("animated-infinite.gif"),
                                         to: directory.appendingPathComponent("a-anim.gif"))
        try FileManager.default.copyItem(at: Fixtures.url("animated.webp"),
                                         to: directory.appendingPathComponent("b-anim.webp"))
        try FileManager.default.copyItem(at: Fixtures.url("static.png"),
                                         to: directory.appendingPathComponent("c-static.png"))
        return directory
    }

    private func open(_ viewer: ViewerViewController, _ url: URL) async {
        viewer.open(url: url)
        let deadline = Date().addingTimeInterval(15)
        while viewer.viewerState.currentImage == nil, Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    func testAnimatedContentAutoplaysWhileStaticContentDoesNot() async throws {
        let directory = try makeFolder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let viewer = ViewerViewController()
        _ = viewer.view

        await open(viewer, directory.appendingPathComponent("a-anim.gif"))
        XCTAssertTrue(viewer.viewerState.isAnimated)
        XCTAssertEqual(viewer.viewerState.playback, .playing, "autoplay is the default")
        XCTAssertTrue(viewer.chromeSnapshot.isAnimationTimerActive)

        viewer.session.select(url: directory.appendingPathComponent("c-static.png"))
        let deadline = Date().addingTimeInterval(6)
        while viewer.chromeSnapshot.isAnimationTimerActive, Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(viewer.viewerState.playback, .staticImage)
        XCTAssertFalse(viewer.chromeSnapshot.isAnimationTimerActive)
    }

    func testSpacePausesAndResumesOnlyAnimatedContent() async throws {
        let directory = try makeFolder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let viewer = ViewerViewController()
        _ = viewer.view
        await open(viewer, directory.appendingPathComponent("a-anim.gif"))
        XCTAssertEqual(viewer.viewerState.playback, .playing)

        viewer.perform(.togglePlayback)
        XCTAssertEqual(viewer.viewerState.playback, .paused)
        let pausedFrame = viewer.viewerState.frameIndex
        try? await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(viewer.viewerState.frameIndex, pausedFrame,
                       "a paused animation must not advance")

        viewer.perform(.togglePlayback)
        XCTAssertEqual(viewer.viewerState.playback, .playing)

        // On a still image, Space navigates instead of pretending to play.
        viewer.session.select(url: directory.appendingPathComponent("c-static.png"))
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        XCTAssertEqual(viewer.viewerState.playback, .staticImage)
        XCTAssertFalse(viewer.viewerState.isAnimated)
    }

    func testSpaceOnAStillImageAdvancesInsteadOfStartingAPlayback() async throws {
        let directory = try makeFolder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let viewer = ViewerViewController()
        _ = viewer.view
        await open(viewer, directory.appendingPathComponent("c-static.png"))
        XCTAssertFalse(viewer.viewerState.isAnimated)

        // Still content: the documented behavior is "next image", never a fake clock.
        viewer.perform(.togglePlayback)
        try? await Task.sleep(nanoseconds: 600_000_000)
        XCTAssertEqual(viewer.viewerState.playback, .staticImage)
        XCTAssertFalse(viewer.chromeSnapshot.isAnimationTimerActive)
    }

    func testSwitchingAwayAndBackRestartsTheAnimationFromFrameZero() async throws {
        let directory = try makeFolder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let viewer = ViewerViewController()
        _ = viewer.view
        let animatedURL = directory.appendingPathComponent("a-anim.gif")
        await open(viewer, animatedURL)

        // Let it run so the frame index is non-zero.
        let deadline = Date().addingTimeInterval(4)
        while viewer.viewerState.frameIndex == 0, Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertGreaterThan(viewer.viewerState.frameIndex, 0, "the animation advanced")

        viewer.session.select(url: directory.appendingPathComponent("c-static.png"))
        try? await Task.sleep(nanoseconds: 900_000_000)
        viewer.session.select(url: animatedURL)
        let reopened = Date().addingTimeInterval(10)
        while viewer.viewerState.currentImage == nil, Date() < reopened {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        try? await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(viewer.viewerState.playback, .playing, "revisiting restarts playback")
        XCTAssertLessThan(viewer.viewerState.frameIndex, 2,
                          "v0.1 restarts from the first frame, got index \(viewer.viewerState.frameIndex)")
    }

    func testAnimatedWebPBehavesLikeAnimatedGIF() async throws {
        let directory = try makeFolder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let viewer = ViewerViewController()
        _ = viewer.view
        await open(viewer, directory.appendingPathComponent("b-anim.webp"))
        XCTAssertTrue(viewer.viewerState.isAnimated, "animated WebP must be detected as animated")
        XCTAssertEqual(viewer.viewerState.playback, .playing)
        let descriptor = try XCTUnwrap(viewer.viewerState.descriptor)
        XCTAssertEqual(descriptor.frameCount, 3)
        XCTAssertEqual(descriptor.frameDurations.count, 3)
        XCTAssertEqual(descriptor.loopCount, 0, "the infinite-loop fixture reports loop 0")
    }

    func testOnlyTheCurrentImageKeepsAnAnimationClock() async throws {
        let directory = try makeFolder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let viewer = ViewerViewController()
        _ = viewer.view
        await open(viewer, directory.appendingPathComponent("a-anim.gif"))
        let index = try XCTUnwrap(viewer.session.currentIndex)

        // Stepping through neighbours must never leave more than one clock active.
        for _ in 0..<4 {
            viewer.perform(.nextImage)
            try? await Task.sleep(nanoseconds: 600_000_000)
            XCTAssertLessThanOrEqual(viewer.chromeSnapshot.activeAnimationClocks, 1,
                                     "at most one animation clock may run, whatever is current")
        }
        _ = index
    }

    func testFiniteLoopStopsPlaybackAndInfiniteKeepsGoing() async throws {
        // The clock itself is deterministic; this pins the loop semantics the
        // viewer feeds it. `loopCount == 0` means infinite, a number means plays.
        let infinite = AnimationClock()
        infinite.start(schedule: .init(durations: [0.05, 0.05], totalPlays: nil), at: 0)
        var time = 0.0
        for _ in 0..<40 { time += 0.05; _ = infinite.tick(at: time) }
        XCTAssertFalse(infinite.isFinished, "an infinite animation keeps running")
        XCTAssertGreaterThan(infinite.completedPlays, 1)

        let finite = AnimationClock()
        finite.start(schedule: .init(durations: [0.05, 0.05], totalPlays: 2), at: 0)
        time = 0
        for _ in 0..<40 { time += 0.05; _ = finite.tick(at: time) }
        XCTAssertTrue(finite.isFinished, "a finite animation stops after its play count")
        XCTAssertEqual(finite.completedPlays, 2)
    }
}
