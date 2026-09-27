import XCTest
import AppKit
import CoreGraphics
@testable import PicViewMac

/// Thumbnails between launches, and what the grid shows while one is being made.
///
/// Measured with ImageIO on the user's own files: a 48,000 × 32,000 PNG (1.9 GB) takes **18.4 s** for a
/// 320 px thumbnail — and the same 18 s at 64 px, and with `kCGImageSourceSubsampleFactor` 8 or 16, so
/// ImageIO inflates the whole picture whatever is asked of it. The only real optimization is to pay
/// that once: the decoded thumbnail is kept on disk, keyed by the file's version identity, and the grid
/// says what it is doing in the meantime.
final class ThumbnailDiskCacheTests: XCTestCase {

    private func makeCache(byteLimit: Int = 8 * 1024 * 1024) throws -> (ThumbnailDiskCache, URL) {
        let directory = try Fixtures.makeScratchDirectory("thumb-disk")
        let cache = ThumbnailDiskCache(directory: directory, byteLimit: byteLimit)
        return (cache, directory)
    }

    /// The second decode of the same file comes off the disk, not out of the decoder.
    func testASecondLookupIsServedFromDisk() async throws {
        let (cache, directory) = try makeCache()
        defer { try? FileManager.default.removeItem(at: directory) }
        let pipeline = ThumbnailPipeline(diskCache: cache)
        let file = Fixtures.url("static.png")

        ThumbnailPipelineMetrics.reset()
        let first = try await pipeline.thumbnail(for: file, maxPixelSize: 160)
        XCTAssertFalse(ThumbnailPipelineMetrics.decodedFilePaths.isEmpty,
                       "precondition: the first one really was decoded")
        XCTAssertEqual(ThumbnailPipelineMetrics.diskCacheHits, 0, "nothing was on disk yet")

        // The store is written off the hot path, so wait for it to land before testing the lookup.
        // (`RunLoop.run` is unavailable here: this test is async.)
        let stored = Date().addingTimeInterval(5)
        while cache.entryCount == 0, Date() < stored {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertGreaterThan(cache.entryCount, 0, "precondition: the thumbnail reached the disk")

        // The memory cache would answer this one; throw it away so the disk has to.
        await pipeline.purge()
        ThumbnailPipelineMetrics.reset()
        let second = try await pipeline.thumbnail(for: file, maxPixelSize: 160)

        XCTAssertEqual(ThumbnailPipelineMetrics.diskCacheHits, 1,
                       "the stored thumbnail answered instead of the decoder")
        XCTAssertTrue(ThumbnailPipelineMetrics.decodedFilePaths.isEmpty,
                      "and the file was not read again: \(ThumbnailPipelineMetrics.decodedFilePaths)")
        XCTAssertEqual(second.width, first.width)
        XCTAssertEqual(second.height, first.height)
    }

    /// A file replaced at the same path is a different file: the stored thumbnail must not be served.
    func testAReplacedFileIsNotServedItsPredecessorsThumbnail() async throws {
        let (cache, directory) = try makeCache()
        defer { try? FileManager.default.removeItem(at: directory) }
        let pipeline = ThumbnailPipeline(diskCache: cache)
        let file = directory.appendingPathComponent("photo.png")
        try FileManager.default.copyItem(at: Fixtures.url("static.png"), to: file)
        let before = try await pipeline.thumbnail(for: file, maxPixelSize: 128)
        await pipeline.purge()

        // Replaced with a picture of a different shape, a second later (the version token is
        // size + mtime + ctime + inode).
        try FileManager.default.removeItem(at: file)
        let context = CGContext(data: nil, width: 300, height: 100, bitsPerComponent: 8,
                                bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.9, green: 0.1, blue: 0.1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 300, height: 100))
        let destination = CGImageDestinationCreateWithURL(file as CFURL,
                                                          "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))

        let after = try await pipeline.thumbnail(for: file, maxPixelSize: 128)
        XCTAssertNotEqual(after.width, before.width,
                          "the replaced file was decoded, not answered from the predecessor's cache")
        XCTAssertEqual(Double(after.width) / Double(after.height), 3, accuracy: 0.05,
                       "and it is the new picture's shape")
    }

    /// The store is bounded, so a folder of thousands of large images cannot fill the disk.
    func testTheStorePrunesItselfUnderItsByteLimit() throws {
        let (cache, directory) = try makeCache(byteLimit: 40 * 1024)
        defer { try? FileManager.default.removeItem(at: directory) }
        let context = CGContext(data: nil, width: 256, height: 256, bitsPerComponent: 8,
                                bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        for index in 0..<40 {
            context.setFillColor(CGColor(red: CGFloat(index) / 40, green: 0.4, blue: 0.6, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 256, height: 256))
            cache.store(context.makeImage()!, forKey: "key-\(index)")
        }
        // Writes and prunes are serialised on the cache's own queue, so wait until the store has
        // stopped changing: polling for "under the limit" alone can catch the dip between a prune and
        // the writes that are still queued behind it.
        var previous = -1
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.15))
            let now = cache.byteCount
            if now == previous { break }
            previous = now
        }
        XCTAssertLessThanOrEqual(cache.byteCount, cache.byteLimitForTesting,
                                "the store stays under its limit (\(cache.entryCount) entries)")
        XCTAssertGreaterThan(cache.entryCount, 0, "and keeps the newest ones")
    }

    /// A stored thumbnail reads back as the same picture.
    func testARoundTripThroughTheDiskKeepsThePixels() throws {
        let (cache, directory) = try makeCache()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = CGImageSourceCreateWithURL(Fixtures.url("static.png") as CFURL, nil)!
        let image = CGImageSourceCreateImageAtIndex(source, 0, nil)!
        cache.store(image, forKey: "round-trip")

        let deadline = Date().addingTimeInterval(5)
        var restored: CGImage?
        while restored == nil, Date() < deadline {
            restored = cache.thumbnail(forKey: "round-trip")
            if restored == nil { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        }
        let read = try XCTUnwrap(restored, "the stored thumbnail reads back")
        XCTAssertEqual(read.width, image.width)
        XCTAssertEqual(read.height, image.height)
    }
}

/// The decode bound: a folder of large images asks for one thumbnail per visible cell, and they must
/// not all decode at once.
final class ThumbnailDecodeBoundTests: XCTestCase {

    func testConcurrentDecodesAreBounded() async throws {
        let directory = try Fixtures.makeScratchDirectory("thumb-bound")
        defer { try? FileManager.default.removeItem(at: directory) }
        var files: [URL] = []
        for index in 0..<12 {
            let url = directory.appendingPathComponent("img\(index).png")
            try FileManager.default.copyItem(at: Fixtures.url("static.png"), to: url)
            files.append(url)
        }
        // No disk cache: otherwise the second request for a file could be answered by the store and
        // the decodes would not overlap at all.
        let pipeline = ThumbnailPipeline(diskCache: nil)
        ThumbnailPipelineMetrics.reset()

        await withTaskGroup(of: Void.self) { group in
            for file in files {
                group.addTask {
                    _ = try? await pipeline.thumbnail(for: file, maxPixelSize: 160)
                }
            }
        }

        XCTAssertGreaterThan(ThumbnailPipelineMetrics.decodePeak, 0, "something was decoded")
        XCTAssertLessThanOrEqual(ThumbnailPipelineMetrics.decodePeak, 4,
                                 "at most four decodes at once, however many cells ask")
    }
}

/// The point of the disk cache: the second look at a large picture is not a second decode.
///
/// The source is generated rather than shipped (a real 12 MP fixture would bloat the repository), and
/// the assertion is a *ratio*: on this machine a 16 MP PNG costs hundreds of milliseconds to
/// thumbnail and a few for the stored copy, so the two are not close.
final class ThumbnailDiskCacheSpeedTests: XCTestCase {

    private func writeLargePNG(to url: URL, side: Int) throws {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        // Noise, not a flat colour: a flat PNG compresses to almost nothing and decodes instantly,
        // which would make this test measure nothing.
        var seed: UInt64 = 0x2545F4914F6CDD1D
        let row = UnsafeMutablePointer<UInt8>.allocate(capacity: side * 4)
        defer { row.deallocate() }
        for y in 0..<side {
            for x in 0..<side {
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                let value = UInt8((seed >> 33) & 0xFF)
                row[x * 4] = value
                row[x * 4 + 1] = value &* 3 &+ UInt8(y & 0xFF)
                row[x * 4 + 2] = UInt8(x & 0xFF)
                row[x * 4 + 3] = 255
            }
            context.data?.advanced(by: y * context.bytesPerRow)
                .copyMemory(from: row, byteCount: side * 4)
        }
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(
            url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }

    func testTheSecondLookAtALargeImageIsNotASecondDecode() async throws {
        let directory = try Fixtures.makeScratchDirectory("thumb-speed")
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("large.png")
        try writeLargePNG(to: file, side: 4000)

        let cache = ThumbnailDiskCache(directory: directory.appendingPathComponent("cache"),
                                       byteLimit: 64 * 1024 * 1024)
        let pipeline = ThumbnailPipeline(diskCache: cache)

        let decodeStart = Date()
        _ = try await pipeline.thumbnail(for: file, maxPixelSize: 320)
        let decodeSeconds = Date().timeIntervalSince(decodeStart)

        var settled = Date().addingTimeInterval(5)
        while cache.entryCount == 0, Date() < settled {
            try await Task.sleep(nanoseconds: 20_000_000)
            settled = settled.addingTimeInterval(0)
        }
        XCTAssertGreaterThan(cache.entryCount, 0, "precondition: the thumbnail was stored")

        await pipeline.purge()
        ThumbnailPipelineMetrics.reset()
        let hitStart = Date()
        _ = try await pipeline.thumbnail(for: file, maxPixelSize: 320)
        let hitSeconds = Date().timeIntervalSince(hitStart)
        XCTAssertEqual(ThumbnailPipelineMetrics.diskCacheHits, 1,
                       "the second call is answered by the store")
        XCTAssertTrue(ThumbnailPipelineMetrics.decodedFilePaths.isEmpty,
                      "and does not read the source again")

        XCTAssertGreaterThan(decodeSeconds, 0.05,
                             "precondition: a 16 MP PNG is not instant (\(decodeSeconds)s)")
        XCTAssertLessThan(hitSeconds, decodeSeconds / 5,
                          "the stored thumbnail must be much faster than the decode "
                          + "(decode \(Int(decodeSeconds * 1000)) ms, disk \(Int(hitSeconds * 1000)) ms)")
    }
}
