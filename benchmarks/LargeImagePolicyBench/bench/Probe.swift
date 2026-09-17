import Foundation
import Darwin

// MARK: - Monotonic clock

/// Absolute monotonic nanoseconds since boot (counts across sleep). Absolute
/// rather than process-relative so there is no lazily-initialized global epoch.
func now() -> Double { Double(clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)) / 1e9 }

func fmtG(_ bytes: Int64) -> String { String(format: "%.3f GiB", Double(bytes) / 1073741824.0) }
func fmtM(_ bytes: Int64) -> String { String(format: "%.1f MiB", Double(bytes) / 1048576.0) }
func ms(_ seconds: Double) -> String { String(format: "%.3f s", seconds) }
func msInt(_ seconds: Double) -> String { String(format: "%.0f ms", seconds * 1000) }

// MARK: - Mach / syscall layer
//
// Every struct here is filled through a large heap buffer. On this OS build the
// kernel writes more bytes than the SDK's structs declare (a stack copy trips
// __stack_chk_fail), and rusage_info_v6's early fields read as zero — so the
// figures used below are the ones verified to be correct on this machine:
//   memory  : task_info(TASK_VM_INFO)
//   peak    : getrusage ru_maxrss
//   cpu     : getrusage user/sys
//   energy  : task_info(TASK_POWER_INFO_V2).task_energy (nanojoules, arm64)
//   wakeups : TASK_POWER_INFO_V2.cpu_energy.task_*_wakeups

enum Mach {
    static func taskInfo<T>(_ flavor: task_flavor_t, as type: T.Type) -> T? {
        let capacity = 8192
        let raw = UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: 16)
        defer { raw.deallocate() }
        memset(raw, 0, capacity)
        var count = mach_msg_type_number_t(capacity / MemoryLayout<integer_t>.size)
        let kr = task_info(mach_task_self_, flavor, raw.assumingMemoryBound(to: integer_t.self), &count)
        guard kr == KERN_SUCCESS else { return nil }
        return raw.load(as: T.self)
    }
}

struct Snapshot {
    var footprint: Int64 = 0      // phys_footprint
    var resident: Int64 = 0
    var virtualSize: Int64 = 0
    var compressed: Int64 = 0
    var peakRSS: Int64 = 0        // getrusage ru_maxrss (bytes)
    var user: Double = 0
    var sys: Double = 0
    var energyNJ: UInt64 = 0
    var wakeups: UInt64 = 0
    var idleWakeups: UInt64 = 0
    var cpuSeconds: Double { user + sys }
    var energyMilliJoules: Double { Double(energyNJ) / 1e6 }

    static func - (a: Snapshot, b: Snapshot) -> Snapshot {
        Snapshot(footprint: a.footprint, resident: a.resident, virtualSize: a.virtualSize,
                 compressed: a.compressed, peakRSS: a.peakRSS,
                 user: a.user - b.user, sys: a.sys - b.sys,
                 energyNJ: a.energyNJ &- b.energyNJ,
                 wakeups: a.wakeups &- b.wakeups, idleWakeups: a.idleWakeups &- b.idleWakeups)
    }
}

enum Proc {
    static func snapshot() -> Snapshot {
        var s = Snapshot()
        if let vm: task_vm_info_data_t = Mach.taskInfo(task_flavor_t(TASK_VM_INFO), as: task_vm_info_data_t.self) {
            s.footprint = Int64(vm.phys_footprint)
            s.resident = Int64(vm.resident_size)
            s.virtualSize = Int64(vm.virtual_size)
            s.compressed = Int64(vm.compressed)
        }
        if let pw: task_power_info_v2_data_t = Mach.taskInfo(task_flavor_t(TASK_POWER_INFO_V2), as: task_power_info_v2_data_t.self) {
            s.energyNJ = pw.task_energy
            s.wakeups = UInt64(pw.cpu_energy.task_interrupt_wakeups)
            s.idleWakeups = UInt64(pw.cpu_energy.task_platform_idle_wakeups)
        }
        var ru = rusage()
        getrusage(RUSAGE_SELF, &ru)
        func secs(_ tv: timeval) -> Double { Double(tv.tv_sec) + Double(tv.tv_usec) / 1e6 }
        s.user = secs(ru.ru_utime); s.sys = secs(ru.ru_stime)
        s.peakRSS = Int64(ru.ru_maxrss)
        return s
    }

    static func systemMemory() -> String {
        var swapUsed: Int64 = 0, swapTotal: Int64 = 0
        var swap = xsw_usage()
        var sz = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &swap, &sz, nil, 0) == 0 {
            swapUsed = Int64(swap.xsu_used); swapTotal = Int64(swap.xsu_total)
        }
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        var pageSize: vm_size_t = 0
        host_page_size(mach_host_self(), &pageSize)
        let kr = withUnsafeMutablePointer(to: &stats) { ptr -> kern_return_t in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        let phys = Int64(ProcessInfo.processInfo.physicalMemory)
        guard kr == KERN_SUCCESS else { return "phys=\(fmtG(phys)) swapUsed=\(fmtM(swapUsed))" }
        func g(_ pages: UInt32) -> Int64 { Int64(pages) * Int64(pageSize) }
        return "phys=\(fmtG(phys)) free=\(fmtM(g(stats.free_count))) active=\(fmtM(g(stats.active_count))) inactive=\(fmtM(g(stats.inactive_count))) wired=\(fmtM(g(stats.wire_count))) compressed=\(fmtM(g(stats.compressor_page_count))) swapUsed=\(fmtM(swapUsed))/\(fmtM(swapTotal))"
    }
}

// MARK: - Sampler

/// Samples footprint/resident at ~500 Hz on a dispatch timer, and keeps the
/// getrusage peak so a spike between samples is still caught.
final class MemSampler: @unchecked Sendable {
    struct Sample { let t: Double; let footprint: Int64; let resident: Int64 }

    private let lock = NSLock()
    private var samples: [Sample] = []
    private var timer: DispatchSourceTimer?

    init() { _ = Proc.snapshot() }

    func start(interval: Double = 0.002) {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .userInteractive))
        timer.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let s = Proc.snapshot()
            let sample = Sample(t: now(), footprint: s.footprint, resident: s.resident)
            self.lock.lock()
            self.samples.append(sample)
            self.lock.unlock()
        }
        self.timer = timer
        timer.resume()
    }

    func stop() { timer?.cancel(); timer = nil }

    func all() -> [Sample] { lock.lock(); defer { lock.unlock() }; return samples }

    func peakFootprint(after t: Double = 0) -> Int64 {
        all().filter { $0.t >= t }.map(\.footprint).max() ?? 0
    }

    func peakFootprintResident(after t: Double = 0) -> Int64 {
        all().filter { $0.t >= t }.map(\.resident).max() ?? 0
    }

    /// Peak RSS from getrusage over the whole process lifetime.
    func peakRSS() -> Int64 { Proc.snapshot().peakRSS }

    func dumpCSV(_ path: String) {
        var text = "t,footprint_bytes,resident_bytes\n"
        for s in all() {
            text += String(format: "%.4f,%lld,%lld\n", s.t, s.footprint, s.resident)
        }
        try? text.write(toFile: path, atomically: true, encoding: .utf8)
    }

    /// Largest single-sample step up in footprint — the biggest allocation burst.
    func largestStep(after t: Double = 0) -> (delta: Int64, at: Double) {
        let xs = all().filter { $0.t >= t }
        var best: (Int64, Double) = (0, 0)
        for i in 1..<max(xs.count, 1) where xs[i].footprint - xs[i - 1].footprint > best.0 {
            best = (xs[i].footprint - xs[i - 1].footprint, xs[i].t)
        }
        return (best.0, best.1)
    }
}

// MARK: - Result reporting

struct Measurement {
    var name: String
    var fields: [(String, String)] = []

    mutating func add(_ key: String, _ value: String) { fields.append((key, value)) }

    func emit() {
        print("### \(name)")
        for (k, v) in fields { print("\(k) = \(v)") }
        print("")
    }
}

/// Standard trailing block: wall/CPU/energy/peak memory for the window [t0, now].
func addResourceBlock(_ m: inout Measurement, t0: Double, snapshot0: Snapshot,
                      sampler: MemSampler, wall1: Double? = nil) {
    let wall = (wall1 ?? now()) - t0
    let s1 = Proc.snapshot()
    let d = s1 - snapshot0
    m.add("wall", ms(wall))
    m.add("cpu", "user=\(ms(d.user)) sys=\(ms(d.sys)) total=\(ms(d.cpuSeconds)) cpu/wall=\(String(format: "%.2f", d.cpuSeconds / max(wall, 1e-9)))x")
    m.add("energy", "\(String(format: "%.1f", d.energyMilliJoules)) mJ  (task_energy, nJ counter)")
    m.add("wakeups", "interrupt=\(d.wakeups) idle=\(d.idleWakeups)")
    m.add("peakFootprint_sampler", fmtG(sampler.peakFootprint(after: t0)))
    let step = sampler.largestStep(after: t0)
    m.add("largest_footprint_step", "\(fmtM(step.delta)) at t+\(msInt(step.at - t0))")
    m.add("peakRSS_getrusage", fmtG(sampler.peakRSS()))
    m.add("system_memory_at_end", Proc.systemMemory())
}
