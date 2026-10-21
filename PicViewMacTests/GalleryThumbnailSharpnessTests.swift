import XCTest
import AppKit
import CoreGraphics
@testable import PicViewMac

/// The size slider makes cells bigger; a bigger cell must get *sharper pixels*, never the small
/// thumbnail stretched to fit.
///
/// The grid keeps showing the old thumbnail while the sharper one is being decoded — that is
/// deliberate, it is what stops the cells from flashing empty during a drag — so the guarantee has to
/// be that the sharper decode actually happens. The sources here are 1200 × 900, big enough that the
/// decoded tier really can differ between a small and a large slider position.
@MainActor
final class GalleryThumbnailSharpnessTests: XCTestCase {

    override func setUp() async throws {
        try await super.setUp()
        TestAppKit.ensureApplication()
    }

    private func pump(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    private func writePNG(_ url: URL, width: Int, height: Int) throws {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        // A pattern rather than a flat fill, so "sharper" is a real difference in pixels.
        for index in 0..<8 {
            context.setFillColor(CGColor(red: CGFloat(index) / 8, green: 0.4, blue: 0.6, alpha: 1))
            context.fill(CGRect(x: index * width / 8, y: 0, width: width / 8, height: height))
        }
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(
            url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }

    private func makeBrowser(count: Int = 6) throws
        -> (directory: URL, controller: ViewerWindowController,
            viewer: ViewerViewController, browser: FolderBrowserViewController) {
        let directory = try Fixtures.makeScratchDirectory("thumb-sharp")
        for index in 0..<count {
            try writePNG(directory.appendingPathComponent("img\(index).png"), width: 1200, height: 900)
        }
        let controller = ViewerWindowController()
        TestAppKit.presentOffScreen(controller)
        controller.window?.setFrame(NSRect(x: 0, y: 0, width: 1100, height: 800), display: false)
        controller.showWindow(nil)
        let viewer = controller.viewerViewController
        _ = viewer.view
        viewer.open(url: directory.appendingPathComponent("img0.png"))
        let deadline = Date().addingTimeInterval(15)
        while viewer.viewerState.currentImage == nil, Date() < deadline { pump(0.05) }
        viewer.perform(.browseFolder)
        pump(0.6)
        viewer.view.layoutSubtreeIfNeeded()
        let browser = try XCTUnwrap(viewer.folderBrowserForTesting)
        browser.view.layoutSubtreeIfNeeded()
        return (directory, controller, viewer, browser)
    }

    /// The widths of the pictures the visible cells are actually holding.
    private func cellImageWidths(_ browser: FolderBrowserViewController) -> [CGFloat] {
        let grid = browser.view.gallery
        return (0..<grid.materializedCellCount).compactMap {
            grid.cellForTesting(at: $0)?.imageForTesting?.size.width
        }
    }

    private func settle(_ browser: FolderBrowserViewController) {
        browser.view.onThumbnailSizeChanged?(browser.view.gallery.thumbnailSizeForTesting)
        browser.view.onThumbnailSizeSettled?(browser.view.gallery.thumbnailSizeForTesting)
    }

    func testGrowingTheCellsReDecodesInsteadOfUpscaling() throws {
        let (directory, controller, _, browser) = try makeBrowser()
        defer { TestAppKit.close(controller); try? FileManager.default.removeItem(at: directory) }
        let grid = browser.view.gallery

        // Small cells first, and let their thumbnails arrive.
        browser.view.onThumbnailSizeChanged?(80)
        browser.view.onThumbnailSizeSettled?(80)
        pump(1.5)
        let small = cellImageWidths(browser)
        let smallWidest = try XCTUnwrap(small.max(), "the small cells hold pictures")
        let requestsBefore = browser.thumbnailRequestCount

        // Now the user drags the slider to the largest level and lets go.
        let target: CGFloat = 320
        browser.view.onThumbnailSizeChanged?(target)
        browser.view.onThumbnailSizeSettled?(target)
        pump(2.0)
        browser.view.layoutSubtreeIfNeeded()
        pump(0.5)

        XCTAssertEqual(grid.thumbnailSizeForTesting, target, accuracy: 0.5)
        let large = cellImageWidths(browser)
        let largeWidest = try XCTUnwrap(large.max(), "the large cells hold pictures too")
        XCTAssertGreaterThan(browser.thumbnailRequestCount, requestsBefore,
                             "growing the cells asked for sharper thumbnails")
        XCTAssertGreaterThan(largeWidest, smallWidest,
                             "a bigger cell holds sharper pixels, not the small thumbnail stretched "
                             + "(small \(small), large \(large))")
        // The sharper tier is what the cell was asked for: half of the 320 pt level is a decode at
        // 640 px, and a 1200 px source can satisfy that without any upscaling.
        XCTAssertLessThanOrEqual(largeWidest, 1200, "and never larger than the source itself")
    }

    /// Shrinking the cells keeps them sharp: a small cell may hold a bigger decode, which is exactly
    /// what downscaling is for.
    func testShrinkingTheCellsKeepsSharpPixels() throws {
        let (directory, controller, _, browser) = try makeBrowser()
        defer { TestAppKit.close(controller); try? FileManager.default.removeItem(at: directory) }

        browser.view.onThumbnailSizeChanged?(320)
        browser.view.onThumbnailSizeSettled?(320)
        pump(2.0)
        let largeBefore = try XCTUnwrap(cellImageWidths(browser).max())

        browser.view.onThumbnailSizeChanged?(80)
        browser.view.onThumbnailSizeSettled?(80)
        pump(1.5)

        let after = try XCTUnwrap(cellImageWidths(browser).max())
        XCTAssertGreaterThanOrEqual(after, 80,
                                    "a small cell still holds at least its own size in pixels")
        XCTAssertLessThanOrEqual(after, largeBefore,
                                 "and shrinking does not ask for a bigger decode than it had "
                                 + "(\(after) vs \(largeBefore))")
    }
}
