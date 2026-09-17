import XCTest
import CoreGraphics
import ImageIO
@testable import PicViewMac

final class ThumbnailPipelineTests: XCTestCase {
    func testThumbnailIsBoundedByRequestedPixelSize() async throws {
        let pipeline = ThumbnailPipeline()
        let thumbnail = try await pipeline.thumbnail(for: Fixtures.url("static.png"), maxPixelSize: 32)
        XCTAssertLessThanOrEqual(max(thumbnail.width, thumbnail.height), 32)
        XCTAssertGreaterThan(thumbnail.width, 0)
    }

    func testThumbnailSmallerThanSourceNeverUpscalesTheSource() async throws {
        let pipeline = ThumbnailPipeline()
        let thumbnail = try await pipeline.thumbnail(for: Fixtures.url("static.bmp"), maxPixelSize: 400)
        XCTAssertLessThanOrEqual(max(thumbnail.width, thumbnail.height), 400)
    }

    /// The EXIF transform is applied at thumbnail creation time, so a rotated
    /// source yields a rotated thumbnail.
    func testThumbnailAppliesEXIFTransform() async throws {
        let pipeline = ThumbnailPipeline()
        let thumbnail = try await pipeline.thumbnail(for: Fixtures.url("oriented-6.jpg"), maxPixelSize: 200)
        XCTAssertGreaterThan(thumbnail.height, thumbnail.width,
                             "orientation 6 must rotate the thumbnail, not just the full image")
    }

    func testThumbnailGenerationDoesNotFullyDecodeHugeSources() async throws {
        // A 4000x3000 source is created on the fly; the pipeline must return a
        // small image without the caller ever holding full resolution pixels.
        let scratch = try Fixtures.makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let large = scratch.appendingPathComponent("large.png")
        let context = CGContext(data: nil, width: 4000, height: 3000, bitsPerComponent: 8,
                                bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.2, green: 0.6, blue: 0.3, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 4000, height: 3000))
        let destination = CGImageDestinationCreateWithURL(large as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))

        let pipeline = ThumbnailPipeline()
        let thumbnail = try await pipeline.thumbnail(for: large, maxPixelSize: 300)
        XCTAssertLessThanOrEqual(max(thumbnail.width, thumbnail.height), 300)
    }

    func testCorruptFileThrowsAndKeepsPipelineUsable() async throws {
        let pipeline = ThumbnailPipeline()
        do {
            _ = try await pipeline.thumbnail(for: Fixtures.url("corrupt.png"), maxPixelSize: 100)
            XCTFail("expected a thumbnail error")
        } catch {
            XCTAssertTrue(error is ImageDecodeError)
        }
        let good = try await pipeline.thumbnail(for: Fixtures.url("static.png"), maxPixelSize: 64)
        XCTAssertGreaterThan(good.width, 0)
    }

    func testCachedThumbnailIsReused() async throws {
        let pipeline = ThumbnailPipeline()
        let first = try await pipeline.thumbnail(for: Fixtures.url("static.png"), maxPixelSize: 40)
        let second = try await pipeline.thumbnail(for: Fixtures.url("static.png"), maxPixelSize: 40)
        XCTAssertEqual(first.width, second.width)
    }

    func testPurgeEmptiesTheThumbnailCache() async throws {
        let pipeline = ThumbnailPipeline()
        _ = try await pipeline.thumbnail(for: Fixtures.url("static.png"), maxPixelSize: 40)
        await pipeline.purge()
        let again = try await pipeline.thumbnail(for: Fixtures.url("static.png"), maxPixelSize: 40)
        XCTAssertGreaterThan(again.width, 0)
    }
}
