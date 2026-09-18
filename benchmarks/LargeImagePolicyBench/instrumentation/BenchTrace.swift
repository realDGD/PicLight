import AppKit
import Foundation
import Darwin
import PicPNGStream
import Metal

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
    nonisolated static let peakLock = NSLock()
    /// The peak, taken under a lock: the heartbeat thread writes it and the main thread reads it in
    /// `finish()`, and the unlocked version once reported 0.199 GiB for a run whose own pulse lines
    /// showed 3.5 GiB. A metric that disagrees with itself is worse than no metric.
    nonisolated static func recordFootprint(_ bytes: Int64) {
        peakLock.lock()
        if bytes > peakFootprintSeen { peakFootprintSeen = bytes }
        peakLock.unlock()
    }
    nonisolated static func peakFootprint() -> Int64 {
        peakLock.lock(); defer { peakLock.unlock() }
        return peakFootprintSeen
    }
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

    // MARK: - variant-switch probe (PICLIGHT_BENCH_VARIANT=1)

    /// Drives a fast 0.8 → 1.2 → 0.8 physical-scale switch and reports the residency invariants
    /// after each move. The scale decides the texture flavour (mipmapped below 1.0, base-only
    /// above), so this is the real-image test for the two failure modes the audit found: an upload
    /// in flight during a switch must not resurrect the dropped flavour, and neither flavour may be
    /// billed twice.
    static func scheduleVariantProbe() {
        guard enabled,
              ProcessInfo.processInfo.environment["PICLIGHT_BENCH_VARIANT"] == "1" else { return }
        var backing: CGFloat = 2
        // physicalScale = zoomScale × backingScale; the probe asks for 0.8 / 1.2 / 0.8.
        let scales = [0.8, 1.2, 0.8, 1.2]
        DispatchQueue.main.asyncAfter(deadline: .now() + 22) {
            guard let window = NSApp.windows.first(where: { $0.isVisible }),
                  let viewer = window.contentViewController as? ViewerViewController else {
                mark("VARIANT probe: no visible viewer")
                return
            }
            backing = window.backingScaleFactor
            viewer.perform(.zoomActualPixels)
            for (index, physical) in scales.enumerated() {
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(index) * 6) {
                    var viewport = viewer.canvasViewportForTesting
                    viewport.zoomScale = physical / backing
                    // Recompute the fit so the transform stays valid for the new zoom.
                    let fit = ViewportState.fitScale(imagePixels: viewer.viewerState.descriptor?
                        .displayPixelSize ?? .zero,
                        viewPoints: viewer.canvasViewForTesting.bounds.size)
                    viewport.fitScale = fit
                    viewer.canvasViewportForTesting = viewport
                    mark(String(format: "VARIANT switch %d → physicalScale %.2f (zoom %.4f)",
                                index, physical, viewport.zoomScale))
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                        reportResidency(viewer: viewer, label: "variant \(index) physical \(physical)")
                    }
                }
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
            let environment = ProcessInfo.processInfo.environment
            if environment["PICLIGHT_BENCH_PUBLISH_BYPASS"] == "1" {
                viewer.publicationCoalescingEnabled = false
                mark("PUBLISH coalescing bypassed (one publication per arrival)")
            } else if let ms = environment["PICLIGHT_BENCH_PUBLISH_MS"], let value = Double(ms) {
                viewer.publicationCoalescingInterval = value / 1000
                mark("PUBLISH coalescing interval \(value) ms")
            }
            viewer.resetPublicationDiagnostics()
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
            // Pan half a viewport and report the production diagnostics before and after: the
            // question is whether the tiles that became visible were already resident on the GPU.
            DispatchQueue.main.asyncAfter(deadline: .now() + 60) {
                reportResidency(viewer: viewer, label: "before pan")
                var viewport = viewer.canvasViewportForTesting
                let visibleSourceWidth = viewport.zoomScale > 0
                    ? viewer.canvasViewForTesting.bounds.width / viewport.zoomScale : 0
                let sourceLongEdge = viewer.viewerState.descriptor?.displayPixelSize.width ?? 48000
                viewport.normalizedCenter = CGPoint(
                    x: viewport.normalizedCenter.x + (visibleSourceWidth * 1.0 / sourceLongEdge),
                    y: viewport.normalizedCenter.y)
                viewer.canvasViewportForTesting = viewport
                mark("PAN one viewport to the right")
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    reportResidency(viewer: viewer, label: "after pan")
                }
            }
        }
    }

    /// The drawer's current thumbnail, as laid out on screen: the reported bug is a frame that
    /// collapses to a few points for a large image, so the numbers that matter are the image box and
    /// the current-item border.
    static func reportDrawerThumbnail() {
        guard enabled,
              ProcessInfo.processInfo.environment["PICLIGHT_BENCH_DRAWER"] == "1" else { return }
        for delay in [24.0, 34.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard let window = NSApp.windows.first(where: { $0.isVisible }),
                      let drawer = findView(ofType: ThumbnailDrawerView.self, in: window.contentView),
                      let table = findView(ofType: NSTableView.self, in: drawer) else {
                    mark("DRAWER probe: drawer or table not found")
                    return
                }
                let rows = table.rows(in: table.visibleRect)
                mark("DRAWER visible rows \(rows.location)..<\(rows.location + rows.length) "
                     + "of \(table.numberOfRows), rowHeight "
                     + String(format: "%.0f", table.rowHeight))
                let range = rows.length > 0 ? rows.location..<(rows.location + rows.length) : 0..<min(3, table.numberOfRows)
                for row in range {
                    // makeIfNecessary: the drawer may be hidden, and the question is how the cell
                    // lays out, not whether the sidebar is on screen.
                    guard let cell = table.view(atColumn: 0, row: row, makeIfNecessary: true)
                            as? ThumbnailCellView else { continue }
                    cell.layoutSubtreeIfNeeded()
                    let image = cell.thumbnailImageView.frame
                    let border = cell.selectionBorderView.frame
                    let hasImage = (cell.thumbnailImageView as? NSImageView)?.image != nil
                    mark("DRAWER row \(row) hidden=\(drawer.isHidden) cell " + String(format: "%.0fx%.0f", cell.bounds.width, cell.bounds.height)
                         + " image " + String(format: "%.0fx%.0f at (%.0f,%.0f)",
                                              image.width, image.height, image.minX, image.minY)
                         + " border " + String(format: "%.0fx%.0f", border.width, border.height)
                         + " current=\(!cell.selectionBorderView.isHidden) hasImage=\(hasImage)")
                }
            }
        }
    }

    static func findView<T: NSView>(ofType: T.Type, in view: NSView?) -> T? {
        guard let view else { return nil }
        if let match = view as? T { return match }
        for sub in view.subviews {
            if let found = findView(ofType: ofType, in: sub) { return found }
        }
        return nil
    }

    /// The production residency diagnostics, printed as a mark so the run's own trace carries them.
    private static func reportResidency(viewer: ViewerViewController, label: String) {
        let d = viewer.nativeDetailDiagnostics()
        mark("RESIDENCY \(label): visible=\(d.visibleTiles) warm=\(d.warmTiles) "
             + "cpuCache=\(d.cpuCacheTiles)(\(d.cpuCacheBytes / 1_048_576) MiB, pinned \(d.cpuPinnedTiles)) "
             + "gpuResident=\(d.gpuResidentTiles)(\(d.gpuTextureBytes / 1_048_576) MiB) "
             + "gpuUploads=\(d.gpuUploads) hits=\(d.gpuCacheHits) bg=\(d.gpuBackgroundUploads) "
             + "sync=\(d.gpuSynchronousUploads)")
        // The dedup and variant invariants, on the real image: textures actually created, entries
        // discarded as stale, warm requests skipped as duplicates, and the LRU's own consistency.
        let p = viewer.publicationDiagnostics()
        mark("PUBLICATION \(label): arrivals=\(p.tileArrivals) requests=\(p.publicationRequests) "
             + "runs=\(p.publicationRuns) coalesced=\(p.publicationCoalesced) "
             + "visibleMat=\(p.visibleTilesMaterialized) warmMat=\(p.warmTilesMaterialized) "
             + "warmSubmitted=\(p.warmSubmissionCount) maxPending=\(p.maxPendingPublications) "
             + "duration=\(String(format: "%.0f", p.publicationDurationMS))ms "
             + "mainThread=\(String(format: "%.0f", p.mainThreadPublicationMS))ms")
        mark("STALEPLAN \(label): skip=\(d.gpuStalePlanSkipped) discard=\(d.gpuStalePlanDiscarded) "
             + "insertions=\(d.gpuResidentInsertions) duplicates=\(d.gpuDuplicateDiscarded)")
        mark("INVARIANTS \(label): creations=\(d.gpuTextureCreations) stale=\(d.gpuStaleDiscarded) "
             + "dupWarm=\(d.gpuDuplicateWarmSkips) inFlight=\(d.gpuInFlight) "
             + "bgHits=\(d.gpuBackgroundHits) protected=\(d.gpuProtectedTiles) "
             + "lru=\(d.gpuLruConsistent ? "consistent" : "INCONSISTENT")")
    }

    /// Renders the current frame offscreen (proxy + tiles) and compares its detail energy
    /// with the source's own.
    ///
    /// A window capture cannot see a Metal layer's contents, and per-pixel comparison needs
    /// sub-pixel-exact sampling that a 48000-pixel source cannot give reliably. Detail
    /// energy asks the question that matters — is this frame as sharp as the source, or
    /// smoothed like an upscaled proxy — and it is immune to a one-pixel slip. Densities are
    /// matched by rendering at the backing scale, so one source pixel is one render pixel.
    /// Runs the heavy half (a full source decode plus two offscreen renders) off the main
    /// thread: doing it inline measured as a 53.8 s "main-thread stall", which was the probe
    /// blocking the app rather than the app blocking itself.
    private static func measureNativeDetail(viewer: ViewerViewController, window: NSWindow) {
        // Capture everything the measurement needs on the main thread, then leave it.
        let captured = (
            descriptor: viewer.viewerState.descriptor,
            proxy: viewer.viewerState.currentImage,
            viewport: viewer.viewerState.viewport,
            tiles: viewer.canvasNativeTilesForTesting,
            viewSize: viewer.canvasViewForTesting.bounds.size,
            backing: window.backingScaleFactor
        )
        DispatchQueue.global(qos: .utility).async {
            measureNativeDetail(captured: captured, proxy: captured.proxy,
                                viewSize: captured.viewSize, backing: captured.backing)
        }
    }

    private static func measureNativeDetail(captured: (descriptor: ImageDescriptor?,
                                                        proxy: CGImage?,
                                                        viewport: ViewportState,
                                                        tiles: [NativeTile],
                                                        viewSize: CGSize,
                                                        backing: CGFloat),
                                             proxy: CGImage?,
                                             viewSize: CGSize,
                                             backing: CGFloat) {
        guard let descriptor = captured.descriptor,
              let proxy,
              let renderer = MetalImageRenderer(device: MTLCreateSystemDefaultDevice()),
              let device = renderer.device as MTLDevice? else {
            mark("NATIVE comparison: no renderer")
            return
        }
        let source = descriptor.displayPixelSize
        let side = CGSize(width: (viewSize.width * backing).rounded(), height: (viewSize.height * backing).rounded())
        guard side.width >= 32, side.height >= 32 else { return }

        let tiles = captured.tiles
        func render(_ tiles: [NativeTile]) -> [UInt8]? {
            let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm, width: Int(side.width), height: Int(side.height), mipmapped: false)
            textureDescriptor.usage = [.renderTarget, .shaderRead]
            textureDescriptor.storageMode = .shared
            guard let target = device.makeTexture(descriptor: textureDescriptor) else { return nil }
            guard renderer.renderOffscreen(image: proxy, nativeTiles: tiles,
                                           sourcePixelSize: source, viewport: captured.viewport,
                                           viewSize: viewSize, contentsScale: backing,
                                           backgroundColor: CGColor(red: 0, green: 0, blue: 0, alpha: 1),
                                           into: target) else { return nil }
            var pixels = [UInt8](repeating: 0, count: Int(side.width) * Int(side.height) * 4)
            pixels.withUnsafeMutableBytes { bytes in
                target.getBytes(bytes.baseAddress!, bytesPerRow: Int(side.width) * 4,
                                from: MTLRegionMake2D(0, 0, Int(side.width), Int(side.height)), mipmapLevel: 0)
            }
            return pixels
        }
        guard let withTiles = render(tiles), let proxyOnly = render([]) else {
            mark("NATIVE comparison: render failed")
            return
        }

        func energy(_ pixels: [UInt8], width: Int, height: Int) -> Double {
            var total = 0.0
            var pairs = 0
            for y in 0..<height {
                for x in 0..<(width - 1) {
                    let a = (y * width + x) * 4
                    let b = (y * width + x + 1) * 4
                    // bgra8Unorm: R at +2, G at +1, B at +0.
                    total += Double(abs(Int(pixels[a + 2]) - Int(pixels[b + 2])))
                    total += Double(abs(Int(pixels[a + 1]) - Int(pixels[b + 1])))
                    total += Double(abs(Int(pixels[a + 0]) - Int(pixels[b + 0])))
                    pairs += 3
                }
            }
            return pairs > 0 ? total / Double(pairs) : 0
        }
        let tilesEnergy = energy(withTiles, width: Int(side.width), height: Int(side.height))
        let proxyEnergy = energy(proxyOnly, width: Int(side.width), height: Int(side.height))

        // The source's own energy over the visible rectangle, so the render has a target.
        var info = ps_info()
        var error = [CChar](repeating: 0, count: 256)
        let url = descriptor.sourceURL
        guard let decoder = url.path.withCString({ ps_open($0, &info, &error, 256) }) else {
            mark(String(format: "NATIVE VERDICT tiles=%.2f proxy=%.2f (source unreadable)", tilesEnergy, proxyEnergy))
            return
        }
        defer { ps_close(decoder) }
        let visible = NativeTilePlanner.visibleSourceRect(viewport: captured.viewport,
                                                          sourcePixelSize: source, viewSize: viewSize)
        let snapped = CGRect(x: visible.minX.rounded(.down), y: visible.minY.rounded(.down),
                             width: visible.width.rounded(.up), height: visible.height.rounded(.up))
        guard snapped.width >= 8, snapped.height >= 8,
              ps_set_region(decoder, ps_rect(x: Int32(snapped.minX), y: Int32(snapped.minY),
                                             width: Int32(snapped.width), height: Int32(snapped.height))) == 1 else {
            mark(String(format: "NATIVE VERDICT tiles=%.2f proxy=%.2f (no region)", tilesEnergy, proxyEnergy))
            return
        }
        var status: Int32 = 1
        while status == 1 { status = ps_step(decoder, &error, 256) }
        guard status == 0, let native = ps_region_pixels(decoder) else { return }
        let width = Int(snapped.width), height = Int(snapped.height)
        var sourceTotal = 0.0
        var pairs = 0
        for y in 0..<height {
            for x in 0..<(width - 1) {
                let a = (y * width + x) * 4, b = (y * width + x + 1) * 4
                sourceTotal += Double(abs(Int(native[a]) - Int(native[b])))
                sourceTotal += Double(abs(Int(native[a + 1]) - Int(native[b + 1])))
                sourceTotal += Double(abs(Int(native[a + 2]) - Int(native[b + 2])))
                pairs += 3
            }
        }
        let sourceEnergy = pairs > 0 ? sourceTotal / Double(pairs) : 0
        mark(String(format: "NATIVE VERDICT tiles=%.2f proxyOnly=%.2f source=%.2f tilesCover=%.0f%% -> %@",
                    tilesEnergy, proxyEnergy, sourceEnergy,
                    tilesEnergy > 0 ? min(100, tilesEnergy / max(sourceEnergy, 0.001) * 100) : 0,
                    tilesEnergy > 0.8 * sourceEnergy ? "screen IS native source detail"
                        : (proxyEnergy < 0.55 * tilesEnergy ? "screen is the PROXY upscaled" : "inconclusive")))
    }

    // MARK: - heartbeat: memory + main-thread responsiveness, off-main

    static func startHeartbeat() {
        guard enabled else { return }
        let thread = Thread {
            while true {
                Thread.sleep(forTimeInterval: 0.25)
                let m = currentMemory()
                recordFootprint(m.footprint)
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
        out += String(format: "peakFootprint_sampled = %.3f GiB (250 ms sampling)\n", Double(peakFootprint()) / 1073741824)
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
