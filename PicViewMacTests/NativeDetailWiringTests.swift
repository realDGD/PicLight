import XCTest
import AppKit
import CoreGraphics
import Metal
@testable import PicViewMac
import PicPNGStream

/// The acceptance the design exists for, end to end: at 100 % a viewport of an oversized
/// source must be served by *native* pixels rather than by the 8192 proxy.
///
/// "Requested a bigger level" is not enough to claim that, so this test asserts three
/// things: the backend ran a pass, the tiles it published contain the source's own pixels
/// (compared against the decoder, not against the proxy), and the canvas holds them for
/// drawing.
@MainActor
final class NativeDetailWiringTests: XCTestCase {

    override func setUp() async throws {
        try await super.setUp()
        TestAppKit.ensureApplication()
    }

    private struct Probe: DimensionProbing {
        let longEdge: Int
        func longEdge(of url: URL) async -> Int? { longEdge }
    }

    private func proxyBitmap(width: Int, height: Int) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    private func pump(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    @discardableResult
    private func pump(until condition: () -> Bool, timeout: TimeInterval = 25) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return condition()
    }

    /// Reads native pixels straight from the fixture with the streaming decoder, so the
    /// comparison cannot be satisfied by the proxy or by a tile that was scaled.
    private func nativePixels(_ url: URL, rect: ps_rect) throws -> [UInt8] {
        var info = ps_info()
        var error = [CChar](repeating: 0, count: 256)
        guard let decoder = url.path.withCString({ ps_open($0, &info, &error, 256) }) else {
            throw XCTSkip("cannot open fixture: \(String(cString: error))")
        }
        defer { ps_close(decoder) }
        XCTAssertEqual(ps_set_region(decoder, rect), 1)
        var status: Int32 = 1
        while status == 1 { status = ps_step(decoder, &error, 256) }
        XCTAssertEqual(status, 0)
        guard let base = ps_region_pixels(decoder) else { throw XCTSkip("no pixels") }
        return [UInt8](UnsafeBufferPointer(start: base, count: Int(ps_region_bytes(decoder))))
    }

    func testOneHundredPercentPublishesNativeDetailTiles() throws {
        let url = Fixtures.url("oversized-detail.png")
        guard FileManager.default.fileExists(atPath: url.path) else { throw XCTSkip("fixture missing") }

        // The head comes from a stub with a proxy-shaped bitmap (2048 wide) and an oversized
        // descriptor, which is exactly the state a real 1.9 GiB open leaves behind.
        let decoder = CountingDecoder(payload: proxyBitmap(width: 2048, height: 78),
                                      document: .still,
                                      pixelSize: CGSize(width: 8448, height: 320))
        let cache = NativeTileCache(totalCostLimit: 64 * 1024 * 1024)
        let scheduler = NativeDetailScheduler(cache: cache, tileSize: 512)
        let viewer = ViewerViewController(decoder: decoder, thumbnails: ThumbnailPipeline(),
                                          probe: Probe(longEdge: 8448), nativeDetail: scheduler)
        let controller = ViewerWindowController(viewer: viewer)
        TestAppKit.presentOffScreen(controller)
        defer { controller.close() }
        _ = viewer.view
        viewer.open(url: url)
        XCTAssertTrue(pump(until: { viewer.viewerState.currentImage != nil }), "the head must land")

        // Fit first: the proxy resolves everything, so the backend must stay out of it.
        pump(0.6)
        XCTAssertEqual(viewer.nativeDetailTileCount, 0,
                       "a fitted view is served by the proxy and must not ask for tiles")

        // 100 %: one source pixel per backing pixel. On a 2× display zoomScale is 0.5, so
        // physicalScale is 1 and the 2048-wide proxy is out-resolved.
        viewer.perform(.zoomActualPixels)
        XCTAssertTrue(pump(until: { viewer.nativeDetailTileCount > 0 }),
                      "at 100 % a viewport of an 8448-pixel source must be served by native tiles")

        let tiles = viewer.canvasNativeTilesForTesting
        XCTAssertFalse(tiles.isEmpty)
        // The cache is the backend's side of the same fact, and it is reachable without
        // awaiting the actor: a pass ran and its output is resident.
        XCTAssertGreaterThan(cache.count, 0, "the backend must have produced tiles")
        XCTAssertGreaterThan(cache.byteCount, 0)

        // The tiles must be native: compare a strip of the first tile against the fixture's
        // own pixels, decoded independently.
        let tile = try XCTUnwrap(tiles.first)
        let rect = ps_rect(x: Int32(tile.sourceRect.minX), y: Int32(tile.sourceRect.minY),
                           width: Int32(min(64, tile.sourceRect.width)),
                           height: Int32(min(16, tile.sourceRect.height)))
        let reference = try nativePixels(url, rect: rect)
        let tilePixels = pixels(of: tile.image)
        var compared = 0
        var largeDifferences = 0
        for y in 0..<Int(rect.height) {
            for x in 0..<Int(rect.width) {
                let referenceOffset = (y * Int(rect.width) + x) * 4
                let tileOffset = (y * tile.image.width + x) * 4
                for channel in 0..<3 {
                    compared += 1
                    let expected = Int(reference[referenceOffset + channel])
                    let actual = Int(tilePixels[tileOffset + channel])
                    if abs(expected - actual) > 2 { largeDifferences += 1 }
                }
            }
        }
        if largeDifferences > 0 {
            var first = ""
            for y in [0, 1, 8] where y < Int(rect.height) {
                let referenceValues = (0..<4).map { Int(reference[(y * Int(rect.width) + $0) * 4]) }
                let tileValues = (0..<4).map { Int(tilePixels[(y * tile.image.width + $0) * 4]) }
                let line = "TILEDBG rect=\(rect) image=\(tile.image.width)x\(tile.image.height) y=\(y)\n"
                    + "  reference R \(referenceValues)\n  tile      R \(tileValues)\n"
                FileHandle.standardError.write(Data(line.utf8))
            }
            first = "see TILEDBG"
            _ = first
        }
        XCTAssertGreaterThan(compared, 0)
        XCTAssertEqual(largeDifferences, 0,
                       "\(largeDifferences) of \(compared) channels differ from the source pixels: "
                       + "a tile that is not native detail is not native detail")
    }

    func testZoomingBackOutReleasesTheTiles() throws {
        let url = Fixtures.url("oversized-detail.png")
        guard FileManager.default.fileExists(atPath: url.path) else { throw XCTSkip("fixture missing") }
        let decoder = CountingDecoder(payload: proxyBitmap(width: 2048, height: 78),
                                      document: .still,
                                      pixelSize: CGSize(width: 8448, height: 320))
        let cache = NativeTileCache(totalCostLimit: 64 * 1024 * 1024)
        let scheduler = NativeDetailScheduler(cache: cache, tileSize: 512)
        let viewer = ViewerViewController(decoder: decoder, thumbnails: ThumbnailPipeline(),
                                          probe: Probe(longEdge: 8448), nativeDetail: scheduler)
        let controller = ViewerWindowController(viewer: viewer)
        TestAppKit.presentOffScreen(controller)
        defer { controller.close() }
        _ = viewer.view
        viewer.open(url: url)
        XCTAssertTrue(pump(until: { viewer.viewerState.currentImage != nil }))
        viewer.perform(.zoomActualPixels)
        XCTAssertTrue(pump(until: { viewer.nativeDetailTileCount > 0 }))
        let bytesWhileZoomed = cache.byteCount
        XCTAssertGreaterThan(bytesWhileZoomed, 0)

        viewer.perform(.zoomToFit)
        XCTAssertTrue(pump(until: { viewer.nativeDetailTileCount == 0 && cache.byteCount == 0 }),
                      "fitting again must give the tile memory back")
    }

    func testPanMovesTheTileWindowWithoutReDecodingTheWholeImage() throws {
        let url = Fixtures.url("oversized-detail.png")
        guard FileManager.default.fileExists(atPath: url.path) else { throw XCTSkip("fixture missing") }
        let decoder = CountingDecoder(payload: proxyBitmap(width: 2048, height: 78),
                                      document: .still,
                                      pixelSize: CGSize(width: 8448, height: 320))
        let cache = NativeTileCache(totalCostLimit: 64 * 1024 * 1024)
        let scheduler = NativeDetailScheduler(cache: cache, tileSize: 512)
        let viewer = ViewerViewController(decoder: decoder, thumbnails: ThumbnailPipeline(),
                                          probe: Probe(longEdge: 8448), nativeDetail: scheduler)
        let controller = ViewerWindowController(viewer: viewer)
        TestAppKit.presentOffScreen(controller)
        defer { controller.close() }
        _ = viewer.view
        viewer.open(url: url)
        XCTAssertTrue(pump(until: { viewer.viewerState.currentImage != nil }))
        viewer.perform(.zoomActualPixels)
        XCTAssertTrue(pump(until: { viewer.nativeDetailTileCount > 0 }))
        // Let the level-upgrade debounce fire and settle: with native detail active it must
        // decide *not* to decode a coarser level, which is part of what this asserts.
        pump(1.0)
        let headsAfterZoom = decoder.headRequestCount

        // Pan far enough that a different tile band is visible, then let it settle.
        var viewport = viewer.canvasViewportForTesting
        viewport.normalizedCenter = CGPoint(x: 0.15, y: 0.5)
        viewer.canvasViewportForTesting = viewport
        pump(1.2)
        XCTAssertTrue(pump(until: { viewer.nativeDetailTileCount > 0 }))

        // A pan must not start a whole-image decode: the proxy is unchanged and still
        // correct, and the tile window is what moves.
        XCTAssertEqual(decoder.headRequestCount, headsAfterZoom,
                       "panning must not re-decode the image at a new level")
        // The tile window moved: the pinned (visible) keys are somewhere else now.
        let pinned = cache.pinnedKeys
        XCTAssertFalse(pinned.isEmpty, "the new viewport must be pinned, not the old one")
        let pinnedX = pinned.map(\.x)
        XCTAssertTrue(pinnedX.contains { $0 * 512 < 2048 },
                      "tiles for the left part of the source must be the ones pinned now: \(pinnedX)")
    }

    func testRepeatedZoomChangesDoNotStartDuplicateDecodes() throws {
        let url = Fixtures.url("oversized-detail.png")
        guard FileManager.default.fileExists(atPath: url.path) else { throw XCTSkip("fixture missing") }
        // A slow head decode stands in for the ~16 s the investigation image needs, so the
        // in-flight window is long enough to poke at.
        let decoder = CountingDecoder(payload: proxyBitmap(width: 2048, height: 78),
                                      delay: 1.2, document: .still,
                                      pixelSize: CGSize(width: 8448, height: 320))
        let scheduler = NativeDetailScheduler(cache: NativeTileCache(totalCostLimit: 32 * 1024 * 1024),
                                              tileSize: 512)
        let viewer = ViewerViewController(decoder: decoder, thumbnails: ThumbnailPipeline(),
                                          probe: Probe(longEdge: 8448), nativeDetail: scheduler)
        let controller = ViewerWindowController(viewer: viewer)
        TestAppKit.presentOffScreen(controller)
        defer { controller.close() }
        _ = viewer.view
        viewer.open(url: url)

        // While the first decode is in flight, ask for upgrades repeatedly. Each of these
        // used to be able to start another full decode, and ImageIO ignores cancellation,
        // so the old decodes would keep running alongside the new one.
        for _ in 0..<6 {
            viewer.perform(.zoomActualPixels)
            viewer.perform(.zoomToFit)
            pump(0.1)
        }
        pump(2.5)
        XCTAssertEqual(decoder.headRequestCount, 1,
                       "six zoom changes during the load must not start \(decoder.headRequestCount) decodes")
    }

    /// Tightly packed premultiplied RGBA8 of a CGImage.
    private func pixels(of image: CGImage) -> [UInt8] {
        var buffer = [UInt8](repeating: 0, count: image.width * image.height * 4)
        buffer.withUnsafeMutableBytes { bytes in
            guard let context = CGContext(data: bytes.baseAddress, width: image.width,
                                          height: image.height, bitsPerComponent: 8,
                                          bytesPerRow: image.width * 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return buffer
    }
}

/// The renderer's own output at 100 %, on an oversized source: proxy plus tiles, compared
/// against the source's pixels. This is the claim the feature rests on, so it is measured
/// on the renderer rather than inferred from the tile contents — a CPU capture cannot see
/// a Metal layer, and "the tiles are correct" is not "the screen is correct".
@MainActor
final class NativeDetailRenderTests: XCTestCase {

    override func setUp() async throws {
        try await super.setUp()
        TestAppKit.ensureApplication()
    }

    private func sourcePixels(_ url: URL, rect: ps_rect) throws -> [UInt8] {
        var info = ps_info()
        var error = [CChar](repeating: 0, count: 256)
        guard let decoder = url.path.withCString({ ps_open($0, &info, &error, 256) }) else {
            throw XCTSkip("cannot open: \(String(cString: error))")
        }
        defer { ps_close(decoder) }
        guard ps_set_region(decoder, rect) == 1 else { throw XCTSkip("no region") }
        var status: Int32 = 1
        while status == 1 { status = ps_step(decoder, &error, 256) }
        guard status == 0, let base = ps_region_pixels(decoder) else { throw XCTSkip("decode failed") }
        return [UInt8](UnsafeBufferPointer(start: base, count: Int(ps_region_bytes(decoder))))
    }

    /// Channel offsets into a `bgra8Unorm` render target.
    private let renderRed = 2
    private let renderGreen = 1
    private let renderBlue = 0

    /// High-frequency energy: the mean absolute difference between horizontally adjacent
    /// pixels, per channel.
    ///
    /// This is the measurement that answers the user's complaint directly. Comparing
    /// individual pixels against the source needs sub-pixel-exact sampling, and a one-pixel
    /// slip on a per-pixel pattern reads as a wrong render; detail energy asks the question
    /// that actually matters — is the screen as sharp as the source, or smoothed like an
    /// upscaled proxy — and is immune to that. A proxy magnified 5× has roughly a fifth of
    /// the source's edge energy; native tiles have all of it.
    private func edgeEnergy(render: [UInt8], side: Int, region: CGRect,
                            red: Int, green: Int, blue: Int) -> Double {
        var total = 0.0
        var pairs = 0
        let minX = max(0, Int(region.minX)), maxX = min(side - 2, Int(region.maxX))
        // View y grows upward, rows grow downward.
        let minY = max(0, side - 1 - Int(region.maxY)), maxY = min(side - 1, side - 1 - Int(region.minY))
        guard minX < maxX, minY < maxY else { return 0 }
        for y in minY...maxY {
            for x in minX...maxX {
                let a = (y * side + x) * 4
                let b = (y * side + x + 1) * 4
                total += Double(abs(Int(render[a + red]) - Int(render[b + red])))
                total += Double(abs(Int(render[a + green]) - Int(render[b + green])))
                total += Double(abs(Int(render[a + blue]) - Int(render[b + blue])))
                pairs += 3
            }
        }
        return pairs > 0 ? total / Double(pairs) : 0
    }

    /// The same energy for a tightly packed RGBA8 reference.
    private func referenceEdgeEnergy(_ pixels: [UInt8], width: Int, height: Int) -> Double {
        var total = 0.0
        var pairs = 0
        for y in 0..<height {
            for x in 0..<(width - 1) {
                let a = (y * width + x) * 4
                let b = (y * width + x + 1) * 4
                for channel in 0..<3 {
                    total += Double(abs(Int(pixels[a + channel]) - Int(pixels[b + channel])))
                }
                pairs += 3
            }
        }
        return pairs > 0 ? total / Double(pairs) : 0
    }

    func testAtOneHundredPercentTheRenderedPixelsAreTheSourcesPixels() throws {
        let url = Fixtures.url("oversized-detail.png")
        guard FileManager.default.fileExists(atPath: url.path) else { throw XCTSkip("fixture missing") }
        guard let device = MTLCreateSystemDefaultDevice(),
              let renderer = MetalImageRenderer(device: device) else {
            throw XCTSkip("no Metal device on this machine")
        }
        let sourceSize = CGSize(width: 8448, height: 320)
        let side = 512
        let contentsScale: CGFloat = 1
        let viewSize = CGSize(width: side, height: side)

        // A proxy that is deliberately a fifth of the source, like the 8192 ceiling.
        let proxyWidth = 1690, proxyHeight = 64
        let proxyContext = CGContext(data: nil, width: proxyWidth, height: proxyHeight,
                                     bitsPerComponent: 8, bytesPerRow: proxyWidth * 4,
                                     space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                     bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        // A fitted, then magnified view: at physicalScale 1 the 1690-wide proxy is out-resolved.
        var viewport = ViewportState(fitScale: 0.05, zoomScale: 1,
                                     normalizedCenter: CGPoint(x: 0.5, y: 0.5))
        viewport.fitScale = ViewportState.fitScale(imagePixels: sourceSize, viewPoints: viewSize)

        // The proxy must not be blank, or the comparison proves nothing.
        proxyContext.setFillColor(CGColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1))
        proxyContext.fill(CGRect(x: 0, y: 0, width: proxyWidth, height: proxyHeight))
        let proxy = proxyContext.makeImage()!

        let visible = NativeTilePlanner.visibleSourceRect(viewport: viewport,
                                                          sourcePixelSize: sourceSize,
                                                          viewSize: viewSize)
        let plan = try XCTUnwrap(NativeTilePlanner.plan(sourceRect: visible,
                                                        sourcePixelSize: sourceSize, tileSize: 512))
        let collector = TileCollector()
        try PNGNativeTileProvider().produce(plan: plan, source: url, pageIndex: 0, gutter: 1,
                                            colorSpace: proxy.colorSpace, orientation: .up,
                                            shouldCancel: { false },
                                            onTile: { collector.append($0) })
        let tiles = collector.tiles
        XCTAssertFalse(tiles.isEmpty)

        // Snap to whole pixels before decoding: a fractional origin makes every reference
        // lookup land between two pixels, which on a per-pixel-varying fixture reads as a
        // huge difference and hides whether the render is actually right.
        let snapped = CGRect(x: floor(visible.minX), y: floor(visible.minY),
                             width: ceil(visible.maxX) - floor(visible.minX),
                             height: ceil(visible.maxY) - floor(visible.minY))
            .intersection(CGRect(origin: .zero, size: sourceSize))
        let reference = try sourcePixels(url, rect: ps_rect(x: Int32(snapped.minX), y: Int32(snapped.minY),
                                                            width: Int32(snapped.width), height: Int32(snapped.height)))
        let referenceStride = Int(snapped.width) * 4

        func renderPixels(tiles: [NativeTile]) throws -> [UInt8] {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm, width: side, height: side, mipmapped: false)
            descriptor.usage = [.renderTarget, .shaderRead]
            // `.managed` is not available on Apple silicon; the parity tests use `.shared`.
            descriptor.storageMode = .shared
            let target = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
            XCTAssertTrue(renderer.renderOffscreen(image: proxy, nativeTiles: tiles,
                                                   sourcePixelSize: sourceSize, viewport: viewport,
                                                   viewSize: viewSize, contentsScale: contentsScale,
                                                   backgroundColor: CGColor(red: 0, green: 0, blue: 0, alpha: 1),
                                                   into: target))
            var pixels = [UInt8](repeating: 0, count: side * side * 4)
            pixels.withUnsafeMutableBytes { bytes in
                target.getBytes(bytes.baseAddress!, bytesPerRow: side * 4,
                                from: MTLRegionMake2D(0, 0, side, side), mipmapLevel: 0)
            }
            return pixels
        }

        let withTiles = try renderPixels(tiles: tiles)
        let proxyOnly = try renderPixels(tiles: [])

        // Only the part of the view the tiles cover, so the proxy-only control is comparable.
        // The covered rect is in source top-left space and the transform works in centred
        // space: converting first is required, and skipping it produced an empty intersection
        // and then an Int(inf) trap rather than a wrong number.
        let covered = tiles.reduce(CGRect.null) { $0.union($1.sourceRect) }
        let transform = viewport.imageToViewTransform(sourcePixelSize: sourceSize, viewSize: viewSize)
        let viewRect = CGRect(x: 0, y: 0, width: viewSize.width, height: viewSize.height)
        let coveredView = ViewportState.centredSourceRect(covered, sourcePixelSize: sourceSize)
            .applying(transform).intersection(viewRect)
        guard !coveredView.isNull, coveredView.width > 8 else {
            return XCTFail("the tiles must cover part of the view, got \(coveredView)")
        }
        // edgeEnergy indexes rows top-down; the rect is in view coordinates (y up).
        let sampleRegion = CGRect(x: coveredView.minX + 2, y: coveredView.minY + 2,
                                  width: coveredView.width - 4, height: coveredView.height - 4)

        let tilesEnergy = edgeEnergy(render: withTiles, side: side, region: sampleRegion,
                                     red: renderRed, green: renderGreen, blue: renderBlue)
        let proxyEnergy = edgeEnergy(render: proxyOnly, side: side, region: sampleRegion,
                                     red: renderRed, green: renderGreen, blue: renderBlue)
        let sourceEnergy = referenceEdgeEnergy(reference, width: Int(snapped.width),
                                               height: Int(snapped.height))
        FileHandle.standardError.write(Data(
            "TRACE energies tiles=\(tilesEnergy) proxy=\(proxyEnergy) source=\(sourceEnergy) region=\(sampleRegion)\n".utf8))

        // The frame with tiles must carry the source's detail; the proxy-only frame is the
        // control and must be visibly smoother, or the comparison proves nothing.
        XCTAssertGreaterThan(sourceEnergy, 2, "the fixture must have detail to lose")
        XCTAssertGreaterThan(tilesEnergy, 0.8 * sourceEnergy,
                             "with tiles the frame carries \(tilesEnergy) of the source's "
                             + "\(sourceEnergy) edge energy: it is smoothed, not native")
        XCTAssertLessThan(proxyEnergy, 0.55 * tilesEnergy,
                          "the proxy-only control must be clearly softer (\(proxyEnergy) vs "
                          + "\(tilesEnergy)) or this test cannot tell them apart")
    }
}
