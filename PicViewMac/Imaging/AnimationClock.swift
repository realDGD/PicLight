import Foundation

/// Deterministic animation clock: tests inject the current time, the viewer
/// injects real time. Respects per-frame durations and the source loop count.
public final class AnimationClock: @unchecked Sendable {
    public struct Schedule: Sendable {
        public let durations: [TimeInterval]
        public let totalPlays: Int?

        /// - Parameter totalPlays: `nil` follows the source loop count
        ///   (`0` in a file means infinite, which maps to `nil` here as well).
        public init(durations: [TimeInterval], totalPlays: Int?) {
            self.durations = durations
            self.totalPlays = totalPlays
        }

        public func duration(at index: Int) -> TimeInterval {
            guard !durations.isEmpty else { return 0.1 }
            let value = durations[index % durations.count]
            // Engines treat a zero delay as "use a default", matching browsers.
            return value > 0.001 ? value : 0.1
        }
    }

    public private(set) var frameIndex: Int = 0
    public private(set) var completedPlays: Int = 0
    public private(set) var isFinished: Bool = false

    private var elapsedInFrame: TimeInterval = 0
    private var schedule: Schedule?
    private var lastTick: TimeInterval?

    public init() {}

    public func start(schedule: Schedule, at time: TimeInterval) {
        self.schedule = schedule
        frameIndex = 0
        completedPlays = 0
        isFinished = false
        elapsedInFrame = 0
        lastTick = time
    }

    public func stop() {
        schedule = nil
        lastTick = nil
        frameIndex = 0
        elapsedInFrame = 0
        isFinished = false
    }

    /// Advances the clock and returns the frame index to display, or `nil` when
    /// nothing changed and no redraw is needed.
    public func tick(at time: TimeInterval) -> Int? {
        guard let schedule, !isFinished else { return nil }
        guard let lastTick else { self.lastTick = time; return nil }
        var delta = time - lastTick
        self.lastTick = time
        guard delta > 0 else { return nil }

        var changed = false
        while delta > 0 {
            let remaining = schedule.duration(at: frameIndex) - elapsedInFrame
            if delta < remaining {
                elapsedInFrame += delta
                delta = 0
                break
            }
            delta -= remaining
            elapsedInFrame = 0
            let next = frameIndex + 1
            if next >= schedule.durations.count {
                completedPlays += 1
                if let total = schedule.totalPlays, completedPlays >= total {
                    isFinished = true
                    changed = true
                    break
                }
                frameIndex = 0
            } else {
                frameIndex = next
            }
            changed = true
        }
        return changed ? frameIndex : nil
    }
}
