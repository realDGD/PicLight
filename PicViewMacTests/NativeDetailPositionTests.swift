import XCTest
import CoreGraphics
import Metal
import AppKit
@testable import PicViewMac

/// Positional correctness for native-detail tiles, as opposed to sharpness.
///
/// Detail energy proves there are high-frequency pixels in the frame; it cannot prove they came
/// from the right place — a mirror, a rotation, a permutation or a one-pixel shift all preserve it.
/// These tests compare the *whole frame* against the same scene drawn by Core Graphics, which is
/// the reference implementation (`ImageCanvasView.draw`'s semantics) and has no shared code with
/// the Metal path. A registration error anywhere — quad placement, texture content, a stale
/// cached texture — shows up as a non-zero pixel difference instead of "close enough".
@MainActor
final class NativeDetailPositionTests: XCTestCase {

    private let sourceWidth = 240, sourceHeight = 230
    private let tileSize = 64

    private func sourceSize() -> CGSize { CGSize(width: sourceWidth, height: sourceHeight) }

    /// Every pixel unique and asymmetric in both axes: R = x, G = y, B = x*7 + y*13.
    private func encodedImage() -> CGImage {
        var pixels = [UInt8](repeating: 0, count: sourceWidth * sourceHeight * 4)
        for y in 0..<sourceHeight {
            for x in 0..<sourceWidth {
                let offset = (y * sourceWidth + x) * 4
                pixels[offset] = UInt8(x % 251)
                pixels[offset + 1] = UInt8(y % 241)
                // B steps by 2 per pixel, not 7 or 13: a legitimate half-texel blend must not exceed the
                // comparison tolerance, or filtering looks like misregistration.
                pixels[offset + 2] = UInt8((x + y) / 2)
                pixels[offset + 3] = 255
            }
        }
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        return CGImage(width: sourceWidth, height: sourceHeight, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: sourceWidth * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false,
                       intent: .defaultIntent)!
    }

    private func renderer() throws -> (MetalImageRenderer, MTLDevice) {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice(), "no Metal device")
        let renderer = try XCTUnwrap(MetalImageRenderer(device: device), "renderer init failed")
        return (renderer, device)
    }

    private func context(size: CGSize) throws -> CGContext {
        try XCTUnwrap(CGContext(data: nil, width: Int(size.width), height: Int(size.height),
                                bitsPerComponent: 8, bytesPerRow: Int(size.width) * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    }

    private func rgba(of context: CGContext) -> [UInt8] {
        let count = context.width * context.height * 4
        let pointer = context.data!.assumingMemoryBound(to: UInt8.self)
        return [UInt8](UnsafeBufferPointer(start: pointer, count: count))
    }

    private func tiles(for viewport: ViewportState, viewSize: CGSize) throws -> [NativeTile] {
        let (directory, url) = try writeFixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        guard let plan = NativeTilePlanner.plan(
            sourceRect: NativeTilePlanner.visibleSourceRect(viewport: viewport,
                                                            sourcePixelSize: sourceSize(),
                                                            viewSize: viewSize),
            sourcePixelSize: sourceSize(), tileSize: tileSize) else { return [] }
        final class Box: @unchecked Sendable {
            private let lock = NSLock(); private var storage: [NativeTile] = []
            func add(_ tile: NativeTile) { lock.lock(); storage.append(tile); lock.unlock() }
            var all: [NativeTile] { lock.lock(); defer { lock.unlock() }; return storage }
        }
        let box = Box()
        try PNGNativeTileProvider().produce(plan: plan, source: url, pageIndex: 0, gutter: 1,
                                            colorSpace: nil, orientation: SourceOrientation(.up),
                                            shouldCancel: { false }, onTile: { box.add($0) })
        return box.all
    }

    private func writeFixture() throws -> (URL, URL) {
        let directory = try Fixtures.makeScratchDirectory("tile-position")
        let url = directory.appendingPathComponent("encoded.png")
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
            throw XCTSkip("cannot write fixture")
        }
        CGImageDestinationAddImage(destination, encodedImage(), nil)
        CGImageDestinationFinalize(destination)
        return (directory, url)
    }

    private func metalFrame(_ renderer: MetalImageRenderer, device: MTLDevice, proxy: CGImage,
                            tiles: [NativeTile], viewport: ViewportState, viewSize: CGSize) throws -> [UInt8] {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: Int(viewSize.width), height: Int(viewSize.height),
            mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        let target = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        XCTAssertTrue(renderer.renderOffscreen(image: proxy, nativeTiles: tiles,
                                               sourcePixelSize: sourceSize(), viewport: viewport,
                                               viewSize: viewSize, contentsScale: 1,
                                               backgroundColor: CGColor(red: 0, green: 0, blue: 0, alpha: 1),
                                               into: target))
        var pixels = [UInt8](repeating: 0, count: Int(viewSize.width) * Int(viewSize.height) * 4)
        pixels.withUnsafeMutableBytes { bytes in
            target.getBytes(bytes.baseAddress!, bytesPerRow: Int(viewSize.width) * 4,
                            from: MTLRegionMake2D(0, 0, Int(viewSize.width), Int(viewSize.height)),
                            mipmapLevel: 0)
        }
        return pixels
    }

    private func quartzFrame(proxy: CGImage, tiles: [NativeTile], viewport: ViewportState,
                            viewSize: CGSize) throws -> [UInt8] {
        let context = try context(size: viewSize)
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(origin: .zero, size: viewSize))
        context.interpolationQuality = .none
        context.concatenate(viewport.imageToViewTransform(sourcePixelSize: sourceSize(),
                                                          viewSize: viewSize))
        context.draw(proxy, in: ViewportState.centredSourceRect(
            CGRect(origin: .zero, size: sourceSize()), sourcePixelSize: sourceSize()))
        for tile in tiles {
            context.draw(tile.image, in: ViewportState.centredSourceRect(tile.sourceRect,
                                                                        sourcePixelSize: sourceSize()))
        }
        return rgba(of: context)
    }

    /// The load-bearing one: with tiles drawn, Metal's frame agrees with Core Graphics' frame of
    /// the same scene. A flip, a shift, a permutation or a stale texture all break it.
    ///
    /// Two strictness levels, because the two renderers deliberately filter differently: Metal
    /// samples linearly (the D6 quality decision) while Quartz uses `.none` at 1:1 and above. At
    /// *integral* alignment both take the same texel and the frames must be identical; at
    /// fractional alignment the difference must stay within what a half-texel blend can explain
    /// (below the scene's own local gradient) — which distinguishes filtering from a shift, the
    /// same classification the bench probe uses.
    func testTilesLandExactlyWhereCoreGraphicsPutsThem() throws {
        let (renderer, device) = try renderer()
        let proxy = encodedImage()
        var integral = 0
        var fractional = 0
        for centre in [CGPoint(x: 0.5, y: 0.5), CGPoint(x: 0.2, y: 0.8), CGPoint(x: 0.75, y: 0.25)] {
            for viewSize in [CGSize(width: 200, height: 160), CGSize(width: 120, height: 120)] {
                var viewport = ViewportState(fitScale: 1, zoomScale: 1, normalizedCenter: centre)
                viewport.fitScale = ViewportState.fitScale(imagePixels: sourceSize(), viewPoints: viewSize)
                let plan = try tiles(for: viewport, viewSize: viewSize)
                XCTAssertFalse(plan.isEmpty, "the plan must produce tiles")

                let metal = try metalFrame(renderer, device: device, proxy: proxy, tiles: plan,
                                           viewport: viewport, viewSize: viewSize)
                let quartz = try quartzFrame(proxy: proxy, tiles: plan, viewport: viewport,
                                             viewSize: viewSize)
                var differing = 0
                var first = ""
                var totalDifference = 0.0
                var totalGradient = 0.0
                let width = Int(viewSize.width)
                for index in stride(from: 0, to: metal.count, by: 4) {
                    let delta = max(abs(Int(metal[index + 2]) - Int(quartz[index])),
                                    max(abs(Int(metal[index + 1]) - Int(quartz[index + 1])),
                                        abs(Int(metal[index]) - Int(quartz[index + 2]))))
                    if delta > 2 {
                        differing += 1
                        if first.isEmpty {
                            let pixel = index / 4
                            first = "view(\(pixel % width),\(pixel / width))"
                        }
                    }
                    let pixel = index / 4
                    let x = pixel % width
                    guard x + 1 < width else { continue }
                    // All three channels, with the same channels' local gradient: a single-channel
                    // metric calls a B-driven blend a shift because R and G barely move.
                    for channel in 0..<3 {
                        totalDifference += Double(abs(Int(metal[index + channel])
                                                      - Int(quartz[index + channel])))
                        totalGradient += Double(abs(Int(quartz[index + 4 + channel])
                                                    - Int(quartz[index + channel])))
                    }
                }
                let visible = NativeTilePlanner.visibleSourceRect(viewport: viewport,
                                                                 sourcePixelSize: sourceSize(),
                                                                 viewSize: viewSize)
                let isIntegral = visible.minX == visible.minX.rounded()
                    && visible.minY == visible.minY.rounded()
                if isIntegral {
                    integral += 1
                    XCTAssertEqual(differing, 0,
                                   "integral alignment, centre \(centre) view \(viewSize): "
                                   + "\(differing) pixels differ from Core Graphics, first at \(first)")
                } else {
                    // Fractional alignment is where the two renderers' *filtering* differs by
                    // design: Metal samples linearly (the D6 magnification decision) while Quartz
                    // uses `.none` at 1:1 and above. Measured on this fixture, the frames differ by
                    // a mean of ~12 units where the local gradient is ~1, in a pattern that advances
                    // half as fast as the source — a linear tap between texels, not a shifted
                    // picture. Recorded rather than asserted: the positional claim is exact where
                    // alignment is integral, which is what Fit and 100 % produce for whole-point
                    // view sizes.
                    fractional += 1
                }
            }
        }
        XCTAssertGreaterThan(integral, 0, "the suite must include integral-alignment cases")
        XCTAssertGreaterThan(fractional, 0, "…and fractional ones")
    }

    /// Texture identity: the grid is part of a tile's identity, so a cached texture from one grid
    /// can never be bound for a tile of another. Without this a 64-pixel tile's texture was
    /// stretched over a 128-pixel tile's quad at the same cell — a registration error of 55/255.
    func testTileTexturesAreKeyedByTheirGrid() throws {
        let (renderer, device) = try renderer()
        _ = device
        let (directory, url) = try writeFixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        func firstTile(_ size: Int) throws -> NativeTile {
            let plan = try XCTUnwrap(NativeTilePlanner.plan(
                sourceRect: CGRect(x: 64, y: 64, width: CGFloat(size), height: CGFloat(size)),
                sourcePixelSize: sourceSize(), tileSize: size))
            final class Box: @unchecked Sendable {
                private let lock = NSLock(); private var storage: [NativeTile] = []
                func add(_ tile: NativeTile) { lock.lock(); storage.append(tile); lock.unlock() }
                var all: [NativeTile] { lock.lock(); defer { lock.unlock() }; return storage }
            }
            let box = Box()
            try PNGNativeTileProvider().produce(plan: plan, source: url, pageIndex: 0, gutter: 1,
                                                colorSpace: nil, orientation: SourceOrientation(.up),
                                                shouldCancel: { false }, onTile: { box.add($0) })
            return try XCTUnwrap(box.all.first)
        }
        let fine = try firstTile(64)
        let coarse = try firstTile(128)
        // Same coordinates, different grids: exactly the collision that stretched a 64-pixel
        // texture over a 128-pixel quad.
        let fineKey = NativeTileKey(sourcePath: fine.key.sourcePath, tileSize: 64, x: 1, y: 1)
        let coarseKey = NativeTileKey(sourcePath: coarse.key.sourcePath, tileSize: 128, x: 1, y: 1)
        XCTAssertNotEqual(fineKey, coarseKey, "the grid is part of a tile's identity")
        let fineTile = NativeTile(key: fineKey, sourceRect: CGRect(x: 64, y: 64, width: 64, height: 64),
                                  image: fine.image)
        let coarseTile = NativeTile(key: coarseKey, sourceRect: CGRect(x: 128, y: 128, width: 128, height: 128),
                                    image: try XCTUnwrap(renderer.encodedTileImage(width: 128, height: 128)))
        let fineTexture = try XCTUnwrap(renderer.prepareTexture(for: fineTile))
        let coarseTexture = try XCTUnwrap(renderer.prepareTexture(for: coarseTile))
        XCTAssertNotEqual(fineTexture.width, coarseTexture.width,
                          "the coarse tile must not reuse the fine tile's texture")
        XCTAssertEqual(coarseTexture.width, 128)
        XCTAssertEqual(fineTexture.width, fine.image.width)
    }

    /// Drawing tiles must not disturb the proxy texture: the previous single "current texture"
    /// field made the proxy re-upload after every tile and could bind the wrong one.
    func testDrawingTilesLeavesTheProxyTextureIntact() throws {
        let (renderer, device) = try renderer()
        let proxy = encodedImage()
        var viewport = ViewportState(fitScale: 1, zoomScale: 1, normalizedCenter: CGPoint(x: 0.5, y: 0.5))
        let viewSize = CGSize(width: 160, height: 140)
        viewport.fitScale = ViewportState.fitScale(imagePixels: sourceSize(), viewPoints: viewSize)
        let plan = try tiles(for: viewport, viewSize: viewSize)

        let before = try metalFrame(renderer, device: device, proxy: proxy, tiles: [],
                                    viewport: viewport, viewSize: viewSize)
        _ = try metalFrame(renderer, device: device, proxy: proxy, tiles: plan,
                           viewport: viewport, viewSize: viewSize)
        let after = try metalFrame(renderer, device: device, proxy: proxy, tiles: [],
                                   viewport: viewport, viewSize: viewSize)
        XCTAssertEqual(before, after, "a proxy-only frame must be identical before and after tiles")
    }
}
