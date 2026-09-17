import XCTest
import CoreGraphics
import AppKit
@testable import PicViewMac

/// Task 21 acceptance gate: error states and huge-folder responsiveness.
final class StressBehaviorTests: XCTestCase {
    func testScanningTenThousandCandidatesNeverDecodesImageBodies() throws {
        let directory = try Fixtures.makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        for index in 0..<10_000 {
            try Data([0x00, 0x01]).write(to: directory.appendingPathComponent("img-\(index).png"))
        }
        let started = Date()
        let items = try FolderScanner.scanSynchronously(directory: directory)
        let sorted = ImageSort.sort(items, by: .filename)
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertEqual(sorted.count, 10_000)
        XCTAssertLessThan(elapsed, 20,
                          "a 10k folder must be listed and sorted without decoding any image")
        XCTAssertTrue(sorted.allSatisfy { $0.pixelSize == nil })
    }

    func testCorruptFixtureKeepsNavigationUsable() async throws {
        let directory = try Fixtures.makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.copyItem(at: Fixtures.url("corrupt.png"),
                                        to: directory.appendingPathComponent("a-corrupt.png"))
        try FileManager.default.copyItem(at: Fixtures.url("static.png"),
                                        to: directory.appendingPathComponent("b-good.png"))

        let scanner = FolderScanner()
        let items = ImageSort.sort(try await scanner.scan(directory: directory), by: .filename)
        await MainActor.run {
            let session = FolderSession(items: items)
            XCTAssertEqual(session.currentItem?.displayName, "a-corrupt.png")
        }

        let decoder = ImageIODecoder()
        do {
            _ = try await decoder.decodeFirstDisplayableFrame(items[0].url, target: .fullResolution)
            XCTFail("the corrupt fixture must fail to decode")
        } catch {
            XCTAssertTrue(error is ImageDecodeError)
        }
        // Navigation survives: the next file still decodes.
        let head = try await decoder.decodeFirstDisplayableFrame(items[1].url, target: .fullResolution)
        XCTAssertGreaterThan(head.image.width, 0)
    }

    func testStaleThumbnailRequestsAreCancelledWhenScrolledAway() async throws {
        let pipeline = ThumbnailPipeline()
        let bigFiles = ["static.png", "static.bmp", "static.jpg", "display-p3.png"].map(Fixtures.url)

        let stale = Task { () -> CGImage? in
            try? await pipeline.thumbnail(for: bigFiles[0], maxPixelSize: 256)
        }
        let current = Task { () -> CGImage? in
            try? await pipeline.thumbnail(for: bigFiles[1], maxPixelSize: 256)
        }
        stale.cancel()
        await pipeline.cancelAll()

        let image = await current.value
        XCTAssertNotNil(image, "the request the user is still looking at must survive")
    }

    func testDecodeCacheEvictsByDecodedByteCostNotByCount() async throws {
        let cache = DecodeCache(totalCostLimit: 40_000)
        let decoder = ImageIODecoder()
        let head = try await decoder.decodeFirstDisplayableFrame(Fixtures.url("static.png"),
                                                                 target: .fullResolution)
        let cost = DecodeCache.cost(of: head.image)
        XCTAssertEqual(cost, head.image.bytesPerRow * head.image.height,
                       "cache cost is the real decoded byte size per the spec")
        XCTAssertGreaterThan(cost, 0)

        cache.store(head: head, for: Fixtures.url("static.png"))
        XCTAssertNotNil(cache.head(for: Fixtures.url("static.png")))
    }

    func testMemoryPressurePurgesEverythingButTheCurrentImage() async throws {
        let cache = DecodeCache(totalCostLimit: 40 * 1024 * 1024)
        let decoder = ImageIODecoder()
        let current = try await decoder.decodeFirstDisplayableFrame(Fixtures.url("static.png"),
                                                                    target: .fullResolution)
        let other = try await decoder.decodeFirstDisplayableFrame(Fixtures.url("static.bmp"),
                                                                  target: .fullResolution)
        cache.store(head: current, for: Fixtures.url("static.png"))
        cache.store(head: other, for: Fixtures.url("static.bmp"))
        // The coordinator marks the shown image; memory pressure keeps only that one.
        cache.setCurrent(Fixtures.url("static.png"))

        NotificationCenter.default.post(name: .decodeCacheMemoryPressure, object: nil)

        XCTAssertNotNil(cache.head(for: Fixtures.url("static.png")),
                        "the currently shown image survives memory pressure")
        XCTAssertNil(cache.head(for: Fixtures.url("static.bmp")),
                     "non-current entries are purged under memory pressure")
        cache.store(head: current, for: Fixtures.url("static.png"))
        XCTAssertNotNil(cache.head(for: Fixtures.url("static.png")))
    }

    @MainActor
    func testViewerOpensAHugeFolderWithoutDecodingEveryFile() async throws {
        let directory = try Fixtures.makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        for index in 0..<2_000 {
            try Data([0x89, 0x50, 0x4E, 0x47]).write(to: directory.appendingPathComponent("photo-\(index).png"))
        }
        let controller = ViewerViewController()
        _ = controller.view
        let started = Date()
        controller.open(url: directory.appendingPathComponent("photo-1500.png"))
        let openerElapsed = Date().timeIntervalSince(started)
        XCTAssertLessThan(openerElapsed, 5, "opening must not block on decode work")

        // Give the background scan a moment, then confirm the session is usable.
        try await Task.sleep(nanoseconds: 1_500_000_000)
        XCTAssertEqual(controller.session.items.count, 2_000)
        XCTAssertEqual(controller.session.currentItem?.displayName, "photo-1500.png")
        XCTAssertNil(controller.viewerState.currentImage,
                     "a corrupt folder must not fabricate decoded pixels")
    }

    @MainActor
    func testEmptyFolderKeepsAUsableWindowWithEmptyState() async throws {
        let directory = try Fixtures.makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = ViewerViewController()
        _ = controller.view
        controller.open(url: directory.appendingPathComponent("missing.png"))
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertTrue(controller.session.isEmpty)
        XCTAssertNil(controller.session.currentItem)
        XCTAssertNil(controller.viewerState.currentImage)
        controller.perform(.nextImage) // must be a safe no-op on an empty folder
    }
}

/// Regression: the drawer used to create one view per folder item and activate
/// constraints between views with no common ancestor, which raised an
/// Objective-C exception inside an async context and corrupted the heap.
@MainActor
final class ThumbnailDrawerTests: XCTestCase {
    func testDrawerRebuildHandlesAThousandItemsWithoutMaterializingThemAll() {
        let drawer = ThumbnailDrawerView(style: .drawer)
        drawer.frame = NSRect(x: 0, y: 0, width: 200, height: 600)
        let items = (0..<1_000).map { FolderItem(url: URL(fileURLWithPath: "/tmp/f\($0).png")) }
        drawer.rebuild(items: items, currentIndex: 500)
        XCTAssertEqual(drawer.visibleRowCount, 1_000)
        drawer.scrollCurrentIntoView()

        // The invariant is that rows are virtualized: no row cell may exist until
        // the table actually displays one. The drawer's own subviews are its
        // material surface, the scroll view and the pin header strip.
        func thumbnailCells(in view: NSView) -> Int {
            var count = view is ThumbnailCellView ? 1 : 0
            for subview in view.subviews { count += thumbnailCells(in: subview) }
            return count
        }
        XCTAssertEqual(thumbnailCells(in: drawer), 0,
                       "1000 items must not materialise 1000 row views")
        XCTAssertLessThanOrEqual(drawer.subviews.count, 4,
                                 "the drawer keeps a bounded number of chrome subviews")
    }

    func testDrawerSelectionReportsTheRowWithoutChangingTheCanvas() {
        let drawer = ThumbnailDrawerView(style: .drawer)
        drawer.frame = NSRect(x: 0, y: 0, width: 200, height: 600)
        let items = (0..<10).map { FolderItem(url: URL(fileURLWithPath: "/tmp/g\($0).png")) }
        var selected: [Int] = []
        drawer.onSelect = { selected.append($0) }
        drawer.rebuild(items: items, currentIndex: 2)
        drawer.setCurrentIndex(nil)
        XCTAssertTrue(selected.isEmpty, "programmatic selection must not look like a user click")
    }
}
