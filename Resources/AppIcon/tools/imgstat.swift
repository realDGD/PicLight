// imgstat — pixel statistics for PNG inspection (no PIL/ImageMagick on this box).
// usage: imgstat <a.png> [b.png]
//   one image: size, alpha coverage, mean RGBA, mean RGB of opaque pixels, 3x3 rule-of-thirds means
//   two images: also mean absolute per-channel difference (0-255) and % of pixels differing > 8
import Foundation
import CoreGraphics
import ImageIO
import AppKit

func load(_ path: String) -> (CGImage, [UInt8], Int, Int) {
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
        FileHandle.standardError.write("cannot load \(path)\n".data(using: .utf8)!)
        exit(2)
    }
    let w = img.width, h = img.height
    var buf = [UInt8](repeating: 0, count: w * h * 4)
    let cs = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8,
                              bytesPerRow: w * 4, space: cs,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { exit(2) }
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    return (img, buf, w, h)
}

func stats(_ path: String) {
    let (_, px, w, h) = load(path)
    var sr = 0.0, sg = 0.0, sb = 0.0, sa = 0.0
    var orr = 0.0, og = 0.0, ob = 0.0, on = 0.0
    for i in stride(from: 0, to: px.count, by: 4) {
        let a = Double(px[i + 3]) / 255.0
        sr += Double(px[i]); sg += Double(px[i + 1]); sb += Double(px[i + 2]); sa += a
        if px[i + 3] > 250 { orr += Double(px[i]); og += Double(px[i + 1]); ob += Double(px[i + 2]); on += 1 }
    }
    let n = Double(w * h)
    let un = max(on, 1)
    print(String(format: "%@  %dx%d", (path as NSString).lastPathComponent, w, h))
    print(String(format: "  alpha coverage : %.1f%%", sa / n * 100))
    print(String(format: "  mean RGBA      : %.1f %.1f %.1f %.3f", sr / n, sg / n, sb / n, sa / n))
    print(String(format: "  mean opaque RGB: %.1f %.1f %.1f", orr / un, og / un, ob / un))
    // opaque pixel count in each third (tiles 3x3) to catch "layer missing" regressions
    var grid = [[Int]](repeating: [Int](repeating: 0, count: 3), count: 3)
    for y in 0..<h {
        for x in 0..<w {
            let a = px[(y * w + x) * 4 + 3]
            if a > 250 { grid[min(y * 3 / h, 2)][min(x * 3 / w, 2)] += 1 }
        }
    }
    // alpha bounding box => icon inset ratio (Big Sur grid: art is inset within the canvas)
    var x0 = w, y0 = h, x1 = -1, y1 = -1
    for y in 0..<h { for x in 0..<w where px[(y * w + x) * 4 + 3] > 4 {
        if x < x0 { x0 = x }; if x > x1 { x1 = x }; if y < y0 { y0 = y }; if y > y1 { y1 = y } } }
    if x1 >= 0 {
        let bw = x1 - x0 + 1, bh = y1 - y0 + 1
        print(String(format: "  alpha bbox     : x %d..%d y %d..%d  (%dx%d)  inset %.1f%%  side/canvas %.4f",
                     x0, x1, y0, y1, bw, bh, Double(w - bw) / 2 / Double(w) * 100, Double(bw) / Double(w)))
    } else { print("  alpha bbox     : fully transparent") }
    print("  opaque 3x3 (row-major, % of cell):")
    for r in 0..<3 {
        let cells = (0..<3).map { String(format: "%5.1f", Double(grid[r][$0]) / (n / 9) * 100) }
        print("    " + cells.joined(separator: " "))
    }
}

let args = Array(CommandLine.arguments.dropFirst())
guard !args.isEmpty else { print("usage: imgstat <a.png> [b.png]"); exit(1) }
stats(args[0])
if args.count > 1 {
    stats(args[1])
    let (i1, p1, w1, h1) = load(args[0])
    let (i2, p2, w2, h2) = load(args[1])
    _ = (i1, i2)
    if w1 == w2 && h1 == h2 {
        var sum = 0.0, big = 0
        let n = w1 * h1
        for i in stride(from: 0, to: p1.count, by: 4) {
            var d = 0
            for c in 0..<4 { d = max(d, abs(Int(p1[i + c]) - Int(p2[i + c]))) }
            sum += Double(d)
            if d > 8 { big += 1 }
        }
        print(String(format: "  DIFF vs %@: meanAbs=%.2f  pixels>8: %.2f%%",
                     (args[1] as NSString).lastPathComponent, sum / Double(n), Double(big) / Double(n) * 100))
    } else {
        print("  DIFF: size mismatch \(w1)x\(h1) vs \(w2)x\(h2)")
    }
}
