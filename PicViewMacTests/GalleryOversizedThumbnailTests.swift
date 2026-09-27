import XCTest
import AppKit
import CoreGraphics
@testable import PicViewMac

/// The drawer's thumbnail policy, applied to the folder grid.
///
/// The drawer has always done two things the grid did not: an item whose pixels the viewer already
/// holds is resampled instead of the file being read again, and an *oversized* source is not decoded
/// at all — a 300 px thumbnail of one costs the same whole-stream decode as the file itself (measured
/// on a real 48,000 × 32,000 PNG: 18.4 s at 320 px, and the same at 64 px and with a subsampling factor
/// of 16). A grid of such files spent minutes starting one decode per visible cell.
@MainActor
final class GalleryOversizedThumbnailTests: XCTestCase {

    override func setUp() async throws {
        try await super.setUp()
        TestAppKit.ensureApplication()
        ThumbnailPipelineMetrics.reset()
    }

    private func pump(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    private func waitUntil(_ timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { pump(0.05) }
        return condition()
    }

    /// A file whose *header* says it is bigger than `DecodeBudget.maximumLongEdge`, which is what the
    /// policy looks at. 9000 × 100 keeps the fixture cheap to write while still being oversized.
    private func writeOversizedPNG(_ url: URL) throws {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 9000, height: 100, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.7, blue: 0.4, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 9000, height: 100))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(
            url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }

    /// The scaffolding folder. Paths are taken from the *app's* own items in the assertions below:
    /// the scanner reports `/private/var/…` while `FileManager.temporaryDirectory` spells the same
    /// place `/var/…`, and URLs across the two spellings are not equal — a test comparing them looks
    /// at the right cell and compares the wrong path.
    private func makeFolder() throws -> (directory: URL, oversized: URL) {
        let directory = try Fixtures.makeScratchDirectory("oversized-grid")
        for index in 0..<4 {
            try FileManager.default.copyItem(
                at: Fixtures.url("static.png"),
                to: directory.appendingPathComponent("normal\(index).png"))
        }
        let oversized = directory.appendingPathComponent("huge.png")
        try writeOversizedPNG(oversized)
        return (directory, oversized)
    }

    private func makeBrowser(opening file: URL) throws
        -> (controller: ViewerWindowController, viewer: ViewerViewController,
            browser: FolderBrowserViewController) {
        let controller = ViewerWindowController()
        TestAppKit.presentOffScreen(controller)
        controller.window?.setFrame(NSRect(x: 0, y: 0, width: 1000, height: 800), display: false)
        controller.showWindow(nil)
        let viewer = controller.viewerViewController
        _ = viewer.view
        viewer.open(url: file)
        XCTAssertTrue(waitUntil(15) { viewer.viewerState.currentImage != nil },
                      "precondition: the opened file decoded")
        viewer.perform(.browseFolder)
        pump(0.6)
        viewer.view.layoutSubtreeIfNeeded()
        let browser = try XCTUnwrap(viewer.folderBrowserForTesting)
        browser.view.layoutSubtreeIfNeeded()
        return (controller, viewer, browser)
    }

    /// The oversized file's cell says so, and nothing ever decodes it for the grid.
    func testAnOversizedFileIsNeverDecodedForItsCell() throws {
        let (directory, oversized) = try makeFolder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (controller, _, browser) = try makeBrowser(
            opening: directory.appendingPathComponent("normal0.png"))
        defer { TestAppKit.close(controller) }
        let gallery = browser.view.gallery

        // Let every request settle, including the retry the scroll/layout pass may issue.
        pump(2.5)
        browser.view.layoutSubtreeIfNeeded()
        pump(0.5)

        let oversizedIndex = try XCTUnwrap(
            gallery.items.firstIndex { $0.url.lastPathComponent == oversized.lastPathComponent },
            "the oversized file is in the folder")
        let oversizedURL = gallery.items[oversizedIndex].url
        var sawCaption = false
        for index in 0..<gallery.materializedCellCount where gallery.items.indices.contains(index) {
            guard gallery.items[index].url == oversizedURL else { continue }
            let cell = try XCTUnwrap(gallery.cellForTesting(at: index))
            XCTAssertNil(cell.imageForTesting, "no thumbnail is invented for an oversized source")
            if cell.loadingCaptionForTesting == GalleryGridView.oversizedCaption { sawCaption = true }
        }
        let captions = (0..<gallery.materializedCellCount)
            .compactMap { gallery.cellForTesting(at: $0)?.loadingCaptionForTesting }
        XCTAssertTrue(sawCaption,
                      "the cell says the file is oversized and what to do about it "
                      + "(captions: \(captions))")
        XCTAssertFalse(ThumbnailPipelineMetrics.decodedFilePaths.contains(oversizedURL.path),
                       "the whole-stream decode the drawer refuses was not started for the grid")
        // The ordinary pictures around it still got their thumbnails. Not the *opened* one: its cell
        // is served from the bitmap the canvas already holds (see the test below), so its file is
        // never read for a thumbnail at all.
        XCTAssertTrue(ThumbnailPipelineMetrics.decodedFilePaths.contains(
            try XCTUnwrap(gallery.items.first { $0.url.lastPathComponent == "normal2.png" }).url.path),
                      "and the ordinary pictures around it still got their thumbnails "
                      + "(\(ThumbnailPipelineMetrics.decodedFilePaths))")
    }

    /// The picture on screen is thumbnailed from the bitmap the canvas already decoded: no file read,
    /// no decode, and the result is remembered so the next request at that size is free.
    func testTheCurrentFileIsServedFromThePixelsInHand() throws {
        let (directory, _) = try makeFolder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let current = directory.appendingPathComponent("normal1.png")
        let (controller, viewer, browser) = try makeBrowser(opening: current)
        defer { TestAppKit.close(controller) }

        let item = try XCTUnwrap(viewer.session.currentItem, "the opened file is the current item")
        XCTAssertEqual(item.url.lastPathComponent, current.lastPathComponent,
                       "the session is on the file this test opened")
        let previewsBefore = ThumbnailPipelineMetrics.previewCount
        let decodesBefore = ThumbnailPipelineMetrics.decodedFilePaths

        var delivered: CGImage?
        viewer.requestGalleryThumbnail(for: item, index: 0, maxPixelSize: 320) { _, image, _ in
            delivered = image
        }
        XCTAssertTrue(waitUntil(10) { delivered != nil },
                      "the request is answered from the bitmap in hand")
        XCTAssertGreaterThan(ThumbnailPipelineMetrics.previewCount, previewsBefore,
                             "and it was a resample, not a decode")
        XCTAssertEqual(ThumbnailPipelineMetrics.decodedFilePaths, decodesBefore,
                       "the file was not read for it")

        // The grid's own cell is filled the same way.
        let index = try XCTUnwrap(browser.view.gallery.items.firstIndex { $0.url == item.url },
                                  "the current item has a cell")
        XCTAssertTrue(waitUntil(10) {
            browser.view.gallery.deliveredPathsForTesting.contains(item.url.path)
        }, "the current file's cell is filled")
        let cell = try XCTUnwrap(browser.view.gallery.cellForTesting(at: index))
        XCTAssertNotNil(cell.imageForTesting)
        XCTAssertNil(cell.loadingCaptionForTesting, "it is not waiting for anything")
    }

    /// Opening an oversized file produces its thumbnail, and the grid then shows it.
    func testAnOversizedFileGetsItsThumbnailOnceItIsOpened() throws {
        let (directory, oversized) = try makeFolder()
        defer { try? FileManager.default.removeItem(at: directory) }
        // Enter the grid first, where the cell can only say "open it".
        let (controller, viewer, browser) = try makeBrowser(
            opening: directory.appendingPathComponent("normal0.png"))
        defer { TestAppKit.close(controller) }
        let gallery = browser.view.gallery
        pump(2.5)
        let oversizedIndex = try XCTUnwrap(
            gallery.items.firstIndex { $0.url.lastPathComponent == oversized.lastPathComponent },
            "the oversized file is in the folder")
        let oversizedURL = gallery.items[oversizedIndex].url
        XCTAssertNil(gallery.cellForTesting(at: oversizedIndex)?.imageForTesting,
                     "precondition: no thumbnail for it yet")

        // Open it: the viewer decodes it (9000 × 100 is cheap), which puts its pixels in hand.
        browser.view.gallery.setCurrentIndex(oversizedIndex, visibility: .revealCurrent)
        if let item = viewer.session.currentItem, item.url == oversized {
            viewer.openGalleryItem(at: oversizedIndex)
        } else {
            viewer.open(url: oversized)
        }
        XCTAssertTrue(waitUntil(15) { viewer.viewerState.currentImage != nil },
                      "the picture opened")
        viewer.perform(.browseFolder)
        pump(1.5)
        browser.view.layoutSubtreeIfNeeded()
        pump(1.0)

        XCTAssertTrue(gallery.deliveredPathsForTesting.contains(oversizedURL.path),
                      "opening the file is what produces its thumbnail — from the decoded bitmap")
        XCTAssertNotNil(gallery.cellForTesting(at: oversizedIndex)?.imageForTesting,
                        "and the cell shows it")
        XCTAssertNil(gallery.cellForTesting(at: oversizedIndex)?.loadingCaptionForTesting)
    }
}
