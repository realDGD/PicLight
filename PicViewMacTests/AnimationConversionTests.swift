import CoreGraphics
import Metal
import XCTest

@testable import PicViewMac

final class AnimationConversionTests: XCTestCase {
    func image(
        _ bytes: [UInt8], _ flags: CGBitmapInfo, space: CGColorSpace? = CGColorSpace(name: CGColorSpace.sRGB)
    ) -> CGImage {
        CGImage(
            width: 2, height: 1, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 8, space: space!,
            bitmapInfo: flags, provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: nil,
            shouldInterpolate: false, intent: .defaultIntent)!
    }
    func converted(_ image: CGImage) throws -> [UInt8] {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let converter = try AnimationPacked32Converter(device: device)
        let layout = try XCTUnwrap(AnimationPacked32Layout(image: image))
        let raw = try XCTUnwrap(image.dataProvider?.data) as Data
        let buffer = try XCTUnwrap(
            raw.withUnsafeBytes {
                device.makeBuffer(bytes: $0.baseAddress!, length: raw.count, options: .storageModeShared)
            })
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: 2, height: 1, mipmapped: false)
        desc.storageMode = .shared
        desc.usage = [.shaderRead, .shaderWrite]
        let texture = try XCTUnwrap(device.makeTexture(descriptor: desc))
        let cmd = try XCTUnwrap(queue.makeCommandBuffer())
        try converter.encode(layout: layout, buffer: buffer, rowBytes: 8, to: texture, command: cmd)
        cmd.commit()
        cmd.waitUntilCompleted()
        XCTAssertEqual(cmd.status, .completed)
        var bytes = [UInt8](repeating: 0, count: 8)
        bytes.withUnsafeMutableBytes {
            texture.getBytes(
                $0.baseAddress!, bytesPerRow: 8, from: MTLRegionMake2D(0, 0, 2, 1), mipmapLevel: 0)
        }
        return bytes
    }
    func testStraightAlphaIsPremultipliedBeforeFiltering() throws {
        let input = image(
            [200, 100, 50, 128, 10, 20, 30, 0], CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue))
        XCTAssertEqual(try converted(input), [25, 50, 100, 128, 0, 0, 0, 0])
    }
    func testPremultipliedAndOpaquePixelsKeepTheirMeaning() throws {
        let p = image(
            [100, 50, 25, 128, 0, 0, 0, 0],
            CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue))
        XCTAssertEqual(try converted(p), [25, 50, 100, 128, 0, 0, 0, 0])
        let o = image(
            [200, 100, 50, 0, 10, 20, 30, 2], CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue))
        XCTAssertEqual(try converted(o), [50, 100, 200, 255, 30, 20, 10, 255])
    }
    func testAlphaFirstAndLittleEndianLayouts() throws {
        let first = image(
            [128, 200, 100, 50, 255, 10, 20, 30], CGBitmapInfo(rawValue: CGImageAlphaInfo.first.rawValue))
        XCTAssertEqual(try converted(first), [25, 50, 100, 128, 30, 20, 10, 255])
        let little = image(
            [128, 50, 100, 200, 255, 30, 20, 10],
            CGBitmapInfo.byteOrder32Little.union(CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue)))
        XCTAssertEqual(try converted(little), [25, 50, 100, 128, 30, 20, 10, 255])
    }
    func testOtherColorSpacesRequireTheColorManagedFallback() {
        let img = image(
            [200, 100, 50, 255, 10, 20, 30, 255], CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
            space: CGColorSpace(name: CGColorSpace.adobeRGB1998))
        XCTAssertNil(AnimationPacked32Layout(image: img))
    }
}
