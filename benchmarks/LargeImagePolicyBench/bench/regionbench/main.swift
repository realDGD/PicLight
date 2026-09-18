// Region-decode capability probe for the LargeImageBackend design.
//
// The question this answers, per format: can we get the pixels of a *part* of an
// oversized image without paying for all of it — in time and, more importantly, in
// memory? ImageIO exposes no region API, so the probe measures the three things that
// decide it:
//
//   1. full decode: wall time and process footprint peak;
//   2. a bounded thumbnail (whole image, small output) — cheap output does not imply
//      cheap work, which is the PNG finding;
//   3. a *crop draw*: decode lazily and draw only a 512×512 corner of it. If that costs
//      what the full decode costs, there is no region decode and a native-detail
//      backend has to stream rows itself.
//   4. kCGImageSourceSubsampleFactor, where the format honours it.
//
// Usage: regionbench [fixture-dir]   (writes its own fixtures next to the source)

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Darwin

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

/// Samples the footprint during an operation so the peak is visible even when the
/// allocation is transient (the 5.86 GiB lazy-draw region was only visible this way).
final class FootprintPeak {
    private let lock = NSLock()
    private var peak = 0
    private var timer: DispatchSourceTimer?
    func start() {
        peak = footprintBytes()
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now(), repeating: .milliseconds(20))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let current = footprintBytes()
            self.lock.lock(); self.peak = max(self.peak, current); self.lock.unlock()
        }
        timer.resume()
        self.timer = timer
    }
    func stop() -> Int {
        timer?.cancel(); timer = nil
        lock.lock(); defer { lock.unlock() }
        return peak
    }
}

func human(_ bytes: Int) -> String { String(format: "%.2f GiB", Double(bytes) / 1_073_741_824) }

// MARK: - Fixtures

let arguments = CommandLine.arguments
let outputDirectory = URL(fileURLWithPath: arguments.count > 1 ? arguments[1]
                          : "/tmp/piclight-bench/fixtures")
try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

/// 12000×9000 of incompressible noise: oversized, and slow enough that "did it decode
/// everything?" is measurable in wall time as well as memory.
let sourceURL = outputDirectory.appendingPathComponent("region-12000x9000.png")
if !FileManager.default.fileExists(atPath: sourceURL.path) {
    let width = 12000, height = 9000
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    var seed: UInt64 = 0x2545F4914F6CDD1D
    for i in 0..<(width * height) {
        seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17
        pixels[i * 4 + 0] = UInt8(truncatingIfNeeded: seed)
        pixels[i * 4 + 1] = UInt8(truncatingIfNeeded: seed >> 8)
        pixels[i * 4 + 2] = UInt8(truncatingIfNeeded: seed >> 16)
        pixels[i * 4 + 3] = 255
    }
    let provider = CGDataProvider(data: Data(pixels) as CFData)!
    let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                        bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                        provider: provider, decode: nil, shouldInterpolate: false,
                        intent: .defaultIntent)!
    let options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.85]
    // WebP is decode-only on this system (CGImageDestination has no WebP encoder), so the
    // matrix covers the encodable formats and WebP is documented from its decoder.
    for type in [UTType.png, UTType.jpeg, UTType.tiff, UTType.bmp] {
        let url = outputDirectory.appendingPathComponent("region-12000x9000.\(type.preferredFilenameExtension ?? "dat")")
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil)
        else { continue }
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        CGImageDestinationFinalize(destination)
        print("wrote \(url.lastPathComponent) (\(ByteCountFormatter.string(fromByteCount: Int64((try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0), countStyle: .file)))")
    }
}

private func existing(_ names: [String]) -> URL? {
    for name in names {
        let url = outputDirectory.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: url.path) { return url }
    }
    return nil
}

private let formats: [(String, URL)] = [
    ("PNG", sourceURL),
    ("JPEG", existing(["region-12000x9000.jpg", "region-12000x9000.jpeg"]) ?? sourceURL),
    ("TIFF", existing(["region-12000x9000.tiff"]) ?? sourceURL),
    ("BMP", existing(["region-12000x9000.bmp"]) ?? sourceURL),
]

// MARK: - Probes

func fullDecode(_ url: URL) {
    let peak = FootprintPeak(); peak.start()
    let start = monotonicNS()
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        print("  full decode: cannot open"); return
    }
    // Force materialization, otherwise the "decode" is lazy and measures nothing.
    let width = image.width, height = image.height
    let context = CGContext(data: nil, width: min(width, 1024), height: min(height, 1024),
                            bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.draw(image, in: CGRect(x: -CGFloat(width) / 2, y: -CGFloat(height) / 2,
                                   width: CGFloat(width), height: CGFloat(height)))
    let elapsed = millis(start, monotonicNS())
    let measured = peak.stop()
    print(String(format: "  full decode + materialize      %8.0f ms  peak %@", elapsed, human(measured)))
}

func boundedThumbnail(_ url: URL, budget: Int) {
    let peak = FootprintPeak(); peak.start()
    let start = monotonicNS()
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return }
    let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceThumbnailMaxPixelSize: budget,
        kCGImageSourceShouldCacheImmediately: true,
    ]
    let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    let elapsed = millis(start, monotonicNS())
    let measured = peak.stop()
    let pixels = image.map { "\($0.width)x\($0.height)" } ?? "nil"
    print(String(format: "  thumbnail maxPixelSize %5d   %8.0f ms  %@  peak %@",
                 budget, elapsed, pixels, human(measured)))
}

/// The decisive one: draw a small corner of a lazily decoded image. A region decode
/// would cost a fraction of the full decode; a stream decoder costs all of it.
func cropDraw(_ url: URL, crop: Int = 512) {
    let peak = FootprintPeak(); peak.start()
    let start = monotonicNS()
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        print("  crop draw: cannot open"); return
    }
    let context = CGContext(data: nil, width: crop, height: crop, bitsPerComponent: 8,
                            bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    // Top-left corner only: translate the image so that corner lands on the canvas.
    context.draw(image, in: CGRect(x: 0, y: CGFloat(crop) - CGFloat(image.height),
                                   width: CGFloat(image.width), height: CGFloat(image.height)))
    let elapsed = millis(start, monotonicNS())
    let measured = peak.stop()
    print(String(format: "  crop %dx%d from a %dx%d      %8.0f ms  peak %@",
                 crop, crop, image.width, image.height, elapsed, human(measured)))
}

func subsample(_ url: URL, factor: Int) {
    let peak = FootprintPeak(); peak.start()
    let start = monotonicNS()
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return }
    let options: [CFString: Any] = [
        kCGImageSourceSubsampleFactor: factor,
        kCGImageSourceShouldCacheImmediately: true,
    ]
    let image = CGImageSourceCreateImageAtIndex(source, 0, options as CFDictionary)
    if let image {
        let context = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8,
                                bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: 64, height: 64))
    }
    let elapsed = millis(start, monotonicNS())
    let measured = peak.stop()
    let pixels = image.map { "\($0.width)x\($0.height)" } ?? "nil"
    print(String(format: "  subsampleFactor %d            %8.0f ms  %@  peak %@",
                 factor, elapsed, pixels, human(measured)))
}

// MARK: - Run

if let giant = ProcessInfo.processInfo.environment["REGIONBENCH_GIANT"], !giant.isEmpty {
    print("\nGIANT (the investigation image) — same probes, to show the cost at 1.9 GiB")
    let url = URL(fileURLWithPath: giant)
    fullDecode(url)
    boundedThumbnail(url, budget: 8192)
    cropDraw(url)
}

for (name, url) in formats {
    guard FileManager.default.fileExists(atPath: url.path) else {
        print("\n\(name): fixture missing (\(url.lastPathComponent))")
        continue
    }
    let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
    print("\n\(name) — \(url.lastPathComponent), \(human(size ?? 0))")
    fullDecode(url)
    boundedThumbnail(url, budget: 1024)
    boundedThumbnail(url, budget: 4096)
    cropDraw(url)
    subsample(url, factor: 4)
}
