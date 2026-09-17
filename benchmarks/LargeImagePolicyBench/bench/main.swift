import Foundation
import CoreGraphics
import ImageIO
import CoreImage
import Metal
import MetalKit
import UniformTypeIdentifiers

// Paths are configurable so the harness is not tied to one machine layout.
//   PICLIGHT_BENCH_GIANT     the multi-gigapixel investigation image (never committed)
//   PICLIGHT_BENCH_FIXTURES  directory produced by `bench/gen` (generated, never committed)
let benchGiantPath = ProcessInfo.processInfo.environment["PICLIGHT_BENCH_GIANT"]
    ?? "/Users/dgd/Downloads/万萝图/万萝图.png"
let benchFixtureDir = ProcessInfo.processInfo.environment["PICLIGHT_BENCH_FIXTURES"]
    ?? "/tmp/piclight-bench/fixtures"

// MARK: - helpers

func arg(_ name: String, _ args: [String], default def: String? = nil) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return def }
    return args[i + 1]
}
func flag(_ name: String, _ args: [String]) -> Bool { args.contains(name) }

func makeContext(width: Int, height: Int, colorSpace: CGColorSpace) -> CGContext? {
    CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
              space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
}

/// Draws into a fresh bitmap of the given size — this is what forces a lazy
/// ImageIO image to decode, and it is what PicLight does on every draw().
@discardableResult
func forceDraw(_ image: CGImage, width: Int, height: Int,
               quality: CGInterpolationQuality = .high) -> (seconds: Double, bitmapBytes: Int64, ok: Bool) {
    let cs = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
    guard let ctx = makeContext(width: width, height: height, colorSpace: cs) else { return (0, 0, false) }
    ctx.interpolationQuality = quality
    let t0 = now()
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    return (now() - t0, Int64(ctx.bytesPerRow) * Int64(height), true)
}

func imageFacts(_ image: CGImage) -> String {
    let cs = image.colorSpace.flatMap { $0.name } as String? ?? "nil"
    return "\(image.width)x\(image.height) bpc=\(image.bitsPerComponent) bpp=\(image.bitsPerPixel) bytesPerRow=\(image.bytesPerRow) rowBytes_per_px=\(String(format: "%.2f", Double(image.bytesPerRow) / Double(image.width))) alphaInfo=\(image.alphaInfo.rawValue) cs=\(cs) bitmapBytes=\(fmtM(Int64(image.bytesPerRow) * Int64(image.height)))"
}

func fitSize(_ w: Int, _ h: Int, into longEdge: Int) -> (Int, Int) {
    let scale = Double(longEdge) / Double(max(w, h))
    return (max(1, Int((Double(w) * scale).rounded())), max(1, Int((Double(h) * scale).rounded())))
}

func holdIfRequested(_ args: [String]) {
    if let hold = Double(arg("--hold", args) ?? "0"), hold > 0 {
        FileHandle.standardError.write("HOLDING \(hold)s pid=\(getpid()) — external tools can sample now\n".data(using: .utf8)!)
        Thread.sleep(forTimeInterval: hold)
    }
}

// MARK: - create

func runCreate(_ args: [String]) async {
    guard let path = args.first else { print("usage: create <file> [--imm 0|1] [--draw N] [--repeat N] [--hold S]"); return }
    let imm = (arg("--imm", args) ?? "0") == "1"
    let cache = arg("--cache", args)
    let drawLong = Int(arg("--draw", args) ?? "0") ?? 0
    let repeats = Int(arg("--repeat", args) ?? "1") ?? 1
    let sampler = MemSampler()
    sampler.start()

    var m = Measurement(name: "CreateImageAtIndex\(imm ? " + shouldCacheImmediately" : " (no options — production path)")\(cache.map { " shouldCache=\($0)" } ?? "") drawLong=\(drawLong) repeats=\(repeats)")
    m.add("file", path)

    for run in 1...repeats {
        var opts: [CFString: Any] = [:]
        if imm { opts[kCGImageSourceShouldCacheImmediately] = true }
        if let cache { opts[kCGImageSourceShouldCache] = (cache == "1") }
        let t0 = now()
        let s0 = Proc.snapshot()
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else {
            print("cannot create source"); return
        }
        let tSource = now()
        var desc = "n/a"
        if let d = try? ImageIODecoder.descriptor(for: source, url: URL(fileURLWithPath: path)) {
            desc = "\(Int(d.pixelSize.width))x\(Int(d.pixelSize.height)) orient=\(d.orientation.rawValue) frames=\(d.frameCount) type=\(d.typeIdentifier ?? "?")"
        }
        let tProps = now()
        var optsUsed = false
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, opts.isEmpty ? nil : opts as CFDictionary) else {
            print("cannot create image"); return
        }
        optsUsed = true
        let tImage = now()
        var line = "source_create=\(msInt(tSource - t0)) props=\(msInt(tProps - tSource)) createImage=\(msInt(tImage - tProps)) total=\(msInt(tImage - t0))"
        if run == 1 { m.add("descriptor", desc) }
        if drawLong > 0 {
            let (w, h) = fitSize(image.width, image.height, into: drawLong)
            let r = forceDraw(image, width: w, height: h)
            line += " draw@\(w)x\(h)=\(msInt(r.seconds))"
        }
        if run == 1 { m.add("image", imageFacts(image)) }
        let sNow = Proc.snapshot()
        line += " footprint_after=\(fmtM(sNow.footprint)) peakRSS=\(fmtG(sNow.peakRSS))"
        line += " cpu=\(ms(sNow.cpuSeconds - s0.cpuSeconds)) energy=\(String(format: "%.1f", sNow.energyMilliJoules - s0.energyMilliJoules))mJ"
        m.add("run\(run)", line)
        _ = optsUsed
    }
    addResourceBlock(&m, t0: samplerStartTime(sampler), snapshot0: Proc.snapshot(), sampler: sampler)
    m.emit()
    sampler.stop()
    sampler.dumpCSV("/tmp/piclight-bench/out/create-imm\(imm)-\(Int(now() * 1000)).csv")
    holdIfRequested(args)
}

/// Sampler start time is the first sample's timestamp.
func samplerStartTime(_ s: MemSampler) -> Double { s.all().first?.t ?? now() }

// MARK: - thumb

func runThumb(_ args: [String]) async {
    guard let path = args.first, let maxPx = Int(args.dropFirst().first ?? "4096") else {
        print("usage: thumb <file> <maxPixelSize> [--imm 0|1] [--transform 0|1] [--always 0|1] [--drawLong N] [--repeat N] [--label X] [--hold S]"); return
    }
    let imm = (arg("--imm", args) ?? "1") == "1"
    let transform = (arg("--transform", args) ?? "1") == "1"
    let always = (arg("--always", args) ?? "0") == "1"
    let drawLong = Int(arg("--drawLong", args) ?? "0") ?? 0
    let repeats = Int(arg("--repeat", args) ?? "1") ?? 1
    let label = arg("--label", args) ?? "thumb"
    let sampler = MemSampler()
    sampler.start()
    var m = Measurement(name: "\(label): CreateThumbnailAtIndex maxPx=\(maxPx) always=\(always) transform=\(transform) cacheImmediately=\(imm) repeats=\(repeats)")
    m.add("file", path)

    for run in 1...repeats {
        var opts: [CFString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: maxPx,
            kCGImageSourceCreateThumbnailWithTransform: transform,
            kCGImageSourceShouldCacheImmediately: imm,
        ]
        if always { opts[kCGImageSourceCreateThumbnailFromImageAlways] = true }
        let t0 = now()
        let s0 = Proc.snapshot()
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let thumb = CGImageSourceCreateThumbnailAtIndex(source, 0, opts as CFDictionary) else {
            print("thumbnail failed"); sampler.stop(); return
        }
        let tCall = now()
        var line = "CreateThumbnailAtIndex=\(ms(tCall - t0))"
        if run == 1 { m.add("image", imageFacts(thumb)) }
        if drawLong > 0 {
            let (w, h) = fitSize(thumb.width, thumb.height, into: drawLong)
            let r = forceDraw(thumb, width: w, height: h)
            line += " forced_draw@\(w)x\(h)=\(msInt(r.seconds))"
        }
        m.add("run\(run)", line)
    }
    addResourceBlock(&m, t0: samplerStartTime(sampler), snapshot0: Proc.snapshot(), sampler: sampler)
    m.emit()
    sampler.stop()
    sampler.dumpCSV("/tmp/piclight-bench/out/\(label)-\(maxPx)-imm\(imm)-\(Int(now() * 1000)).csv")
    holdIfRequested(args)
}

// MARK: - orient (production decode path)

func runOrient(_ args: [String]) async {
    guard let path = args.first else { print("usage: orient <file> [--degrees 0|90|180|270]"); return }
    let degrees = Int(arg("--degrees", args) ?? "0") ?? 0
    let url = URL(fileURLWithPath: path)
    let sampler = MemSampler(); sampler.start()
    let s0 = Proc.snapshot()
    let t0 = now()

    let decoder = ImageIODecoder()
    guard let head = try? await decoder.decodeFirstDisplayableFrame(url, target: .fullResolution) else {
        print("decode failed"); sampler.stop(); return
    }
    let tProd = now()
    var m = Measurement(name: "production decodeFirstDisplayableFrame (file orientation=\(head.descriptor.orientation.rawValue), forced copy degrees=\(degrees))")
    m.add("total", ms(tProd - t0))
    m.add("image", imageFacts(head.image))
    m.add("metadata_fields", head.metadata.fields.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " | "))

    if degrees != 0 {
        let orient: CGImagePropertyOrientation = degrees == 90 ? .right : (degrees == 180 ? .down : .left)
        let t1 = now()
        let rotated = ImageIODecoder.apply(orientation: orient, to: head.image)
        let t2 = now()
        m.add("apply(orientation) second_bitmap", "\(ms(t2 - t1)) result=\(rotated.map { "\($0.width)x\($0.height)" } ?? "nil")")
        m.add("peakFootprint_after_copy", fmtG(sampler.peakFootprint(after: t0)))
    }
    m.add("forced_draw_4096", ms(forceDraw(head.image, width: 4096, height: 4096).seconds))
    addResourceBlock(&m, t0: t0, snapshot0: s0, sampler: sampler)
    m.emit()
    sampler.stop()
    holdIfRequested(args)
}

// MARK: - Core Image

func runCI(_ args: [String]) async {
    guard let path = args.first else { print("usage: ci <file> [--ctx mtl|cpu] [--scale F] [--render WxH] [--noScale] [--hold S]"); return }
    let kind = arg("--ctx", args) ?? "mtl"
    let scale = Double(arg("--scale", args) ?? "0.08533") ?? 0.08533
    let noScale = flag("--noScale", args)
    let renderSpec = arg("--render", args)
    let sampler = MemSampler(); sampler.start()
    let s0 = Proc.snapshot()
    let t0 = now()
    let url = URL(fileURLWithPath: path)

    guard let ci = CIImage(contentsOf: url) else { print("CIImage(contentsOf:) failed"); sampler.stop(); return }
    let tCreate = now()

    let context: CIContext
    if kind == "mtl", let dev = MTLCreateSystemDefaultDevice() {
        context = CIContext(mtlDevice: dev)
    } else {
        context = CIContext(options: [.useSoftwareRenderer: false])
    }
    let tCtx = now()

    var m = Measurement(name: "Core Image ctx=\(kind) scale=\(noScale ? 1.0 : scale)")
    m.add("CIImage_contentsOf", msInt(tCreate - t0))
    m.add("extent", "\(ci.extent)")
    m.add("CIContext_create", msInt(tCtx - tCreate))

    var target = ci
    if !noScale && scale != 1.0 { target = ci.transformed(by: CGAffineTransform(scaleX: scale, y: scale)) }
    m.add("scaled_extent", "\(target.extent)")

    let renderRect: CGRect
    if let spec = renderSpec {
        let parts = spec.split(separator: "x").map(String.init)
        renderRect = CGRect(x: 0, y: 0, width: Int(parts[0]) ?? 4096, height: Int(parts.count > 1 ? parts[1] : parts[0]) ?? 4096)
    } else {
        renderRect = target.extent
    }
    m.add("render_rect", "\(renderRect)")

    let t1 = now()
    let drawn = context.createCGImage(target, from: renderRect)
    let t2 = now()
    m.add("createCGImage_first", ms(t2 - t1))
    m.add("rendered", drawn.map { imageFacts($0) } ?? "nil")
    m.add("peakFootprint_after_render", fmtG(sampler.peakFootprint(after: t0)))

    let t3 = now()
    _ = context.createCGImage(target, from: renderRect)
    m.add("createCGImage_second", ms(now() - t3))
    addResourceBlock(&m, t0: t0, snapshot0: s0, sampler: sampler)
    m.emit()
    sampler.stop()
    holdIfRequested(args)
}

// MARK: - production DecodeCoordinator

func runPipeline(_ args: [String]) async {
    guard let path = args.first else { print("usage: pipeline <file> [--prev F] [--next F] [--target N] [--hold S]"); return }
    let url = URL(fileURLWithPath: path)
    let prev = arg("--prev", args).map { URL(fileURLWithPath: $0) }
    let next = arg("--next", args).map { URL(fileURLWithPath: $0) }
    let targetSize = arg("--target", args).flatMap { Int($0) }
    let sampler = MemSampler(); sampler.start()
    let s0 = Proc.snapshot()
    let coordinator = DecodeCoordinator()
    let t0 = now()
    let (stream, cont) = AsyncStream<DecodeEvent>.makeStream()
    let task = await coordinator.show(item: url, previous: prev, next: next, direction: .forward,
                                     target: targetSize.map { DecodeTarget(maxPixelSize: $0) } ?? .fullResolution) { event in
        cont.yield(event)
    }
    var headTime: Double = -1, headW = 0, headH = 0
    var headBytes: Int64 = 0
    var failure: String?
    for await event in stream {
        switch event {
        case let .head(head):
            headTime = now(); headW = head.image.width; headH = head.image.height
            headBytes = Int64(head.image.bytesPerRow) * Int64(head.image.height)
        case let .failure(reason): failure = reason
        case .frame: break
        }
        break
    }
    cont.finish()
    var m = Measurement(name: "DecodeCoordinator.show target=\(targetSize.map(String.init) ?? "native") prev=\(prev?.lastPathComponent ?? "-") next=\(next?.lastPathComponent ?? "-")")
    m.add("head_event_after", msInt(headTime - t0))
    m.add("head_image", "\(headW)x\(headH) \(fmtM(headBytes))")
    if let failure { m.add("failure", failure) }
    for _ in 0..<600 {
        // activeTaskCount never drops below 1: the finished `currentTask` stays
        // counted. <= 1 therefore means "no preload is still running".
        if await coordinator.activeTaskCount <= 1 { break }
        try? await Task.sleep(nanoseconds: 100_000_000)
    }
    let tIdle = now()
    m.add("all_tasks_idle_after", ms(tIdle - t0))
    m.add("peakFootprint", fmtG(sampler.peakFootprint(after: t0)))
    addResourceBlock(&m, t0: t0, snapshot0: s0, sampler: sampler)
    m.emit()
    sampler.stop()
    sampler.dumpCSV("/tmp/piclight-bench/out/pipeline-\(targetSize.map(String.init) ?? "native")-\(Int(now() * 1000)).csv")
    holdIfRequested(args)
    _ = task
}

// MARK: - production sidebar thumbnail path

func runThumbPipe(_ args: [String]) async {
    guard let path = args.first else { print("usage: thumbpipe <file> <maxPx>"); return }
    let maxPx = Int(args.dropFirst().first ?? "300") ?? 300
    let url = URL(fileURLWithPath: path)
    let sampler = MemSampler(); sampler.start()
    let s0 = Proc.snapshot()
    let pipeline = ThumbnailPipeline()
    let t0 = now()
    let thumb = try? await pipeline.thumbnail(for: url, maxPixelSize: maxPx)
    let t1 = now()
    var m = Measurement(name: "ThumbnailPipeline.thumbnail(maxPixelSize: \(maxPx)) — sidebar/navigator path")
    m.add("time", ms(t1 - t0))
    m.add("image", thumb.map { imageFacts($0) } ?? "nil")
    addResourceBlock(&m, t0: t0, snapshot0: s0, sampler: sampler)
    m.emit()
    sampler.stop()
    holdIfRequested(args)
}

// MARK: - banded draw of the native image (can CGImage be consumed incrementally?)

func runBands(_ args: [String]) async {
    guard let path = args.first else { print("usage: bands <file> [--bands 6]"); return }
    let bandCount = Int(arg("--bands", args) ?? "6") ?? 6
    let sampler = MemSampler(); sampler.start()
    let s0 = Proc.snapshot()
    let t0 = now()
    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { print("decode failed"); return }
    let tCreate = now()
    let cs = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
    // Destination is one band tall: if CG decodes incrementally, later bands are
    // cheap; if it decodes the whole image per draw, every band costs a full pass.
    guard let ctx = makeContext(width: image.width, height: 64, colorSpace: cs) else { return }
    var m = Measurement(name: "banded native draw (destination \(image.width)x64)")
    m.add("source+create_lazy", msInt(tCreate - t0))
    var rows = 0
    let step = max(1, image.height / bandCount)
    for band in 0..<bandCount {
        rows = min(band * step, image.height - 64)
        ctx.saveGState()
        ctx.translateBy(x: 0, y: CGFloat(-rows))
        let tb = now()
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        ctx.restoreGState()
        let s = Proc.snapshot()
        m.add("band\(band)_rows\(rows)", "draw=\(msInt(now() - tb)) cumulative=\(msInt(now() - t0)) footprint=\(fmtM(s.footprint))")
        if now() - t0 > 300 { m.add("aborted", "band drawing exceeded 300 s"); break }
    }
    addResourceBlock(&m, t0: t0, snapshot0: s0, sampler: sampler)
    m.emit()
    sampler.stop()
}

// MARK: - cancellation

func runCancel(_ args: [String]) async {
    guard args.count >= 2 else { print("usage: cancel <bigFile> <smallFile>"); return }
    let big = URL(fileURLWithPath: args[0])
    let small = URL(fileURLWithPath: args[1])
    let decoder = ImageIODecoder()

    final class Flag: @unchecked Sendable {
        private let lock = NSLock(); private var v = false
        var value: Bool { lock.lock(); defer { lock.unlock() }; return v }
        func set() { lock.lock(); v = true; lock.unlock() }
    }

    print("### cancellation (Task.cancel during the expensive part of a 1.9 GB image)")
    let tA0 = now()
    guard let headA = try? await decoder.decodeFirstDisplayableFrame(big, target: .fullResolution) else {
        print("decode failed"); return
    }
    print("decodeFirstDisplayableFrame(lazy, production call) = \(ms(now() - tA0))")
    let tDraw0 = now()
    _ = forceDraw(headA.image, width: 3200, height: 2133)
    print("one draw into a 3200x2133 canvas (what the viewer does) = \(ms(now() - tDraw0))")

    // Now cancel a draw in flight.
    let sampler = MemSampler(); sampler.start()
    let t0 = now()
    let done = Flag()
    let task = Task.detached(priority: .userInitiated) { () -> Void in
        if let head = try? await decoder.decodeFirstDisplayableFrame(big, target: .fullResolution) {
            _ = forceDraw(head.image, width: 3200, height: 2133)
        }
        done.set()
    }
    try? await Task.sleep(nanoseconds: 300_000_000)
    task.cancel()
    let sCancel = Proc.snapshot()
    print("cancel_issued_at = \(msInt(now() - t0))  Task.isCancelled=\(task.isCancelled)  finished_at_cancel=\(done.value)")

    let tB0 = now()
    _ = try? await decoder.decodeFirstDisplayableFrame(small, target: .fullResolution)
    print("small_decode_while_cancelled_draw_running = \(ms(now() - tB0))  returned_at=\(msInt(now() - t0))")

    while !done.value, now() - t0 < 300 { try? await Task.sleep(nanoseconds: 20_000_000) }
    let endOfWork = now()
    let s1 = Proc.snapshot()
    print("cancelled_work_actually_ended = \(msInt(endOfWork - t0))  (\(msInt(endOfWork - t0 - 0.3)) after cancel)")
    print("cpu_after_cancel = user=\(ms(s1.user - sCancel.user)) sys=\(ms(s1.sys - sCancel.sys))")
    print("energy_after_cancel = \(String(format: "%.1f", s1.energyMilliJoules - sCancel.energyMilliJoules)) mJ WASTED")
    print("peakFootprint = \(fmtG(sampler.peakFootprint(after: t0)))")
    print("peakRSS_getrusage = \(fmtG(sampler.peakRSS()))")
    print("conclusion_hint = Task.cancel() only sets a flag; an in-flight CGContext.draw/ImageIO decode never observes it.")
    print("")
    sampler.stop()
    _ = task
}


// MARK: - asset preparation: write a bounded downsample to /tmp for renderer tests

func runWriteBMP(_ args: [String]) async {
    guard args.count >= 3, let maxPx = Int(args[1]) else {
        print("usage: writebmp <srcFile> <maxPx> <outFile>"); return
    }
    let srcURL = URL(fileURLWithPath: args[0])
    let outURL = URL(fileURLWithPath: args[2])
    guard let src = CGImageSourceCreateWithURL(srcURL as CFURL, nil),
          let thumb = CGImageSourceCreateThumbnailAtIndex(src, 0, [
              kCGImageSourceThumbnailMaxPixelSize: maxPx,
              kCGImageSourceCreateThumbnailWithTransform: true,
              kCGImageSourceShouldCacheImmediately: true,
          ] as CFDictionary) else { print("thumbnail failed"); return }
    guard let dest = CGImageDestinationCreateWithURL(outURL as CFURL, UTType.bmp.identifier as CFString, 1, nil) else {
        print("cannot create destination"); return
    }
    CGImageDestinationAddImage(dest, thumb, nil)
    let ok = CGImageDestinationFinalize(dest)
    let size = (try? FileManager.default.attributesOfItem(atPath: outURL.path)[.size] as? NSNumber)?.int64Value ?? 0
    print("wrote \(outURL.path) \(thumb.width)x\(thumb.height) \(fmtM(size)) ok=\(ok)")
    // Verify it reads back as the same size.
    if let check = CGImageSourceCreateWithURL(outURL as CFURL, nil),
       let back = CGImageSourceCreateImageAtIndex(check, 0, nil) {
        print("readback \(back.width)x\(back.height) bytesPerRow=\(back.bytesPerRow)")
    }
}


// MARK: - region decode: can a crop of a lazy CGImage be decoded without the whole stream?

func runCrop(_ args: [String]) async {
    guard let path = args.first else { print("usage: crop <file> [--row R] [--rows N] [--draw W]"); return }
    let startRow = Int(arg("--row", args) ?? "0") ?? 0
    let rows = Int(arg("--rows", args) ?? "1000") ?? 1000
    let drawW = Int(arg("--draw", args) ?? "0") ?? 0
    let sampler = MemSampler(); sampler.start()
    let s0 = Proc.snapshot()
    let t0 = now()
    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { print("decode failed"); return }
    let tLazy = now()
    var m = Measurement(name: "region decode: rows \(startRow)..<\(startRow + rows) of \(image.width)x\(image.height)")
    m.add("lazy_create", msInt(tLazy - t0))
    let rect = CGRect(x: 0, y: startRow, width: image.width, height: min(rows, image.height - startRow))
    // CGImage origin is top-left for cropped images produced this way.
    guard let cropped = image.cropping(to: rect) else { m.add("crop", "failed"); m.emit(); return }
    let tCrop = now()
    m.add("cropping(to:)", msInt(tCrop - tLazy))
    m.add("crop_size", "\(cropped.width)x\(cropped.height) \(fmtM(Int64(cropped.bytesPerRow) * Int64(cropped.height)))")
    if drawW > 0 {
        let (w, h) = fitSize(cropped.width, cropped.height, into: drawW)
        let r = forceDraw(cropped, width: w, height: h)
        m.add("draw_crop", "\(ms(r.seconds)) into \(w)x\(h)")
    } else {
        let r = forceDraw(cropped, width: cropped.width, height: cropped.height)
        m.add("draw_crop_native", "\(ms(r.seconds))")
    }
    m.add("total_until_crop_pixels_ready", ms(now() - t0))
    addResourceBlock(&m, t0: t0, snapshot0: s0, sampler: sampler)
    m.emit()
    sampler.stop()
}


// MARK: - DecodeCache semantics for a 5.86 GiB entry

func runCacheSem(_ args: [String]) async {
    guard let path = args.first else { print("usage: cachesem <file>"); return }
    let url = URL(fileURLWithPath: path)
    var m = Measurement(name: "DecodeCache semantics (totalCostLimit 384 MiB, countLimit 24)")
    let cache = DecodeCache()
    let decoder = ImageIODecoder()
    guard let head = try? await decoder.decodeFirstDisplayableFrame(url, target: .fullResolution) else {
        print("decode failed"); return
    }
    let cost = DecodeCache.cost(of: head.image)
    m.add("head_image", "\(head.image.width)x\(head.image.height)")
    m.add("cost_reported_by_production_calc", "\(fmtG(Int64(cost)))  (bytesPerRow x height)")
    m.add("cache_totalCostLimit", fmtM(384 * 1024 * 1024))
    m.add("cost_limit_ratio", String(format: "%.1fx over the limit", Double(cost) / Double(384 * 1024 * 1024)))
    cache.store(head: head, for: url)
    m.add("retrievable_after_store", cache.head(for: url) != nil ? "yes" : "NO — evicted immediately")
    // Raw NSCache behaviour with the same cost.
    let nc = NSCache<NSString, NSString>()
    nc.totalCostLimit = 384 * 1024 * 1024
    nc.countLimit = 24
    nc.setObject("x" as NSString, forKey: "k" as NSString, cost: cost)
    m.add("nscache_same_cost_retrievable", nc.object(forKey: "k" as NSString) != nil ? "yes" : "NO — evicted immediately")
    let nc2 = NSCache<NSString, NSString>()
    nc2.totalCostLimit = 384 * 1024 * 1024
    nc2.countLimit = 24
    nc2.setObject("x" as NSString, forKey: "k1" as NSString, cost: 6_144_000_000)
    nc2.setObject("x" as NSString, forKey: "k2" as NSString, cost: 6_144_000_000)
    nc2.setObject("x" as NSString, forKey: "k3" as NSString, cost: 6_144_000_000)
    m.add("three_oversized_entries", "k1=\(nc2.object(forKey: "k1" as NSString) != nil) k2=\(nc2.object(forKey: "k2" as NSString) != nil) k3=\(nc2.object(forKey: "k3" as NSString) != nil)")
    // Does the cached (lazy) head avoid re-decoding on a later draw?
    let t1 = now(); _ = forceDraw(head.image, width: 3200, height: 2133); let d1 = now() - t1
    let t2 = now(); _ = forceDraw(head.image, width: 3200, height: 2133); let d2 = now() - t2
    m.add("draw_after_cache_store", "first=\(ms(d1)) second=\(ms(d2))  -> cached entry holds a lazy reference, not pixels")
    m.emit()
}

// MARK: - orientation copy cost (production apply(orientation:))

func runRotCost(_ args: [String]) async {
    guard let path = args.first else { print("usage: rotcost <file> [--degrees 90|180|270]"); return }
    let degrees = Int(arg("--degrees", args) ?? "90") ?? 90
    let sampler = MemSampler(); sampler.start()
    let s0 = Proc.snapshot()
    let t0 = now()
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let img = CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else {
        print("decode failed"); return
    }
    _ = forceDraw(img, width: img.width, height: img.height)
    let tDecoded = now()
    let orientation: CGImagePropertyOrientation = degrees == 90 ? .right : (degrees == 180 ? .down : .left)
    let t1 = now()
    let rotated = ImageIODecoder.apply(orientation: orientation, to: img)
    let t2 = now()
    var m = Measurement(name: "production apply(orientation: .\(degrees)) — second full-size bitmap")
    m.add("input", "\(img.width)x\(img.height) \(fmtM(Int64(img.bytesPerRow) * Int64(img.height)))")
    m.add("decode_plus_materialise", ms(tDecoded - t0))
    m.add("apply_orientation_copy", "\(ms(t2 - t1)) -> \(rotated.map { "\($0.width)x\($0.height)" } ?? "nil")")
    m.add("peakFootprint_during_copy", fmtG(sampler.peakFootprint(after: t1)))
    addResourceBlock(&m, t0: t0, snapshot0: s0, sampler: sampler)
    m.emit()
    sampler.stop()
}

// MARK: - Metal texture upload cost

func runTexUp(_ args: [String]) async {
    guard let path = args.first, let maxPx = Int(args.dropFirst().first ?? "8192") else {
        print("usage: texup <file> <maxPx>"); return
    }
    guard let device = MTLCreateSystemDefaultDevice() else { print("no metal"); return }
    let sampler = MemSampler(); sampler.start()
    let s0 = Proc.snapshot()
    let t0 = now()
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let img = CGImageSourceCreateThumbnailAtIndex(src, 0, [
              kCGImageSourceThumbnailMaxPixelSize: maxPx,
              kCGImageSourceCreateThumbnailWithTransform: true,
              kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { print("thumb failed"); return }
    let tDecoded = now()
    var m = Measurement(name: "texture upload maxPx=\(maxPx) image=\(img.width)x\(img.height)")
    m.add("thumbnail_decode", ms(tDecoded - t0))
    let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm,
                                                       width: img.width, height: img.height, mipmapped: true)
    desc.usage = [.shaderRead]
    desc.storageMode = .shared
    guard let tex = device.makeTexture(descriptor: desc) else { m.add("texture", "ALLOCATION FAILED"); m.emit(); return }
    let cs = img.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
    guard let ctx = CGContext(data: nil, width: img.width, height: img.height, bitsPerComponent: 8,
                             bytesPerRow: img.width * 4, space: cs,
                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
    let tCtx = now()
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
    let tConv = now()
    tex.replace(region: MTLRegionMake2D(0, 0, img.width, img.height), mipmapLevel: 0,
                withBytes: ctx.data!, bytesPerRow: ctx.bytesPerRow)
    let tUpload = now()
    let queue = device.makeCommandQueue()!
    let cb = queue.makeCommandBuffer()!
    let blit = cb.makeBlitCommandEncoder()!
    blit.generateMipmaps(for: tex)
    blit.endEncoding()
    cb.commit()
    await cb.completed()
    let tMip = now()
    m.add("texture_bytes", fmtM(Int64(img.width) * Int64(img.height) * 4))
    m.add("cgcontext_draw(classic bitmap)", ms(tConv - tCtx))
    m.add("texture_replace(upload)", ms(tUpload - tConv))
    m.add("generate_mipmaps", ms(tMip - tUpload))
    m.add("total_to_gpu_ready", ms(tMip - t0))
    m.add("device_allocated_after", fmtM(Int64(device.currentAllocatedSize)))
    addResourceBlock(&m, t0: t0, snapshot0: s0, sampler: sampler)
    m.emit()
    sampler.stop()
}


// MARK: - which draws are cached? (same CGImage, different destinations)

func runDrawSeq(_ args: [String]) async {
    guard let path = args.first else { print("usage: drawseq <file>"); return }
    let sampler = MemSampler(); sampler.start()
    let s0 = Proc.snapshot()
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else { print("decode failed"); return }
    var m = Measurement(name: "draw sequence on one lazy CGImage (48000x32000)")
    let plan: [(String, Int, Int)] = [
        ("canvas fit 1600x1000pt retina", 3200, 2133),
        ("same again", 3200, 2133),
        ("navigator preview 336", 336, 224),
        ("sidebar 300", 300, 200),
        ("4096", 4096, 2731),
        ("canvas fit again", 3200, 2133),
    ]
    for (label, w, h) in plan {
        let t = now()
        let r = forceDraw(image, width: w, height: h)
        m.add(label, "\(ms(now() - t))  footprint=(\(fmtM(Proc.snapshot().footprint))) dest=\(fmtM(r.bitmapBytes))")
    }
    addResourceBlock(&m, t0: sampler.all().first?.t ?? now(), snapshot0: s0, sampler: sampler)
    m.emit()
    sampler.stop()
}


// MARK: - kCGImageSourceSubsampleFactor: bounded decode without a resample pass?

func runSubsample(_ args: [String]) async {
    guard let path = args.first, let factor = Int(args.dropFirst().first ?? "4") else {
        print("usage: subsample <file> <factor> [--draw]"); return
    }
    let sampler = MemSampler(); sampler.start()
    let s0 = Proc.snapshot()
    let t0 = now()
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { print("no source"); return }
    let opts: [CFString: Any] = [kCGImageSourceSubsampleFactor: factor,
                                kCGImageSourceShouldCacheImmediately: true]
    guard let img = CGImageSourceCreateImageAtIndex(src, 0, opts as CFDictionary) else {
        var m = Measurement(name: "subsample factor=\(factor)")
        m.add("result", "CreateImageAtIndex returned nil")
        m.emit(); return
    }
    let tCreate = now()
    var m = Measurement(name: "kCGImageSourceSubsampleFactor=\(factor)")
    m.add("createImage_return", ms(tCreate - t0))
    m.add("image", imageFacts(img))
    m.add("theoretical_reduction", "\(img.width) x \(img.height) = \(1.0 / (Double(img.width) / 48000.0 * Double(img.height) / 32000.0))x fewer pixels")
    let tDraw = now()
    _ = forceDraw(img, width: img.width, height: img.height)
    m.add("forced_draw", ms(now() - tDraw))
    m.add("total", ms(now() - t0))
    addResourceBlock(&m, t0: t0, snapshot0: s0, sampler: sampler)
    m.emit()
    sampler.stop()
}


// MARK: - A-series: materialization validation (A1 / A2 / A3)
//
// A1: CreateImageAtIndex (+ cache flags) -> publish lazy -> first draw pays decode
// A2: CreateThumbnailAtIndex(maxPixelSize: sourceLongEdge) -> publish -> draw
// A3: CreateImageAtIndex -> background CGContext materialize -> publish -> draw

enum MaterializeMode: String { case a1, a2, a3 }

@discardableResult
func materializeOnBackground(_ image: CGImage) -> (image: CGImage?, seconds: Double, bytes: Int64) {
    let t0 = now()
    let cs = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
    guard let ctx = makeContext(width: image.width, height: image.height, colorSpace: cs) else {
        return (nil, 0, 0)
    }
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    let out = ctx.makeImage()
    return (out, now() - t0, Int64(ctx.bytesPerRow) * Int64(ctx.height))
}

func runMatBench(_ args: [String]) async {
    guard let path = args.first, let modeArg = arg("--mode", args),
          let mode = MaterializeMode(rawValue: modeArg) else {
        print("usage: matbench <file> --mode a1|a2|a3 [--canvas 3200] [--pause-publish S] [--pause-draw S]")
        return
    }
    let canvasLong = Int(arg("--canvas", args) ?? "3200") ?? 3200
    let pausePublish = Double(arg("--pause-publish", args) ?? "0") ?? 0
    let pauseDraw = Double(arg("--pause-draw", args) ?? "0") ?? 0
    let url = URL(fileURLWithPath: path)
    let sizeBytes = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.int64Value ?? 0

    let sampler = MemSampler(); sampler.start()
    let s0 = Proc.snapshot()
    let t0 = now()
    var m = Measurement(name: "matbench mode=\(mode.rawValue) file=\(url.lastPathComponent) (\(fmtM(sizeBytes))) canvasLong=\(canvasLong)")
    m.add("pid", "\(getpid())")

    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { print("no source"); return }
    let tSource = now()

    var delivered: CGImage?
    var materializeSeconds = 0.0
    var materializeBytes: Int64 = 0

    switch mode {
    case .a1:
        let opts: [CFString: Any] = [kCGImageSourceShouldCache: true, kCGImageSourceShouldCacheImmediately: true]
        delivered = CGImageSourceCreateImageAtIndex(source, 0, opts as CFDictionary)
    case .a2:
        // Native-sized thumbnail request: deliberately exercises the "is this a
        // materialization shortcut?" question.
        if let probe = CGImageSourceCreateImageAtIndex(source, 0, nil) {
            let nativeLong = max(probe.width, probe.height)
            delivered = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: nativeLong,
            ] as CFDictionary)
        }
    case .a3:
        guard let lazy = CGImageSourceCreateImageAtIndex(source, 0, nil) else { break }
        let r = await Task.detached(priority: .userInitiated) { materializeOnBackground(lazy) }.value
        delivered = r.image
        materializeSeconds = r.seconds
        materializeBytes = r.bytes
    }

    guard let image = delivered else { m.add("result", "FAILED to deliver an image"); m.emit(); sampler.stop(); return }
    let tDelivered = now()
    let publishSnapshot = Proc.snapshot()
    m.add("source_create", msInt(tSource - t0))
    m.add("delivered_in", ms(tDelivered - t0))
    if mode == .a3 { m.add("background_materialize", "\(ms(materializeSeconds)) into \(fmtM(materializeBytes))") }
    m.add("delivered_image", imageFacts(image))
    m.add("footprint_at_publish", fmtM(publishSnapshot.footprint))
    m.add("source_cs_alphaInfo_before_after", "see delivered_image; source alphaInfo usually 3 (.last), thumbnails 2 (premultipliedFirst)")

    if pausePublish > 0 {
        print("PAUSE_AFTER_PUBLISH \(pausePublish)s pid=\(getpid()) footprint=\(fmtM(publishSnapshot.footprint))")
        try? await Task.sleep(nanoseconds: UInt64(pausePublish * 1_000_000_000))
    }

    // First renderer draw, at the app's canvas scale (Fit into canvasLong x canvasLong*0.625).
    let (dw, dh) = fitSize(image.width, image.height, into: canvasLong)
    let tDraw1 = now()
    let r1 = forceDraw(image, width: dw, height: dh)
    let tFirst = now()
    m.add("first_draw", "\(ms(tFirst - tDraw1)) dest=\(dw)x\(dh)")

    if pauseDraw > 0 {
        print("PAUSE_AFTER_FIRST_DRAW \(pauseDraw)s pid=\(getpid()) footprint=\(fmtM(Proc.snapshot().footprint))")
        try? await Task.sleep(nanoseconds: UInt64(pauseDraw * 1_000_000_000))
    }

    let tDraw2 = now()
    _ = forceDraw(image, width: dw, height: dh)
    let tSecond = now()
    m.add("second_draw_same_size", ms(tSecond - tDraw2))

    let (dw3, dh3) = fitSize(image.width, image.height, into: 4096)
    let tDraw3 = now()
    _ = forceDraw(image, width: dw3, height: dh3)
    let tThird = now()
    m.add("draw_different_size", "\(ms(tThird - tDraw3)) dest=\(dw3)x\(dh3)")

    m.add("first_draw_paid_a_decode", (tFirst - tDraw1) > 0.100 ? "YES (>100 ms)" : "no (<100 ms)")
    addResourceBlock(&m, t0: t0, snapshot0: s0, sampler: sampler)
    m.emit()
    sampler.stop()
    sampler.dumpCSV("/tmp/piclight-bench/out/matbench-\(mode.rawValue)-\(url.deletingPathExtension().lastPathComponent).csv")
}


// MARK: - E3: cache working-set behaviour with real bucket-sized entries
//
// Synthetic bitmaps with the exact byte sizes the bucket policy produces, so no
// 18 s PNG decode is needed to test cache retention semantics.

func syntheticHead(width: Int, height: Int) -> DecodedImageHead? {
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                              bytesPerRow: width * 4, space: cs,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
          let image = ctx.makeImage() else { return nil }
    let url = URL(fileURLWithPath: "/tmp/synthetic-\(width)x\(height).png")
    let descriptor = ImageDescriptor(sourceURL: url,
                                     pixelSize: CGSize(width: 48000, height: 32000),
                                     typeIdentifier: "public.png")
    return DecodedImageHead(image: image, descriptor: descriptor, metadata: ImageMetadata())
}

func runCachePlan(_ args: [String]) async {
    var m = Measurement(name: "E3 cache working set (DecodeCache: totalCostLimit 384 MiB, countLimit 24)")
    m.add("bucket_costs", "1024≈2.7MB 2048≈10.7MB 4096≈42.7MB 8192≈170.7MB native8192sq≈256MB")

    // Scenario 1: bounded-only design. current 8192 + preloads 4096/4096.
    do {
        let cache = DecodeCache()
        let cur = syntheticHead(width: 8192, height: 5461)!
        let p1 = syntheticHead(width: 4096, height: 2731)!
        let p2 = syntheticHead(width: 4096, height: 2731)!
        cache.store(head: cur, for: cur.descriptor.sourceURL)
        cache.store(head: p1, for: p1.descriptor.sourceURL)
        cache.store(head: p2, for: p2.descriptor.sourceURL)
        let curBytes = Int64(cur.image.bytesPerRow) * Int64(cur.image.height)
        m.add("S1_bounded_8192_plus_2x4096", "working_set=\(fmtM(curBytes + 2 * Int64(p1.image.bytesPerRow) * Int64(p1.image.height))) retrievable: current=\(cache.head(for: cur.descriptor.sourceURL) != nil) p1=\(cache.head(for: p1.descriptor.sourceURL) != nil) p2=\(cache.head(for: p2.descriptor.sourceURL) != nil)")
    }
    // Scenario 2: R4 native path with big native images. 8192x8192 (256 MB) x3.
    do {
        let cache = DecodeCache()
        let a = syntheticHead(width: 8192, height: 8192)!
        let b = syntheticHead(width: 8192, height: 8192)!
        let c = syntheticHead(width: 8192, height: 8192)!
        cache.store(head: a, for: a.descriptor.sourceURL)
        cache.store(head: b, for: b.descriptor.sourceURL)
        cache.store(head: c, for: c.descriptor.sourceURL)
        m.add("S2_native_8192sq_x3", "working_set=\(fmtM(3 * Int64(a.image.bytesPerRow) * Int64(a.image.height))) retrievable: a=\(cache.head(for: a.descriptor.sourceURL) != nil) b=\(cache.head(for: b.descriptor.sourceURL) != nil) c=\(cache.head(for: c.descriptor.sourceURL) != nil)")
    }
    // Scenario 3: mixed current-native 8192sq + neighbours 8192x5461
    do {
        let cache = DecodeCache()
        let cur = syntheticHead(width: 8192, height: 8192)!
        let n = syntheticHead(width: 8192, height: 5461)!
        cache.store(head: cur, for: cur.descriptor.sourceURL)
        cache.store(head: n, for: n.descriptor.sourceURL)
        let total = Int64(cur.image.bytesPerRow) * Int64(cur.image.height) + Int64(n.image.bytesPerRow) * Int64(n.image.height)
        m.add("S3_native_8192sq_plus_8192x5461", "working_set=\(fmtM(total)) retrievable: current=\(cache.head(for: cur.descriptor.sourceURL) != nil) neighbour=\(cache.head(for: n.descriptor.sourceURL) != nil)")
    }
    // Scenario 4: revisit after a purge-like eviction pressure (memory pressure notification)
    do {
        let cache = DecodeCache()
        let cur = syntheticHead(width: 8192, height: 5461)!
        cache.setCurrent(cur.descriptor.sourceURL)
        cache.store(head: cur, for: cur.descriptor.sourceURL)
        NotificationCenter.default.post(name: .decodeCacheMemoryPressure, object: nil)
        m.add("S4_after_memory_pressure", "current(8192) retrievable=\(cache.head(for: cur.descriptor.sourceURL) != nil) -> a purge keeps only the current image")
    }
    m.emit()
}


// MARK: - B-series: preload / cache policy arbitration
//
// Simulates the four candidate policies from spec §13.2 over navigation workloads.
// Cache identity is (url, level) by encoding the level in the cache key, which is
// what §6.3 will do in production. Decoded cost is the real bitmap byte size.

enum PreloadPolicy: String { case b0, b1, b2, b3, b4 }

struct LevelCache {
    let cache: DecodeCache
    // B3 enlarges the budget; the production default is 384 MiB.
    init(totalCostLimitMiB: Int) { cache = DecodeCache(totalCostLimit: totalCostLimitMiB * 1024 * 1024) }

    static func key(_ url: URL, _ level: Int) -> URL {
        // DecodeCache keys on url.path, so the level has to live in the path.
        URL(fileURLWithPath: url.path + "@level=\(level)")
    }
    func head(_ url: URL, _ level: Int) -> DecodedImageHead? { cache.head(for: Self.key(url, level)) }
    func store(_ head: DecodedImageHead, _ url: URL, _ level: Int) { cache.store(head: head, for: Self.key(url, level)) }
}

struct NavResult {
    var latencies: [Double] = []
    var hits = 0, misses = 0, decodes = 0
    var speculativeCPU = 0.0
    var speculativeEnergyMJ = 0.0
    var peakFootprint: Int64 = 0
    var maxConcurrent = 0
    var currentEvicted = 0
}

func probeLongEdge(_ url: URL) -> Int {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
          let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return 0 }
    let w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
    let h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
    return max(w, h)
}

func loadMaterialized(_ decoder: ImageIODecoder, _ url: URL) async -> DecodedImageHead? {
    guard let head = try? await decoder.decodeFirstDisplayableFrame(url, target: .fullResolution) else { return nil }
    // R4: normal-size images keep native resolution but must be materialized off-thread.
    let r = await Task.detached(priority: .userInitiated) { materializeOnBackground(head.image) }.value
    if let mat = r.image {
        return DecodedImageHead(image: mat, descriptor: head.descriptor, metadata: head.metadata)
    }
    return head
}

final class SpecCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _cpu = 0.0, _energy = 0.0, _issued = 0, _completed = 0, _skipped = 0
    private var _origins = Set<String>()
    func addCPU(_ x: Double, energy: Double, completed: Bool, key: String) {
        lock.lock(); _cpu += x; _energy += energy; _completed += (completed ? 1 : 0)
        if completed { _origins.insert(key) }
        lock.unlock()
    }
    func noteIssued() { lock.lock(); _issued += 1; lock.unlock() }
    func noteSkippedOversized() { lock.lock(); _skipped += 1; lock.unlock() }
    var cpu: Double { lock.lock(); defer { lock.unlock() }; return _cpu }
    var energyMJ: Double { lock.lock(); defer { lock.unlock() }; return _energy }
    var issued: Int { lock.lock(); defer { lock.unlock() }; return _issued }
    var completed: Int { lock.lock(); defer { lock.unlock() }; return _completed }
    var skipped: Int { lock.lock(); defer { lock.unlock() }; return _skipped }
    func wasSpeculative(_ key: String) -> Bool { lock.lock(); defer { lock.unlock() }; return _origins.contains(key) }
}

final class DimProbeCache: @unchecked Sendable {
    private let lock = NSLock()
    private var cache: [String: (Int, Int)] = [:]
    func dims(_ url: URL) -> (Int, Int) {
        lock.lock()
        if let c = cache[url.path] { lock.unlock(); return c }
        lock.unlock()
        var result = (0, 0)
        if let src = CGImageSourceCreateWithURL(url as CFURL, nil),
           let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] {
            let w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
            let h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
            result = (w, h)
        }
        lock.lock(); cache[url.path] = result; lock.unlock()
        return result
    }
}
let dimProbes = DimProbeCache()

func probeDims(_ url: URL) -> (Int, Int) { dimProbes.dims(url) }

func estimatedDecodedBytes(_ url: URL, level: Int) -> Int64 {
    let (w, h) = probeDims(url)
    let longEdge = max(w, h)
    if longEdge == 0 { return 0 }
    if longEdge <= level { return Int64(w) * Int64(h) * 4 }
    let scale = Double(level) / Double(longEdge)
    let bw = Int((Double(w) * scale).rounded()), bh = Int((Double(h) * scale).rounded())
    return Int64(bw) * Int64(bh) * 4
}

func runPreloadBench(_ args: [String]) async {
    guard let workloadArg = arg("--workload", args), let setArg = arg("--set", args) else {
        print("usage: preloadbench --workload N,N,N --set giant|normal|mixed [--canvas 4096] [--dwell 0.6]")
        return
    }
    let workload = workloadArg.split(separator: ",").compactMap { Int($0) }
    let level = Int(arg("--canvas", args) ?? "4096") ?? 4096
    let dwell = Double(arg("--dwell", args) ?? "0.6") ?? 0.6
    var urls: [URL] = []
    switch setArg {
    case "giant":
        urls = [URL(fileURLWithPath: benchGiantPath)]
    case "normal":
        urls = ["noise-4032x3024.png", "photo-4032x3024.jpg", "noise-6000x4000.png", "noise-8192x5461.png"]
            .map { URL(fileURLWithPath: "/tmp/piclight-bench/fixtures/\($0)") }
    case "big3":
        urls = ["noise-8192x8192.png", "noise-8192x5461.png", "noise-7000x7000.png"]
            .map { URL(fileURLWithPath: "/tmp/piclight-bench/fixtures/\($0)") }
    case "mixed":
        urls = [URL(fileURLWithPath: benchGiantPath),
                URL(fileURLWithPath: "\(benchFixtureDir)/noise-4032x3024.png"),
                URL(fileURLWithPath: "\(benchFixtureDir)/photo-4032x3024.jpg"),
                URL(fileURLWithPath: "\(benchFixtureDir)/noise-8192x5461.png")]
    default: break
    }
    let oversized = urls.map { max(probeDims($0).0, probeDims($0).1) > 8192 }
    print("### preloadbench set=\(setArg) workload=\(workload) level=\(level) dwell=\(dwell)s")
    print("images = " + zip(urls, oversized).map { "\($0.lastPathComponent)(dim=\(probeDims($0).0)x\(probeDims($0).1),over=\($1))" }.joined(separator: ", "))
    print(String(format: "%-4@ %9@ %6@ %6@ %7@ %6@ %9@ %9@ %9@ %9@ %7@ %7@",
                 "pol" as NSString, "lat_p50" as NSString, "hits" as NSString, "preHit" as NSString,
                 "misses" as NSString, "decod" as NSString, "specCPU_s" as NSString, "specE_mJ" as NSString,
                 "totE_mJ" as NSString, "peakMiB" as NSString, "skipOv" as NSString, "curEv" as NSString))
    for policy in [PreloadPolicy.b0, .b1, .b2, .b3, .b4] {
        let lc = LevelCache(totalCostLimitMiB: policy == .b3 ? 768 : 384)
        let decoder = ImageIODecoder()
        let counter = SpecCounter()
        let sampler = MemSampler(); sampler.start()
        let runStart = Proc.snapshot()
        var latencies: [Double] = []
        var hits = 0, preloadHits = 0, misses = 0, decodes = 0, currentEvicted = 0
        var peak: Int64 = 0
        var tasks: [Task<Void, Never>] = []

        for step in workload where step >= 0 && step < urls.count {
            let url = urls[step]
            let key = url.path + "@level=\(level)"
            let t0 = now()
            if let hit = lc.head(url, level) {
                hits += 1
                if counter.wasSpeculative(key) { preloadHits += 1 }
                _ = forceDraw(hit.image, width: 512, height: 512)
            } else {
                misses += 1
                if let head = await loadMaterialized(decoder, url) {
                    decodes += 1
                    lc.store(head, url, level)
                    _ = forceDraw(head.image, width: 512, height: 512)
                }
            }
            latencies.append(now() - t0)
            // was the on-screen image retained afterwards? (NSCache may evict under cost pressure)
            if lc.head(url, level) == nil { currentEvicted += 1 }

            // speculative preload for the neighbours
            var wanted: [(URL, Int)] = []
            let neighbours = [step - 1 >= 0 ? urls[step - 1] : nil, step + 1 < urls.count ? urls[step + 1] : nil].compactMap { $0 }
            switch policy {
            case .b0: break
            case .b1, .b3, .b2: wanted = neighbours.map { ($0, level) }
            case .b4: wanted = neighbours.map { ($0, max(1024, level / 2)) }
            }
            for (nurl, nlevel) in wanted {
                if let idx = urls.firstIndex(of: nurl), oversized[idx] {
                    counter.noteSkippedOversized()
                    continue
                }
                if policy == .b2 {
                    let currentBytes = estimatedDecodedBytes(url, level: level)
                    let specBytes = wanted.reduce(Int64(0)) { $0 + estimatedDecodedBytes($1.0, level: $1.1) }
                    if (currentBytes + specBytes) * 55 / 100 > 384 * 1024 * 1024 { continue }   // keep a 45 % margin
                }
                if lc.head(nurl, nlevel) != nil { continue }
                counter.noteIssued()
                let c0 = Proc.snapshot()
                let nkey = nurl.path + "@level=\(nlevel)"
                tasks.append(Task.detached(priority: .utility) { [lc] in
                    var ok = false
                    if let head = await loadMaterialized(decoder, nurl) {
                        lc.store(head, nurl, nlevel); ok = true
                    }
                    let c1 = Proc.snapshot()
                    counter.addCPU(c1.cpuSeconds - c0.cpuSeconds,
                                   energy: c1.energyMilliJoules - c0.energyMilliJoules,
                                   completed: ok, key: nkey)
                })
            }
            try? await Task.sleep(nanoseconds: UInt64(dwell * 1_000_000_000))
            peak = max(peak, Proc.snapshot().footprint)
        }
        for t in tasks { _ = await t.value }        // let them finish; their cost is already counted
        let runEnd = Proc.snapshot()
        sampler.stop()
        let p50 = latencies.isEmpty ? 0 : latencies.sorted()[latencies.count / 2 - 1]
        print(String(format: "%-4@ %8.3f %6d %6d %7d %6d %9.3f %9.0f %9.0f %9.0f %7d %7d",
                     policy.rawValue as NSString, p50, hits, preloadHits, misses, decodes,
                     counter.cpu, counter.energyMJ, runEnd.energyMilliJoules - runStart.energyMilliJoules,
                     Double(peak) / 1048576, counter.skipped, currentEvicted))
    }
    print("")
}

// MARK: - dispatch

let argv = Array(CommandLine.arguments.dropFirst())
guard let cmd = argv.first else {
    print("commands: create thumb orient ci pipeline thumbpipe cancel bands")
    exit(2)
}
let rest = Array(argv.dropFirst())
switch cmd {
case "create": await runCreate(rest)
case "thumb": await runThumb(rest)
case "orient": await runOrient(rest)
case "ci": await runCI(rest)
case "pipeline": await runPipeline(rest)
case "thumbpipe": await runThumbPipe(rest)
case "cancel": await runCancel(rest)
case "bands": await runBands(rest)
case "writebmp": await runWriteBMP(rest)
case "crop": await runCrop(rest)
case "cachesem": await runCacheSem(rest)
case "rotcost": await runRotCost(rest)
case "texup": await runTexUp(rest)
case "drawseq": await runDrawSeq(rest)
case "subsample": await runSubsample(rest)
case "matbench": await runMatBench(rest)
case "cacheplan": await runCachePlan(rest)
case "preloadbench": await runPreloadBench(rest)
default: print("unknown command \(cmd)")
}
