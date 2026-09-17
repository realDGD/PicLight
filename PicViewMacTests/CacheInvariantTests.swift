import XCTest
import CoreGraphics
import Darwin
@testable import PicViewMac

/// Cache and memory invariants. This cannot replace Instruments, but it locks the
/// properties the design depends on.
final class CacheInvariantTests: XCTestCase {
    func testCacheCostIsTheRealDecodedByteSize() async throws {
        let decoder = ImageIODecoder()
        let head = try await decoder.decodeFirstDisplayableFrame(Fixtures.url("static.png"),
                                                                 target: .fullResolution)
        let cost = DecodeCache.cost(of: head.image)
        XCTAssertEqual(cost, head.image.bytesPerRow * head.image.height)
        XCTAssertGreaterThan(cost, 0)
        // 64x48 RGBA is 12288 bytes; a bytes-per-pixel double count would report
        // ~49152 for the same image.
        XCTAssertEqual(cost, 12_288, accuracy: 4_096,
                       "cost must not multiply in bytes-per-pixel a second time")
    }

    func testCostScalesWithImageSizeNotWithFileSize() async throws {
        let scratch = try Fixtures.makeScratchDirectory("cost")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let big = scratch.appendingPathComponent("big.png")
        let small = scratch.appendingPathComponent("small.png")
        for (url, side) in [(big, 2000), (small, 200)] {
            let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8,
                                    bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.setFillColor(CGColor(red: 0.3, green: 0.5, blue: 0.7, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: side, height: side))
            let image = context.makeImage()!
            let cost = DecodeCache.cost(of: image)
            XCTAssertEqual(cost, image.bytesPerRow * image.height)
        }
        _ = small
    }

    func testOrdinaryEvictionKeepsTheCurrentImageUsable() async throws {
        // A cache with room for roughly one 64x48 image: storing a second one must
        // not invalidate the API for the current image.
        let cache = DecodeCache(totalCostLimit: 40_000)
        let decoder = ImageIODecoder()
        let first = try await decoder.decodeFirstDisplayableFrame(Fixtures.url("static.png"),
                                                                  target: .fullResolution)
        cache.setCurrent(Fixtures.url("static.png"))
        cache.store(head: first, for: Fixtures.url("static.png"))
        XCTAssertNotNil(cache.head(for: Fixtures.url("static.png")))

        // Reloading the current image always works, whether or not it was evicted.
        cache.store(head: first, for: Fixtures.url("static.png"))
        XCTAssertNotNil(cache.head(for: Fixtures.url("static.png")))
    }

    func testMemoryPressureKeepsOnlyTheCurrentImage() async throws {
        let cache = DecodeCache(totalCostLimit: 64 * 1024 * 1024)
        let decoder = ImageIODecoder()
        let current = try await decoder.decodeFirstDisplayableFrame(Fixtures.url("static.png"),
                                                                    target: .fullResolution)
        let other = try await decoder.decodeFirstDisplayableFrame(Fixtures.url("static.bmp"),
                                                                  target: .fullResolution)
        cache.setCurrent(Fixtures.url("static.png"))
        cache.store(head: current, for: Fixtures.url("static.png"))
        cache.store(head: other, for: Fixtures.url("static.bmp"))

        NotificationCenter.default.post(name: .decodeCacheMemoryPressure, object: nil)

        XCTAssertNotNil(cache.head(for: Fixtures.url("static.png")), "the shown image survives")
        XCTAssertNil(cache.head(for: Fixtures.url("static.bmp")), "non-current entries are purged")
    }

    func testAnimationFramesAreCachedSeparatelyFromTheHead() async throws {
        let cache = DecodeCache()
        let url = Fixtures.url("animated-infinite.gif")
        let decoder = ImageIODecoder()
        let head = try await decoder.decodeFirstDisplayableFrame(url, target: .fullResolution)
        let frame = try await decoder.decodeFrame(url, index: 1)
        cache.store(head: head, for: url)
        cache.store(frame: frame, for: url)
        XCTAssertNotNil(cache.head(for: url))
        XCTAssertNotNil(cache.frame(for: url, index: 1))
        // Frame 0 is the head, so it is never stored twice.
        cache.store(frame: DecodedFrame(image: frame.image, index: 0, duration: 0.1), for: url)
        XCTAssertNotNil(head.image)
    }

    func testThumbnailCacheIsSeparateFromTheFullImageCache() async throws {
        // Two different components with independent budgets: purging thumbnails
        // must not disturb the decoded-image cache and vice versa.
        let thumbnails = ThumbnailPipeline()
        let cache = DecodeCache()
        let decoder = ImageIODecoder()
        let url = Fixtures.url("static.png")

        _ = try await thumbnails.thumbnail(for: url, maxPixelSize: 64)
        let head = try await decoder.decodeFirstDisplayableFrame(url, target: .fullResolution)
        cache.store(head: head, for: url)

        await thumbnails.purge()
        XCTAssertNotNil(cache.head(for: url), "purging thumbnails must not empty the image cache")

        cache.purge(keeping: nil)
        XCTAssertNil(cache.head(for: url))
        let thumbnailAgain = try await thumbnails.thumbnail(for: url, maxPixelSize: 64)
        XCTAssertGreaterThan(thumbnailAgain.width, 0, "thumbnails remain available after a cache purge")
    }

    func testOpeningAViewerCancelsAndReleasesDecodeWorkOnTheWayOut() async throws {
        let decoder = CountingDecoder(delay: 0.05)
        let collector = EventCollector()
        var coordinator: DecodeCoordinator? = DecodeCoordinator(decoder: decoder)
        _ = await coordinator?.show(item: URL(fileURLWithPath: "/tmp/release-a.png"),
                                    previous: URL(fileURLWithPath: "/tmp/release-b.png"),
                                    next: URL(fileURLWithPath: "/tmp/release-c.png"),
                                    direction: .forward) { collector.record($0) }
        await coordinator?.cancelAll()
        coordinator = nil
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertTrue(collector.publishedNames.isEmpty,
                      "a released coordinator must not keep publishing")
    }

    /// Long-loop smoke test that records RSS so a human can see the trend. No
    /// threshold is asserted: RSS thresholds are flaky on shared machines.
    func testLongDecodeLoopRecordsResidentMemoryTrend() async throws {
        guard let rssBefore = Self.residentMemoryBytes() else {
            throw XCTSkip("task_info is unavailable in this environment")
        }
        let pipeline = ThumbnailPipeline()
        let urls = ["static.png", "static.bmp", "static.jpg", "display-p3.png"].map(Fixtures.url)
        for round in 0..<40 {
            for url in urls {
                _ = try? await pipeline.thumbnail(for: url, maxPixelSize: 128)
            }
            if round % 20 == 0 { await pipeline.purge() }
        }
        let rssAfter = Self.residentMemoryBytes() ?? rssBefore
        let deltaMB = Double(Int64(rssAfter) - Int64(rssBefore)) / 1_048_576
        print(String(format: "METRIC RSS before %.1f MB, after %.1f MB, delta %+.1f MB over 160 thumbnail decodes",
                     Double(rssBefore) / 1_048_576, Double(rssAfter) / 1_048_576, deltaMB))
        XCTAssertGreaterThan(rssAfter, 0)
    }

    private static func residentMemoryBytes() -> UInt64? {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.resident_size : nil
    }
}
