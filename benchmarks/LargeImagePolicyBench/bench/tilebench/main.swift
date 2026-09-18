// Tile-size sweep for the native-detail backend.
//
// The plan asked for a measured default rather than a felt one. What tile size actually
// changes: how soon the *first* tile is on screen (delivery granularity), how many textures
// and cache entries the viewport needs, and the gutter overhead (a one-pixel border around
// every tile). What it does not change: the cost of the pass itself, which is one traversal of
// the compressed stream regardless of how the output is sliced — the same finding as the
// bounded-thumbnail measurements, where output size did not move the needle.
//
// Usage: tilebench <fixture.png> [tileSizes...]

import Foundation
import CoreGraphics
import ImageIO
import Darwin

func monotonicNS() -> UInt64 { clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) }

let arguments = CommandLine.arguments
guard arguments.count >= 2 else {
    FileHandle.standardError.write(Data("usage: tilebench <fixture.png> [sizes...]\n".utf8))
    exit(2)
}
let url = URL(fileURLWithPath: arguments[1])
let sizes = arguments.count > 2 ? arguments[2...].compactMap { Int($0) } : [256, 512, 1024, 2048]

guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
      let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
      let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue else {
    FileHandle.standardError.write(Data("cannot read \(url.lastPathComponent)\n".utf8))
    exit(1)
}
let sourceSize = CGSize(width: width, height: height)
// A viewport the size a 100 % view of the investigation image shows on a 2× display.
let visible = CGRect(x: sourceSize.width * 0.3, y: sourceSize.height * 0.3,
                     width: min(2400, sourceSize.width * 0.4),
                     height: min(1600, sourceSize.height * 0.4))

print("tilebench: \(url.lastPathComponent) \(Int(width))x\(Int(height)), "
      + "visible \(Int(visible.width))x\(Int(visible.height))")

struct Sample {
    let firstTileMS: Double
    let totalMS: Double
    let tiles: Int
    let bytes: Int
    let textureCount: Int
}

func run(tileSize: Int) -> Sample? {
    guard let plan = NativeTilePlanner.plan(sourceRect: visible, sourcePixelSize: sourceSize,
                                            tileSize: tileSize) else { return nil }
    let provider = PNGNativeTileProvider()
    // The callback is @Sendable, so the tallies live in a box rather than in captured vars.
    final class Tally: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        private var bytes = 0
        private var firstAt: Double = -1
        func note(_ tile: NativeTile, since start: UInt64) {
            lock.lock()
            count += 1
            bytes += tile.byteCost
            if firstAt < 0 { firstAt = Double(monotonicNS() - start) / 1_000_000 }
            lock.unlock()
        }
        var snapshot: (Int, Int, Double) {
            lock.lock(); defer { lock.unlock() }
            return (count, bytes, firstAt)
        }
    }
    let tally = Tally()
    let start = monotonicNS()
    do {
        try provider.produce(plan: plan, source: url, pageIndex: 0, gutter: 1, colorSpace: nil, orientation: SourceOrientation(.up),
                             shouldCancel: { false },
                             onTile: { tally.note($0, since: start) })
    } catch {
        FileHandle.standardError.write(Data("tile \(tileSize) failed: \(error)\n".utf8))
        return nil
    }
    let total = Double(monotonicNS() - start) / 1_000_000
    let (count, bytes, firstAt) = tally.snapshot
    return Sample(firstTileMS: firstAt, totalMS: total, tiles: count, bytes: bytes,
                  textureCount: count)
}

// A plain literal, not String(format:): "%s" expects a C string and traps on a Swift String.
print("    tile firstTile       pass    tiles  tileBytes   gutter%  textures")
for size in sizes {
    guard let sample = run(tileSize: size) else { continue }
    let gutter = 1.0 - Double(size * size) / Double((size + 2) * (size + 2))
    print(String(format: "%8d %8.0f ms %8.0f ms %8d %9.1f MiB %9.2f%% %9d",
                 size, sample.firstTileMS, sample.totalMS, sample.tiles,
                 Double(sample.bytes) / 1_048_576.0, gutter * 100, sample.textureCount))
}
