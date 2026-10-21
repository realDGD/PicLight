import XCTest
import AppKit
import CoreGraphics
import ImageIO
@testable import PicViewMac

/// The drawer's thumbnails are a window over the folder, not a copy of it.
///
/// Measured before the fix: 200 thumbnails of 400×400 sources were held at once — about 69 MiB —
/// and emptying the folder list released none of them, because the dictionary of strong references
/// had no eviction and the pipeline's own `NSCache` budget cannot see through it.
@MainActor
final class DrawerThumbnailBudgetTests: XCTestCase {

    override func setUp() async throws {
        try await super.setUp()
        TestAppKit.ensureApplication()
    }

    private func pump(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    private func waitUntil(_ timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return condition()
    }

    private func writePNG(to url: URL, side: Int, red: CGFloat) {
        let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8,
                                bytesPerRow: side * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: red, green: 0.3, blue: 0.4, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        let destination = CGImageDestinationCreateWithURL(url as CFURL,
                                                          "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        _ = CGImageDestinationFinalize(destination)
    }

    private func makeViewer() -> (ViewerWindowController, ViewerViewController) {
        let controller = ViewerWindowController()
        TestAppKit.presentOffScreen(controller)
        controller.window?.setFrame(NSRect(x: 0, y: 0, width: 1000, height: 760), display: false)
        controller.showWindow(nil)
        let viewer = controller.viewerViewController
        _ = viewer.view
        viewer.view.layoutSubtreeIfNeeded()
        return (controller, viewer)
    }

    /// Asking for every row's thumbnail must not retain every row's thumbnail.
    func testTheDrawerKeepsAWindowNotTheWholeFolder() throws {
        let directory = try Fixtures.makeScratchDirectory("drawer-budget")
        defer { try? FileManager.default.removeItem(at: directory) }
        let count = 200
        for index in 0..<count {
            writePNG(to: directory.appendingPathComponent(String(format: "img%03d.png", index)),
                     side: 400, red: CGFloat(index) / CGFloat(count))
        }

        let (controller, viewer) = makeViewer()
        defer { TestAppKit.close(controller) }
        viewer.open(url: directory.appendingPathComponent("img000.png"))
        XCTAssertTrue(waitUntil(20) { viewer.viewerState.currentImage != nil })
        // The drawer has to be on screen for its window to mean anything.
        viewer.setDrawerOpen(true)
        pump(0.4)
        viewer.view.layoutSubtreeIfNeeded()

        for item in viewer.session.items { viewer.requestThumbnailForTesting(item) }
        XCTAssertTrue(waitUntil(60) { viewer.thumbnailRequestDiagnostics().active == 0 },
                      "every request settles")
        pump(0.3)

        let retained = viewer.thumbnailCacheCountForTesting
        let bytes = viewer.thumbnailCacheBytesForTesting
        XCTAssertLessThan(retained, count,
                          "the drawer must not hold a copy of the folder "
                          + "(retained \(retained) of \(count), \(bytes / 1024 / 1024) MiB)")
        XCTAssertLessThanOrEqual(retained, 140,
                                 "the retained set is a window plus the prefetch band, "
                                 + "not \(count) pictures")
    }

    /// A folder change releases what the new folder cannot show.
    func testANewListReleasesThePreviousFoldersThumbnails() throws {
        let directory = try Fixtures.makeScratchDirectory("drawer-prune")
        defer { try? FileManager.default.removeItem(at: directory) }
        for index in 0..<12 {
            writePNG(to: directory.appendingPathComponent("img\(index).png"),
                     side: 400, red: CGFloat(index) / 12)
        }
        let (controller, viewer) = makeViewer()
        defer { TestAppKit.close(controller) }
        viewer.open(url: directory.appendingPathComponent("img0.png"))
        XCTAssertTrue(waitUntil(20) { viewer.viewerState.currentImage != nil })
        viewer.setDrawerOpen(true)
        pump(0.4)
        for item in viewer.session.items { viewer.requestThumbnailForTesting(item) }
        XCTAssertTrue(waitUntil(30) { viewer.thumbnailCacheCountForTesting > 0 })

        viewer.session.setItems([])
        pump(0.3)
        XCTAssertEqual(viewer.thumbnailCacheCountForTesting, 0,
                       "an empty list has nothing to keep (measured before: still 60 entries)")
        XCTAssertEqual(viewer.thumbnailCacheBytesForTesting, 0)
    }

    /// A replacement at the same path is not served from the drawer's cache either.
    func testAReplacementDropsTheDrawerThumbnail() throws {
        let directory = try Fixtures.makeScratchDirectory("drawer-replacement")
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("photo.png")
        writePNG(to: file, side: 400, red: 0.9)
        writePNG(to: directory.appendingPathComponent("other.png"), side: 400, red: 0.2)

        let (controller, viewer) = makeViewer()
        defer { TestAppKit.close(controller) }
        viewer.open(url: file)
        XCTAssertTrue(waitUntil(20) { viewer.viewerState.currentImage != nil })
        viewer.setDrawerOpen(true)
        pump(0.4)
        let currentItem = try XCTUnwrap(viewer.session.currentItem)
        // The session's own URL: the scan canonicalizes the folder, and `/var/...` and
        // `/private/var/...` are two keys to a dictionary.
        viewer.requestThumbnailForTesting(currentItem)
        XCTAssertTrue(waitUntil(20) { viewer.hasCachedThumbnailForTesting(currentItem.url) },
                      "precondition: the drawer has a thumbnail for the file on screen "
                      + "(diag: \(viewer.thumbnailRequestDiagnostics()))")

        try? FileManager.default.removeItem(at: file)
        writePNG(to: file, side: 400, red: 0.1)
        // Whatever the drawer holds after the replacement must describe the file that is there now —
        // either it was dropped and re-delivered, or it never was the old file's picture. The
        // watcher's rescan is what re-checks it.
        XCTAssertTrue(waitUntil(15) {
            let current = SourceFileIdentity.read(at: currentItem.url).versionToken
            return viewer.cachedThumbnailVersionForTesting(currentItem.url) == nil
                || viewer.cachedThumbnailVersionForTesting(currentItem.url) == current
        }, "the retained thumbnail is a picture of the file at that path now")
    }
}
