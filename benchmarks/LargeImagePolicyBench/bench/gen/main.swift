// Fixture generator for the A/B/C/D/E policy gates.
// Writes synthetic images to /tmp only. Never touches the source PNG.
//
//   gen list                              print the plan
//   gen make <name>                       create one fixture
//   gen tiny <count> <dir>                many small PNGs (C-series folders)
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// Deterministic xorshift so fixtures are reproducible across runs.
struct Rand {
    var s: UInt64
    init(seed: UInt64) { s = seed | 1 }
    mutating func next() -> UInt64 {
        s ^= s << 13; s ^= s >> 7; s ^= s << 17
        return s
    }
    mutating func byte() -> UInt8 { UInt8(truncatingIfNeeded: next() >> 33) }
}

func writePNG(width: Int, height: Int, to path: String, kind: String, seed: UInt64 = 0x9E3779B97F4A7C15) -> Bool {
    let bytesPerRow = width * 4
    var data = [UInt8](repeating: 255, count: bytesPerRow * height)
    switch kind {
    case "noise":
        var r = Rand(seed: seed)
        data.withUnsafeMutableBytes { raw in
            let p = raw.bindMemory(to: UInt8.self)
            var i = 0
            while i < p.count {
                p[i] = r.byte(); p[i + 1] = r.byte(); p[i + 2] = r.byte(); p[i + 3] = 255
                i += 4
            }
        }
    case "gradient":
        for y in 0..<height {
            let gy = UInt8(truncatingIfNeeded: y &* 255 / max(height, 1))
            for x in 0..<width {
                let o = y * bytesPerRow + x * 4
                data[o] = UInt8(truncatingIfNeeded: x &* 255 / max(width, 1))
                data[o + 1] = gy
                data[o + 2] = 128
                data[o + 3] = 255
            }
        }
    case "solid":
        for i in stride(from: 0, to: data.count, by: 4) {
            data[i] = 20; data[i + 1] = 130; data[i + 2] = 200; data[i + 3] = 255
        }
    default: break
    }

    guard let provider = CGDataProvider(data: Data(data) as CFData),
          let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                              bytesPerRow: bytesPerRow, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                              provider: provider, decode: nil, shouldInterpolate: false,
                              intent: .defaultIntent) else { return false }
    guard let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL,
                                                     UTType.png.identifier as CFString, 1, nil) else { return false }
    CGImageDestinationAddImage(dest, image, nil)
    return CGImageDestinationFinalize(dest)
}

func writeJPEG(width: Int, height: Int, to path: String, quality: Double = 0.9) -> Bool {
    let bytesPerRow = width * 4
    var data = [UInt8](repeating: 255, count: bytesPerRow * height)
    var r = Rand(seed: 0xDEADBEEFCAFEBABE)
    data.withUnsafeMutableBytes { raw in
        let p = raw.bindMemory(to: UInt8.self)
        var i = 0
        while i < p.count {
            // smooth-ish content plus noise: looks like a photo, decodes fast
            let x = (i / 4) % width, y = (i / 4) / width
            p[i] = UInt8(truncatingIfNeeded: (x &* 3 &+ y &* 5) &+ Int(r.byte() >> 3))
            p[i + 1] = UInt8(truncatingIfNeeded: (x &* 2 &+ y &* 7) &+ Int(r.byte() >> 3))
            p[i + 2] = UInt8(truncatingIfNeeded: 128 &+ Int(r.byte() >> 4))
            p[i + 3] = 255
            i += 4
        }
    }
    guard let provider = CGDataProvider(data: Data(data) as CFData),
          let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                              bytesPerRow: bytesPerRow, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                              provider: provider, decode: nil, shouldInterpolate: false,
                              intent: .defaultIntent) else { return false }
    guard let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL,
                                                     UTType.jpeg.identifier as CFString, 1, nil) else { return false }
    CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
    return CGImageDestinationFinalize(dest)
}

func writeAnimatedGIF(width: Int, height: Int, frames: Int, to path: String) -> Bool {
    guard let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL,
                                                     UTType.gif.identifier as CFString, frames, nil) else { return false }
    CGImageDestinationSetProperties(dest, [
        kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]
    ] as CFDictionary)
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    for f in 0..<frames {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                            bytesPerRow: width * 4, space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        // a moving detailed pattern: forces real per-frame decode work
        for y in stride(from: 0, to: height, by: 4) {
            for x in stride(from: 0, to: width, by: 4) {
                let v = CGFloat(((x + y + f * 37) / 4) % 16) / 16.0
                ctx.setFillColor(CGColor(red: v, green: 1 - v, blue: 0.5, alpha: 1))
                ctx.fill(CGRect(x: x, y: y, width: 4, height: 4))
            }
        }
        let img = ctx.makeImage()!
        CGImageDestinationAddImage(dest, img, [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.04]
        ] as CFDictionary)
    }
    return CGImageDestinationFinalize(dest)
}

let args = Array(CommandLine.arguments.dropFirst())
let root = "/tmp/piclight-bench/fixtures"
try? FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)

struct Fixture { let name: String; let w: Int; let h: Int; let kind: String; let format: String }
let plan: [Fixture] = [
    Fixture(name: "photo-4032x3024.jpg", w: 4032, h: 3024, kind: "photo", format: "jpeg"),
    Fixture(name: "noise-4032x3024.png", w: 4032, h: 3024, kind: "noise", format: "png"),
    Fixture(name: "noise-6000x4000.png", w: 6000, h: 4000, kind: "noise", format: "png"),
    Fixture(name: "noise-8192x5461.png", w: 8192, h: 5461, kind: "noise", format: "png"),
    Fixture(name: "grad-12000x9000.png", w: 12000, h: 9000, kind: "gradient", format: "png"),
    Fixture(name: "solid-8192x8192.png", w: 8192, h: 8192, kind: "solid", format: "png"),
    Fixture(name: "solid-12000x12000.png", w: 12000, h: 12000, kind: "solid", format: "png"),
    Fixture(name: "noise-8192x8192.png", w: 8192, h: 8192, kind: "noise", format: "png"),
    Fixture(name: "noise-7000x7000.png", w: 7000, h: 7000, kind: "noise", format: "png"),
    Fixture(name: "anim-1000.gif", w: 1000, h: 1000, kind: "anim", format: "gif"),
]

guard let cmd = args.first else {
    print("usage: gen make <name> | gen list | gen tiny <count> <dir>")
    exit(2)
}
switch cmd {
case "list":
    for f in plan { print("\(f.name)\t\(f.w)x\(f.h)\t\(f.format)") }
case "make":
    guard args.count > 1, let f = plan.first(where: { $0.name == args[1] }) else { print("unknown fixture"); exit(2) }
    let path = "\(root)/\(f.name)"
    let t0 = Date()
    let ok: Bool
    switch f.format {
    case "png":  ok = writePNG(width: f.w, height: f.h, to: path, kind: f.kind)
    case "jpeg": ok = writeJPEG(width: f.w, height: f.h, to: path)
    case "gif":  ok = writeAnimatedGIF(width: f.w, height: f.h, frames: 30, to: path)
    default:     ok = false
    }
    let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.int64Value ?? 0
    print("\(f.name) ok=\(ok) \(size / 1048576) MiB in \(String(format: "%.1f", -t0.timeIntervalSinceNow))s")
    if f.kind == "noise" { print("  (incompressible on purpose: decode must do real inflate + Paeth work)") }
case "tiny":
    guard args.count > 2, let n = Int(args[1]) else { print("usage: gen tiny <count> <dir>"); exit(2) }
    let dir = args[2]
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let t0 = Date()
    for i in 0..<n {
        // 64x48 graded content, distinct per index
        _ = writePNG(width: 64, height: 48, to: "\(dir)/t\(i).png", kind: i % 3 == 0 ? "gradient" : "solid",
                     seed: UInt64(i) &* 2654435761 &+ 1)
    }
    print("wrote \(n) tiny PNGs to \(dir) in \(String(format: "%.1f", -t0.timeIntervalSinceNow))s")
default:
    print("unknown command")
}
