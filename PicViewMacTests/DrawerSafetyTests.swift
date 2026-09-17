import XCTest
import AppKit
import CoreGraphics
@testable import PicViewMac

/// Drawer and navigator safety for large images.
///
/// The pre-change app read the whole compressed stream once per surface: canvas
/// rasterization, the navigator preview and the current item's drawer cell (measured
/// 18.7–19.9 s and ~136 J for one open of the investigation image). These tests pin
/// the property that matters: the item on screen is served from the bitmap that is
/// already decoded, oversized neighbours are left as placeholders, and the file-based
/// thumbnail pipeline still works for ordinary neighbours.
@MainActor
final class DrawerSafetyTests: XCTestCase {

    /// Small solid PNG, sized so a thumbnail is a real resample but the test is cheap.
    @discardableResult
    private func writePNG(named name: String, in directory: URL, width: Int, height: Int) throws -> URL {
        let url = directory.appendingPathComponent(name)
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.25, green: 0.5, blue: 0.75, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let destination = try XCTUnwrap(
            CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }

    /// An oversized source that is cheap on disk and in memory: the policy keys on
    /// the long edge, so 8300×100 exercises the bounded path.
    @discardableResult
    private func writeOversizedPNG(named name: String, in directory: URL) throws -> URL {
        try writePNG(named: name, in: directory, width: 8300, height: 100)
    }

    private func openAndSettle(_ viewer: ViewerViewController, _ url: URL, settle: TimeInterval = 0.8) async {
        viewer.open(url: url)
        let deadline = Date().addingTimeInterval(15)
        while viewer.viewerState.currentImage == nil, Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        _ = viewer.chromeSnapshot                       // force a layout pass
        try? await Task.sleep(nanoseconds: UInt64(settle * 1_000_000_000))
    }

    func testCurrentItemThumbnailComesFromTheMainBitmapNotTheFile() async throws {
        let directory = try Fixtures.makeScratchDirectory("drawer")
        defer { try? FileManager.default.removeItem(at: directory) }
        for name in ["a.png", "b.png", "c.png"] { try writePNG(named: name, in: directory, width: 200, height: 150) }

        let viewer = ViewerViewController()
        _ = viewer.view
        await openAndSettle(viewer, directory.appendingPathComponent("b.png"))

        let items = viewer.session.items
        XCTAssertEqual(items.count, 3)
        let current = try XCTUnwrap(items.first { $0.displayName == "b.png" })
        let neighbour = try XCTUnwrap(items.first { $0.displayName == "a.png" })

        let before = ThumbnailPipelineMetrics.decodedFilePaths
        let currentThumbnail = await viewer.thumbnailImage(for: current)
        XCTAssertNotNil(currentThumbnail, "the current item still gets a thumbnail")
        XCTAssertFalse(ThumbnailPipelineMetrics.decodedFilePaths.subtracting(before)
                        .contains(current.url.path),
                       "the item on screen must be served from the decoded bitmap, not re-read from disk")

        let neighbourThumbnail = await viewer.thumbnailImage(for: neighbour)
        XCTAssertNotNil(neighbourThumbnail, "an ordinary neighbour still gets a thumbnail")
        XCTAssertTrue(ThumbnailPipelineMetrics.decodedFilePaths.contains(neighbour.url.path),
                      "ordinary neighbours still use the file-based pipeline")
    }

    /// Spec §8: non-current oversized items keep a placeholder instead of starting a
    /// full-stream decode (a 300 px thumbnail of the investigation image costs the
    /// same whole-stream decode as any other size, per visible row).
    func testOversizedItemsAreLeftAsPlaceholders() async throws {
        let directory = try Fixtures.makeScratchDirectory("drawer-oversized")
        defer { try? FileManager.default.removeItem(at: directory) }
        for name in ["a.png", "b.png", "c.png"] { try writePNG(named: name, in: directory, width: 200, height: 150) }

        let viewer = ViewerViewController(probe: StubProbe(value: 20_000))
        _ = viewer.view
        await openAndSettle(viewer, directory.appendingPathComponent("b.png"))

        let before = ThumbnailPipelineMetrics.decodedFilePaths
        let currentURL = viewer.session.currentItem?.url
        for item in viewer.session.items {
            let thumbnail = await viewer.thumbnailImage(for: item)
            if item.url == currentURL {
                // The item on screen is still served from the bitmap it is already
                // showing; "oversized" only forbids *reading the file* for it.
                XCTAssertNotNil(thumbnail, "the current item is served from the on-screen bitmap")
            } else {
                XCTAssertNil(thumbnail, "\(item.displayName) is oversized: placeholder, no decode")
            }
        }
        XCTAssertTrue(ThumbnailPipelineMetrics.decodedFilePaths.subtracting(before).isEmpty,
                      "no drawer cell may start a file-based thumbnail decode for an oversized item")
        XCTAssertNotNil(viewer.viewerState.currentImage, "the canvas still shows the (bounded) image")
    }

    /// The whole point of the design, end to end: an oversized file is displayed as a
    /// bounded bitmap while the descriptor keeps the source geometry, and neither the
    /// navigator nor the drawer's current cell re-reads the file.
    func testOversizedSourceShowsABoundedBitmapAndIsNeverReRead() async throws {
        let directory = try Fixtures.makeScratchDirectory("drawer-bounded")
        defer { try? FileManager.default.removeItem(at: directory) }
        try writeOversizedPNG(named: "wide.png", in: directory)

        let before = ThumbnailPipelineMetrics.decodedFilePaths
        let beforePreviews = ThumbnailPipelineMetrics.previewCount
        let viewer = ViewerViewController()
        _ = viewer.view
        await openAndSettle(viewer, directory.appendingPathComponent("wide.png"), settle: 1.2)

        let image = try XCTUnwrap(viewer.viewerState.currentImage)
        XCTAssertLessThanOrEqual(max(image.width, image.height), DecodeBudget.maximumLongEdge,
                                 "the bitmap handed to the renderer is bounded")
        XCTAssertEqual(viewer.viewerState.descriptor?.displayPixelSize, CGSize(width: 8300, height: 100),
                       "source geometry is untouched by the bounded decode")
        XCTAssertFalse(ThumbnailPipelineMetrics.decodedFilePaths.subtracting(before)
                        .contains(directory.appendingPathComponent("wide.png").path),
                       "the current item is never re-read from disk")
        XCTAssertGreaterThan(ThumbnailPipelineMetrics.previewCount, beforePreviews,
                             "the navigator previews the bounded bitmap")
    }
}

/// Deterministic size answers so a test can describe an oversized folder without
/// large files on disk.
private struct StubProbe: DimensionProbing {
    var value: Int?
    func longEdge(of url: URL) async -> Int? { value }
}
