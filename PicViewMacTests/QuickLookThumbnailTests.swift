import XCTest
import AppKit
import CoreGraphics
@testable import PicViewMac

/// The cascade's third leg: macOS's own thumbnail cache.
///
/// Measured on the user's 48,000 × 32,000 PNG (1.9 GB): Quick Look answers in **23 ms** when the
/// system already has a thumbnail, takes **20.7 s** when it has to make one (a fresh copy), and a full
/// ImageIO decode of the same file is **18.8 s**. On an ordinary 1946 × 1248 JPEG it is the *slow*
/// path (195 ms against 3.4 ms in process), which is why it is only consulted where a decode is known
/// to be expensive.
///
/// These tests use a stub generator: the real one's timing depends on what Finder has cached, so a
/// test that asserted a hit would be testing the machine, not the code.
final class QuickLookThumbnailTests: XCTestCase {

    private func makeImage(width: Int, height: Int) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.4, green: 0.7, blue: 0.3, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    /// A source whose shape is known, so the aspect guard can be exercised.
    private func makeSource(aspect: CGFloat) throws -> (url: URL, directory: URL) {
        let directory = try Fixtures.makeScratchDirectory("quicklook")
        let url = directory.appendingPathComponent("source.png")
        let width = 400
        let height = max(1, Int((CGFloat(width) / aspect).rounded()))
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.8, green: 0.2, blue: 0.2, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(
            url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return (url, directory)
    }

    private func makePipeline(_ stub: StubQuickLookThumbnails,
                              diskCache: ThumbnailDiskCache?) -> ThumbnailPipeline {
        ThumbnailPipeline(diskCache: diskCache, quickLook: stub)
    }

    /// A warm system cache answers immediately, and the answer is kept.
    func testASystemThumbnailIsUsedScaledAndRemembered() async throws {
        let (url, directory) = try makeSource(aspect: 1)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cacheDirectory = directory.appendingPathComponent("cache")
        let diskCache = ThumbnailDiskCache(directory: cacheDirectory)
        // A warm cache answers with whatever size it stored — measured: 2048 × 1365 for a 320 px
        // request — so the pipeline has to scale it down before it is remembered.
        let stub = StubQuickLookThumbnails(.answer(makeImage(width: 800, height: 800)))
        let pipeline = makePipeline(stub, diskCache: diskCache)
        ThumbnailPipelineMetrics.reset()

        let image = await pipeline.systemThumbnail(for: url, maxPixelSize: 320)
        let delivered = try XCTUnwrap(image, "the system's thumbnail is used")
        XCTAssertEqual(max(delivered.width, delivered.height), 320, "scaled to what was asked for")
        XCTAssertEqual(stub.requestCountForTesting, 1)
        XCTAssertEqual(ThumbnailPipelineMetrics.quickLookHits, 1)

        // Remembered: the next request is answered without any decode.
        ThumbnailPipelineMetrics.reset()
        await pipeline.purge()
        let again = try await pipeline.thumbnail(for: url, maxPixelSize: 320)
        XCTAssertTrue(ThumbnailPipelineMetrics.decodedFilePaths.isEmpty,
                      "the system's answer was remembered, so nothing was decoded")
        XCTAssertEqual(again.width, delivered.width)
    }

    /// A cold system cache must not be waited on — but its answer is still worth keeping.
    func testASlowSystemThumbnailIsAbandonedAtTheBudgetAndKeptWhenItArrives() async throws {
        let (url, directory) = try makeSource(aspect: 1)
        defer { try? FileManager.default.removeItem(at: directory) }
        let diskCache = ThumbnailDiskCache(directory: directory.appendingPathComponent("cache"))
        let stub = StubQuickLookThumbnails(.answerAfter(1.2, makeImage(width: 400, height: 400)))
        let pipeline = makePipeline(stub, diskCache: diskCache)
        ThumbnailPipelineMetrics.reset()

        let start = Date()
        let image = await pipeline.systemThumbnail(for: url, maxPixelSize: 320, budget: 0.2)
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertNil(image, "the caller does not wait for a cold system cache")
        XCTAssertLessThan(elapsed, 0.8, "and gives up near its budget (took \(elapsed)s)")
        XCTAssertEqual(ThumbnailPipelineMetrics.quickLookHits, 0)

        // The request was left running; when it answers, the result is kept so the *next* look at the
        // folder is instant. This is how a folder of huge files fills itself in.
        let deadline = Date().addingTimeInterval(5)
        while ThumbnailPipelineMetrics.quickLookLateArrivals == 0, Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(ThumbnailPipelineMetrics.quickLookLateArrivals, 1,
                       "the late answer warmed the cache instead of being dropped")
        ThumbnailPipelineMetrics.reset()
        await pipeline.purge()
        _ = try await pipeline.thumbnail(for: url, maxPixelSize: 320)
        XCTAssertTrue(ThumbnailPipelineMetrics.decodedFilePaths.isEmpty,
                      "so the next request needs no decode at all")
    }

    /// A system thumbnail that is not this file's shape cannot be its picture.
    func testASystemThumbnailOfTheWrongShapeIsRejected() async throws {
        let (url, directory) = try makeSource(aspect: 1)
        defer { try? FileManager.default.removeItem(at: directory) }
        let diskCache = ThumbnailDiskCache(directory: directory.appendingPathComponent("cache"))
        let stub = StubQuickLookThumbnails(.answer(makeImage(width: 300, height: 100)))
        let pipeline = makePipeline(stub, diskCache: diskCache)
        ThumbnailPipelineMetrics.reset()

        let image = await pipeline.systemThumbnail(for: url, maxPixelSize: 320)
        XCTAssertNil(image, "a 3:1 picture is not a thumbnail of a 1:1 source")
        XCTAssertEqual(ThumbnailPipelineMetrics.quickLookHits, 0)
        XCTAssertEqual(diskCache.entryCount, 0, "and it is not remembered either")
    }

    /// A system thumbnail smaller than the cell would be drawn upscaled — the blur the size slider
    /// must never produce — so it is refused, and the cell keeps its placeholder instead.
    func testASystemThumbnailSmallerThanTheRequestIsRefused() async throws {
        let (url, directory) = try makeSource(aspect: 1)
        defer { try? FileManager.default.removeItem(at: directory) }
        let diskCache = ThumbnailDiskCache(directory: directory.appendingPathComponent("cache"))
        // The shape matches (1:1), so only the size can rule it out: a 96 px answer for a 320 px cell.
        let stub = StubQuickLookThumbnails(.answer(makeImage(width: 96, height: 96)))
        let pipeline = makePipeline(stub, diskCache: diskCache)
        ThumbnailPipelineMetrics.reset()

        let refused = await pipeline.systemThumbnail(for: url, maxPixelSize: 320)
        XCTAssertNil(refused, "a 96 px answer cannot fill a 320 px cell without being stretched")
        XCTAssertEqual(ThumbnailPipelineMetrics.quickLookHits, 0)
        XCTAssertEqual(diskCache.entryCount, 0, "and nothing is remembered for it")
    }

    /// Just under the request is still used, and is *not* silently upscaled to the request.
    func testASystemThumbnailSlightlyUnderTheRequestIsUsedAsIs() async throws {
        let (url, directory) = try makeSource(aspect: 1)
        defer { try? FileManager.default.removeItem(at: directory) }
        let stub = StubQuickLookThumbnails(.answer(makeImage(width: 240, height: 240)))
        let pipeline = makePipeline(stub, diskCache: nil)
        ThumbnailPipelineMetrics.reset()

        let answered = await pipeline.systemThumbnail(for: url, maxPixelSize: 320)
        let image = try XCTUnwrap(answered)
        XCTAssertEqual(image.width, 240, "the picture is served at its own size, never stretched")
        XCTAssertEqual(ThumbnailPipelineMetrics.quickLookHits, 1)
    }

    /// And a *late* answer that is too small is dropped too, rather than warming the cache with it.
    func testALateAnswerThatIsTooSmallIsNotKept() async throws {
        let (url, directory) = try makeSource(aspect: 1)
        defer { try? FileManager.default.removeItem(at: directory) }
        let diskCache = ThumbnailDiskCache(directory: directory.appendingPathComponent("cache"))
        let stub = StubQuickLookThumbnails(.answerAfter(0.5, makeImage(width: 96, height: 96)))
        let pipeline = makePipeline(stub, diskCache: diskCache)
        ThumbnailPipelineMetrics.reset()

        let timedOut = await pipeline.systemThumbnail(for: url, maxPixelSize: 320, budget: 0.1)
        XCTAssertNil(timedOut)
        try await Task.sleep(nanoseconds: 1_500_000_000)
        XCTAssertEqual(ThumbnailPipelineMetrics.quickLookLateArrivals, 0,
                       "a too-small answer is not worth keeping")
        XCTAssertEqual(diskCache.entryCount, 0)
    }

    /// A generator that never answers must not hold anything up.
    func testAGeneratorThatNeverAnswersDoesNotBlock() async throws {
        let (url, directory) = try makeSource(aspect: 1)
        defer { try? FileManager.default.removeItem(at: directory) }
        let stub = StubQuickLookThumbnails(.never)
        let pipeline = makePipeline(stub, diskCache: nil)
        ThumbnailPipelineMetrics.reset()

        let start = Date()
        let image = await pipeline.systemThumbnail(for: url, maxPixelSize: 320, budget: 0.15)
        XCTAssertNil(image)
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.6)
        XCTAssertEqual(stub.requestCountForTesting, 1, "it was asked, once")
    }

    /// No system generator configured (the tests' default) means no request at all.
    func testWithoutAGeneratorNothingIsAsked() async throws {
        let (url, directory) = try makeSource(aspect: 1)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pipeline = ThumbnailPipeline(diskCache: nil)
        let image = await pipeline.systemThumbnail(for: url, maxPixelSize: 320)
        XCTAssertNil(image)
    }

    /// The budget has to sit between "warm cache" (23 ms) and "generate from scratch" (20 s).
    func testTheBudgetLeavesNoRoomForWaitingOnAColdCache() {
        XCTAssertGreaterThanOrEqual(ThumbnailPipeline.quickLookBudget, 0.1)
        XCTAssertLessThanOrEqual(ThumbnailPipeline.quickLookBudget, 1.0,
                                 "a longer budget trades a wait for a shorter wait")
    }
}
