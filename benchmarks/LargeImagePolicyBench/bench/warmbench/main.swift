// Warm-area strategy benchmark for native-detail tiles.
//
// The question: how much does it cost to keep roughly a nine-grid of viewports warm around the
// current one, and does that cost stay sane at the *low* magnifications where native detail
// first turns on? The threshold is physicalScale ≈ 0.2 for a 48000-pixel source with an 8192
// proxy, and that is exactly where the visible source rectangle — and therefore any warm area
// around it — is largest.
//
// Method: for each physical scale, build the plans that the three candidate strategies would
// ask for, then run the decoder *once* for the largest of them and derive every other plan's
// numbers from that pass. Tiles are the same tiles whoever asked for them, so this measures
// resource cost per strategy without paying a traversal per strategy per scale — the traversal
// count itself is one of the things being measured, so it would be dishonest to hide twelve of
// them in the benchmark.
//
// Usage: warmbench <image.png> [scales...]

import Foundation
import CoreGraphics
import ImageIO
import Metal
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

func residentBytes() -> Int {
    var info = mach_task_basic_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info_data_t>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
        }
    }
    return result == KERN_SUCCESS ? Int(info.resident_size) : 0
}

final class TileCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}

final class PeakSampler {
    private let lock = NSLock()
    private var peakFootprint = 0
    private var peakResident = 0
    private var timer: DispatchSourceTimer?
    func start() {
        peakFootprint = footprintBytes(); peakResident = residentBytes()
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now(), repeating: .milliseconds(20))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let f = footprintBytes(), r = residentBytes()
            self.lock.lock()
            self.peakFootprint = max(self.peakFootprint, f)
            self.peakResident = max(self.peakResident, r)
            self.lock.unlock()
        }
        timer.resume()
        self.timer = timer
    }
    func stop() -> (footprint: Int, resident: Int) {
        timer?.cancel(); timer = nil
        lock.lock(); defer { lock.unlock() }
        return (peakFootprint, peakResident)
    }
}

func trace(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

func human(_ bytes: Int) -> String { String(format: "%.1f MiB", Double(bytes) / 1_048_576) }
func gib(_ bytes: Int) -> String { String(format: "%.2f GiB", Double(bytes) / 1_073_741_824) }

// MARK: - Setup

let arguments = CommandLine.arguments
guard arguments.count >= 2 else {
    FileHandle.standardError.write(Data("usage: warmbench <image.png> [scales...]\n".utf8)); exit(2)
}
let url = URL(fileURLWithPath: arguments[1])
let scales: [Double] = arguments.count > 2 ? arguments[2...].compactMap { Double($0) } : [0.2, 0.5, 1.0, 2.0]
let tileSize = 512
let backingScale: CGFloat = 2
let viewPoints = CGSize(width: 1200, height: 800)         // a plausible 2× window
let backing = CGSize(width: viewPoints.width * backingScale, height: viewPoints.height * backingScale)

guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
      let sourceWidth = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
      let sourceHeight = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue else {
    FileHandle.standardError.write(Data("cannot read \(url.lastPathComponent)\n".utf8)); exit(1)
}
let sourceSize = CGSize(width: sourceWidth, height: sourceHeight)

let device = MTLCreateSystemDefaultDevice()
let renderer = device.flatMap { MetalImageRenderer(device: $0) }

/// Straight RGBA bytes for a set of tiles, and the same figure including a mip chain.
func tileBytes(_ coordinates: [TileCoordinate], sourceSize: CGSize, mipmapped: Bool) -> Int {
    var total = 0
    for coordinate in coordinates {
        let rect = NativeTilePlanner.sourceRect(for: coordinate, tileSize: tileSize,
                                                sourcePixelSize: sourceSize)
        total += Int(rect.width) * Int(rect.height) * 4 * (mipmapped ? 4 / 3 : 1)
    }
    return total
}

/// What one strategy would ask the decoder for, at this scale.
struct Strategy {
    let name: String
    let plan: NativeTilePlan
    /// Bytes the *current* provider would allocate for this plan's decode rectangle.
    var regionBytes: Int { Int(plan.decodeRect.width) * Int(plan.decodeRect.height) * 4 }
}

func strategies(visible: CGRect, sourceSize: CGSize) -> [Strategy] {
    var result: [Strategy] = []
    if let plan = NativeTilePlanner.plan(sourceRect: visible, sourcePixelSize: sourceSize,
                                         tileSize: tileSize, ring: 0) {
        result.append(Strategy(name: "visible only", plan: plan))
    }
    if let plan = NativeTilePlanner.plan(sourceRect: visible, sourcePixelSize: sourceSize,
                                         tileSize: tileSize, ring: 1) {
        result.append(Strategy(name: "visible+1ring (current)", plan: plan))
    }
    for margin in [0.25, 0.5, 1.0] {
        let warm = visible.insetBy(dx: -visible.width * margin, dy: -visible.height * margin)
        if let plan = NativeTilePlanner.plan(sourceRect: warm, sourcePixelSize: sourceSize,
                                             tileSize: tileSize, ring: 0) {
            result.append(Strategy(name: String(format: "warm margin %.2f", margin), plan: plan))
        }
    }
    return result
}

trace("warmbench: opening \(url.lastPathComponent)")
print("warmbench: \(url.lastPathComponent) \(Int(sourceSize.width))x\(Int(sourceSize.height)), "
      + "viewport \(Int(backing.width))x\(Int(backing.height)) backing px, tile \(tileSize)")

// MARK: - Per scale

var reportRows: [String] = []
for scale in scales {
    let zoomScale = scale / backingScale
    let visibleSize = CGSize(width: backing.width / scale, height: backing.height / scale)
    var viewport = ViewportState(fitScale: zoomScale, zoomScale: zoomScale,
                                 normalizedCenter: CGPoint(x: 0.5, y: 0.5))
    viewport.fitScale = ViewportState.fitScale(imagePixels: sourceSize, viewPoints: viewPoints)
    let visible = CGRect(x: (sourceSize.width - visibleSize.width) / 2,
                         y: (sourceSize.height - visibleSize.height) / 2,
                         width: visibleSize.width, height: visibleSize.height)

    print("\n=== physicalScale \(scale) — visible source \(Int(visible.width))x\(Int(visible.height)) ===")
    let candidates = strategies(visible: visible, sourceSize: sourceSize)
    guard let widest = candidates.max(by: { $0.plan.decodeRect.width < $1.plan.decodeRect.width }) else { continue }
    let visiblePlan = candidates.first?.plan

    // Interpolation, not String(format:): "%s" expects a C string and "%@" a NSString, and both
    // trap on a Swift String — a trap this project has now paid for three times.
    func padded(_ text: String, _ width: Int) -> String {
        text.count >= width ? text : text + String(repeating: " ", count: width - text.count)
    }
    print("  " + padded("strategy", 26) + padded("tiles", 8) + padded("tile bytes", 13) + padded("region bytes", 15) + "region")
    for candidate in candidates {
        let bytes = tileBytes(candidate.plan.allCoordinates, sourceSize: sourceSize, mipmapped: false)
        print("  " + padded(candidate.name, 26) + padded("\(candidate.plan.allCoordinates.count)", 8)
              + padded(human(bytes), 13) + padded(human(candidate.regionBytes), 15)
              + gib(candidate.regionBytes))
    }

    // The policy's own plan for this scale, with the production budget: at 0.2 that is visible-only,
    // and its peak is the number the task asks for.
    if let policyPlan = WarmAreaPolicy.plan(visible: visible, sourcePixelSize: sourceSize,
                                            tileSize: tileSize,
                                            cpuBudgetBytes: 256 * 1024 * 1024) {
        let sampler = PeakSampler()
        sampler.start()
        let start = monotonicNS()
        let counter = TileCounter()
        do {
            try PNGNativeTileProvider().produce(plan: policyPlan.plan, source: url, pageIndex: 0,
                                                gutter: 1, colorSpace: nil,
                                                orientation: SourceOrientation(.up),
                                                shouldCancel: { false },
                                                onTile: { _ in counter.increment() })
        } catch {
            FileHandle.standardError.write(Data("policy pass failed: \(error)\n".utf8))
        }
        let peak = sampler.stop()
        print(String(format: "  POLICY plan: margin %.2f%@, %d tiles, %.0f ms, peak footprint %@, peak RSS %@",
                     policyPlan.margin, policyPlan.clampedByBudget ? " (clamped)" : "",
                     counter.value, millis(start, monotonicNS()),
                     human(peak.footprint), gib(peak.resident)))
    }

    // One traversal for the widest plan: everything narrower is a subset of its tiles.
    trace("scale \(scale): starting pass for plan \(widest.name) decodeRect \(widest.plan.decodeRect)")
    let sampler = PeakSampler()
    sampler.start()
    let start = monotonicNS()
    let visibleKeys = Set((visiblePlan?.allCoordinates ?? []).map {
        NativeTileKey(sourcePath: url.path, tileSize: tileSize, x: $0.x, y: $0.y)
    })
    final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var keys: [NativeTileKey] = []
        private var bytes = 0
        private var firstVisibleAt: Double = -1
        private var visible: Set<NativeTileKey> = []
        func expect(_ keys: Set<NativeTileKey>) { lock.lock(); visible = keys; lock.unlock() }
        func add(_ tile: NativeTile, at millis: Double) {
            lock.lock()
            keys.append(tile.key)
            bytes += tile.byteCost
            if firstVisibleAt < 0, visible.contains(tile.key) { firstVisibleAt = millis }
            lock.unlock()
        }
        var snapshot: (keys: [NativeTileKey], bytes: Int, firstVisibleAt: Double) {
            lock.lock(); defer { lock.unlock() }
            return (keys, bytes, firstVisibleAt)
        }
    }
    let box = Box()
    box.expect(visibleKeys)
    do {
        try PNGNativeTileProvider().produce(plan: widest.plan, source: url, pageIndex: 0, gutter: 1,
                                            colorSpace: nil, orientation: SourceOrientation(.up),
                                            shouldCancel: { false }, onTile: { tile in
            box.add(tile, at: millis(start, monotonicNS()))
        })
    } catch {
        FileHandle.standardError.write(Data("pass failed: \(error)\n".utf8))
        _ = sampler.stop()
        continue
    }
    trace("scale \(scale): pass returned")
    let totalMS = millis(start, monotonicNS())
    let peak = sampler.stop()
    let snapshot = box.snapshot
    let deliveredKeys = Set(snapshot.keys)
    let firstVisibleAt = snapshot.firstVisibleAt

    print("  pass: \(snapshot.keys.count) tiles, \(human(snapshot.bytes)), "
          + String(format: "%.0f ms, first visible tile %.0f ms", totalMS, firstVisibleAt)
          + ", peak footprint \(human(peak.footprint)), peak RSS \(gib(peak.resident))")

    // Pan simulation: what is already resident after moving by N viewports, and what would it
    // cost to become sharp.
    print("  " + padded("pan (+x)", 10) + padded("strategy", 26) + padded("visible", 10)
          + padded("warm hits", 11) + "time-to-sharp")
    for viewports in [0.5, 1.0, 2.0] {
        let moved = visible.offsetBy(dx: visible.width * CGFloat(viewports), dy: 0)
            .intersection(CGRect(origin: .zero, size: sourceSize))
        guard let plan = NativeTilePlanner.plan(sourceRect: moved, sourcePixelSize: sourceSize,
                                                tileSize: tileSize, ring: 0) else { continue }
        let keys = plan.allCoordinates.map {
            NativeTileKey(sourcePath: url.path, tileSize: tileSize, x: $0.x, y: $0.y)
        }
        for candidate in candidates {
            let owned = Set(candidate.plan.allCoordinates.map {
                NativeTileKey(sourcePath: url.path, tileSize: tileSize, x: $0.x, y: $0.y)
            })
            // The denominator is the *panned viewport*, not the overlap: dividing by the
            // intersection reports 100 % for every strategy, including one that owns nothing.
            let hits = keys.filter { owned.contains($0) && deliveredKeys.contains($0) }.count
            let rate = keys.isEmpty ? 1 : Double(hits) / Double(keys.count)
            let sharp = rate >= 1.0 ? "0 ms (GPU upload only)"
                                    : String(format: "%.0f ms (one pass)", totalMS)
            print("  " + padded(String(format: "%.1f", viewports), 10) + padded(candidate.name, 26)
                  + padded("\(keys.count)", 10)
                  + padded(String(format: "%.1f%%", rate * 100), 11) + sharp)
        }
    }
    reportRows.append("| \(widest.name) | \(scale) | \(human(peak.footprint)) | "
                      + "\(gib(peak.resident)) | \(human(snapshot.bytes)) | 1 | "
                      + "\(String(format: "%.0f", firstVisibleAt)) ms | — |")
}

// MARK: - GPU upload cost for the warm set at the 100 % scale

trace("scales done; GPU section")
if let renderer, device != nil {
    let scale = 1.0
    let visibleSize = CGSize(width: backing.width / scale, height: backing.height / scale)
    let visible = CGRect(x: (sourceSize.width - visibleSize.width) / 2,
                         y: (sourceSize.height - visibleSize.height) / 2,
                         width: visibleSize.width, height: visibleSize.height)
    let warm = visible.insetBy(dx: -visible.width, dy: -visible.height)
    if let plan = NativeTilePlanner.plan(sourceRect: warm, sourcePixelSize: sourceSize, tileSize: tileSize) {
        final class Box: @unchecked Sendable {
            private let lock = NSLock(); private var tiles: [NativeTile] = []
            func add(_ tile: NativeTile) { lock.lock(); tiles.append(tile); lock.unlock() }
            var all: [NativeTile] { lock.lock(); defer { lock.unlock() }; return tiles }
        }
        let box = Box()
        try? PNGNativeTileProvider().produce(plan: plan, source: url, pageIndex: 0, gutter: 1,
                                             colorSpace: nil, orientation: SourceOrientation(.up),
                                             shouldCancel: { false }, onTile: { box.add($0) })
        let warmTiles = box.all
        let visibleTiles = warmTiles.filter { $0.sourceRect.intersects(visible) }
        for (label, tiles) in [("visible", visibleTiles), ("visible+1ring", warmTiles)] {
            let uploadStart = monotonicNS()
            var uploaded = 0
            for tile in tiles where renderer.prepareTexture(for: tile, variant: .baseOnly) != nil { uploaded += 1 }
            let uploadMS = millis(uploadStart, monotonicNS())
            print(String(format: "  GPU upload (\(label)): %d tiles, %.1f ms on the calling thread", uploaded, uploadMS)
                  + ", \(human(renderer.tileTextureBytes)) resident")
        }
    }
}

print("\n| strategy | scale | peak footprint | peak RSS | tile bytes | traversals | first visible tile | report |")
print("| --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |")
for row in reportRows { print(row) }
