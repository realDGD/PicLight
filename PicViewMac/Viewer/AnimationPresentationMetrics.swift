import Foundation

/// Bounded diagnostics from actual drawable presentation, including redraws while paused.
/// No per-frame history is retained in the application.
final class AnimationPresentationMetrics: @unchecked Sendable {
    /// Presentation callbacks may outlive GPU execution and drawable recycling.
    /// Diagnostics need identity/timing only. The GPU completion handler owns the
    /// texture lease, so drawable lifetime does not delay recycling a frame slot.
    struct Frame: Sendable {
        let sourceID: UUID
        let sequence: Int, index: Int, frameCount: Int
        let duration: Double
        init(_ frame: AnimationFrameLease) {
            sourceID = frame.sourceID
            sequence = frame.sequence
            index = frame.index
            frameCount = frame.frameCount
            duration = frame.duration
        }
    }
    struct Snapshot: Codable, Sendable {
        var presented = 0, invalidTimestamps = 0, transitions = 0, skipped = 0
        var skippedAfterWarmup = 0
        var maxExtraHold = 0.0, maxExtraHoldAfterWarmup = 0.0
        var minimumLoop = 0.0, maximumLoop = 0.0, measuredLoops = 0
        var selected = 0, selectionSkipped = 0, submitted = 0, submissionSkipped = 0
        var polls = 0, pollSkipped = 0, unavailablePolls = 0, maximumPollGap = 0.0
    }
    private let lock = NSLock()
    private var sourceID: UUID?
    private var state = Snapshot()
    private var firstTime = 0.0, lastTime = 0.0, lastSequence = -1, lastDuration = 0.0
    private var loopTime = 0.0, loopSequence = -1
    private var selectedSequence = -1, submittedSequence = -1
    private var pollSequence = -1, pollTime = 0.0

    func begin(sourceID: UUID) {
        lock.lock()
        defer { lock.unlock() }
        if self.sourceID != sourceID {
            self.sourceID = sourceID
            state = Snapshot()
            firstTime = 0
            lastTime = 0
            lastSequence = -1
            loopTime = 0
            loopSequence = -1
            selectedSequence = -1
            submittedSequence = -1
            pollSequence = -1
            pollTime = 0
        }
    }
    func poll(sequence: Int, at time: Double, available: Bool) {
        lock.lock()
        defer { lock.unlock() }
        state.polls += 1
        if pollTime > 0 { state.maximumPollGap = max(state.maximumPollGap, time - pollTime) }
        if pollSequence >= 0 { state.pollSkipped += max(0, sequence - pollSequence - 1) }
        if !available { state.unavailablePolls += 1 }
        pollSequence = sequence
        pollTime = time
    }
    func select(_ frame: AnimationFrameLease) {
        lock.lock()
        defer { lock.unlock() }
        guard sourceID == frame.sourceID, frame.sequence > selectedSequence else { return }
        if selectedSequence >= 0 { state.selectionSkipped += max(0, frame.sequence - selectedSequence - 1) }
        state.selected += 1
        selectedSequence = frame.sequence
    }
    func submit(_ frame: AnimationFrameLease) {
        lock.lock()
        defer { lock.unlock() }
        guard sourceID == frame.sourceID, frame.sequence > submittedSequence else { return }
        if submittedSequence >= 0 { state.submissionSkipped += max(0, frame.sequence - submittedSequence - 1) }
        state.submitted += 1
        submittedSequence = frame.sequence
    }
    func discardInterval() {
        lock.lock()
        defer { lock.unlock() }
        lastTime = 0
        loopSequence = -1
        pollTime = 0
    }
    func record(_ frame: Frame, at time: Double) {
        lock.lock()
        defer { lock.unlock() }
        guard sourceID == frame.sourceID else { return }
        guard time > 0, time.isFinite else {
            state.invalidTimestamps += 1
            return
        }
        state.presented += 1
        guard frame.sequence != lastSequence, frame.sequence > lastSequence, time >= lastTime else { return }
        if lastSequence >= 0, lastTime > 0 {
            let skipped = max(0, frame.sequence - lastSequence - 1)
            let extra = max(0, time - lastTime - lastDuration)
            state.skipped += skipped
            state.maxExtraHold = max(state.maxExtraHold, extra)
            if lastTime - firstTime >= 1 {
                state.skippedAfterWarmup += skipped
                state.maxExtraHoldAfterWarmup = max(state.maxExtraHoldAfterWarmup, extra)
            }
            state.transitions += 1
        } else {
            firstTime = time
        }
        if frame.index == 0 {
            if loopSequence >= 0, frame.sequence - loopSequence == frame.frameCount {
                let duration = time - loopTime
                state.minimumLoop = state.measuredLoops == 0 ? duration : min(state.minimumLoop, duration)
                state.maximumLoop = max(state.maximumLoop, duration)
                state.measuredLoops += 1
            }
            loopTime = time
            loopSequence = frame.sequence
        }
        lastSequence = frame.sequence
        lastTime = time
        lastDuration = frame.duration
    }
    var snapshot: Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return state
    }
}
