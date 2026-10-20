import Foundation

struct AnimationMediaClock {
    private(set) var epoch: Double?
    private var pausedAt: Double?, pausedTotal = 0.0
    init() {}
    mutating func start(at t: Double) { if epoch == nil { epoch = t } }
    mutating func pause(at t: Double) { if epoch != nil && pausedAt == nil { pausedAt = t } }
    mutating func resume(at t: Double) {
        if let p = pausedAt {
            pausedTotal += max(0, t - p)
            pausedAt = nil
        }
    }
    func elapsed(at t: Double) -> Double {
        guard let epoch else { return 0 }
        return max(0, (pausedAt ?? t) - epoch - pausedTotal)
    }
}
struct AnimationPosition {
    let sequence: Int, index: Int, loop: Int
    let start: Double, end: Double
    let finished: Bool
}
struct AnimationTimeline {
    let durations: [Double], prefix: [Double], duration: Double, loops: Int
    init(durations: [Double], loops: Int) throws {
        guard !durations.isEmpty, durations.allSatisfy({ $0.isFinite && $0 > 0 }), loops >= 0 else {
            throw NSError(domain: "timeline", code: 1)
        }
        self.durations = durations
        self.loops = loops
        var p = [0.0]
        for d in durations { p.append(p.last! + d) }
        prefix = p
        duration = p.last!
    }
    func position(at elapsed: Double) -> AnimationPosition {
        let t = max(0, elapsed)
        let epsilon = 1e-9
        let n = durations.count
        if loops > 0 && t + epsilon >= Double(loops) * duration {
            return AnimationPosition(
                sequence: loops * n - 1, index: n - 1, loop: loops - 1,
                start: Double(loops - 1) * duration + prefix[n - 1], end: Double(loops) * duration,
                finished: true)
        }
        let loop = Int(floor((t + epsilon) / duration))
        let within = max(0, t - Double(loop) * duration)
        var low = 0
        var high = n
        while low + 1 < high {
            let mid = (low + high) / 2
            if prefix[mid] <= within + epsilon { low = mid } else { high = mid }
        }
        return AnimationPosition(
            sequence: loop * n + low, index: low, loop: loop, start: Double(loop) * duration + prefix[low],
            end: Double(loop) * duration + prefix[low + 1], finished: false)
    }
    func start(of sequence: Int) -> Double {
        Double(sequence / durations.count) * duration + prefix[sequence % durations.count]
    }
}
struct AnimationReadyPlan {
    let expired: [Int], selected: Int?
    init(target: Int, ready: [Int]) {
        expired = ready.filter { $0 < target }
        selected = ready.contains(target) ? target : nil
    }
}
