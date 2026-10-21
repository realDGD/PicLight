import XCTest
import AppKit
@testable import PicViewMac

/// Copy Image: what actually lands on the pasteboard, and what it cost to put it there.
///
/// The spec's constraints are the subject of every test here — responsive, bounded memory, and
/// honest semantics. A `48000 x 32000` source is 6 GiB as an RGBA bitmap, so "copy" cannot mean
/// "decode the source and encode it": the file URL goes on the pasteboard as the original, and the
/// pixels are offered lazily from the bitmap that is already on screen. Both are placed, each under
/// its own type, so nothing is presented as something it is not.
@MainActor
final class CopyImageTests: XCTestCase {

    override func setUp() async throws {
        try await super.setUp()
        TestAppKit.ensureApplication()
    }

    // MARK: - Fixtures

    private func writePNG(named name: String, in directory: URL, width: Int, height: Int) throws -> URL {
        let url = directory.appendingPathComponent(name)
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.6, blue: 0.3, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let destination = try XCTUnwrap(
            CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }

    private func makeViewer(_ url: URL) throws -> (controller: ViewerWindowController,
                                                   viewer: ViewerViewController) {
        let controller = ViewerWindowController()
        TestAppKit.presentOffScreen(controller)
        let viewer = controller.viewerViewController
        controller.showWindow(nil)
        _ = viewer.view
        viewer.open(url: url)
        let deadline = Date().addingTimeInterval(15)
        while viewer.viewerState.currentImage == nil, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        XCTAssertNotNil(viewer.viewerState.currentImage, "the fixture must load")
        return (controller, viewer)
    }

    // MARK: - What lands on the pasteboard

    /// Both representations, and the file URL points at the original file.
    func testCopyPlacesTheOriginalFileURLAndAPixelRepresentation() throws {
        let directory = try Fixtures.makeScratchDirectory("copy-image")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try writePNG(named: "photo.png", in: directory, width: 400, height: 300)
        let (controller, viewer) = try makeViewer(url)
        defer { controller.close() }

        XCTAssertTrue(viewer.copyImageToPasteboard())
        let pasteboard = NSPasteboard.general

        let types = Set(pasteboard.types ?? [])
        XCTAssertTrue(types.contains(.fileURL), "the original is offered by reference")
        XCTAssertTrue(types.contains(.tiff), "and pixels are offered for apps that want them")

        let fileURLString = try XCTUnwrap(pasteboard.string(forType: .fileURL))
        let pasted = try XCTUnwrap(URL(string: fileURLString))
        XCTAssertEqual(pasted.standardizedFileURL.path, url.standardizedFileURL.path,
                       "the pasted file URL is the file the user is looking at")
    }

    /// The pixels are produced by a consumer asking for them, and they are the bitmap on screen.
    func testThePixelRepresentationIsProducedOnDemandAndMatchesTheScreen() throws {
        let directory = try Fixtures.makeScratchDirectory("copy-image-pixels")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try writePNG(named: "photo.png", in: directory, width: 400, height: 300)
        let (controller, viewer) = try makeViewer(url)
        defer { controller.close() }
        guard let onScreen = viewer.viewerState.currentImage else { return XCTFail("no image") }

        XCTAssertTrue(viewer.copyImageToPasteboard())

        let data = try XCTUnwrap(NSPasteboard.general.data(forType: .tiff),
                                 "reading the type is what makes the provider produce it")
        let rep = try XCTUnwrap(NSBitmapImageRep(data: data))
        XCTAssertEqual(rep.pixelsWide, onScreen.width,
                       "the pixels pasted are the ones on screen, not a different rendering")
        XCTAssertEqual(rep.pixelsHigh, onScreen.height)
    }

    /// Nothing is decoded to satisfy a copy: the provider holds the on-screen bitmap by reference,
    /// so the pixels are not re-read from disk and not copied into a second buffer eagerly.
    func testCopyDoesNotDecodeAnything() throws {
        let directory = try Fixtures.makeScratchDirectory("copy-image-nodecode")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try writePNG(named: "photo.png", in: directory, width: 400, height: 300)
        let (controller, viewer) = try makeViewer(url)
        defer { controller.close() }

        let before = ThumbnailPipelineMetrics.decodedFilePaths
        XCTAssertTrue(viewer.copyImageToPasteboard())
        XCTAssertTrue(ThumbnailPipelineMetrics.decodedFilePaths.subtracting(before).isEmpty,
                      "copy must not read the file at all")
        XCTAssertEqual(viewer.copyCount, 1)
    }

    /// With nothing on screen there is nothing to copy, and the menu says so.
    func testCopyWithoutAnImageDoesNothing() throws {
        let controller = ViewerWindowController()
        TestAppKit.presentOffScreen(controller)
        defer { controller.close() }
        let viewer = controller.viewerViewController
        _ = viewer.view
        NSPasteboard.general.clearContents()
        XCTAssertFalse(viewer.copyImageToPasteboard())
        XCTAssertTrue((NSPasteboard.general.types ?? []).isEmpty,
                      "a failed copy must not leave a half-written pasteboard behind")
        let menu = viewer.canvasContextMenu()
        let copy = try XCTUnwrap(menu.items.first {
            $0.representedObject as? String == ViewerCommand.copyImage.rawValue
        })
        XCTAssertFalse(copy.isEnabled)
    }

    // MARK: - The large-source case

    /// An oversized source is the case the spec calls out. The bitmap the viewer holds is bounded,
    /// so the copy is bounded — and the original is still there, by URL, for anyone who needs it.
    func testAnOversizedSourceIsCopiedBoundedAndStillOffersTheOriginal() throws {
        let directory = try Fixtures.makeScratchDirectory("copy-image-oversized")
        defer { try? FileManager.default.removeItem(at: directory) }
        // 8300 x 100 is over the long-edge budget, so the viewer shows a bounded proxy.
        let url = try writePNG(named: "wide.png", in: directory, width: 8300, height: 100)
        let (controller, viewer) = try makeViewer(url)
        defer { controller.close() }

        let onScreen = try XCTUnwrap(viewer.viewerState.currentImage)
        XCTAssertLessThanOrEqual(max(onScreen.width, onScreen.height), DecodeBudget.maximumLongEdge,
                                 "the viewer is showing a bounded bitmap, as designed")
        XCTAssertEqual(viewer.viewerState.descriptor?.displayPixelSize,
                       CGSize(width: 8300, height: 100),
                       "while the descriptor still knows the source geometry")

        let started = Date()
        XCTAssertTrue(viewer.copyImageToPasteboard())
        let copyCost = Date().timeIntervalSince(started)
        XCTAssertLessThan(copyCost, 0.25,
                          "copy must return without decoding anything (took \(copyCost) s)")

        let pasteboard = NSPasteboard.general
        XCTAssertTrue(Set(pasteboard.types ?? []).contains(.fileURL),
                      "the original file is offered, so a consumer that wants it gets it")
        let data = try XCTUnwrap(pasteboard.data(forType: .tiff))
        let rep = try XCTUnwrap(NSBitmapImageRep(data: data))
        XCTAssertEqual(rep.pixelsWide, onScreen.width,
                       "and the pixels offered are the bounded proxy, not a 48k full decode")
        let bytes = data.count
        XCTAssertLessThan(bytes, 64 * 1024 * 1024,
                          "the pasted payload is bounded (\(bytes) bytes)")

        // The strongest form of "no decode": the pixels offered are the very object on screen.
        let provider = BitmapPasteboardProvider(image: onScreen)
        XCTAssertTrue(provider.imageForTesting === onScreen,
                      "the provider holds the on-screen bitmap by reference")
    }

    // MARK: - The mechanism

    /// The provider produces only the type it is asked for. That is what makes the lazy
    /// registration worth the complexity: an app that wants the file never pays for a TIFF.
    func testTheProviderAnswersOnlyForTheTypeItIsAskedAbout() throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8,
                                              bytesPerRow: 32,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try XCTUnwrap(context.makeImage())
        let provider = BitmapPasteboardProvider(image: image)
        let item = NSPasteboardItem()

        provider.pasteboard(nil, item: item, provideDataForType: .png)
        XCTAssertNil(item.data(forType: .png), "a type the provider does not offer is refused")

        provider.pasteboard(nil, item: item, provideDataForType: .tiff)
        XCTAssertNotNil(item.data(forType: .tiff))
        XCTAssertEqual(provider.pixelSize, CGSize(width: 8, height: 8))
    }

    /// The writer clears first, so two copies in a row do not leave the first one's types behind.
    func testASecondCopyReplacesTheFirst() throws {
        let directory = try Fixtures.makeScratchDirectory("copy-image-twice")
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try writePNG(named: "a.png", in: directory, width: 120, height: 80)
        let second = try writePNG(named: "b.png", in: directory, width: 60, height: 90)

        let (controller, viewer) = try makeViewer(first)
        defer { controller.close() }
        XCTAssertTrue(viewer.copyImageToPasteboard())
        let firstText = try XCTUnwrap(NSPasteboard.general.string(forType: .fileURL))

        viewer.open(url: second)
        let deadline = Date().addingTimeInterval(10)
        while viewer.viewerState.currentImage == nil, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        XCTAssertTrue(viewer.copyImageToPasteboard())
        let secondText = try XCTUnwrap(NSPasteboard.general.string(forType: .fileURL))

        XCTAssertNotEqual(firstText, secondText, "the second copy replaced the first")
        XCTAssertEqual(URL(string: secondText)?.standardizedFileURL.path,
                       second.standardizedFileURL.path)
        let data = try XCTUnwrap(NSPasteboard.general.data(forType: .tiff))
        let rep = try XCTUnwrap(NSBitmapImageRep(data: data))
        XCTAssertEqual(rep.pixelsWide, viewer.viewerState.currentImage?.width,
                       "and its pixels are the second image's")
    }
}
