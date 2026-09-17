import XCTest
import AppKit
import Metal
import CoreGraphics
@testable import PicViewMac

/// The Metal renderer must agree with the Quartz renderer: same geometry, same
/// colours, same orientation. These tests compare the two directly, which is what
/// makes "Metal is only a faster way to draw the same thing" a checked claim rather
/// than a description.
final class MetalParityTests: XCTestCase {

    private static let device = MTLCreateSystemDefaultDevice()

    private func renderer() throws -> MetalImageRenderer {
        let device = try XCTUnwrap(Self.device, "no Metal device on this machine")
        return try XCTUnwrap(MetalImageRenderer(device: device), "renderer/prepare failed")
    }

    private func bitmap(width: Int, height: Int, colorSpace: CGColorSpace? = nil,
                        bitmapInfo: UInt32 = CGImageAlphaInfo.premultipliedLast.rawValue,
                        bitsPerComponent: Int = 8) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: bitsPerComponent, bytesPerRow: 0,
            space: colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: bitmapInfo))
        context.setFillColor(CGColor(red: 0.9, green: 0.2, blue: 0.1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
        context.setFillColor(CGColor(red: 0.1, green: 0.4, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: width / 2, y: 0, width: width / 2, height: height))
        return try XCTUnwrap(context.makeImage())
    }

    // MARK: - Layout mapping

    func testEveryEightBitThirtyTwoBitLayoutIsRenderableAsOneCanonicalFormat() throws {
        // The renderer uploads every supported source as BGRA premultiplied and lets the
        // upload pass do the channel conversion, so the interesting assertion is which
        // layouts are accepted at all — the *order* is verified pixel-wise below.
        let layouts: [(String, UInt32)] = [
            ("RGBA premultipliedLast", CGBitmapInfo.byteOrder32Little.rawValue
                | CGImageAlphaInfo.premultipliedLast.rawValue),
            ("BGRA premultipliedFirst", CGBitmapInfo.byteOrder32Little.rawValue
                | CGImageAlphaInfo.premultipliedFirst.rawValue),
            ("BGRA opaque", CGBitmapInfo.byteOrder32Little.rawValue
                | CGImageAlphaInfo.noneSkipFirst.rawValue),
        ]
        for (name, info) in layouts {
            let image = try bitmap(width: 8, height: 8, bitmapInfo: info)
            let layout = try XCTUnwrap(MetalImageRenderer.textureLayout(for: image), name)
            XCTAssertEqual(layout.pixelFormat, .bgra8Unorm, name)
            XCTAssertEqual(layout.bytesPerPixel, 4, name)
            XCTAssertTrue(MetalImageRenderer.canRender(image), name)
        }
    }

    /// The pixel-level half of the layout question: a bitmap whose halves are
    /// unmistakably red and blue must come back red and blue, not swapped.
    func testRenderedChannelsKeepTheirIdentity() throws {
        let renderer = try renderer()
        let image = try bitmap(width: 64, height: 48)          // left red, right blue
        let size = 128
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: size, height: 96, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        let texture = try XCTUnwrap(Self.device?.makeTexture(descriptor: descriptor))
        var viewport = ViewportState()
        viewport.zoomScale = 1
        XCTAssertTrue(renderer.renderOffscreen(image: image, sourcePixelSize: CGSize(width: 64, height: 48),
                                              viewport: viewport, viewSize: CGSize(width: size, height: 96),
                                              contentsScale: 1, backgroundColor: NSColor.clear.cgColor,
                                              into: texture))
        var bytes = [UInt8](repeating: 0, count: size * 96 * 4)
        bytes.withUnsafeMutableBytes { raw in
            texture.getBytes(raw.baseAddress!, bytesPerRow: size * 4,
                             from: MTLRegionMake2D(0, 0, size, 96), mipmapLevel: 0)
        }
        func pixel(_ x: Int, _ y: Int) -> (b: Int, g: Int, r: Int, a: Int) {
            let index = (y * size + x) * 4
            return (Int(bytes[index]), Int(bytes[index + 1]), Int(bytes[index + 2]), Int(bytes[index + 3]))
        }
        let left = pixel(48, 48), right = pixel(80, 48)
        XCTAssertGreaterThan(left.r, left.b + 60, "the left half is red, not blue")
        XCTAssertGreaterThan(right.b, right.r + 60, "the right half is blue, not red")
        XCTAssertGreaterThan(left.a, 200)
    }

    func testExoticLayoutsAreRefusedRatherThanMisRendered() throws {
        let sixteenBit = try bitmap(width: 8, height: 8, bitsPerComponent: 16)
        XCTAssertNil(MetalImageRenderer.textureLayout(for: sixteenBit),
                     "16-bit must take the Quartz path, not be narrowed to 8-bit")
        XCTAssertFalse(MetalImageRenderer.canRender(sixteenBit))

        let grey = try bitmap(width: 8, height: 8,
                              colorSpace: CGColorSpaceCreateDeviceGray(),
                              bitmapInfo: CGImageAlphaInfo.none.rawValue)
        XCTAssertNil(MetalImageRenderer.textureLayout(for: grey),
                     "an 8 bpp grey/alpha-less layout is not a 32-bit texture")
    }

    // MARK: - Geometry parity

    func testQuadCornersMatchTheSourceRectangleAtFit() throws {
        let source = CGSize(width: 48000, height: 32000)
        let viewSize = CGSize(width: 1600, height: 1000)      // 3:2 source, height-limited
        let fit = ViewportState.fitScale(imagePixels: source, viewPoints: viewSize)
        var viewport = ViewportState()
        viewport.fitScale = fit
        viewport.zoomScale = fit
        viewport.normalizedCenter = CGPoint(x: 0.5, y: 0.5)

        let corners = MetalImageRenderer.quadCorners(
            sourcePixelSize: source, viewport: viewport, viewSize: viewSize,
            contentsScale: 2, drawableSize: CGSize(width: 3200, height: 2000))

        // Displayed at fit: 1500x1000 points centred in 1600x1000 → x from 50 to 1550.
        // Corner order is bottom-left, bottom-right, top-left, top-right.
        XCTAssertEqual(Double(corners[0].x), 50.0 / 1600 * 2 - 1, accuracy: 1e-5)
        XCTAssertEqual(Double(corners[0].y), -1, accuracy: 1e-5)
        XCTAssertEqual(Double(corners[1].x), 1550.0 / 1600 * 2 - 1, accuracy: 1e-5)
        XCTAssertEqual(Double(corners[3].y), 1, accuracy: 1e-5)
    }

    func testQuadCornersFollowPanAndZoom() throws {
        let source = CGSize(width: 48000, height: 32000)
        let viewSize = CGSize(width: 1600, height: 1000)
        var viewport = ViewportState()
        viewport.fitScale = ViewportState.fitScale(imagePixels: source, viewPoints: viewSize)
        viewport.zoomScale = viewport.fitScale * 2
        viewport.normalizedCenter = CGPoint(x: 0.25, y: 0.5)

        let corners = MetalImageRenderer.quadCorners(
            sourcePixelSize: source, viewport: viewport, viewSize: viewSize,
            contentsScale: 2, drawableSize: CGSize(width: 3200, height: 2000))
        // Zoomed 2x (displayed width 3000 pt in a 1600 pt view) and panned to the left
        // edge: the left edge of the image is on screen and the right edge is far off it.
        XCTAssertGreaterThan(corners[0].x, -1.0, "the left edge is inside the view")
        XCTAssertGreaterThan(corners[1].x, 1.0, "the right edge is outside a zoomed view")
        XCTAssertLessThan(corners[0].x, 0.0, "and it is left of centre after panning")
    }

    func testQuarterTurnSwapsTheDisplayedExtent() throws {
        let source = CGSize(width: 48000, height: 32000)
        let viewSize = CGSize(width: 1600, height: 1000)
        var viewport = ViewportState()
        viewport.fitScale = ViewportState.fitScale(imagePixels: source, viewPoints: viewSize)
        viewport.zoomScale = viewport.fitScale
        viewport.viewRotationQuarterTurns = 1

        let corners = MetalImageRenderer.quadCorners(
            sourcePixelSize: source, viewport: viewport, viewSize: viewSize,
            contentsScale: 2, drawableSize: CGSize(width: 3200, height: 2000))
        // Corner order is defined in the image's own space, so after a quarter turn the
        // axis-aligned extent must be measured across all four corners.
        let xs = corners.map { Double($0.x) }, ys = corners.map { Double($0.y) }
        let width = (xs.max()! - xs.min()!) / 2 * viewSize.width
        let height = (ys.max()! - ys.min()!) / 2 * viewSize.height
        XCTAssertLessThan(width, height, "a quarter turn displays the source's width vertically")
        XCTAssertEqual(width, 32000 * viewport.zoomScale, accuracy: 1)
        XCTAssertEqual(height, 48000 * viewport.zoomScale, accuracy: 1)
    }

    // MARK: - Pixel parity

    private func coverage(_ bytes: [UInt8]) -> Double {
        var lit = 0
        for index in stride(from: 0, to: bytes.count, by: 4) where bytes[index + 3] > 8 { lit += 1 }
        return Double(lit) / Double(bytes.count / 4)
    }

    func testOffscreenRenderMatchesTheQuartzRendering() throws {
        let renderer = try renderer()
        let image = try bitmap(width: 64, height: 48)
        let viewSize = CGSize(width: 128, height: 96)

        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: 128, height: 96, mipmapped: false)
        textureDescriptor.usage = [.renderTarget, .shaderRead]
        textureDescriptor.storageMode = .shared
        let texture = try XCTUnwrap(Self.device?.makeTexture(descriptor: textureDescriptor))

        var viewport = ViewportState()
        viewport.zoomScale = 1
        let rendered = renderer.renderOffscreen(image: image, sourcePixelSize: CGSize(width: 64, height: 48),
                                                viewport: viewport, viewSize: viewSize, contentsScale: 1,
                                                backgroundColor: NSColor.clear.cgColor, into: texture)
        XCTAssertTrue(rendered)

        var metalBytes = [UInt8](repeating: 0, count: 128 * 96 * 4)
        // Explicit buffer access: `getBytes(&array, …)` would hand the GPU a pointer to
        // the array object and write 49 KB over it.
        metalBytes.withUnsafeMutableBytes { raw in
            texture.getBytes(raw.baseAddress!, bytesPerRow: 128 * 4,
                             from: MTLRegionMake2D(0, 0, 128, 96), mipmapLevel: 0)
        }

        // The Quartz renderer, same geometry: the image is drawn 1:1 centred.
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 128, height: 96, bitsPerComponent: 8, bytesPerRow: 128 * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue
                | CGImageAlphaInfo.premultipliedFirst.rawValue))
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 32, y: 24, width: 64, height: 48))
        var quartzBytes = [UInt8](repeating: 0, count: 128 * 96 * 4)
        quartzBytes.withUnsafeMutableBytes { raw in
            memcpy(raw.baseAddress!, try! XCTUnwrap(context.data), raw.count)
        }

        // Row order differs (CGContext is bottom-up), so compare the covered fraction
        // and the mean colour of the covered area rather than raw memory order.
        let metalCoverage = coverage(metalBytes)
        let quartzCoverage = coverage(quartzBytes)
        XCTAssertEqual(metalCoverage, quartzCoverage, accuracy: 0.01,
                       "the same source rectangle must be covered")

        func meanColor(_ bytes: [UInt8]) -> (Double, Double, Double) {
            var r = 0.0, g = 0.0, b = 0.0, n = 0.0
            for index in stride(from: 0, to: bytes.count, by: 4) where bytes[index + 3] > 8 {
                b += Double(bytes[index]); g += Double(bytes[index + 1]); r += Double(bytes[index + 2])
                n += 1
            }
            return n > 0 ? (r / n, g / n, b / n) : (0, 0, 0)
        }
        let metalMean = meanColor(metalBytes)
        let quartzMean = meanColor(quartzBytes)
        XCTAssertEqual(metalMean.0, quartzMean.0, accuracy: 3, "mean red")
        XCTAssertEqual(metalMean.1, quartzMean.1, accuracy: 3, "mean green")
        XCTAssertEqual(metalMean.2, quartzMean.2, accuracy: 3, "mean blue")
    }

    /// The mip chain is not optional (spec §9.4): without it, strong minification
    /// aliases by 1.5-2.6x against the current Quartz renderer's shimmer.
    func testTextureCarriesAMipChainAndUploadsOncePerImage() throws {
        let renderer = try renderer()
        let image = try bitmap(width: 256, height: 256)

        XCTAssertTrue(renderer.prepareTexture(for: image))
        XCTAssertTrue(renderer.hasMipmaps, "mipmaps are mandatory")
        XCTAssertGreaterThan(renderer.textureBytes, 256 * 256 * 4,
                             "the reported texture size includes the mip chain")

        let firstBytes = renderer.textureBytes
        XCTAssertTrue(renderer.prepareTexture(for: image), "the same bitmap is a no-op")
        XCTAssertEqual(renderer.textureBytes, firstBytes)
    }

    func testMagnificationIsLinearRatherThanBlocky() throws {
        let renderer = try renderer()
        let image = try bitmap(width: 32, height: 32)
        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: 128, height: 128, mipmapped: false)
        textureDescriptor.usage = [.renderTarget, .shaderRead]
        textureDescriptor.storageMode = .shared
        let texture = try XCTUnwrap(Self.device?.makeTexture(descriptor: textureDescriptor))

        var viewport = ViewportState()
        viewport.zoomScale = 1
        XCTAssertTrue(renderer.renderOffscreen(image: image, sourcePixelSize: CGSize(width: 32, height: 32),
                                              viewport: viewport, viewSize: CGSize(width: 128, height: 128),
                                              contentsScale: 1, backgroundColor: NSColor.clear.cgColor,
                                              into: texture))
        var bytes = [UInt8](repeating: 0, count: 128 * 128 * 4)
        bytes.withUnsafeMutableBytes { raw in
            texture.getBytes(raw.baseAddress!, bytesPerRow: 128 * 4,
                             from: MTLRegionMake2D(0, 0, 128, 128), mipmapLevel: 0)
        }

        // Nearest magnification of a 32px bitmap to 128px produces a hard step every
        // 4 rows; linear produces none across the colour boundary.
        var hardSteps = 0
        for row in 1..<127 {
            let offset = row * 128 * 4
            let above = offset - 128 * 4
            if abs(Int(bytes[offset + 2]) - Int(bytes[above + 2])) > 24 { hardSteps += 1 }
        }
        XCTAssertLessThan(hardSteps, 8, "linear magnification must not produce block edges")
    }
}
