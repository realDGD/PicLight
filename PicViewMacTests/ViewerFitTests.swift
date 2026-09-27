import XCTest
import AppKit
import CoreGraphics
@testable import PicViewMac

/// How a picture meets the window: it opens fitted, and it stays fitted while the window changes
/// size — unless the user chose a zoom, which belongs to that picture until another one arrives.
///
/// Measured before this was fixed: `ViewerState` set the zoom from the *previous* fit scale, and the
/// publisher only re-fitted when that value happened to be exactly 1, so a new picture could open at
/// the old picture's zoom (leaving a margin all round after the window was sized to the image), and
/// switching pictures through the browser kept the zoom the previous one had.
@MainActor
final class ViewerFitTests: XCTestCase {

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
            RunLoop.current.run(until: Date().addingTimeInterval(0.03))
        }
        return condition()
    }

    private func makeViewer(width: CGFloat = 900, height: CGFloat = 700)
        -> (controller: ViewerWindowController, viewer: ViewerViewController) {
        let controller = ViewerWindowController()
        TestAppKit.presentOffScreen(controller)
        controller.window?.setFrame(NSRect(x: 0, y: 0, width: width, height: height), display: false)
        controller.showWindow(nil)
        let viewer = controller.viewerViewController
        _ = viewer.view
        viewer.view.layoutSubtreeIfNeeded()
        return (controller, viewer)
    }

    private func writePNG(to url: URL, width: Int, height: Int, red: CGFloat) {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                bytesPerRow: width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: red, green: 0.3, blue: 0.4, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let destination = CGImageDestinationCreateWithURL(url as CFURL,
                                                          "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        _ = CGImageDestinationFinalize(destination)
    }

    /// A noisy PNG of `side × side`: cheap to write, slow enough to decode that the test can act
    /// while it is in flight (a flat fill compresses to nothing and decodes instantly).
    private func writeNoisePNG(to url: URL, side: Int) throws {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let row = UnsafeMutablePointer<UInt8>.allocate(capacity: side * 4)
        defer { row.deallocate() }
        var seed: UInt64 = 0x2545F4914F6CDD1D
        for y in 0..<side {
            for x in 0..<side {
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                let value = UInt8((seed >> 33) & 0xFF)
                row[x * 4] = value
                row[x * 4 + 1] = value &+ UInt8(y & 0xFF)
                row[x * 4 + 2] = UInt8(x & 0xFF)
                row[x * 4 + 3] = 255
            }
            context.data?.advanced(by: y * context.bytesPerRow)
                .copyMemory(from: row, byteCount: side * 4)
        }
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(
            url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }

    private func open(_ viewer: ViewerViewController, _ url: URL) {
        viewer.open(url: url)
        XCTAssertTrue(waitUntil(15) { viewer.viewerState.currentImage != nil },
                      "precondition: \(url.lastPathComponent) decoded")
        pump(0.3)
        viewer.view.layoutSubtreeIfNeeded()
    }

    /// The picture fills the canvas it was opened into.
    func testOpeningAnImageFitsItToTheWindow() throws {
        let directory = try Fixtures.makeScratchDirectory("fit-open")
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("photo.png")
        writePNG(to: file, width: 900, height: 500, red: 0.9)

        let (controller, viewer) = makeViewer()
        defer { TestAppKit.close(controller) }
        open(viewer, file)

        let canvas = viewer.canvasViewForTesting
        XCTAssertEqual(canvas.viewport.zoomScale, canvas.viewport.fitScale, accuracy: 1e-6,
                       "a freshly opened picture is fitted, not left at another zoom")
        // Fitted means: touching the canvas on the axis that limits it, and centred on the other.
        let displayed = CGSize(width: canvas.imagePixelSize.width * canvas.viewport.zoomScale,
                               height: canvas.imagePixelSize.height * canvas.viewport.zoomScale)
        XCTAssertEqual(min(canvas.bounds.width - displayed.width,
                           canvas.bounds.height - displayed.height), 0, accuracy: 1.0,
                       "the picture touches the canvas it fits into "
                       + "(canvas \(canvas.bounds.size), displayed \(displayed))")
        XCTAssertEqual(viewer.viewerState.viewport.normalizedCenter.x, 0.5, accuracy: 1e-6)
        XCTAssertEqual(viewer.viewerState.viewport.normalizedCenter.y, 0.5, accuracy: 1e-6)
    }

    /// A window resized while the picture is fitted keeps it fitted — the image-sized window on open
    /// is exactly that case, and it is what left a margin all round when the zoom was not updated.
    func testResizingTheWindowKeepsAPictureFitted() throws {
        let directory = try Fixtures.makeScratchDirectory("fit-resize")
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("photo.png")
        writePNG(to: file, width: 900, height: 500, red: 0.9)

        let (controller, viewer) = makeViewer()
        defer { TestAppKit.close(controller) }
        open(viewer, file)
        let canvas = viewer.canvasViewForTesting
        XCTAssertEqual(canvas.viewport.zoomScale, canvas.viewport.fitScale, accuracy: 1e-6)

        controller.window?.setFrame(NSRect(x: 0, y: 0, width: 600, height: 600), display: true)
        pump(0.4)
        viewer.view.layoutSubtreeIfNeeded()

        XCTAssertEqual(canvas.viewport.zoomScale, canvas.viewport.fitScale, accuracy: 1e-6,
                       "the picture still fills the window it was fitted into")
    }

    /// A zoom the user chose survives the window changing size.
    func testResizingKeepsAUserChosenZoom() throws {
        let directory = try Fixtures.makeScratchDirectory("fit-zoom-resize")
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("photo.png")
        writePNG(to: file, width: 900, height: 500, red: 0.9)

        let (controller, viewer) = makeViewer()
        defer { TestAppKit.close(controller) }
        open(viewer, file)
        let canvas = viewer.canvasViewForTesting
        // Zoomed in by the user, well past fit (100% actual pixels can be *below* fit for a small
        // picture, so the step is what makes the state unambiguous).
        viewer.perform(.zoomIn)
        viewer.perform(.zoomIn)
        pump(0.2)
        let chosen = canvas.viewport.zoomScale
        XCTAssertGreaterThan(chosen, canvas.viewport.fitScale, "precondition: zoomed past fit")

        controller.window?.setFrame(NSRect(x: 0, y: 0, width: 640, height: 620), display: true)
        pump(0.4)

        XCTAssertEqual(canvas.viewport.zoomScale, chosen, accuracy: 1e-6,
                       "resizing is not a request to re-fit")
    }

    /// Switching pictures in the folder browser starts the new one fitted, whatever the old zoom was.
    func testSwitchingPicturesThroughTheBrowserFitsTheNewOne() throws {
        let directory = try Fixtures.makeScratchDirectory("fit-switch")
        defer { try? FileManager.default.removeItem(at: directory) }
        for index in 0..<3 {
            writePNG(to: directory.appendingPathComponent("img\(index).png"),
                     width: 400 + index * 200, height: 300, red: CGFloat(index) / 3)
        }

        let (controller, viewer) = makeViewer()
        defer { TestAppKit.close(controller) }
        open(viewer, directory.appendingPathComponent("img0.png"))
        let canvas = viewer.canvasViewForTesting
        viewer.perform(.zoomToFit)
        viewer.perform(.zoomIn)
        viewer.perform(.zoomIn)
        pump(0.2)
        XCTAssertGreaterThan(canvas.viewport.zoomScale, canvas.viewport.fitScale,
                             "precondition: the first picture is zoomed in")

        // The browser path: double-clicking a cell opens that item and leaves the mode.
        viewer.perform(.browseFolder)
        pump(0.6)
        let browser = try XCTUnwrap(viewer.folderBrowserForTesting)
        browser.view.gallery.onItemOpened?(2)
        XCTAssertTrue(waitUntil(10) {
            viewer.session.currentItem?.displayName == "img2.png"
        })
        XCTAssertTrue(waitUntil(10) { viewer.viewerMode == .image })
        pump(0.4)
        viewer.view.layoutSubtreeIfNeeded()

        XCTAssertEqual(canvas.viewport.zoomScale, canvas.viewport.fitScale, accuracy: 1e-6,
                       "the picture the user switched to opens fitted")
    }

    /// A zoom the user asks for *while* a picture is still loading must survive that picture's
    /// arrival.
    ///
    /// Reported from the app: opening an image through the folder browser left pinch-to-zoom looking
    /// dead. The gesture was arriving and the zoom was being applied — but the new picture's own
    /// "start fitted" request was applied when the decode landed, seconds later for a large file
    /// (measured: ~20 s for a 1.9 GB PNG), and wiped it out. Pinching during a load is exactly what a
    /// person does when the picture takes a while to appear.
    func testAZoomMadeWhileThePictureLoadsSurvivesItsArrival() throws {
        let directory = try Fixtures.makeScratchDirectory("fit-while-loading")
        defer { try? FileManager.default.removeItem(at: directory) }
        let quick = directory.appendingPathComponent("quick.png")
        writePNG(to: quick, width: 400, height: 300, red: 0.9)
        // Slow enough that the test can ask for a zoom while its decode is still running.
        let slow = directory.appendingPathComponent("slow.png")
        try writeNoisePNG(to: slow, side: 5000)

        let (controller, viewer) = makeViewer()
        defer { TestAppKit.close(controller) }
        open(viewer, quick)
        let canvas = viewer.canvasViewForTesting

        // Ask for the next picture and, before it can arrive, do what a pinch does.
        viewer.perform(.nextImage)
        XCTAssertNil(viewer.viewerState.currentImage, "precondition: the slow picture is still loading")
        canvas.zoomBy(factor: 2.5)
        let requested = canvas.viewport.zoomScale

        XCTAssertTrue(waitUntil(30) { viewer.viewerState.currentImage != nil },
                      "the slow picture arrived")
        pump(0.6)
        viewer.view.layoutSubtreeIfNeeded()
        pump(0.3)

        XCTAssertEqual(canvas.viewport.zoomScale, requested, accuracy: 1e-6,
                       "the zoom the user asked for while loading is the zoom they keep "
                       + "(fit is \(canvas.viewport.fitScale), requested \(requested), "
                       + "now \(canvas.viewport.zoomScale))")
        XCTAssertNotEqual(canvas.viewport.zoomScale, canvas.viewport.fitScale, accuracy: 1e-6)
    }

    /// A picture the user did *not* touch still opens fitted, however slow it is.
    func testAnUntouchedPictureStillOpensFitted() throws {
        let directory = try Fixtures.makeScratchDirectory("fit-untouched")
        defer { try? FileManager.default.removeItem(at: directory) }
        let quick = directory.appendingPathComponent("quick.png")
        writePNG(to: quick, width: 400, height: 300, red: 0.9)
        let slow = directory.appendingPathComponent("slow.png")
        try writeNoisePNG(to: slow, side: 3000)

        let (controller, viewer) = makeViewer()
        defer { TestAppKit.close(controller) }
        open(viewer, quick)
        viewer.perform(.nextImage)
        XCTAssertTrue(waitUntil(30) { viewer.viewerState.currentImage != nil })
        pump(0.5)
        viewer.view.layoutSubtreeIfNeeded()
        pump(0.3)

        let canvas = viewer.canvasViewForTesting
        XCTAssertEqual(canvas.viewport.zoomScale, canvas.viewport.fitScale, accuracy: 1e-6,
                       "a picture nobody zoomed opens fitted, slow or not")
    }

    /// The canvas is what receives gesture events: a pinch reaches the view under the pointer, and an
    /// overlay covering the centre would silently take the gesture away from the picture.
    func testTheCanvasIsTheHitTestViewInTheMiddleOfTheWindow() throws {
        let directory = try Fixtures.makeScratchDirectory("hit-test")
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("photo.png")
        writePNG(to: file, width: 800, height: 600, red: 0.5)

        let (controller, viewer) = makeViewer()
        defer { TestAppKit.close(controller) }
        open(viewer, file)
        let canvas = viewer.canvasViewForTesting
        let centre = CGPoint(x: canvas.bounds.midX, y: canvas.bounds.midY)
        let hit = canvas.hitTest(centre)
        XCTAssertTrue(hit === canvas || hit?.isDescendant(of: canvas) == true,
                      "the canvas owns the middle of the window, or nothing receives the pinch "
                      + "(hit: \(String(describing: hit)))")
    }
}
