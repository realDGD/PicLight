import XCTest
import AppKit
@testable import PicViewMac

/// The gallery's toolbar: the back button, the two layouts, the size slider and the sort controls.
///
/// The slider's contract is the interesting one. It reflows the grid live — that is what makes it
/// feel attached to the pointer — but a *decode* per slider pixel is exactly what the spec forbids,
/// so a sharper thumbnail is only requested once the drag settles.
@MainActor
final class FolderBrowserSliderTests: XCTestCase {

    override func setUp() async throws {
        try await super.setUp()
        TestAppKit.ensureApplication()
    }

    private func makeViewer(_ count: Int = 12) throws -> (directory: URL,
                                                         controller: ViewerWindowController,
                                                         viewer: ViewerViewController,
                                                         browser: FolderBrowserViewController) {
        let directory = try Fixtures.makeScratchDirectory("slider")
        for index in 0..<count {
            try FileManager.default.copyItem(at: Fixtures.url("static.png"),
                                             to: directory.appendingPathComponent("img\(index).png"))
        }
        let controller = ViewerWindowController()
        TestAppKit.presentOffScreen(controller)
        let viewer = controller.viewerViewController
        controller.showWindow(nil)
        _ = viewer.view
        viewer.open(url: directory.appendingPathComponent("img0.png"))
        let deadline = Date().addingTimeInterval(10)
        while viewer.viewerState.currentImage == nil, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        viewer.perform(.browseFolder)
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        // The gallery's own constraints need a layout pass before it has a width to lay out into.
        viewer.view.layoutSubtreeIfNeeded()
        let browser = try XCTUnwrap(viewer.folderBrowserForTesting)
        browser.view.layoutSubtreeIfNeeded()
        return (directory, controller, viewer, browser)
    }

    private func cleanup(_ directory: URL, _ controller: ViewerWindowController) {
        controller.close()
        try? FileManager.default.removeItem(at: directory)
    }

    /// The toolbar is the documented order, left to right.
    func testTheToolbarIsTheDocumentedOrder() {
        XCTAssertEqual(FolderBrowserView.toolbarLayout, [
            .back,
            .layout(.uniformGrid),
            .layout(.adaptiveGrid),
            .thumbnailSizeSlider,
            .folderTitle,
            .sortKey,
            .sortDirection,
        ])
    }

    /// The slider covers the spec's range and starts at the spec's default.
    func testTheSliderCoversTheSpecifiedRange() throws {
        let (directory, controller, _, browser) = try makeViewer()
        defer { cleanup(directory, controller) }
        let slider = browser.view.thumbnailSizeSlider
        XCTAssertEqual(slider.minValue, 80)
        XCTAssertEqual(slider.maxValue, 320)
        XCTAssertEqual(slider.doubleValue, 160, accuracy: 0.5, "the default is 160 pt")
    }

    /// Dragging the slider reflows the grid: the number of cells on screen changes with the size.
    func testDraggingTheSliderReflowsTheGridLive() throws {
        let (directory, controller, _, browser) = try makeViewer(24)
        defer { cleanup(directory, controller) }
        let grid = browser.view.gallery

        browser.view.onThumbnailSizeChanged?(80)
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        browser.view.layoutSubtreeIfNeeded()
        let small = grid.materializedCellCount
        let smallRows = grid.rowsForTesting(containerWidth: max(grid.bounds.width, 400)).count

        browser.view.onThumbnailSizeChanged?(320)
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        browser.view.layoutSubtreeIfNeeded()
        let large = grid.materializedCellCount
        let largeRows = grid.rowsForTesting(containerWidth: max(grid.bounds.width, 400)).count

        XCTAssertEqual(grid.thumbnailSizeForTesting, 320, "the grid followed the slider")
        XCTAssertGreaterThan(small, 0)
        XCTAssertLessThan(smallRows, largeRows,
                          "smaller thumbnails need fewer rows for the same items")
        _ = large
    }

    /// The reflow itself decodes nothing. Only the settled handler asks for sharper thumbnails.
    func testTheReflowItselfRequestsNoNewThumbnails() throws {
        let (directory, controller, _, browser) = try makeViewer(12)
        defer { cleanup(directory, controller) }
        RunLoop.current.run(until: Date().addingTimeInterval(1.0))
        let requestsBefore = browser.thumbnailRequestCount

        // A long drag, the way a person moves a slider: many small steps.
        for step in stride(from: CGFloat(80), through: 320, by: 8) {
            browser.view.onThumbnailSizeChanged?(step)
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }

        XCTAssertEqual(browser.thumbnailRequestCount, requestsBefore,
                       "moving the slider must not decode anything; only settling may")
    }

    /// When the drag settles, a request is made for the new size.
    func testTheSettledSliderRequestsSharperThumbnails() throws {
        let (directory, controller, _, browser) = try makeViewer(8)
        defer { cleanup(directory, controller) }
        RunLoop.current.run(until: Date().addingTimeInterval(1.0))
        let coalescedBefore = browser.thumbnailRequestsCoalesced

        browser.view.onThumbnailSizeChanged?(320)
        browser.view.onThumbnailSizeSettled?(320)
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))

        XCTAssertGreaterThan(browser.thumbnailRequestsCoalesced, coalescedBefore,
                             "the settle is what escalates the resolution")
    }

    /// Choosing a layout switches the geometry, and the choice is remembered for the window.
    ///
    /// The folder holds a wide and a tall image, so the two layouts really do differ: with every
    /// aspect equal to 1 they would agree, and a test on that folder would prove nothing.
    func testChoosingALayoutChangesTheGeometry() throws {
        let directory = try Fixtures.makeScratchDirectory("layout-choice")
        defer { try? FileManager.default.removeItem(at: directory) }
        try writePNG(named: "wide.png", in: directory, width: 600, height: 100)
        try writePNG(named: "tall.png", in: directory, width: 100, height: 600)
        try writePNG(named: "square.png", in: directory, width: 200, height: 200)

        let controller = ViewerWindowController()
        TestAppKit.presentOffScreen(controller)
        // Closed on every path: a visible viewer window left behind shifts the window count every
        // later test in this process sees.
        defer { controller.close() }
        let viewer = controller.viewerViewController
        controller.showWindow(nil)
        _ = viewer.view
        viewer.open(url: directory.appendingPathComponent("square.png"))
        let deadline = Date().addingTimeInterval(15)
        while viewer.viewerState.currentImage == nil, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        viewer.perform(.browseFolder)
        // The header probes run off the main actor; give them a moment, then let the browse settle.
        RunLoop.current.run(until: Date().addingTimeInterval(1.2))
        viewer.view.layoutSubtreeIfNeeded()
        let browser = try XCTUnwrap(viewer.folderBrowserForTesting)
        let grid = browser.view.gallery
        XCTAssertEqual(grid.layoutKindForTesting, .uniformGrid, "layout A is the default")

        let uniform = grid.rowsForTesting(containerWidth: 800)
        browser.view.onLayoutChanged?(.adaptiveGrid)
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        XCTAssertEqual(grid.layoutKindForTesting, .adaptiveGrid)
        XCTAssertEqual(viewer.galleryLayoutKind, .adaptiveGrid, "remembered on the viewer")

        let adaptive = grid.rowsForTesting(containerWidth: 800)
        XCTAssertEqual(uniform.flatMap(\.cells).count, 3, "every item is placed by both layouts")
        XCTAssertEqual(adaptive.flatMap(\.cells).count, 3)
        XCTAssertNotEqual(uniform.map { $0.cells.map { $0.frame.width } },
                          adaptive.map { $0.cells.map { $0.frame.width } },
                          "the adaptive layout gives a wide item a wide cell")
        // Layout A's slots are identical; layout B's are not.
        XCTAssertEqual(Set(uniform.flatMap(\.cells).map(\.frame.width)).count, 1)
        XCTAssertGreaterThan(Set(adaptive.flatMap(\.cells).map(\.frame.width)).count, 1)
    }

    private func writePNG(named name: String, in directory: URL,
                          width: Int, height: Int) throws {
        let url = directory.appendingPathComponent(name)
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.7, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let destination = try XCTUnwrap(
            CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }

    /// The layout buttons show which one is in force.
    func testTheLayoutButtonsShowWhichIsActive() throws {
        let (directory, controller, _, browser) = try makeViewer(4)
        defer { cleanup(directory, controller) }
        XCTAssertEqual(browser.view.uniformLayoutControl.tint, .controlAccentColor)
        XCTAssertNotEqual(browser.view.adaptiveLayoutControl.tint, .controlAccentColor)

        browser.view.onLayoutChanged?(.adaptiveGrid)
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(browser.view.adaptiveLayoutControl.tint, .controlAccentColor)
        XCTAssertNotEqual(browser.view.uniformLayoutControl.tint, .controlAccentColor)
    }

    /// The toolbar reports the folder and the position, from the session.
    func testTheToolbarShowsTheFolderAndPosition() throws {
        let (directory, controller, viewer, browser) = try makeViewer(5)
        defer { cleanup(directory, controller) }
        let text = browser.view.folderTitleLabel.stringValue
        XCTAssertTrue(text.contains(directory.lastPathComponent),
                      "the folder name is shown: \(text)")
        XCTAssertTrue(text.contains(viewer.session.positionDescription),
                      "and the position: \(text)")
    }
}
