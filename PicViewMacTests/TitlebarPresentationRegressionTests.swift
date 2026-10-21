import XCTest
import AppKit
@testable import PicViewMac

@MainActor
final class TitlebarPresentationRegressionTests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        TestAppKit.ensureApplication()
    }

    private func makeWindow() -> ViewerWindow {
        let window = ViewerWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600))
        TestAppKit.prepareForOffScreen(window)
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        window.makeKeyAndOrderFront(nil)
        TestAppKit.moveOffScreen(window)
        window.layoutIfNeeded()
        return window
    }

    private func waitUntil(timeout: TimeInterval = 3, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return condition()
    }

    func testNativeTitlebarRevealPreservesFitAndManualViewportAcrossRepeatedCycles() throws {
        let originalTitlebar = AppSettings.shared.titlebar
        let originalWindowSize = AppSettings.shared.lastWindowSize
        AppSettings.shared.titlebar = .autoHide
        defer {
            AppSettings.shared.titlebar = originalTitlebar
            AppSettings.shared.lastWindowSize = originalWindowSize
        }
        let controller = ViewerWindowController()
        defer { TestAppKit.close(controller) }
        TestAppKit.presentOffScreen(controller)
        let window = try XCTUnwrap(controller.window as? ViewerWindow)
        let viewer = controller.viewerViewController
        viewer.open(url: Fixtures.url("static.png"))
        XCTAssertTrue(waitUntil(timeout: 10) { viewer.viewerState.currentImage != nil })
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        // Apply after loading so the user's image-sized-window policy cannot replace it.
        window.setFrame(NSRect(origin: window.frame.origin, size: NSSize(width: 900, height: 600)),
                        display: false)
        viewer.view.layoutSubtreeIfNeeded()

        func leaveTitlebar() {
            viewer.simulatePointer(atWindowPoint: viewer.view.convert(
                CGPoint(x: viewer.view.bounds.midX, y: viewer.view.bounds.midY), to: nil))
        }
        leaveTitlebar()
        XCTAssertTrue(waitUntil { window.titlebarState == .hidden })
        let outerFrame = window.frame
        let canvasFrame = viewer.chromeSnapshot.canvasFrame

        for manualZoom in [false, true] {
            viewer.perform(manualZoom ? .zoomDoubleFit : .zoomToFit)
            if manualZoom {
                var viewport = viewer.canvasViewportForTesting
                viewport.normalizedCenter = CGPoint(x: 0.55, y: 0.45)
                viewer.canvasViewportForTesting = viewport
            }
            let originalViewport = viewer.canvasViewportForTesting
            let canvas = viewer.chromeSnapshot.canvasView
            let originalCanvasInWindow = canvas.convert(canvas.bounds, to: nil)
            for _ in 0..<3 {
                let lightsZone = viewer.titlebarRevealZones.a
                viewer.simulatePointer(atWindowPoint: viewer.view.convert(
                    CGPoint(x: lightsZone.midX, y: lightsZone.midY), to: nil))
                XCTAssertTrue(waitUntil { window.titlebarState == .trafficLightsOnly })
                XCTAssertEqual(viewer.chromeSnapshot.canvasFrame, canvasFrame)
                XCTAssertEqual(canvas.convert(canvas.bounds, to: nil), originalCanvasInWindow)

                let zone = viewer.titlebarRevealZones.b
                viewer.simulatePointer(atWindowPoint: viewer.view.convert(
                    CGPoint(x: zone.midX, y: zone.midY), to: nil))
                XCTAssertTrue(waitUntil { window.titlebarState == .full })
                XCTAssertEqual(window.frame, outerFrame)
                XCTAssertEqual(viewer.chromeSnapshot.canvasFrame, canvasFrame,
                               "hovering the titlebar must not take space from the picture")
                XCTAssertEqual(canvas.convert(canvas.bounds, to: nil), originalCanvasInWindow)
                XCTAssertEqual(viewer.chromeSnapshot.zoomScale, originalViewport.zoomScale,
                               accuracy: 0.0001)
                XCTAssertEqual(viewer.chromeSnapshot.fitScale, originalViewport.fitScale,
                               accuracy: 0.0001)
                XCTAssertEqual(viewer.canvasViewportForTesting.normalizedCenter.x,
                               originalViewport.normalizedCenter.x, accuracy: 0.0001)
                XCTAssertEqual(viewer.canvasViewportForTesting.normalizedCenter.y,
                               originalViewport.normalizedCenter.y, accuracy: 0.0001)

                leaveTitlebar()
                XCTAssertTrue(waitUntil { window.titlebarState == .hidden })
                XCTAssertEqual(window.frame, outerFrame)
                XCTAssertEqual(viewer.chromeSnapshot.canvasFrame, canvasFrame)
                XCTAssertEqual(viewer.chromeSnapshot.zoomScale, originalViewport.zoomScale,
                               accuracy: 0.0001)
                XCTAssertEqual(viewer.canvasViewportForTesting.normalizedCenter.x,
                               originalViewport.normalizedCenter.x, accuracy: 0.005)
                XCTAssertEqual(viewer.canvasViewportForTesting.normalizedCenter.y,
                               originalViewport.normalizedCenter.y, accuracy: 0.005)
            }
        }
    }

    func testLeavingMergedBrowserRestoresAlwaysVisibleContentGeometry() {
        let window = makeWindow()
        defer { window.close() }
        window.applyTitlebarMode(.alwaysVisible)
        let originalFrame = window.frame
        let originalContent = window.contentLayoutRect

        for _ in 0..<3 {
            window.isTopBarMergedWithContent = true
            window.isTopBarMergedWithContent = false
            window.applyTitlebarMode(.alwaysVisible)
            window.layoutIfNeeded()

            XCTAssertFalse(window.styleMask.contains(.fullSizeContentView),
                           "the image must leave the browser's merged titlebar layout")
            XCTAssertEqual(window.frame, originalFrame, "mode changes must not grow the window")
            XCTAssertEqual(window.contentLayoutRect, originalContent)
            XCTAssertFalse(window.titlebarAppearsTransparent)
            XCTAssertEqual(window.titleVisibility, .visible)
        }
    }

    func testRevealedAutoHideOverlaysStableContentWithoutGrowingWindow() {
        let window = makeWindow()
        defer { window.close() }
        let originalFrame = window.frame
        let originalContent = window.contentView!.convert(window.contentView!.bounds, to: nil)

        for _ in 0..<3 {
            window.applyTitlebarState(.full)
            window.layoutIfNeeded()
            XCTAssertEqual(window.frame, originalFrame, "a reveal must not resize the outer window")
            let content = window.contentView!.convert(window.contentView!.bounds, to: nil)
            XCTAssertEqual(content, originalContent,
                           "the native bar must overlay the same image area in every hover state")
            XCTAssertFalse(window.titlebarAppearsTransparent)
            XCTAssertEqual(window.titleVisibility, .visible)

            window.applyTitlebarState(.hidden)
            window.layoutIfNeeded()
            XCTAssertEqual(window.contentView!.convert(window.contentView!.bounds, to: nil),
                           originalContent)
            XCTAssertEqual(window.frame, originalFrame, "hiding must restore content within the frame")
        }
    }

    func testRevealedTitlebarDoesNotTakeItsTintFromTheImage() throws {
        let window = makeWindow()
        defer { window.close() }
        window.contentView?.wantsLayer = true
        window.contentView?.layer?.backgroundColor = NSColor.systemRed.cgColor
        window.applyTitlebarState(.full)
        window.layoutIfNeeded()
        let theme = try XCTUnwrap(window.contentView?.superview)
        let bitmap = try XCTUnwrap(theme.bitmapImageRepForCachingDisplay(in: theme.bounds))
        theme.cacheDisplay(in: theme.bounds, to: bitmap)
        let color = try XCTUnwrap(bitmap.colorAt(x: bitmap.pixelsWide - 40, y: 16)?
            .usingColorSpace(.deviceRGB))
        XCTAssertEqual(color.redComponent, color.greenComponent, accuracy: 0.04,
                       "a saturated image must not wash out the native titlebar's labels")
    }

    func testImageSizeAccessoryIsRemovedWhileBrowserOwnsTheToolbar() throws {
        let originalTitlebar = AppSettings.shared.titlebar
        AppSettings.shared.titlebar = .alwaysVisible
        defer { AppSettings.shared.titlebar = originalTitlebar }
        let controller = ViewerWindowController()
        defer { TestAppKit.close(controller) }
        TestAppKit.presentOffScreen(controller)
        let window = try XCTUnwrap(controller.window as? ViewerWindow)
        controller.viewerViewController.onSizeReadoutChanged?("1145 × 1374")
        window.applyTitlebarMode(.alwaysVisible)

        func containsReadout(_ view: NSView) -> Bool {
            if let text = view as? NSTextField, text.stringValue == "1145 × 1374" { return true }
            return view.subviews.contains(where: containsReadout)
        }
        XCTAssertTrue(window.titlebarAccessoryViewControllers.contains { containsReadout($0.view) })
        window.isTopBarMergedWithContent = true
        XCTAssertFalse(window.titlebarAccessoryViewControllers.contains { containsReadout($0.view) },
                       "image dimensions must not overlap the browser's trailing toolbar controls")
        XCTAssertFalse(controller.drawerTitlebarButton?.isHidden ?? true,
                       "the browser still keeps its left-column control")
        window.isTopBarMergedWithContent = false
        XCTAssertTrue(window.titlebarAccessoryViewControllers.contains { containsReadout($0.view) },
                      "returning to the image restores the dimensions")
    }

    func testSizeReadoutTextIsCenteredAndInsetInsideNativeTitlebar() throws {
        let originalTitlebar = AppSettings.shared.titlebar
        AppSettings.shared.titlebar = .alwaysVisible
        defer { AppSettings.shared.titlebar = originalTitlebar }
        let controller = ViewerWindowController()
        defer { TestAppKit.close(controller) }
        TestAppKit.presentOffScreen(controller)
        let window = try XCTUnwrap(controller.window as? ViewerWindow)
        controller.viewerViewController.onSizeReadoutChanged?("1145 × 1374")
        window.applyTitlebarMode(.alwaysVisible)
        window.layoutIfNeeded()

        func findReadout(_ view: NSView) -> NSTextField? {
            if let text = view as? NSTextField, text.stringValue == "1145 × 1374" { return text }
            return view.subviews.lazy.compactMap(findReadout).first
        }
        let text = try XCTUnwrap(window.titlebarAccessoryViewControllers.lazy
            .compactMap { findReadout($0.view) }.first)
        let frame = text.convert(text.bounds, to: nil)
        let lights = try XCTUnwrap(window.standardWindowButton(.closeButton))
        let lightsFrame = lights.convert(lights.bounds, to: nil)
        XCTAssertEqual(frame.height, 16, accuracy: 0.5,
                       "AppKit must expand the accessory container, not the label's drawing bounds")
        XCTAssertEqual(frame.midY, lightsFrame.midY, accuracy: 0.5)
        XCTAssertGreaterThanOrEqual(window.frame.width - frame.maxX, 8,
                                    "the text needs an inset from the rounded trailing window edge")
    }

    func testTrafficLightRevealGeometryUsesTheActualWindowCoordinates() throws {
        let window = makeWindow()
        defer { window.close() }
        window.applyTitlebarState(.full)
        window.layoutIfNeeded()
        let measured = try XCTUnwrap(window.trafficLightsFrame)
        for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            let button = try XCTUnwrap(window.standardWindowButton(type))
            let frame = button.convert(button.bounds, to: nil)
            XCTAssertTrue(measured.contains(frame),
                          "the reveal region must cover the actual native button, not its local frame")
        }
        XCTAssertGreaterThan(measured.minY, window.contentLayoutRect.maxY)
    }
}
