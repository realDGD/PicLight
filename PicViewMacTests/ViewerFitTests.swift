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
