import XCTest
import AppKit
@testable import PicViewMac

@MainActor
final class AFeatureCacheTests: XCTestCase {
    func testSharedServiceClearsAllViewersAndRejectsPreClearDiskWrites() async throws {
        let directory = try Fixtures.makeScratchDirectory("a-cache")
        defer { try? FileManager.default.removeItem(at: directory) }
        let disk = ThumbnailDiskCache(directory: directory)
        let service = ThumbnailCacheService(diskCache: disk)
        let first = service.makePipeline(), second = service.makePipeline()
        let source = Fixtures.url("static.png")
        let image = try await first.thumbnail(for: source, maxPixelSize: 80)
        await second.remember(image, for: source, maxPixelSize: 80)
        await second.remember(image, for: source, maxPixelSize: 80)
        let before = await service.statistics()
        XCTAssertEqual(before.diskCount, 1)
        XCTAssertEqual(before.memoryCount, 2, "replacing a cached thumbnail must not inflate statistics")
        XCTAssertGreaterThan(before.diskBytes, 0)
        let oldEpoch = disk.generation
        await service.clear()
        disk.store(image, forKey: "stale", generation: oldEpoch)
        let cleared = await service.statistics()
        XCTAssertEqual(cleared.diskCount, 0)
        XCTAssertEqual(cleared.memoryCount, 0)
        _ = try await second.thumbnail(for: source, maxPixelSize: 80)
        let rebuilt = await service.statistics()
        XCTAssertEqual(rebuilt.diskCount, 1)
        XCTAssertEqual(ThumbnailDiskCache(directory: directory).entryCount, 1,
                       "clearing keeps the format marker so next launch does not retire fresh entries")
    }

    func testClearingRejectsAllWaitersOnACoalescedDecode() async throws {
        let pipeline = ThumbnailPipeline()
        for _ in 0..<4 { await ThumbnailPipeline.decodeGate.acquire() }
        let source = Fixtures.url("static.png")
        let owner = Task { try await pipeline.thumbnail(for: source, maxPixelSize: 123) }
        try await Task.sleep(nanoseconds: 20_000_000)
        let waiter = Task { try await pipeline.thumbnail(for: source, maxPixelSize: 123) }
        try await Task.sleep(nanoseconds: 20_000_000)
        await pipeline.purge()
        for _ in 0..<4 { await ThumbnailPipeline.decodeGate.release() }
        for result in [await owner.result, await waiter.result] {
            switch result {
            case .success: XCTFail("a pre-clear waiter must not publish an old thumbnail")
            case .failure(let error): XCTAssertTrue(error is CancellationError)
            }
        }
    }

    func testLateQuickLookCannotRepopulateClearedCaches() async throws {
        let directory = try Fixtures.makeScratchDirectory("a-cache-late")
        defer { try? FileManager.default.removeItem(at: directory) }
        let disk = ThumbnailDiskCache(directory: directory)
        let context = CGContext(data: nil, width: 80, height: 80, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let image = context.makeImage()!
        let provider = LateThumbnail(image: image)
        let pipeline = ThumbnailPipeline(diskCache: disk, quickLook: provider)
        _ = await pipeline.systemThumbnail(for: URL(fileURLWithPath: "/tmp/nonexistent-a.png"),
                                            maxPixelSize: 80, budget: 0.005)
        disk.removeAll()
        await pipeline.purge()
        try await Task.sleep(nanoseconds: 150_000_000)
        let memoryCount = await pipeline.retainedImageCount
        XCTAssertEqual(memoryCount, 0)
        XCTAssertEqual(disk.entryCount, 0)
    }
}

private struct LateThumbnail: QuickLookThumbnailProviding, @unchecked Sendable {
    let image: CGImage
    func requestLowQualityThumbnail(for url: URL, maxPixelSize: Int,
                                   completion: @escaping @Sendable (CGImage?) -> Void) {
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.06) { completion(image) }
    }
}
