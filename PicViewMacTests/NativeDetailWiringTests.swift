import XCTest
import AppKit
import CoreGraphics
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
