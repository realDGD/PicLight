// Quick Look spike (Task 10 of the large-image plan).
//
// Question: can QLThumbnailGenerator deliver a materially earlier preview of an
// oversized image than our own bounded decode, and is a "warm" hit Quick Look's own
// thumbnail cache or merely the file page cache?
//
// Report only. Nothing here is linked into the app.
//
// Discriminators
//   * cold vs warm request on the same URL (QL's cache is keyed by file identity,
//     so the first request for a path is cold);
//   * a plain `CGImageSourceCreateThumbnailAtIndex` control at the same size, run
//     after the QL requests, which measures the *page-cache-warm* ImageIO cost with
//     no Quick Look cache involved at all;
//   * the `.thumb` cache directory size before/after;
//   * resident memory of the Quick Look helper processes while the request runs
//     (the generator runs out of process, so our own footprint says nothing).

import Foundation
import CoreGraphics
import ImageIO
import AppKit
import QuickLookThumbnailing

func monotonicNS() -> UInt64 { clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) }
func millis(_ from: UInt64, _ to: UInt64) -> Double { Double(to - from) / 1_000_000 }

func footprintBytes() -> Int {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return result == KERN_SUCCESS ? Int(info.phys_footprint) : 0
}

/// Samples our own footprint and the Quick Look helpers' resident memory.
final class Sampler {
    private let lock = NSLock()
    private var maxFootprint = 0
    private var maxHelperRSS: [String: Int] = [:]
    private var timer: DispatchSourceTimer?

    func start() {
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now(), repeating: .milliseconds(100))
        timer.setEventHandler { [weak self] in self?.sample() }
        timer.resume()
        self.timer = timer
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    private func sample() {
        let footprint = footprintBytes()
        let helpers = Self.quickLookHelperRSS()
        lock.lock()
        maxFootprint = max(maxFootprint, footprint)
        for (name, rss) in helpers { maxHelperRSS[name] = max(maxHelperRSS[name] ?? 0, rss) }
        lock.unlock()
    }

    /// `ps` is the one interface that reports another process's resident size
    /// without entitlements; the cadence is 10 Hz, so the cost is irrelevant.
    private static func quickLookHelperRSS() -> [String: Int] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-Ao", "rss=,comm="]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return [:] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        var result: [String: Int] = [:]
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let space = trimmed.firstIndex(of: " ") else { continue }
            let rssKB = Int(trimmed[trimmed.startIndex..<space]) ?? 0
            let command = trimmed[trimmed.index(after: space)...].trimmingCharacters(in: .whitespaces)
            let name = (command as NSString).lastPathComponent
            guard name.localizedCaseInsensitiveContains("QuickLook")
                || name.localizedCaseInsensitiveContains("ThumbnailsAgent")
                || name == "qlmanage" else { continue }
            result[name] = max(result[name] ?? 0, rssKB * 1024)
        }
        return result
    }

    func report() -> (footprint: Int, helpers: [String: Int]) {
        lock.lock(); defer { lock.unlock() }
        return (maxFootprint, maxHelperRSS)
    }
}

func cacheDirectoryBytes() -> (bytes: Int, files: Int) {
    let path = ("~/Library/Caches/ThumbnailsCache" as NSString).expandingTildeInPath
    guard let entries = try? FileManager.default.contentsOfDirectory(atPath: path) else { return (0, 0) }
    var total = 0
    for entry in entries {
        let attributes = try? FileManager.default.attributesOfItem(atPath: path + "/" + entry)
        total += (attributes?[.size] as? Int) ?? 0
    }
    return (total, entries.count)
}

func human(_ bytes: Int) -> String {
    String(format: "%.2f GiB", Double(bytes) / 1_073_741_824)
}

// MARK: - Arguments

let arguments = CommandLine.arguments
guard arguments.count >= 2 else {
    FileHandle.standardError.write(Data("usage: qlspike <image> [maxPixelSize ...]\n".utf8))
    exit(2)
}
let url = URL(fileURLWithPath: arguments[1])
let sizes = arguments.count > 2 ? arguments[2...].compactMap { Int($0) } : [2048, 4096]

let fileBytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
print("qlspike on \(url.lastPathComponent) (\(human(fileBytes ?? 0)))")

// MARK: - Quick Look requests

for size in sizes {
    for pass in ["cold", "warm"] {
        // `size` is in points; scale 2 doubles it to the pixel budget asked for.
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: CGSize(width: Double(size) / 2, height: Double(size) / 2),
            scale: 2,
            representationTypes: .thumbnail
        )

        let cacheBefore = cacheDirectoryBytes()
        let sampler = Sampler()
        sampler.start()
        let start = monotonicNS()
        var outcome = "no representation"
        var pixels = "-"
        var type = "-"
        do {
            let representation = try await QLThumbnailGenerator.shared.generateBestRepresentation(for: request)
            let image = representation.cgImage
            pixels = "\(image.width)x\(image.height)"
            type = String(describing: representation.type)
            outcome = "ok"
        } catch {
            outcome = "error: \(error.localizedDescription)"
        }
        let elapsed = millis(start, monotonicNS())
        sampler.stop()
        let cacheAfter = cacheDirectoryBytes()
        let stats = sampler.report()

        print(String(format: "\nsize=%d pass=%@ %@ in %.0f ms  pixels=%@ type=%@",
                     size, pass, outcome, elapsed, pixels, type))
        print(String(format: "  our footprint peak   %@", human(stats.footprint)))
        print(String(format: "  QL .thumb cache      %d -> %d bytes (%d -> %d files)",
                     cacheBefore.bytes, cacheAfter.bytes, cacheBefore.files, cacheAfter.files))
        if stats.helpers.isEmpty {
            print("  QL helper processes  none observed")
        } else {
            for (name, rss) in stats.helpers.sorted(by: { $0.value > $1.value }) {
                print(String(format: "  QL helper %-28@ peak RSS %@", name as NSString, human(rss)))
            }
        }
    }
}

// MARK: - Control: page-cache-warm ImageIO thumbnail, no Quick Look cache

print("\n--- control: ImageIO thumbnail (page cache warm, no Quick Look cache) ---")
for size in sizes {
    let cacheBefore = cacheDirectoryBytes()
    let sampler = Sampler()
    sampler.start()
    let start = monotonicNS()
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
        print("size=\(size) cannot create source")
        continue
    }
    let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceShouldCacheImmediately: true,
        kCGImageSourceThumbnailMaxPixelSize: size,
    ]
    let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    let elapsed = millis(start, monotonicNS())
    sampler.stop()
    let cacheAfter = cacheDirectoryBytes()
    let stats = sampler.report()
    let pixels = image.map { "\($0.width)x\($0.height)" } ?? "nil"
    print(String(format: "size=%d fromImageAlways in %.0f ms pixels=%@ footprint peak %@ cache %d->%d bytes",
                 size, elapsed, pixels, human(stats.footprint), cacheBefore.bytes, cacheAfter.bytes))
}
