import XCTest
import AppKit
@testable import PicViewMac

/// The dock's zoom controls: a multiplicative step, and a percentage that comes from the
/// viewport rather than from a number the dock keeps.
///
/// The step is a ratio on purpose. A fixed percentage delta moves the view nearly not at all when
/// zoomed out and a long way when zoomed in; ×1.25 / ÷1.25 moves the same visual distance at every
/// scale.
@MainActor
final class ToolDockZoomTests: XCTestCase {

    override func setUp() async throws {
        try await super.setUp()
        TestAppKit.ensureApplication()
    }

    private func makeViewer() throws -> (controller: ViewerWindowController,
                                         viewer: ViewerViewController,
                                         dock: ViewerToolDockView) {
        let controller = ViewerWindowController()
        TestAppKit.presentOffScreen(controller)
        let viewer = controller.viewerViewController
        controller.showWindow(nil)
        _ = viewer.view
        viewer.open(url: Fixtures.url("static.png"))
        let deadline = Date().addingTimeInterval(10)
        while viewer.viewerState.currentImage == nil, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        let dock = try XCTUnwrap(viewer.chromeViewsForTesting["toolDock"] as? ViewerToolDockView)
        return (controller, viewer, dock)
    }

    /// The step itself: 1.25, and its reciprocal.
    func testTheZoomStepIsMultiplicative() {
        XCTAssertEqual(ViewerToolDockView.zoomStep, 1.25)
        XCTAssertEqual(1 / ViewerToolDockView.zoomStep, 0.8, accuracy: 1e-12)
    }

    /// Zoom in multiplies by 1.25 and zoom out divides by it, exactly.
    func testZoomInAndOutAreExactReciprocalSteps() throws {
        let (controller, viewer, _) = try makeViewer()
        defer { controller.close() }
        let start = viewer.chromeSnapshot.zoomScale
        XCTAssertGreaterThan(start, 0)

        viewer.perform(.zoomIn)
        XCTAssertEqual(viewer.chromeSnapshot.zoomScale, start * ViewerToolDockView.zoomStep,
                       accuracy: 1e-9, "zoom in is ×1.25")

        viewer.perform(.zoomOut)
        XCTAssertEqual(viewer.chromeSnapshot.zoomScale, start, accuracy: 1e-9,
                       "and zoom out returns exactly to where it was")
    }

    /// A zoom in/out pair leaves the viewport where it started — the round trip is exact, not
    /// merely close, which is the property a fixed-delta implementation does not have.
    func testARepeatedRoundTripDoesNotDrift() throws {
        let (controller, viewer, _) = try makeViewer()
        defer { controller.close() }
        let start = viewer.chromeSnapshot.zoomScale

        for _ in 0..<8 {
            viewer.perform(.zoomIn)
        }
        for _ in 0..<8 {
            viewer.perform(.zoomOut)
        }

        XCTAssertEqual(viewer.chromeSnapshot.zoomScale, start, accuracy: 1e-9,
                       "eight steps out and back must land where they started")
    }

    /// The percentage the dock shows is the viewport's own, updated as the zoom changes.
    func testThePercentageComesFromTheViewport() throws {
        let (controller, viewer, dock) = try makeViewer()
        defer { controller.close() }

        func viewportPercent() -> Int {
            Int((viewer.chromeSnapshot.zoomScale * 100).rounded())
        }
        XCTAssertEqual(dock.zoomReadoutText, "\(viewportPercent())%")

        viewer.perform(.zoomIn)
        XCTAssertEqual(dock.zoomReadoutText, "\(viewportPercent())%",
                       "the readout follows the real zoom state")

        viewer.perform(.zoomOut)
        XCTAssertEqual(dock.zoomReadoutText, "\(viewportPercent())%")

        viewer.perform(.zoomToFit)
        XCTAssertEqual(dock.zoomReadoutText, "\(viewportPercent())%")
    }

    /// The percentage is `ViewportState.zoomPercent`, and its documented meaning is one image
    /// pixel per *physical* display pixel at 100 %. On a 2× display that makes "actual pixels"
    /// 50 %, which is worth stating: the command is titled "实际像素 100%" while the number next
    /// to it reads 50. That mismatch predates the zoom readout — the semantics are
    /// `ViewportState`'s and are not changed here — but the two now sit side by side, so a reader
    /// is entitled to see why.
    func testThePercentageFollowsTheDocumentedPhysicalPixelScale() throws {
        let (controller, viewer, dock) = try makeViewer()
        defer { controller.close() }
        XCTAssertEqual(ViewportState.actualPixelScale(backingScale: 2), 0.5, accuracy: 1e-12)
        XCTAssertEqual(ViewportState.actualPixelScale(backingScale: 1), 1, accuracy: 1e-12)

        viewer.perform(.zoomActualPixels)
        let scale = viewer.chromeSnapshot.zoomScale
        XCTAssertEqual(scale, ViewportState.actualPixelScale(backingScale: 2), accuracy: 1e-9)
        XCTAssertEqual(dock.zoomReadoutText,
                       "\(Int((scale * 100).rounded()))%",
                       "the dock reports the viewport's own number, whatever it is")
    }

    /// A zoom change is a meaningful change for the info HUD too, so the two surfaces agree.
    func testZoomingAlsoShowsTheInfoHUD() throws {
        let (controller, viewer, dock) = try makeViewer()
        defer { controller.close() }
        let bar = try XCTUnwrap(viewer.chromeViewsForTesting["bottomBar"])
        RunLoop.current.run(until: Date().addingTimeInterval(
            InfoHUDVisibilityModel.Timing().idleFadeDelay + 0.6))
        XCTAssertTrue(bar.isHidden)

        viewer.perform(.zoomIn)
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        XCTAssertFalse(bar.isHidden, "the zoom readout is worth showing again")
        XCTAssertNotEqual(dock.zoomReadoutText, "", "and the dock agrees about the percentage")
    }

    /// Zooming never changes the canvas *frame*: the geometry the zoom is measured against is
    /// untouched by the control that changes it.
    func testZoomingDoesNotChangeTheCanvasFrame() throws {
        let (controller, viewer, _) = try makeViewer()
        defer { controller.close() }
        let frame = viewer.chromeSnapshot.canvasFrame

        viewer.perform(.zoomIn)
        viewer.perform(.zoomOut)
        viewer.perform(.zoomToFit)
        viewer.perform(.zoomToFitWidth)
        viewer.perform(.zoomActualPixels)

        XCTAssertEqual(viewer.chromeSnapshot.canvasFrame, frame)
    }

    /// The zoom commands exist in the command set the menu and the context menu share.
    func testTheZoomCommandsArePartOfTheViewerCommandSet() {
        XCTAssertTrue(ViewerCommand.allCases.contains(.zoomIn))
        XCTAssertTrue(ViewerCommand.allCases.contains(.zoomOut))
        XCTAssertEqual(ViewerCommand.zoomIn.localizedTitle, "放大")
        XCTAssertEqual(ViewerCommand.zoomOut.localizedTitle, "缩小")
    }

    /// With no image there is nothing to zoom, and the commands must not trap or move a viewport
    /// that does not describe anything.
    func testZoomingWithoutAnImageDoesNothing() throws {
        let controller = ViewerWindowController()
        TestAppKit.presentOffScreen(controller)
        defer { controller.close() }
        let viewer = controller.viewerViewController
        _ = viewer.view
        let before = viewer.chromeSnapshot.zoomScale

        viewer.perform(.zoomIn)
        viewer.perform(.zoomOut)

        XCTAssertEqual(viewer.chromeSnapshot.zoomScale, before)
    }
}
