import XCTest
import CoreGraphics
import ImageIO
@testable import PicViewMac
import PicPNGStream

/// The tile backend reads raw PNG rows; the viewer, the proxy and `displayPixelSize` all speak
/// *canonical oriented* space. These tests cross that boundary the way it has to be crossed,
/// with ImageIO's own oriented decode (`kCGImageSourceCreateThumbnailWithTransform`) as the
/// reference — not the app's helper, which shares the table under test.
///
/// The fixture is 40×30 with every pixel unique and asymmetric in both axes, so a swap, a flip
/// or a rotation cannot pass by symmetry. The first version of the table had three of the four
/// axis-swapping cases the wrong way round; a square fixture hid it, which is why this one is
/// not square.
final class SourceOrientationTests: XCTestCase {

    private let orientations: [CGImagePropertyOrientation] = [
        .up, .upMirrored, .down, .downMirrored, .left, .leftMirrored, .right, .rightMirrored,
    ]
    private let width = 40, height = 30

    private func pixel(_ x: Int, _ y: Int) -> (UInt8, UInt8, UInt8) {
        (UInt8((x * 5) % 256), UInt8((y * 7) % 256), UInt8((255 - (x + y)) % 256))
    }

    private func rawFixture() -> (pixels: [UInt8], image: CGImage) {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let (r, g, b) = pixel(x, y)
                let offset = (y * width + x) * 4
                pixels[offset] = r; pixels[offset + 1] = g; pixels[offset + 2] = b; pixels[offset + 3] = 255
            }
        }
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                            provider: provider, decode: nil, shouldInterpolate: false,
                            intent: .defaultIntent)!
        return (pixels, image)
    }

    private func pngData(_ image: CGImage, orientation: CGImagePropertyOrientation) -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else {
            return Data()
        }
        CGImageDestinationAddImage(destination, image,
                                   [kCGImagePropertyOrientation: orientation.rawValue] as CFDictionary)
        CGImageDestinationFinalize(destination)
        return data as Data
    }

    private func rgba(_ image: CGImage) -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        pixels.withUnsafeMutableBytes { bytes in
            guard let context = CGContext(data: bytes.baseAddress, width: image.width,
                                          height: image.height, bitsPerComponent: 8,
                                          bytesPerRow: image.width * 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return pixels
    }

    /// ImageIO's answer for this file.
    private func reference(_ data: Data) throws -> (pixels: [UInt8], size: CGSize) {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw XCTSkip("cannot read the fixture")
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(width, height),
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw XCTSkip("ImageIO cannot orient the fixture")
        }
        return (rgba(image), CGSize(width: image.width, height: image.height))
    }

    /// Our answer: raw pixels through `SourceOrientation`, exactly as the tile backend does it.
    private func streamed(_ data: Data, orientation: SourceOrientation)
        throws -> (pixels: [UInt8], size: CGSize) {
        var info = ps_info()
        var error = [CChar](repeating: 0, count: 256)
        let directory = try Fixtures.makeScratchDirectory("orientation")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("fixture.png")
        try data.write(to: url)
        guard let decoder = url.path.withCString({ ps_open($0, &info, &error, 256) }) else {
            throw XCTSkip("decoder refused: \(String(cString: error))")
        }
        defer { ps_close(decoder) }
        let rawSize = CGSize(width: CGFloat(info.width), height: CGFloat(info.height))
        XCTAssertEqual(rawSize, CGSize(width: width, height: height))

        let canonicalSize = orientation.canonicalPixelSize(rawPixelSize: rawSize)
        guard let plan = NativeTilePlanner.plan(sourceRect: CGRect(origin: .zero, size: canonicalSize),
                                                sourcePixelSize: canonicalSize,
                                                tileSize: Int(canonicalSize.width)) else {
            throw XCTSkip("no plan")
        }
        final class Box: @unchecked Sendable {
            private let lock = NSLock(); private var tiles: [NativeTile] = []
            func add(_ tile: NativeTile) { lock.lock(); tiles.append(tile); lock.unlock() }
            var all: [NativeTile] { lock.lock(); defer { lock.unlock() }; return tiles }
        }
        let box = Box()
        try PNGNativeTileProvider().produce(plan: plan, source: url, pageIndex: 0, gutter: 0,
                                            colorSpace: nil, orientation: orientation,
                                            shouldCancel: { false }, onTile: { box.add($0) })

        let canvasWidth = Int(canonicalSize.width), canvasHeight = Int(canonicalSize.height)
        var canvas = [UInt8](repeating: 0, count: canvasWidth * canvasHeight * 4)
        for tile in box.all {
            let tilePixels = rgba(tile.image)
            let originX = Int(tile.sourceRect.minX), originY = Int(tile.sourceRect.minY)
            for row in 0..<tile.image.height {
                for column in 0..<tile.image.width {
                    let x = originX + column, y = originY + row
                    guard x >= 0, y >= 0, x < canvasWidth, y < canvasHeight else { continue }
                    let from = (row * tile.image.width + column) * 4
                    let to = (y * canvasWidth + x) * 4
                    for channel in 0..<4 { canvas[to + channel] = tilePixels[from + channel] }
                }
            }
        }
        return (canvas, canonicalSize)
    }

    func testEveryOrientationMatchesImageIO() throws {
        let (_, image) = rawFixture()
        for orientation in orientations {
            let data = pngData(image, orientation: orientation)
            let expected = try reference(data)
            let actual = try streamed(data, orientation: SourceOrientation(orientation))
            XCTAssertEqual(actual.size, expected.size,
                           "orientation \(orientation.rawValue): canonical size")
            guard actual.size == expected.size else { continue }
            var mismatches = 0
            var first = ""
            let wide = Int(actual.size.width)
            let tall = Int(actual.size.height)
            for y in 0..<tall {
                for x in 0..<wide {
                    let index = (y * wide + x) * 4
                    for channel in 0..<3 where abs(Int(expected.pixels[index + channel])
                                                   - Int(actual.pixels[index + channel])) > 1 {
                        mismatches += 1
                        if first.isEmpty {
                            first = "canonical (\(x),\(y)) channel \(channel): ImageIO "
                                  + "\(expected.pixels[index + channel]) vs tiles \(actual.pixels[index + channel])"
                        }
                    }
                }
            }
            if mismatches > 0 {
                let wide = Int(actual.size.width)
                FileHandle.standardError.write(Data(
                    "ORIENTDBG \(orientation.rawValue) canonical \(wide)x\(tall)\n".utf8))
                for y in [0, 1, tall / 2] where y < tall {
                    let mineRow = (0..<min(4, wide)).map { Int(actual.pixels[(y * wide + $0) * 4]) }
                    let refRow = (0..<min(4, wide)).map { Int(expected.pixels[(y * wide + $0) * 4]) }
                    FileHandle.standardError.write(Data(
                        "  y=\(y) mine R \(mineRow) reference R \(refRow)\n".utf8))
                }
            }
            XCTAssertEqual(mismatches, 0, "orientation \(orientation.rawValue): \(first)")
        }
    }

    /// The table's two halves must be exact inverses, in pixel *index* terms.
    func testRawAndCanonicalRectsRoundTrip() {
        let rawSize = CGSize(width: 40, height: 30)
        for orientation in orientations {
            let source = SourceOrientation(orientation)
            let canonicalSize = source.canonicalPixelSize(rawPixelSize: rawSize)
            XCTAssertEqual(source.swapsDimensions, canonicalSize.width != rawSize.width,
                           "orientation \(orientation.rawValue): swap flag")
            let rect = CGRect(x: 7, y: 5, width: 11, height: 9)
            let raw = source.rawRect(forCanonicalRect: rect, rawPixelSize: rawSize)
            let back = source.canonicalRect(forRawRect: raw, rawPixelSize: rawSize)
            XCTAssertEqual(back, rect, "orientation \(orientation.rawValue) round trip")
        }
    }
}

/// The pixel transform on its own, against the positions measured from ImageIO (see the probe
/// in the commit message): where does the raw top-left pixel land?
extension SourceOrientationTests {
    func testRawTopLeftLandsWhereImageIOSays() {
        let (raw, _) = rawFixture()
        let rawSize = CGSize(width: width, height: height)
        // Measured from ImageIO's oriented decode of this exact fixture, by EXIF value, and
        // keyed by the CG case each value actually is (`.left` is 8, `.leftMirrored` is 5).
        let anchors: [CGImagePropertyOrientation: (Int, Int)] = [
            .up: (0, 0), .upMirrored: (width - 1, 0),
            .down: (width - 1, height - 1), .downMirrored: (0, height - 1),
            .leftMirrored: (0, 0), .right: (height - 1, 0),
            .rightMirrored: (height - 1, width - 1), .left: (0, width - 1),
        ]
        for orientation in orientations {
            let source = SourceOrientation(orientation)
            let result = source.canonicalPixels(fromRawBuffer: raw,
                                                rawRect: CGRect(origin: .zero, size: rawSize),
                                                rawPixelSize: rawSize)
            let wide = Int(result.size.width)
            var marker: (Int, Int)?
            for y in 0..<Int(result.size.height) {
                for x in 0..<wide where result.pixels[(y * wide + x) * 4] == 0
                    && result.pixels[(y * wide + x) * 4 + 1] == 0
                    && result.pixels[(y * wide + x) * 4 + 2] == 255 {
                    marker = (x, y)
                }
            }
            XCTAssertEqual(marker?.0, anchors[orientation]?.0, "\(orientation.rawValue) x")
            XCTAssertEqual(marker?.1, anchors[orientation]?.1, "\(orientation.rawValue) y")
        }
    }
}
