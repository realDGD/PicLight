import AppKit
import Foundation
import Darwin
import PicPNGStream

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

    // MARK: - scripted live resize (§9.5)

    /// `PICLIGHT_BENCH_RESIZE=1` drives the window through sizes the way a user drags an
    /// edge: many small changes in quick succession (4 s of growing, 2 s hold, 4 s of
    /// shrinking), then it settles. The heartbeat keeps sampling ping latency through
    /// all of it, every step is timestamped in the same trace as the decode marks, and
    /// the traversal counter says whether a decode started while the drag was still
    /// going. None of this touches production code — it only moves the window.
    nonisolated(unsafe) private static var resizeTimer: Timer?
    /// MainActor-isolated because every mutation happens inside the hop below.
    private static var resizeStep = 0

    static func scheduleResizeSequence() {
        guard enabled,
              let mode = ProcessInfo.processInfo.environment["PICLIGHT_BENCH_RESIZE"], !mode.isEmpty,
              mode != "0" else { return }
        // After the first bounded decode has published (16-18 s on the investigation
        // image), otherwise the viewer has no descriptor and the upgrade path is a
        // no-op by design.
        let begin = Double(ProcessInfo.processInfo.environment["PICLIGHT_BENCH_RESIZE_AT"] ?? "20") ?? 20
        let interval = 0.12          // far faster than the 300 ms debounce, like a real drag
        let growSteps = 30, holdSteps = 16, shrinkSteps = 30
        resizeStep = 0

        resizeTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            Task { @MainActor in
                guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }),
                      let screen = window.screen ?? NSScreen.main else { return }
                let t = benchNow() - start
                guard t >= begin else { return }
                let base = NSSize(width: 420, height: 320)
                let large = NSSize(width: min(1700, screen.visibleFrame.width - 40),
                                   height: min(1100, screen.visibleFrame.height - 40))
                let phase = resizeStep
                var size = window.contentView?.bounds.size ?? base
                let label: String
                let applies: Bool
                if phase < growSteps {
                    size = NSSize(width: base.width + (large.width - base.width) * CGFloat(phase + 1) / CGFloat(growSteps),
                                  height: base.height + (large.height - base.height) * CGFloat(phase + 1) / CGFloat(growSteps))
                    label = "grow"; applies = true
                } else if phase < growSteps + holdSteps {
                    // A real hold: no window calls at all, so the debounce can fire.
                    size = large; label = "hold-large (quiet)"; applies = false
                } else if phase < growSteps + holdSteps + shrinkSteps {
                    let k = phase - growSteps - holdSteps
                    size = NSSize(width: large.width - (large.width - base.width) * CGFloat(k + 1) / CGFloat(shrinkSteps),
                                  height: large.height - (large.height - base.height) * CGFloat(k + 1) / CGFloat(shrinkSteps))
                    label = "shrink"; applies = true
                } else {
                    resizeTimer?.invalidate(); resizeTimer = nil
                    return
                }
                if applies { window.setContentSize(size) }
                let canvas = window.contentView?.bounds.size ?? .zero
                mark(String(format: "RESIZE step %d %@ window=%.0fx%.0f canvas=%.0fx%.0f",
                            resizeStep, label, size.width, size.height, canvas.width, canvas.height))
                resizeStep += 1
            }
        }
    }

    // MARK: - native-detail probe (PICLIGHT_BENCH_ZOOM=1)

    /// Drives the app to 100 %, then answers the question the whole native-detail backend
    /// exists for: are the pixels on screen the source's own pixels, or the proxy blown up?
    ///
    /// It compares, for a grid of samples: what the canvas actually rendered, the source
    /// pixels read independently through the streaming decoder, and what the bounded proxy
    /// would have shown. Colour-space conversion between the window and the raw file can
    /// shift values a little, which is why the verdict is a *comparison of distances*
    /// rather than an absolute equality.
    static func scheduleZoomProbe() {
        guard enabled,
              let mode = ProcessInfo.processInfo.environment["PICLIGHT_BENCH_ZOOM"], mode == "1" else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) {
            guard let window = NSApp.windows.first(where: { $0.isVisible }),
                  let viewer = window.contentViewController as? ViewerViewController else {
                mark("NATIVE probe: no visible viewer")
                return
            }
            viewer.perform(.zoomActualPixels)
            mark(String(format: "NATIVE zoom to 100%% (zoom=%.4f backing=%.1f)",
                        viewer.viewerState.viewport.zoomScale, window.backingScaleFactor))
            for step in 1...12 {
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(step) * 5) {
                    mark(String(format: "NATIVE tiles=%d cacheTiles=%d",
                                viewer.canvasNativeTilesForTesting.count,
                                viewer.nativeDetailCacheCountForTesting))
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 40) {
                measureNativeDetail(viewer: viewer, window: window)
            }
        }
    }

    private static func measureNativeDetail(viewer: ViewerViewController, window: NSWindow) {
        guard let descriptor = viewer.viewerState.descriptor,
              let proxy = viewer.viewerState.currentImage else {
            mark("NATIVE comparison: nothing on screen")
            return
        }
        let source = descriptor.displayPixelSize
        var viewport = viewer.viewerState.viewport
        viewport.viewRotationQuarterTurns = 0
        viewport.mirroredHorizontally = false
        let canvas = viewer.canvasViewForTesting
        let viewSize = canvas.bounds.size
        guard viewSize.width > 8, viewSize.height > 8 else { return }

        // One decode of the visible rectangle, sampled for the reference values.
        let transform = viewport.imageToViewTransform(sourcePixelSize: source, viewSize: viewSize)
        let inverse = transform.inverted()
        let visible = CGRect(origin: .zero, size: viewSize).applying(inverse)
        let visibleSource = CGRect(x: visible.minX + source.width / 2,
                                   y: source.height / 2 - visible.maxY,
                                   width: visible.width, height: visible.height)
            .intersection(CGRect(origin: .zero, size: source))
        guard visibleSource.width >= 2, visibleSource.height >= 2 else { return }

        // Render what the window shows right now.
        guard let rep = canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds) else { return }
        canvas.cacheDisplay(in: canvas.bounds, to: rep)
        let repScale = CGFloat(rep.pixelsWide) / max(canvas.bounds.width, 1)

        guard let url = viewer.viewerState.descriptor?.sourceURL else { return }
        var info = ps_info()
        var error = [CChar](repeating: 0, count: 256)
        guard let decoder = url.path.withCString({ ps_open($0, &info, &error, 256) }) else {
            mark("NATIVE comparison: decoder refused: \(String(cString: error))")
            return
        }
        defer { ps_close(decoder) }
        let region = ps_rect(x: Int32(visibleSource.minX), y: Int32(visibleSource.minY),
                             width: Int32(visibleSource.width), height: Int32(visibleSource.height))
        guard ps_set_region(decoder, region) == 1 else { return }
        var status: Int32 = 1
        while status == 1 { status = ps_step(decoder, &error, 256) }
        guard status == 0, let native = ps_region_pixels(decoder) else {
            mark("NATIVE comparison: decode failed")
            return
        }
        let nativeStride = Int(visibleSource.width) * 4

        // How far the proxy is from that rectangle, for the control distance.
        let proxyWidth = proxy.width, proxyHeight = proxy.height
        let proxyStride = proxy.bytesPerRow
        let proxyData = proxy.dataProvider?.data
        // flatMap, not map: CFDataGetBytePtr is itself optional, and `map` would leave an
        // optional-of-optional that `if let` only half unwraps.
        let proxyBytes = proxyData.flatMap { CFDataGetBytePtr($0) }

        var samples = 0
        var renderedVsNative = 0.0
        var renderedVsProxy = 0.0
        for row in 0..<8 {
            for column in 0..<8 {
                let fx = (Double(column) + 0.5) / 8
                let fy = (Double(row) + 0.5) / 8
                let sx = visibleSource.minX + CGFloat(fx) * visibleSource.width
                let sy = visibleSource.minY + CGFloat(fy) * visibleSource.height
                let centred = ViewportState.centredSourceRect(
                    CGRect(x: sx, y: sy, width: 1, height: 1), sourcePixelSize: source)
                let viewPoint = CGPoint(x: centred.midX, y: centred.midY).applying(transform)
                let px = Int(viewPoint.x * repScale), py = Int((viewSize.height - viewPoint.y) * repScale)
                guard px >= 0, py >= 0, px < rep.pixelsWide, py < rep.pixelsHigh else { continue }
                guard let rendered = rep.colorAt(x: px, y: py)?.usingColorSpace(.sRGB) else { continue }

                let nx = Int(sx - visibleSource.minX), ny = Int(sy - visibleSource.minY)
                let n = native + ny * nativeStride + nx * 4
                let nativeRed = Double(n[0]), nativeGreen = Double(n[1]), nativeBlue = Double(n[2])

                var proxyRed = 0.0, proxyGreen = 0.0, proxyBlue = 0.0
                if let proxyBytes {
                    let bx = min(proxyWidth - 1, max(0, Int(Double(nx) / Double(visibleSource.width) * Double(proxyWidth))))
                    let by = min(proxyHeight - 1, max(0, Int(Double(ny) / Double(visibleSource.height) * Double(proxyHeight))))
                    let p = proxyBytes + by * proxyStride + bx * 4
                    // The proxy is uploaded as BGRA premultiplied; only the ordering matters here.
                    proxyBlue = Double(p[0]); proxyGreen = Double(p[1]); proxyRed = Double(p[2])
                }
                let renderedRed = Double(rendered.redComponent) * 255
                let renderedGreen = Double(rendered.greenComponent) * 255
                let renderedBlue = Double(rendered.blueComponent) * 255
                renderedVsNative += (abs(renderedRed - nativeRed) + abs(renderedGreen - nativeGreen)
                                     + abs(renderedBlue - nativeBlue)) / 3
                renderedVsProxy += (abs(renderedRed - proxyRed) + abs(renderedGreen - proxyGreen)
                                    + abs(renderedBlue - proxyBlue)) / 3
                samples += 1
            }
        }
        guard samples > 0 else { return }
        let toNative = renderedVsNative / Double(samples)
        let toProxy = renderedVsProxy / Double(samples)
        mark(String(format: "NATIVE VERDICT samples=%d meanDeltaToNative=%.1f meanDeltaToProxy=%.1f -> %@",
                    samples, toNative, toProxy,
                    toNative < toProxy ? "screen is NATIVE SOURCE pixels" : "screen is the PROXY upscaled"))
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
