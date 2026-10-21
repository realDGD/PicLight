import XCTest
import AppKit
@testable import PicViewMac

/// An invisible overlay must not take events.
///
/// Reported, with a gesture trace as evidence: after opening an image through the folder browser,
/// two-finger pinch did nothing. Every magnify event went to `NSStackView` / `EmptyStateView
/// hidden=false alpha=0.0` and not one reached the canvas — the empty state had been *unhidden*
/// without being faded in, by the mode transition that puts the image mode's views back
/// (`setImageModeViewsHidden(false)`), because it was already hidden for the right reason: a picture
/// was on screen. Invisible is not the same as absent: alpha 0 views are hit-tested normally.
@MainActor
final class InvisibleOverlayGestureTests: XCTestCase {

    override func setUp() async throws {
        try await super.setUp()
        TestAppKit.ensureApplication()
    }

    private func pump(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    private func waitUntil(_ timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { pump(0.05) }
        return condition()
    }

    /// The unit-level rule: transparent or hidden means "not there" for hit testing.
    func testATransparentEmptyStateTakesNoHits() {
        let view = EmptyStateView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        view.isHidden = false
        view.alphaValue = 0
        XCTAssertNil(view.hitTest(CGPoint(x: 200, y: 150)),
                     "an invisible overlay must not swallow the gesture")

        view.alphaValue = 1
        XCTAssertNotNil(view.hitTest(CGPoint(x: 200, y: 150)),
                        "a visible one still takes its own hits (its open button needs them)")

        view.isHidden = true
        view.alphaValue = 1
        XCTAssertNil(view.hitTest(CGPoint(x: 200, y: 150)))
    }

    /// And the reported flow: opening an image through the folder browser must leave the canvas
    /// owning the picture area, so a pinch reaches it.
    func testTheCanvasOwnsThePictureAfterOpeningFromTheBrowser() throws {
        let directory = try Fixtures.makeScratchDirectory("invisible-overlay")
        defer { try? FileManager.default.removeItem(at: directory) }
        for index in 0..<3 {
            try FileManager.default.copyItem(at: Fixtures.url("static.png"),
                                             to: directory.appendingPathComponent("img\(index).png"))
        }
        let controller = ViewerWindowController()
        TestAppKit.presentOffScreen(controller)
        controller.window?.setFrame(NSRect(x: 0, y: 0, width: 1000, height: 800), display: false)
        controller.showWindow(nil)
        let viewer = controller.viewerViewController
        _ = viewer.view
        defer { TestAppKit.close(controller) }
        viewer.open(url: directory.appendingPathComponent("img0.png"))
        XCTAssertTrue(waitUntil(15) { viewer.viewerState.currentImage != nil })

        // The round trip through the browser, twice: once opening *another* item, once returning to
        // the one already on screen (the case in the trace, where nothing re-renders the empty state).
        for round in 0..<2 {
            viewer.enterFolderBrowser()
            pump(0.5)
            viewer.view.layoutSubtreeIfNeeded()
            if round == 0, let browser = viewer.folderBrowserForTesting {
                browser.view.gallery.onItemOpened?(1)
            } else {
                viewer.leaveFolderBrowser()
            }
            XCTAssertTrue(waitUntil(15) { viewer.viewerMode == .image })
            pump(0.6)
            viewer.view.layoutSubtreeIfNeeded()

            let canvas = viewer.canvasViewForTesting
            let centre = viewer.view.convert(CGPoint(x: canvas.bounds.midX, y: canvas.bounds.midY),
                                             from: canvas)
            let hit = viewer.view.hitTest(centre)
            XCTAssertTrue(hit === canvas || hit?.isDescendant(of: canvas) == true,
                          "round \(round): the picture area belongs to the canvas, or the pinch goes "
                          + "to whatever is on top (hit: \(String(describing: hit.map { type(of: $0) })))")
            XCTAssertTrue(hit === canvas || hit?.isDescendant(of: canvas) == true
                          || viewer.viewerState.currentImage == nil)
        }
    }
}
