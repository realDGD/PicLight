import XCTest
import AppKit
import CoreGraphics
@testable import PicViewMac

/// What the folder browser shows while thumbnails are being made.
///
/// A 48,000 × 32,000 PNG takes ImageIO ≈18 s for a 320 px thumbnail (measured on the user's own file),
/// and the same at every target size and subsampling factor. Nothing can make that decode fast; what
/// can be fixed is leaving the user staring at an empty grid with no idea whether it is working.
@MainActor
final class GalleryLoadingStateTests: XCTestCase {

    override func setUp() async throws {
        try await super.setUp()
        TestAppKit.ensureApplication()
    }

    private func pump(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    private func makeBrowser(count: Int = 8) throws
        -> (directory: URL, controller: ViewerWindowController,
            viewer: ViewerViewController, browser: FolderBrowserViewController) {
        let directory = try Fixtures.makeScratchDirectory("gallery-loading")
        for index in 0..<count {
            try FileManager.default.copyItem(
                at: Fixtures.url("static.png"),
                to: directory.appendingPathComponent("img\(index).png"))
        }
        let controller = ViewerWindowController()
        TestAppKit.presentOffScreen(controller)
        controller.window?.setFrame(NSRect(x: 0, y: 0, width: 1000, height: 800), display: false)
        controller.showWindow(nil)
        let viewer = controller.viewerViewController
        _ = viewer.view
        viewer.open(url: directory.appendingPathComponent("img0.png"))
        let deadline = Date().addingTimeInterval(10)
        while viewer.viewerState.currentImage == nil, Date() < deadline { pump(0.05) }
        viewer.perform(.browseFolder)
        pump(0.5)
        viewer.view.layoutSubtreeIfNeeded()
        let browser = try XCTUnwrap(viewer.folderBrowserForTesting)
        browser.view.layoutSubtreeIfNeeded()
        // The folder's own thumbnails are still arriving at this point, and the tests below assert exact
        // counts of what is left to load. Waiting for the grid to settle is what makes those counts
        // about the test's own request instead of about the folder's.
        let settled = Date().addingTimeInterval(20)
        while browser.view.gallery.loadingThumbnailCount > 0, Date() < settled { pump(0.05) }
        XCTAssertEqual(browser.view.gallery.loadingThumbnailCount, 0,
                       "precondition: the folder's thumbnails are all in")
        return (directory, controller, viewer, browser)
    }

    /// A visible cell that is waiting shows a placeholder saying so, and reports the wait.
    func testCellsWaitingForAThumbnailShowAPlaceholderAndReportIt() throws {
        let (directory, controller, _, browser) = try makeBrowser()
        defer { TestAppKit.close(controller); try? FileManager.default.removeItem(at: directory) }
        let gallery = browser.view.gallery
        let index = 0
        let url = gallery.items[index].url
        // A request is only made for a cell that has nothing: forget what was delivered while the
        // folder was opening.
        gallery.dropDelivered(for: url)

        // The bookkeeping the request path drives: a request marks the item loading.
        gallery.noteThumbnailRequested(for: url)
        gallery.layoutSubtreeIfNeeded()

        XCTAssertTrue(gallery.isLoading(gallery.items[index]))
        XCTAssertGreaterThan(gallery.loadingThumbnailCount, 0)
        let cell = try XCTUnwrap(gallery.cellForTesting(at: index), "the cell is on screen")
        XCTAssertEqual(cell.loadingCaptionForTesting, "载入中…",
                       "a waiting cell says so instead of looking empty")

        // The delivery clears it.
        let context = CGContext(data: nil, width: 64, height: 48, bitsPerComponent: 8,
                                bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.2, green: 0.6, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
        let image = context.makeImage()!
        gallery.noteDelivered(image, pixelSize: 128, versionToken: "test", for: url)
        gallery.updateThumbnail(for: url, image: image)
        XCTAssertFalse(gallery.isLoading(gallery.items[index]))
        XCTAssertNil(cell.loadingCaptionForTesting, "the placeholder goes when the picture arrives")
        XCTAssertNotNil(cell.imageForTesting)
    }

    /// A file that cannot be thumbnailed stops claiming to load.
    func testAFailedRequestDropsThePlaceholder() throws {
        let (directory, controller, _, browser) = try makeBrowser()
        defer { TestAppKit.close(controller); try? FileManager.default.removeItem(at: directory) }
        let gallery = browser.view.gallery
        let url = gallery.items[0].url
        gallery.noteThumbnailRequested(for: url)
        XCTAssertEqual(gallery.loadingThumbnailCount, 1)

        gallery.noteThumbnailFailed(for: url)
        XCTAssertEqual(gallery.loadingThumbnailCount, 0, "no spinner for a file that will never load")
        let cell = try XCTUnwrap(gallery.cellForTesting(at: 0))
        XCTAssertNil(cell.loadingCaptionForTesting)
    }

    /// An enormous picture gets its own sentence: "loading" would read as a hang after a minute.
    func testAnEnormousImageSaysWhatItIs() {
        let huge = FolderItem(url: URL(fileURLWithPath: "/tmp/huge.png"),
                              pixelSize: CGSize(width: 48000, height: 32000))
        XCTAssertEqual(GalleryGridView.loadingCaption(for: huge), "超大图片，正在生成缩略图…")
        let ordinary = FolderItem(url: URL(fileURLWithPath: "/tmp/small.png"),
                                  pixelSize: CGSize(width: 4000, height: 3000))
        XCTAssertEqual(GalleryGridView.loadingCaption(for: ordinary), "载入中…")
        let unknown = FolderItem(url: URL(fileURLWithPath: "/tmp/unknown.png"))
        XCTAssertEqual(GalleryGridView.loadingCaption(for: unknown), "载入中…",
                       "until the dimensions are probed it is just another picture")
    }

    /// The toolbar readout counts what is on screen and disappears when nothing is pending.
    func testTheToolbarReportsThumbnailProgress() throws {
        let (directory, controller, _, browser) = try makeBrowser()
        defer { TestAppKit.close(controller); try? FileManager.default.removeItem(at: directory) }
        let view = browser.view
        XCTAssertNil(view.thumbnailProgressTextForTesting, "nothing pending, nothing shown")

        view.updateThumbnailProgress(loading: 3, total: 12)
        XCTAssertEqual(view.thumbnailProgressTextForTesting, "缩略图 9 / 12")

        view.updateThumbnailProgress(loading: 0, total: 12)
        XCTAssertNil(view.thumbnailProgressTextForTesting, "and it goes away when the work is done")
    }

    /// End to end: opening a folder marks the visible cells as loading, and they finish.
    func testOpeningAFolderShowsAndThenClearsTheLoadingState() throws {
        let (directory, controller, _, browser) = try makeBrowser(count: 12)
        defer { TestAppKit.close(controller); try? FileManager.default.removeItem(at: directory) }
        let gallery = browser.view.gallery

        // Deliveries are asynchronous; either we catch the wait, or it is already finished — but the
        // bookkeeping must be consistent either way, and it must finish.
        let deadline = Date().addingTimeInterval(20)
        while gallery.loadingThumbnailCount > 0, Date() < deadline { pump(0.1) }

        XCTAssertEqual(gallery.loadingThumbnailCount, 0, "every visible request finished")
        XCTAssertGreaterThan(gallery.thumbnailRequestAnnouncementsForTesting, 0,
                             "the cells announced that they were waiting, so the placeholder and the "
                             + "readout were reachable")
        XCTAssertNil(browser.view.thumbnailProgressTextForTesting)
        XCTAssertGreaterThan(gallery.materializedCellCount, 0)
        for index in 0..<gallery.materializedCellCount {
            let cell = try XCTUnwrap(gallery.cellForTesting(at: index))
            XCTAssertNil(cell.loadingCaptionForTesting,
                         "no cell is left claiming to load after the folder settled")
        }
    }
}
