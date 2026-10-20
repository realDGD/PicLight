import XCTest

@testable import PicViewMac

final class AnimationTimelineTests: XCTestCase {
    func testVariableFrameDurationsAndLoopBoundary() throws {
        let t = try AnimationTimeline(durations: [0.02, 0.04, 0.08], loops: 0)
        for (time, seq) in [
            (0.0, 0), (0.019, 0), (0.02, 1), (0.059, 1), (0.06, 2), (0.139, 2), (0.14, 3), (0.375, 8),
        ] {
            XCTAssertEqual(t.position(at: time).sequence, seq, "time \(time)")
        }
    }
    func testMissingFramesCannotStopClockOrAccumulateDrift() throws {
        var c = AnimationMediaClock()
        c.start(at: 10)
        let t = try AnimationTimeline(durations: [0.02, 0.04, 0.08], loops: 0)
        // No ready frames or timer ticks during the 375 ms gap.
        XCTAssertEqual(c.elapsed(at: 10.375), 0.375, accuracy: 1e-8)
        XCTAssertEqual(t.position(at: c.elapsed(at: 10.375)).sequence, 8)
        XCTAssertEqual(t.position(at: c.elapsed(at: 24)).sequence, 300)
    }
    func testOnlyExplicitPauseStopsClock() {
        var c = AnimationMediaClock()
        c.start(at: 10)
        c.pause(at: 10.3)
        XCTAssertEqual(c.elapsed(at: 11), 0.3, accuracy: 1e-8)
        c.resume(at: 11)
        XCTAssertEqual(c.elapsed(at: 11.2), 0.5, accuracy: 1e-8)
    }
    func testFiniteLoopsStopAtSourceDeadline() throws {
        let t = try AnimationTimeline(durations: [0.02, 0.04, 0.08], loops: 2)
        XCTAssertFalse(t.position(at: 0.279).finished)
        XCTAssertTrue(t.position(at: 0.28).finished)
        XCTAssertEqual(t.position(at: 100).sequence, 5)
    }
    func testLateReadyFramesAreDiscardedAndFutureFrameNeverShownEarly() {
        let a = AnimationReadyPlan(target: 8, ready: [3, 4, 8, 9])
        XCTAssertEqual(a.expired, [3, 4])
        XCTAssertEqual(a.selected, 8)
        let b = AnimationReadyPlan(target: 8, ready: [3, 4, 9])
        XCTAssertEqual(b.expired, [3, 4])
        XCTAssertNil(b.selected)
    }
    func testInvalidDurationsAreRejected() {
        XCTAssertThrowsError(try AnimationTimeline(durations: [], loops: 0))
        XCTAssertThrowsError(try AnimationTimeline(durations: [0], loops: 0))
        XCTAssertThrowsError(try AnimationTimeline(durations: [.nan], loops: 0))
    }
}
