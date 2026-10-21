import XCTest
import AppKit
import CoreGraphics
import ImageIO
@testable import PicViewMac

/// A file replaced at the same path is a different file.
///
/// Measured before the fix: a 64×48 picture replaced by an 8192×256 one came back from the decode
/// cache as the 64×48 bitmap, and `DimensionProbe` kept answering the old size (8192) after the file
/// at that path had become 32×24. Identity is `SourceFileIdentity.versionToken`, the same value the
/// tile cache and the thumbnail pipeline already key on.
@MainActor
final class SamePathReplacementTests: XCTestCase {

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

    @discardableResult
    private func writePNG(_ url: URL, width: Int, height: Int, red: CGFloat) -> URL {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                bytesPerRow: width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: red, green: 0.2, blue: 0.2, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let destination = CGImageDestinationCreateWithURL(url as CFURL,
                                                          "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        _ = CGImageDestinationFinalize(destination)
        return url
    }

    private final class HeadCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var events: [DecodeEvent] = []
        func record(_ event: DecodeEvent) {
            lock.lock(); defer { lock.unlock() }
            events.append(event)
        }
        var heads: [DecodedImageHead] {
            lock.lock(); defer { lock.unlock() }
            return events.compactMap { if case let .head(head) = $0 { return head } else { return nil } }
        }
    }

    /// The decode cache is keyed by the file's version, so a replacement is a miss.
    func testTheDecodeCacheDoesNotServeTheReplacedFilesBitmap() async throws {
        let directory = try Fixtures.makeScratchDirectory("replacement-decode")
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("replaced.png")
        writePNG(file, width: 64, height: 48, red: 0.9)

        let coordinator = DecodeCoordinator()
        let first = HeadCollector()
        await (await coordinator.show(item: file) { first.record($0) }).value
        XCTAssertEqual(first.heads.last?.image.width, 64, "precondition: the first file is on screen")

        try? FileManager.default.removeItem(at: file)
        writePNG(file, width: 200, height: 120, red: 0.1)

        let second = HeadCollector()
        await (await coordinator.show(item: file) { second.record($0) }).value
        let head = try XCTUnwrap(second.heads.last, "the replacement must produce a bitmap")
        XCTAssertEqual(head.image.width, 200,
                       "the pixels are the file's current bytes, not the previous file's")
        XCTAssertEqual(head.descriptor.pixelSize.width, 200,
                       "and the size the UI reports is the current file's")
    }

    /// The same replacement, seen by the dimension probe.
    func testTheDimensionProbeForgetsTheOldFilesSize() async throws {
        let directory = try Fixtures.makeScratchDirectory("replacement-probe")
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("resized.png")
        writePNG(file, width: 400, height: 300, red: 0.5)

        let probe = DimensionProbe()
        let before = await probe.longEdge(of: file)
        XCTAssertEqual(before, 400)

        try? FileManager.default.removeItem(at: file)
        writePNG(file, width: 64, height: 48, red: 0.7)
        let after = await probe.longEdge(of: file)
        XCTAssertEqual(after, 64, "the remembered size belongs to the version it was read from")
    }

    /// And end to end: the viewer re-decodes the file that replaced the one on screen, with no
    /// keyboard or menu action — the watcher's rescan is what tells it.
    func testTheViewerShowsTheReplacementAfterTheWatcherRescans() throws {
        let directory = try Fixtures.makeScratchDirectory("replacement-viewer")
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = writePNG(directory.appendingPathComponent("photo.png"),
                            width: 64, height: 48, red: 0.9)
        // A sibling, so the folder has a second item and the rescan is a real list change.
        writePNG(directory.appendingPathComponent("other.png"), width: 32, height: 32, red: 0.3)

        let controller = ViewerWindowController()
        TestAppKit.presentOffScreen(controller)
        defer { TestAppKit.close(controller) }
        controller.window?.setFrame(NSRect(x: 0, y: 0, width: 900, height: 700), display: false)
        controller.showWindow(nil)
        let viewer = controller.viewerViewController
        _ = viewer.view
        viewer.open(url: file)
        XCTAssertTrue(waitUntil(15) { viewer.viewerState.descriptor?.pixelSize.width == 64 },
                      "precondition: the first version is on screen")

        try? FileManager.default.removeItem(at: file)
        writePNG(file, width: 200, height: 120, red: 0.1)

        XCTAssertTrue(waitUntil(15) { viewer.viewerState.descriptor?.pixelSize.width == 200 },
                      "the file on screen is the file the path resolves to now "
                      + "(descriptor is still "
                      + "\(viewer.viewerState.descriptor.map { "\($0.pixelSize.width)" } ?? "nil"))")
        pump(0.2)
        XCTAssertEqual(viewer.viewerState.currentImage?.width, 200,
                       "and the bitmap on the canvas is the replacement's")
    }
}
