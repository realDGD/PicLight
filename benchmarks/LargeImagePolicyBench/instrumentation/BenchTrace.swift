import AppKit
import Foundation
import Darwin

// TEMPORARY benchmark instrumentation for the 1.9 GB image investigation.
// Exists only in the throwaway copy under /tmp; enabled with
// PICLIGHT_TTI_BENCH=<image path>.

func benchNow() -> Double { Double(clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)) / 1e9 }

@MainActor
enum BenchTrace {
    nonisolated static let enabled = ProcessInfo.processInfo.environment["PICLIGHT_TTI_BENCH"] != nil
    nonisolated static let start = benchNow()
    /// Highest footprint seen by the heartbeat (250 ms sampling). What was previously
    /// reported as "peakFootprint" was the footprint at finish, which understates
    /// short-lived transients.
    nonisolated(unsafe) static var peakFootprintSeen: Int64 = 0
    /// Frames the viewer actually published versus frames decoded and frames drawn:
    /// the gap between them is decode work that never reached the screen.
    nonisolated(unsafe) private static var appliedFrames = 0
    nonisolated(unsafe) private static let appliedLock = NSLock()
    nonisolated static func noteAppliedFrame() {
        appliedLock.lock(); appliedFrames += 1; appliedLock.unlock()
        FileHandle.standardError.write("APPLIEDFRAME\n".data(using: .utf8)!)
    }
    nonisolated static var appliedFrameCount: Int {
        appliedLock.lock(); defer { appliedLock.unlock() }; return appliedFrames
    }
    nonisolated(unsafe) static var energyStart: UInt64 = 0
    nonisolated(unsafe) static var energyEnd: UInt64 = 0
    static var lines: [String] = []
    static var drawCount = 0
    static var firstDrawEnd: Double?
    static var extraRedraws = 0
    static var timer: Timer?

    static func mark(_ label: String) {
        guard enabled else { return }
        let t = benchNow() - start
        let m = currentMemory()
        let line = String(format: "T+%8.3f  %-58@ fp=%7.1fMiB res=%7.1fMiB peakRSS=%8.1fMiB",
                          t, label as NSString,
                          Double(m.footprint) / 1048576, Double(m.resident) / 1048576,
                          Double(m.peakRSS) / 1048576)
        lines.append(line)
        FileHandle.standardError.write((line + "\n").data(using: .utf8)!)
    }

    /// Logs from any thread (used by decoders and background work).
    // E4: full-stream traversal counter. A "traversal" is any operation that must
    // read the whole compressed stream: ImageIO thumbnail creation, a preview
    // resample of an already-decoded image, or a canvas rasterization of an
    // oversized lazy image.
    private nonisolated static let traversalLock = NSLock()
    nonisolated(unsafe) static var traversals = 0
    nonisolated(unsafe) static var traversalKinds: [String: Int] = [:]
    nonisolated static func noteTraversal(_ kind: String) {
        traversalLock.lock()
        traversals += 1
        traversalKinds[kind, default: 0] += 1
        traversalLock.unlock()
        markFromAnyThread("TRAVERSAL #\(traversals) kind=\(kind)")
    }
    nonisolated static func traversalSummary() -> String {
        traversalLock.lock(); defer { traversalLock.unlock() }
        return "\(traversals) traversals: " + traversalKinds.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
    }

    nonisolated static func markFromAnyThread(_ label: String) {
        let t = benchNow() - start
        let main = Thread.isMainThread ? "MAIN" : "bg"
        let line = String(format: "T+%8.3f  [%@] %@", t, main, label)
        FileHandle.standardError.write((line + "\n").data(using: .utf8)!)
        Task { @MainActor in lines.append(line) }
    }

    // MARK: - canvas draws

    static func noteDraw(duration: Double, dirty: NSRect, bounds: NSRect, hasImage: Bool) {
        guard enabled else { return }
        drawCount += 1
        let end = benchNow() - start
        let label = String(format: "canvas draw #%d COMPLETE took=%.3fs image=%@ bounds=%.0fx%.0f dirty=%.0fx%.0f",
                           drawCount, duration, hasImage ? "yes" : "nil",
                           bounds.width, bounds.height, dirty.width, dirty.height)
        mark(label)
        if hasImage, firstDrawEnd == nil {
            firstDrawEnd = end
            scheduleExtraRedraws()
        }
    }

    private static func scheduleExtraRedraws() {
        guard extraRedraws < 2 else { return }
        extraRedraws += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            mark("forcing extra redraw #\(extraRedraws)")
            for window in NSApp.windows where window.isVisible {
                window.contentView?.needsDisplay = true
                window.displayIfNeeded()
            }
        }
    }

    // MARK: - heartbeat: memory + main-thread responsiveness, off-main

    static func startHeartbeat() {
        guard enabled else { return }
        let thread = Thread {
            while true {
                Thread.sleep(forTimeInterval: 0.25)
                let m = currentMemory()
                if m.footprint > peakFootprintSeen { peakFootprintSeen = m.footprint }
                let pingStart = benchNow()
                DispatchQueue.main.async {
                    let latency = benchNow() - pingStart
                    let line = String(format: "T+%8.3f  [pulse] mainThreadLatency=%6.0fms fp=%.0fMiB res=%.0fMiB peakRSS=%.0fMiB",
                                      benchNow() - start, latency * 1000,
                                      Double(m.footprint) / 1048576, Double(m.resident) / 1048576,
                                      Double(m.peakRSS) / 1048576)
                    FileHandle.standardError.write((line + "\n").data(using: .utf8)!)
                    Task { @MainActor in lines.append(line) }
                }
            }
        }
        thread.qualityOfService = .userInteractive
        thread.stackSize = 1 << 20
        thread.start()
    }

    nonisolated static func readEnergyNJ() -> UInt64 {
        let capacity = 8192
        let raw = UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: 16)
        defer { raw.deallocate() }
        memset(raw, 0, capacity)
        var count = mach_msg_type_number_t(capacity / MemoryLayout<integer_t>.size)
        guard task_info(mach_task_self_, task_flavor_t(TASK_POWER_INFO_V2),
                        raw.assumingMemoryBound(to: integer_t.self), &count) == KERN_SUCCESS else { return 0 }
        return raw.load(as: task_power_info_v2_data_t.self).task_energy
    }

    static func beginSummaryLoop() {
        guard enabled else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in
            Task { @MainActor in
                let t = benchNow() - start
                // PICLIGHT_BENCH_SECONDS>0 measures a fixed window (needed for animation
                // playback, where the draw count grows quickly); 0 keeps the still-image
                // behaviour of finishing after the first image plus two forced redraws.
                let window = Double(ProcessInfo.processInfo.environment["PICLIGHT_BENCH_SECONDS"] ?? "0") ?? 0
                if window > 0 {
                    if t >= window { finish() }
                } else if drawCount >= 3 || t > 200 {
                    finish()
                }
            }
        }
    }

    private static func finish() {
        timer?.invalidate(); timer = nil
        energyEnd = readEnergyNJ()
        let m = currentMemory()
        var out = "\n=== PicLight baseline (1.9 GB PNG) ===\n"
        out += lines.joined(separator: "\n") + "\n"
        out += String(format: "\npeakRSS_getrusage = %.3f GiB\n", Double(m.peakRSS) / 1073741824)
        out += String(format: "footprint_at_finish   = %.3f GiB\n", Double(m.peakFootprint) / 1073741824)
        out += String(format: "peakFootprint_sampled = %.3f GiB (250 ms sampling)\n", Double(peakFootprintSeen) / 1073741824)
        out += String(format: "total_wall        = %.3f s\n", benchNow() - start)
        out += "canvas_draws      = \(drawCount)\n"
        out += "frames_applied    = \(appliedFrameCount)\n"
        out += "full_stream_traversals = \(traversalSummary())\n"
        out += String(format: "open_energy_mJ    = %.0f\n", Double(energyEnd &- energyStart) / 1e6)
        print(out)
        try? out.write(toFile: "/tmp/piclight-bench/results/app-trace.log", atomically: true, encoding: .utf8)
        NSApp.terminate(nil)
    }

    struct Memory {
        var footprint: Int64 = 0, resident: Int64 = 0, peakRSS: Int64 = 0, peakFootprint: Int64 = 0
    }

    nonisolated static func currentMemory() -> Memory {
        var m = Memory()
        let capacity = 8192
        let raw = UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: 16)
        defer { raw.deallocate() }
        memset(raw, 0, capacity)
        var count = mach_msg_type_number_t(capacity / MemoryLayout<integer_t>.size)
        if task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO),
                     raw.assumingMemoryBound(to: integer_t.self), &count) == KERN_SUCCESS {
            let vm = raw.load(as: task_vm_info_data_t.self)
            m.footprint = Int64(vm.phys_footprint)
            m.resident = Int64(vm.resident_size)
        }
        var ru = rusage()
        getrusage(RUSAGE_SELF, &ru)
        m.peakRSS = Int64(ru.ru_maxrss)
        m.peakFootprint = m.footprint
        return m
    }
}
