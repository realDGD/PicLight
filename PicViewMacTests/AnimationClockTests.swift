import XCTest
@testable import PicViewMac

final class AnimationClockTests: XCTestCase {
    func testFrameAdvancesRespectVariableDurations() {
        let clock = AnimationClock()
        clock.start(schedule: .init(durations: [0.1, 0.2, 0.3], totalPlays: nil), at: 0)
        XCTAssertEqual(clock.frameIndex, 0)

        XCTAssertNil(clock.tick(at: 0.05), "still inside the first frame")
        XCTAssertEqual(clock.tick(at: 0.12), 1)
        XCTAssertNil(clock.tick(at: 0.2), "0.08 s into a 0.2 s frame")
        XCTAssertEqual(clock.tick(at: 0.35), 2)
        XCTAssertNil(clock.tick(at: 0.5), "0.15 s into a 0.3 s frame")
        XCTAssertEqual(clock.tick(at: 0.7), 0, "wraps to the first frame")
    }

    func testInfiniteLoopNeverFinishes() {
        let clock = AnimationClock()
        clock.start(schedule: .init(durations: [0.1, 0.1], totalPlays: nil), at: 0)
        for step in 1...50 {
            _ = clock.tick(at: Double(step) * 0.1)
        }
        XCTAssertFalse(clock.isFinished)
        XCTAssertGreaterThan(clock.completedPlays, 1)
    }

    func testFiniteLoopStopsAfterTheRequestedPlayCount() {
        let clock = AnimationClock()
        clock.start(schedule: .init(durations: [0.1, 0.1], totalPlays: 2), at: 0)
        var time = 0.0
        for _ in 0..<10 {
            time += 0.1
            _ = clock.tick(at: time)
        }
        XCTAssertTrue(clock.isFinished)
        XCTAssertEqual(clock.completedPlays, 2)
        XCTAssertNil(clock.tick(at: time + 1), "a finished clock stops producing changes")
    }

    func testSinglePlayStopsAtTheEndOfTheFirstLoop() {
        let clock = AnimationClock()
        clock.start(schedule: .init(durations: [0.1, 0.1, 0.1], totalPlays: 1), at: 0)
        var time = 0.0
        for _ in 0..<6 {
            time += 0.1
            _ = clock.tick(at: time)
        }
        XCTAssertTrue(clock.isFinished)
        XCTAssertEqual(clock.completedPlays, 1)
    }

    func testZeroDurationsFallBackToADefaultDelay() {
        let clock = AnimationClock()
        clock.start(schedule: .init(durations: [0, 0], totalPlays: nil), at: 0)
        XCTAssertNil(clock.tick(at: 0.01), "a zero delay must not spin frames every tick")
        XCTAssertEqual(clock.tick(at: 0.2), 1)
    }

    func testStopResetsToTheFirstFrameSoRevisitingRestarts() {
        let clock = AnimationClock()
        clock.start(schedule: .init(durations: [0.1], totalPlays: nil), at: 0)
        _ = clock.tick(at: 0.15)
        clock.stop()
        XCTAssertEqual(clock.frameIndex, 0)
        XCTAssertFalse(clock.isFinished)
    }

    func testSingleFrameAnimationIsHandled() {
        let clock = AnimationClock()
        clock.start(schedule: .init(durations: [0.1], totalPlays: nil), at: 0)
        XCTAssertNil(clock.tick(at: 0.05))
        XCTAssertEqual(clock.tick(at: 0.15), 0)
    }
}
