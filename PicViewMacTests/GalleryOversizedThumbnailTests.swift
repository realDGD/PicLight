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

/// The report this guard exists for: a grid cell showed the thumbnail of a *different* picture.
///
/// Reported exactly: with `Doriyanetwork-广州电信.jpg` open, the cell for `万萝图.png`
/// (48,000 × 32,000) showed the JPEG's thumbnail. The cause was the in-hand-bitmap fast path
/// comparing the session's *selection*: selecting the huge file moves the selection immediately but
/// its decode takes tens of seconds, so the canvas still holds the previous picture — and resampling
/// "the bitmap on screen" produced the previous picture's thumbnail for the new file.
@MainActor
final class GalleryStaleThumbnailTests: XCTestCase {

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

    /// Writes a solid PNG. `oversized` is achieved with a long edge above
    /// `DecodeBudget.maximumLongEdge`; the extra height is what makes its decode slow enough for the
    /// "selection moved, bitmap not updated yet" state to be entered deliberately.
    private func writeSolidPNG(_ url: URL, width: Int, height: Int,
                               red: CGFloat, green: CGFloat, blue: CGFloat) throws {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: red, green: green, blue: blue, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(
            url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }

    /// The colour at the centre of an image, so a delivery can be attributed to a picture.
    private func centreColor(of image: CGImage?) -> (r: CGFloat, g: CGFloat, b: CGFloat)? {
        guard let image else { return nil }
        var pixel = [UInt8](repeating: 0, count: 4)
        guard let context = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8,
                                      bytesPerRow: 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return (CGFloat(pixel[0]) / 255, CGFloat(pixel[1]) / 255, CGFloat(pixel[2]) / 255)
    }

    func testACellDoesNotBorrowThePreviousPicturesPixels() throws {
        let directory = try Fixtures.makeScratchDirectory("stale-thumb")
        defer { try? FileManager.default.removeItem(at: directory) }
        let opened = directory.appendingPathComponent("a-opened.png")
        let huge = directory.appendingPathComponent("b-huge.png")
        try writeSolidPNG(opened, width: 900, height: 700, red: 1, green: 0, blue: 0)
        // Oversized (9000 > 8192) *and* slow enough to decode that the canvas cannot have caught up
        // by the time the thumbnail is asked for.
        try writeSolidPNG(huge, width: 9000, height: 3000, red: 0, green: 0, blue: 1)

        let controller = ViewerWindowController()
        TestAppKit.presentOffScreen(controller)
        controller.window?.setFrame(NSRect(x: 0, y: 0, width: 1000, height: 800), display: false)
        controller.showWindow(nil)
        let viewer = controller.viewerViewController
        _ = viewer.view
        defer { TestAppKit.close(controller) }
        viewer.open(url: opened)
        XCTAssertTrue(waitUntil(15) { viewer.viewerState.currentImage != nil },
                      "precondition: the first picture is on screen")
        pump(0.2)
        let shown = try XCTUnwrap(centreColor(of: viewer.viewerState.currentImage))
        XCTAssertGreaterThan(shown.r, 0.8, "precondition: the canvas is showing the red picture")

        viewer.perform(.browseFolder)
        pump(0.8)
        viewer.view.layoutSubtreeIfNeeded()
        let browser = try XCTUnwrap(viewer.folderBrowserForTesting)
        let gallery = browser.view.gallery
        let hugeItem = try XCTUnwrap(gallery.items.first { $0.url.lastPathComponent == "b-huge.png" },
                                     "the huge file is in the folder")

        // Move the selection onto the huge file and immediately ask for its thumbnail: the decode has
        // not landed, so the canvas still holds the red picture.
        viewer.session.select(index: try XCTUnwrap(gallery.items.firstIndex(of: hugeItem)))
        var delivered: CGImage?
        var skip: GalleryThumbnailSkip = .none
        viewer.requestGalleryThumbnail(for: hugeItem, index: 0, maxPixelSize: 320) { _, image, reason in
            delivered = image
            skip = reason
        }
        XCTAssertTrue(waitUntil(20) { delivered != nil || skip != .none },
                      "the request was answered")
        pump(0.3)

        if let color = centreColor(of: delivered) {
            XCTAssertGreaterThan(color.b, 0.8,
                                 "a cell may only show the file's *own* pixels, never the previous "
                                 + "picture's (delivered colour r=\(color.r) g=\(color.g) b=\(color.b))")
            XCTAssertLessThan(color.r, 0.2, "and certainly not the red picture that was open before")
        } else {
            XCTAssertEqual(skip, .oversized,
                           "no image for an oversized source: the cell says so instead")
        }
        XCTAssertTrue(waitUntil(20) {
            gallery.cellForTesting(at: try! XCTUnwrap(gallery.items.firstIndex(of: hugeItem)))
                .map { $0.imageForTesting == nil
                    || self.centreColor(of: $0.imageForTesting?.cgImage(forProposedRect: nil,
                                                                       context: nil,
                                                                       hints: nil))
                        .map { $0.b > 0.8 } == true } ?? true
        }, "and the cell on screen follows the same rule")
    }
}
