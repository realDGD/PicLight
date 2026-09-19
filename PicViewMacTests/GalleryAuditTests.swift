import XCTest
import AppKit
import CoreGraphics
import ImageIO
@testable import PicViewMac

// MARK: - Deterministic audit host

/// A gallery host with no windows, no files and no pipeline: the browser's request scope and its
/// delivery races are driven by hand, so the numbers are reproducible run to run.
@MainActor
final class GalleryAuditHost: FolderBrowserHost {
    struct Record: Equatable {
        let url: URL
        let index: Int
        let maxPixelSize: Int
    }

    let session: FolderSession
    var galleryLayoutKind: GalleryLayoutKind = .uniformGrid
    var galleryThumbnailSize: CGFloat = 160

    private(set) var requests: [Record] = []
    /// Every completion handed out, in order — a test fires them in whichever order it needs.
    private(set) var completions: [(url: URL, index: Int, completion: (Int, CGImage?) -> Void)] = []
    private(set) var cancelCount = 0
    private(set) var leaves = 0
    /// When set, each request completes immediately with the returned image.
    var autoDeliver: ((URL, Int) -> CGImage?)?

    init(items: [FolderItem], directory: URL? = nil) {
        self.session = FolderSession(items: items, directory: directory)
    }

    func requestGalleryThumbnail(for item: FolderItem, index: Int, maxPixelSize: Int,
                                 completion: @escaping (Int, CGImage?) -> Void) {
        requests.append(Record(url: item.url, index: index, maxPixelSize: maxPixelSize))
        completions.append((item.url, index, completion))
        if let image = autoDeliver?(item.url, maxPixelSize) {
            completion(index, image)
        }
    }

    func cancelGalleryThumbnails() { cancelCount += 1 }
    func openFolder(_ url: URL) {}
    func leaveFolderBrowser() { leaves += 1 }
    func openGalleryItem(at index: Int) {}

    func requests(for url: URL) -> [Record] { requests.filter { $0.url == url } }
}

// MARK: - Helpers

private func auditItem(_ index: Int, folder: String = "gallery-a") -> FolderItem {
    FolderItem(url: URL(fileURLWithPath: "/tmp/\(folder)/img-\(index).png"),
               pixelSize: CGSize(width: 2, height: 2))
}

private func solidImage(width: Int, height: Int, red: CGFloat, green: CGFloat = 0.3,
                        blue: CGFloat = 0.4) -> CGImage {
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                            bytesPerRow: width * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(CGColor(red: red, green: green, blue: blue, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return context.makeImage()!
}

private func pump(_ seconds: TimeInterval) {
    RunLoop.current.run(until: Date().addingTimeInterval(seconds))
}

@MainActor
private func presentOffScreen(_ view: NSView, size: NSSize = NSSize(width: 1200, height: 800))
    -> NSWindow {
    let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                          styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = view
    window.setFrameOrigin(NSPoint(x: -30000, y: -30000))
    window.makeKeyAndOrderFront(nil)
    view.layoutSubtreeIfNeeded()
    window.layoutIfNeeded()
    return window
}

// MARK: - The audit: request scope, retention, slider tiers, races

/// The audit's deterministic measurements. The first two tests are written against the shipped
/// behaviour and are expected to FAIL while the known issues are present — they are the
/// reproduction, and the same assertions become the regression tests once fixed.
@MainActor
final class GalleryAuditTests: XCTestCase {

    override func setUp() async throws {
        try await super.setUp()
        TestAppKit.ensureApplication()
    }

    /// A: how many thumbnails does the first load actually ask for, across folder sizes?
    ///
    /// The invariant: the number must be a function of the visible window, not of the folder size.
    func testFirstLoadRequestCountAcrossFolderSizes() throws {
        for count in [100, 1_000, 5_000, 10_000] {
            let host = GalleryAuditHost(
                items: (0..<count).map { auditItem($0) },
                directory: URL(fileURLWithPath: "/tmp/gallery-a"))
            let browser = FolderBrowserViewController(host: host)
            let window = presentOffScreen(browser.view)
            defer { window.close() }
            let started = Date()
            browser.reload()
            window.layoutIfNeeded()
            let layoutSeconds = Date().timeIntervalSince(started)
            pump(0.3)
            print("METRIC A \(count)-item folder: requests=\(browser.thumbnailRequestCount) "
                + "materializedCells=\(browser.view.gallery.materializedCellCount) "
                + "reload+firstLayout=\(String(format: "%.3f", layoutSeconds))s")
            XCTAssertLessThanOrEqual(browser.thumbnailRequestCount, 250,
                                     "A(\(count)): first load must request visible+prefetch rows only, "
                                     + "got \(browser.thumbnailRequestCount) for \(count) items")
        }
    }

    /// B: after scrolling through the whole folder, what does the gallery still hold?
    func testScrollingThroughTheFolderDoesNotRetainEveryThumbnail() throws {
        let count = 2_000
        let host = GalleryAuditHost(
            items: (0..<count).map { auditItem($0) },
            directory: URL(fileURLWithPath: "/tmp/gallery-a"))
        host.autoDeliver = { _, _ in solidImage(width: 64, height: 64, red: 0.8) }
        let browser = FolderBrowserViewController(host: host)
        let window = presentOffScreen(browser.view)
        defer { window.close() }
        browser.reload()
        pump(0.3)
        let grid = browser.view.gallery
        let scroll = try XCTUnwrap(grid.enclosingScrollView)
        let rows = grid.rows
        let contentHeight = GalleryLayout.contentHeight(of: rows)
        let viewportHeight = scroll.contentView.bounds.height
        let maxY = max(0, contentHeight - viewportHeight)
        var y: CGFloat = 0
        while y < maxY {
            y = min(y + 500, maxY)
            scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
            scroll.reflectScrolledClipView(scroll.contentView)
            grid.needsLayout = true
            grid.layoutSubtreeIfNeeded()
            pump(0.01)
        }
        pump(0.2)
        print("METRIC B after full scroll of \(count) items: materialized=\(grid.materializedCellCount) "
            + "requests=\(browser.thumbnailRequestCount)")

        let gridAfter = browser.view.gallery
        XCTAssertLessThan(gridAfter.materializedCellCount, 100,
                          "cells stay a window, never the folder")
        // The first item scrolled past long ago must not still be strongly retained.
        XCTAssertFalse(gridAfter.deliveredPathsForTesting.contains(auditItem(0).url.path),
                       "B: an item scrolled past must not remain retained (index 0 of \(count))")
        XCTAssertFalse(gridAfter.deliveredPathsForTesting.contains(auditItem(count / 2).url.path),
                       "B: the middle of the folder must not be retained either")
    }

    /// K: scrolling one page at a time requests only what each page newly needs — the request
    /// count grows with the *pages visited times a window*, never with the folder size.
    func testScrollingRequestsOnlyNewlyRevealedRows() throws {
        let count = 5_000
        let host = GalleryAuditHost(
            items: (0..<count).map { auditItem($0) },
            directory: URL(fileURLWithPath: "/tmp/gallery-a"))
        host.autoDeliver = { _, _ in solidImage(width: 64, height: 64, red: 0.8) }
        let browser = FolderBrowserViewController(host: host)
        let window = presentOffScreen(browser.view)
        defer { window.close() }
        browser.reload()
        pump(0.3)
        let grid = browser.view.gallery
        let scroll = try XCTUnwrap(grid.enclosingScrollView)
        let contentHeight = GalleryLayout.contentHeight(of: grid.rows)
        let viewportHeight = scroll.contentView.bounds.height
        let maxY = max(0, contentHeight - viewportHeight)

        var before = browser.thumbnailRequestCount
        var y: CGFloat = 0
        var pages = 0
        while y < maxY {
            y = min(y + 600, maxY)
            scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
            scroll.reflectScrolledClipView(scroll.contentView)
            grid.needsLayout = true
            grid.layoutSubtreeIfNeeded()
            pump(0.02)
            let after = browser.thumbnailRequestCount
            let pageDelta = after - before
            before = after
            pages += 1
            XCTAssertLessThanOrEqual(pageDelta, 250,
                                     "K: one scroll page adds only the newly revealed window, "
                                     + "got +\(pageDelta) requests on page \(pages)")
        }
        print("METRIC K scrolled \(pages) pages of a \(count)-item folder; "
            + "total requests=\(browser.thumbnailRequestCount)")
        XCTAssertLessThanOrEqual(browser.thumbnailRequestCount, count,
                                 "K: a forward scroll fetches each item once, as it first enters "
                                 + "the window — never more than the folder holds, got "
                                 + "\(browser.thumbnailRequestCount) of \(count)")
    }

    /// C: does sliding from 80 to 320 actually request sharper pixels?
    func testSliderUpgradeRequestsSharperThumbnails() throws {
        let host = GalleryAuditHost(items: (0..<12).map { auditItem($0) },
                                    directory: URL(fileURLWithPath: "/tmp/gallery-a"))
        host.autoDeliver = { _, size in solidImage(width: size, height: size, red: 0.2) }
        let browser = FolderBrowserViewController(host: host)
        let window = presentOffScreen(browser.view)
        defer { window.close() }
        browser.reload()
        pump(0.3)

        // Live reflow only, then a settle at the small size: requests at 160 px.
        browser.view.onThumbnailSizeChanged?(80)
        browser.view.onThumbnailSizeSettled?(80)
        pump(0.6)
        let smallRequests = host.requests(for: auditItem(0).url)
        XCTAssertFalse(smallRequests.isEmpty)

        // Now enlarge. The settle must ask for a *sharper* thumbnail, not reuse the old pixels.
        browser.view.onThumbnailSizeChanged?(320)
        browser.view.onThumbnailSizeSettled?(320)
        pump(0.6)
        let largeRequests = host.requests(for: auditItem(0).url)
        print("METRIC C requests for item 0 at 80pt: \(smallRequests.map(\.maxPixelSize)); "
            + "after settle at 320pt: \(largeRequests.map(\.maxPixelSize))")
        XCTAssertTrue(largeRequests.contains { $0.maxPixelSize >= 640 },
                      "C: settling at 320 pt must request a ≥640 px thumbnail, got "
                      + "\(largeRequests.map(\.maxPixelSize))")
    }

    /// C3: shrinking the slider again downgrades the *displayed* tier but must not re-decode —
    /// the already-delivered sharper thumbnail keeps serving the smaller slot.
    func testSliderDowngradeDoesNotDecodeAgain() throws {
        let host = GalleryAuditHost(items: (0..<12).map { auditItem($0) },
                                    directory: URL(fileURLWithPath: "/tmp/gallery-a"))
        host.autoDeliver = { _, _ in solidImage(width: 320, height: 320, red: 0.2) }
        let browser = FolderBrowserViewController(host: host)
        let window = presentOffScreen(browser.view)
        defer { window.close() }
        browser.reload()
        pump(0.3)
        let item0 = auditItem(0)
        let requestsBefore = host.requests(for: item0.url).count

        browser.view.onThumbnailSizeChanged?(80)
        browser.view.onThumbnailSizeSettled?(80)
        pump(0.6)
        let afterDowngrade = host.requests(for: item0.url).count
        print("METRIC C3 requests for item 0 before/after downgrade to 80pt: "
            + "\(requestsBefore) → \(afterDowngrade)")
        XCTAssertEqual(afterDowngrade, requestsBefore,
                       "C3: a downgrade must not re-request: the delivered ≥160 px tier already "
                       + "serves the 80 pt slot")
        // And the sharper image is what the cell keeps showing.
        let cell = try XCTUnwrap(browser.view.gallery.cellForTesting(at: 0))
        XCTAssertEqual(cell.imageForTesting?.size.width ?? 0, 320,
                       "the sharper thumbnail stays on screen after the downgrade")
    }

    /// I: a late low-resolution completion must not overwrite a newer high-resolution one.
    func testOldLowResolutionCompletionCannotOverwriteNewHighResolution() throws {
        let host = GalleryAuditHost(items: (0..<12).map { auditItem($0) },
                                    directory: URL(fileURLWithPath: "/tmp/gallery-a"))
        let browser = FolderBrowserViewController(host: host)
        let window = presentOffScreen(browser.view)
        defer { window.close() }
        browser.reload()
        pump(0.3)

        // Request at 80 pt; do NOT let the low-res complete yet.
        browser.view.onThumbnailSizeChanged?(80)
        browser.view.onThumbnailSizeSettled?(80)
        pump(0.6)
        let item0 = auditItem(0)
        let lowRequests = host.requests(for: item0.url)
        XCTAssertGreaterThanOrEqual(lowRequests.count, 1)

        // The drag settles at 320 pt while the low-res request is still in flight.
        browser.view.onThumbnailSizeChanged?(320)
        browser.view.onThumbnailSizeSettled?(320)
        pump(0.7)
        let highRequests = host.requests(for: item0.url)
        let high = highRequests.last { $0.maxPixelSize >= 640 }
        XCTAssertNotNil(high, "I: an upgrade at settle must exist for the old completion to race")

        // The old low-res completes AFTER the new high-res request was issued, and then the new one.
        let itemCompletions = host.completions.filter { $0.url == item0.url }
        let lowCompletion = itemCompletions.first?.completion   // the 160 px request
        let highCompletion = itemCompletions.last?.completion   // the 640 px request
        XCTAssertNotNil(lowCompletion)
        XCTAssertNotNil(highCompletion)
        // The new high-res result lands first; the stale low-res completion arrives late.
        highCompletion!(0, solidImage(width: 640, height: 640, red: 0.1))
        pump(0.05)
        lowCompletion!(0, solidImage(width: 160, height: 160, red: 0.9))
        pump(0.1)

        let cell = try XCTUnwrap(browser.view.gallery.cellForTesting(at: 0))
        let shown = cell.imageForTesting?.size ?? .zero
        print("METRIC I final cell image size after late low-res completion: \(shown)")
        XCTAssertEqual(shown.width, 640,
                       "I: the late 160 px completion must not overwrite the 640 px thumbnail, got \(shown)")
    }

    /// J: folder switch — old folder thumbnails must leave, and a late completion from folder A
    /// must never land in folder B.
    func testFolderSwitchDropsOldFolderAndRejectsLateCompletions() throws {
        let host = GalleryAuditHost(
            items: (0..<12).map { auditItem($0, folder: "gallery-a") },
            directory: URL(fileURLWithPath: "/tmp/gallery-a"))
        host.autoDeliver = { _, _ in solidImage(width: 64, height: 64, red: 0.8) }
        let browser = FolderBrowserViewController(host: host)
        let window = presentOffScreen(browser.view)
        defer { window.close() }
        browser.reload()
        pump(0.3)
        let itemA0 = auditItem(0, folder: "gallery-a")
        XCTAssertTrue(browser.view.gallery.deliveredPathsForTesting.contains(itemA0.url.path),
                      "precondition: folder A's thumbnail was delivered")

        // Switch to folder B.
        let itemsB = (0..<12).map { auditItem($0, folder: "gallery-b") }
        host.session.setItems(itemsB)
        browser.reload()
        pump(0.3)

        XCTAssertFalse(browser.view.gallery.deliveredPathsForTesting.contains(itemA0.url.path),
                       "J: folder A's thumbnails must be gone after the switch")

        // Now a completion from folder A's request arrives late.
        if let stale = host.completions.first(where: { $0.url == itemA0.url }) {
            stale.completion(stale.index, solidImage(width: 64, height: 64, red: 0.95))
        }
        pump(0.1)
        XCTAssertFalse(browser.view.gallery.deliveredPathsForTesting.contains(itemA0.url.path),
                       "J: a late folder-A completion must not re-enter folder B's gallery")
        let b0Cell = browser.view.gallery.cellForTesting(at: 0)?.imageForTesting
        XCTAssertNotNil(b0Cell, "folder B has its own thumbnail on screen")
    }

    /// D: the pipeline must not serve the old bytes after a same-path replacement.
    func testPipelineServesFreshPixelsAfterSamePathReplacement() async throws {
        let scratch = try Fixtures.makeScratchDirectory("identity-replacement")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let file = scratch.appendingPathComponent("replaced.png")

        func writePNG(red: CGFloat, width: Int = 96, height: Int = 96) {
            let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                    bytesPerRow: width * 4,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.setFillColor(CGColor(red: red, green: 0.1, blue: 0.1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            let destination = CGImageDestinationCreateWithURL(file as CFURL,
                                                              "public.png" as CFString, 1, nil)!
            CGImageDestinationAddImage(destination, context.makeImage()!, nil)
            XCTAssertTrue(CGImageDestinationFinalize(destination))
        }

        let pipeline = ThumbnailPipeline()
        writePNG(red: 0.9)   // v1: red
        let v1 = try await pipeline.thumbnail(for: file, maxPixelSize: 48)
        let redPixel = pixel(v1)

        // Replace the file at the SAME path with different bytes.
        try? FileManager.default.removeItem(at: file)
        writePNG(red: 0.1, width: 200, height: 200)   // v2: dark
        let v2 = try await pipeline.thumbnail(for: file, maxPixelSize: 48)
        let darkPixel = pixel(v2)

        print("METRIC D v1 pixel rgb=(\(redPixel.r),\(redPixel.g),\(redPixel.b)); "
            + "v2 rgb=(\(darkPixel.r),\(darkPixel.g),\(darkPixel.b))")
        XCTAssertGreaterThan(redPixel.r, 180, "v1 is red")
        XCTAssertLessThan(darkPixel.r, 80,
                          "D: the thumbnail after replacement must be v2's pixels, got "
                          + "rgb=(\(darkPixel.r),\(darkPixel.g),\(darkPixel.b))")
    }

    private func pixel(_ image: CGImage) -> (r: UInt8, g: UInt8, b: UInt8) {
        let context = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        let bytes = context.data!.assumingMemoryBound(to: UInt8.self)
        return (bytes[0], bytes[1], bytes[2])
    }
}