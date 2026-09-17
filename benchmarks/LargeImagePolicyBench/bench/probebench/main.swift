// C-series: dimension/oversized detection policy benchmark.
//   probebench <folder> [--policy c1|c2|c3] [--visible N] [--byte-threshold MB]
// Measures the cost of deciding "is this file oversized (>8192 long edge)".
// Ground truth is computed once by probing everything, so correctness is checked too.
import Foundation
import ImageIO
import CoreGraphics

func now() -> Double { Double(clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)) / 1e9 }

func usageSnapshot() -> (user: Double, sys: Double, footprint: Int64) {
    var ru = rusage(); getrusage(RUSAGE_SELF, &ru)
    func secs(_ tv: timeval) -> Double { Double(tv.tv_sec) + Double(tv.tv_usec) / 1e6 }
    var footprint: Int64 = 0
    let capacity = 8192
    let raw = UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: 16)
    defer { raw.deallocate() }
    memset(raw, 0, capacity)
    var count = mach_msg_type_number_t(capacity / MemoryLayout<integer_t>.size)
    if task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO),
                 raw.assumingMemoryBound(to: integer_t.self), &count) == KERN_SUCCESS {
        footprint = Int64(raw.load(as: task_vm_info_data_t.self).phys_footprint)
    }
    return (secs(ru.ru_utime), secs(ru.ru_stime), footprint)
}

/// Header-only probe: no pixel decode.
func probe(_ url: URL) -> (CGSize?, Bool) {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
        return (nil, false)
    }
    let w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue ?? 0
    let h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue ?? 0
    guard w > 0, h > 0 else { return (nil, false) }
    return (CGSize(width: w, height: h), true)
}

let args = Array(CommandLine.arguments.dropFirst())
guard let folder = args.first else { print("usage: probebench <folder> [--policy c1|c2|c3] [--visible N] [--byte-threshold MB]"); exit(2) }
func arg(_ n: String, default d: String) -> String {
    guard let i = args.firstIndex(of: n), i + 1 < args.count else { return d }
    return args[i + 1]
}
let policy = arg("--policy", default: "c1")
let visible = Int(arg("--visible", default: "20")) ?? 20
let byteThreshold = Int64(arg("--byte-threshold", default: "64")) ?? 64

let fm = FileManager.default
let names = (try? fm.contentsOfDirectory(atPath: folder))?.filter { !$0.hasPrefix(".") }.sorted() ?? []
let files: [(url: URL, bytes: Int64)] = names.map { name in
    let url = URL(fileURLWithPath: folder).appendingPathComponent(name)
    let bytes = (try? fm.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
    return (url, bytes)
}
print("### probebench policy=\(policy) folder=\(folder) files=\(files.count) visible=\(visible) byteThreshold=\(byteThreshold)MB")

// ---- ground truth (always probes everything; used only to score correctness) ----
var truth: [String: Bool] = [:]
var probeCosts: [Double] = []
let tTruth = now()
for f in files {
    let t = now()
    let (size, ok) = probe(f.url)
    probeCosts.append(now() - t)
    truth[f.url.lastPathComponent] = ok ? (max(size!.width, size!.height) > 8192) : false
}
let truthSeconds = now() - tTruth
probeCosts.sort()

// ---- policy under test ----
let s0 = usageSnapshot()
let t0 = now()
var probes = 0
var classified: [String: Bool] = [:]
switch policy {
case "c1":   // eager folder-wide fill
    for f in files {
        let (size, ok) = probe(f.url); probes += 1
        classified[f.url.lastPathComponent] = ok ? (max(size!.width, size!.height) > 8192) : false
    }
case "c2":   // on-demand: current + the visible drawer window only
    for f in files.prefix(visible) {
        let (size, ok) = probe(f.url); probes += 1
        classified[f.url.lastPathComponent] = ok ? (max(size!.width, size!.height) > 8192) : false
    }
case "c3":   // one-way byte filter: huge bytes => oversized without probing, else probe
    for f in files {
        if f.bytes > byteThreshold * 1024 * 1024 {
            classified[f.url.lastPathComponent] = true      // decided without a probe
        } else {
            let (size, ok) = probe(f.url); probes += 1
            classified[f.url.lastPathComponent] = ok ? (max(size!.width, size!.height) > 8192) : false
        }
    }
default: break
}
let policySeconds = now() - t0
let s1 = usageSnapshot()

var wrong = 0
var wrongNames: [String] = []
for (name, truthValue) in truth {
    if let got = classified[name] {
        if got != truthValue { wrong += 1; wrongNames.append("\(name)(truth=\(truthValue) got=\(got))") }
    } else if policy == "c2" {
        // on-demand deliberately leaves the rest unclassified; that is not an error
    } else {
        wrong += 1; wrongNames.append("\(name)(unclassified)")
    }
}

print(String(format: "folder_enumeration_and_ground_truth = %.3f s (probed all %d files)", truthSeconds, files.count))
print(String(format: "policy_cost = %.3f s  probes = %d  (%.2f ms/probe median, %.2f ms p95)",
             policySeconds, probes,
             (probeCosts.isEmpty ? 0 : probeCosts[probeCosts.count / 2] * 1000),
             (probeCosts.isEmpty ? 0 : probeCosts[min(probeCosts.count - 1, Int(Double(probeCosts.count) * 0.95))] * 1000)))
print(String(format: "cpu = user %.3f s sys %.3f s", s1.user - s0.user, s1.sys - s0.sys))
print("footprint = \(String(format: "%.1f", Double(s1.footprint) / 1048576)) MiB")
print("classified = \(classified.count) / \(files.count)   misclassified = \(wrong)\(wrong > 0 ? " -> \(wrongNames.prefix(6).joined(separator: ", "))" : "")")
print("oversized_in_truth = \(truth.values.filter { $0 }.count)")
