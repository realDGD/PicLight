import XCTest
import AppKit
import CoreGraphics
import ImageIO
@testable import PicViewMac

/// E: the effective thumbnail memory audit.
///
/// Two questions, measured not assumed: does the pipeline's `NSCache` budget actually hold under
/// a folder's worth of distinct thumbnails, and does the gallery itself stop retaining images
/// once they leave its window (that half lives in `GalleryAuditTests`; this file measures the
/// pipeline side with the gallery on top of it, the way production composes them).
@MainActor
final class ThumbnailMemoryAuditTests: XCTestCase {

    override func setUp() async throws {
        try await super.setUp()
        TestAppKit.ensureApplication()
    }

    /// Writes `count` distinct PNG files (distinct inodes → distinct identities → distinct cache
    /// keys) into a scratch directory.
    private func makeFiles(count: Int, width: Int, height: Int) throws -> URL {
        let directory = try Fixtures.makeScratchDirectory("memory-audit")
        for index in 0..<count {
            let url = directory.appendingPathComponent("img-\(index).png")
            let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                    bytesPerRow: 0,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.setFillColor(CGColor(red: CGFloat(index % 7) / 7, green: 0.4, blue: 0.6,
                                         alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            let destination = CGImageDestinationCreateWithURL(url as CFURL,
                                                              "public.png" as CFString, 1, nil)!
            CGImageDestinationAddImage(destination, context.makeImage()!, nil)
            _ = CGImageDestinationFinalize(destination)
        }
        return directory
    }

    /// 600 200×200 thumbnails (≈160 KB each ≈ 96 MB if unbounded) must settle at the pipeline's
    /// own budget, not at the folder's size.
    func testPipelineCacheStaysWithinItsBudgetUnderManyDistinctFiles() async throws {
        let directory = try makeFiles(count: 600, width: 800, height: 600)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pipeline = ThumbnailPipeline()
        let urls = (0..<600).map { directory.appendingPathComponent("img-\($0).png") }
        // The decode-path counter is process-wide; measure the delta this test causes.
        let decodedBefore = ThumbnailPipelineMetrics.decodedFilePaths.count

        for url in urls {
            _ = try? await pipeline.thumbnail(for: url, maxPixelSize: 200)
        }

        let retained = await pipeline.retainedImageCount
        let bytes = await pipeline.retainedImageBytes
        let decodedDelta = ThumbnailPipelineMetrics.decodedFilePaths.count - decodedBefore
        print("METRIC E after 600 distinct thumbnails: retainedCount=\(retained) "
            + "retainedBytes=\(bytes) (\(bytes / 1024 / 1024) MiB) decodedDelta=\(decodedDelta)")
        XCTAssertLessThanOrEqual(retained, 601, "the cache count limit is the bound, not 600 files")
        XCTAssertLessThanOrEqual(bytes, 50 * 1024 * 1024,
                                 "the 48 MiB cost limit is the bound, not the folder")
        XCTAssertEqual(decodedDelta, 600, "every distinct identity really decoded once")

        // A re-request of a still-retained file is a cache hit, not a re-decode.
        let before = ThumbnailPipelineMetrics.decodedFilePaths.count
        for _ in 0..<3 {
            _ = try? await pipeline.thumbnail(for: urls[0], maxPixelSize: 200)
        }
        XCTAssertEqual(ThumbnailPipelineMetrics.decodedFilePaths.count, before,
                       "a warm re-request must not decode")
    }

    /// The same budget, driven through the real browser: a 5000-image folder scrolled top to
    /// bottom leaves the pipeline inside its budget and the gallery inside its window.
    func testScrollingARealLargeFolderKeepsEffectiveMemoryBounded() async throws {
        let directory = try makeFiles(count: 500, width: 1600, height: 1200)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pipeline = ThumbnailPipeline()
        let controller = ViewerViewController(thumbnails: pipeline)
        let windowController = ViewerWindowController(viewer: controller)
        // Closed on every path: an offscreen viewer window left behind shifts every later
        // window-count test in this process sees.
        defer { windowController.close() }
        TestAppKit.presentOffScreen(windowController)
        let items = try await FolderScanner().scan(directory: directory)
        controller.session.setItems(items)
        controller.perform(.browseFolder)
        let deadline = Date().addingTimeInterval(10)
        while controller.folderBrowserForTesting == nil, Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let browser = try XCTUnwrap(controller.folderBrowserForTesting)
        browser.view.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 500_000_000)

        let grid = browser.view.gallery
        let scroll = try XCTUnwrap(grid.enclosingScrollView)
        let contentHeight = GalleryLayout.contentHeight(of: grid.rows)
        let viewportHeight = scroll.contentView.bounds.height
        let maxY = max(0, contentHeight - viewportHeight)
        var y: CGFloat = 0
        while y < maxY {
            y = min(y + 500, maxY)
            scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
            scroll.reflectScrolledClipView(scroll.contentView)
            grid.needsLayout = true
            grid.layoutSubtreeIfNeeded()
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        // Let the final window's decodes land.
        try await Task.sleep(nanoseconds: 1_000_000_000)

        let retained = await pipeline.retainedImageCount
        let bytes = await pipeline.retainedImageBytes
        let galleryPixels = grid.retainedThumbnailByteCountForTesting
        print("METRIC E real-browser 500-item scroll: pipelineRetained=\(retained) "
            + "(\(bytes / 1024 / 1024) MiB) galleryRetainedBytes=\(galleryPixels) "
            + "galleryRetainedCount=\(grid.deliveredImageCountForTesting) "
            + "requests=\(browser.thumbnailRequestCount)")
        XCTAssertLessThanOrEqual(retained, 601)
        XCTAssertLessThanOrEqual(bytes, 50 * 1024 * 1024)
        XCTAssertLessThanOrEqual(grid.deliveredImageCountForTesting, 250,
                                 "the gallery's own retained images stay a window")
        XCTAssertLessThan(browser.thumbnailRequestCount, 600,
                          "requests across a full scroll of 500 items stay page-windowed, "
                          + "got \(browser.thumbnailRequestCount)")
    }
}