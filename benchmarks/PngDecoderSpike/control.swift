// Same-session ImageIO control for the PNG decoder spike (Task 11).
//
// This is the production shape: `CGImageSourceCreateThumbnailAtIndex` streaming into
// the requested pixel budget, run twice so the second pass is page-cache-warm. The
// comparison is only meaningful when both sides are measured minutes apart on the
// same machine, so this lives next to the libspng driver.
//
// Usage: control <file> <maxPixelSize> [passes]

import Foundation
import CoreGraphics
import ImageIO

func monotonicNS() -> UInt64 { clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) }

func footprintGiB() -> Double {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_073_741_824 : 0
}

/// Peak sampled footprint, so the number is comparable with the C driver's maxrss.
final class Peak {
    private let lock = NSLock()
    private var value = 0.0
    private var timer: DispatchSourceTimer?
    func start() {
        value = footprintGiB()
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now(), repeating: .milliseconds(50))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let current = footprintGiB()
            self.lock.lock(); self.value = max(self.value, current); self.lock.unlock()
        }
        timer.resume()
        self.timer = timer
    }
    func stop() -> Double {
        timer?.cancel(); timer = nil
        lock.lock(); defer { lock.unlock() }
        return value
    }
}

let arguments = CommandLine.arguments
guard arguments.count >= 3, let budget = Int(arguments[2]) else {
    FileHandle.standardError.write(Data("usage: control <file> <maxPixelSize> [passes]\n".utf8))
    exit(2)
}
let url = URL(fileURLWithPath: arguments[1])
let passes = arguments.count > 3 ? (Int(arguments[3]) ?? 2) : 2

print("control: \(url.lastPathComponent) budget=\(budget)")
for pass in 1...passes {
    let peak = Peak()
    peak.start()
    let start = monotonicNS()
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
        print("  pass \(pass): cannot create source"); continue
    }
    let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceShouldCacheImmediately: true,
        kCGImageSourceThumbnailMaxPixelSize: budget,
    ]
    let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    let elapsed = Double(monotonicNS() - start) / 1_000_000
    let measured = peak.stop()
    let pixels = image.map { "\($0.width)x\($0.height)" } ?? "nil"
    let core = image.map { $0.bytesPerRow * $0.height } ?? 0
    print(String(format: "  pass %d: %.0f ms | %@ | sampled footprint peak %.2f GiB | bitmap %.1f MiB",
                 pass, elapsed, pixels, measured, Double(core) / 1_048_576))
}
