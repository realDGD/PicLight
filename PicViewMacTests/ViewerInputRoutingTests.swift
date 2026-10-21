import XCTest
import AppKit
import ImageIO
@testable import PicViewMac

/// A window made key by focus follows mouse software has no click to restore its
/// image responder. Overlay controls also sit beside the canvas in the responder
/// hierarchy, so their unhandled gestures need the same image route.
@MainActor
final class ViewerInputRoutingTests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        TestAppKit.ensureApplication()
    }

    private func makeViewer() throws -> (ViewerWindowController, ViewerViewController) {
        let controller = ViewerWindowController()
        TestAppKit.presentOffScreen(controller)
        let viewer = controller.viewerViewController
        _ = viewer.view
        viewer.view.layoutSubtreeIfNeeded()
        let canvas = viewer.canvasViewForTesting
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(Fixtures.url("static.png") as CFURL, nil))
        let bitmap = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        canvas.renderImage = RenderImage(
            bitmap: bitmap,
            descriptor: ImageDescriptor(sourceURL: Fixtures.url("static.png"),
                                        pixelSize: CGSize(width: bitmap.width, height: bitmap.height)))
        canvas.viewport = ViewportState(fitScale: 1, zoomScale: 1,
                                       normalizedCenter: CGPoint(x: 0.5, y: 0.5))
        return (controller, viewer)
    }

    func testMakingTheWindowKeyWithoutAClickRestoresImageInput() throws {
        let (controller, viewer) = try makeViewer()
        defer { TestAppKit.close(controller) }
        let window = try XCTUnwrap(controller.window)
        XCTAssertTrue(window.makeFirstResponder(viewer.view))

        controller.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification,
                                                   object: window))

        XCTAssertTrue(window.firstResponder === viewer.canvasViewForTesting,
                      "focus follows mouse supplies no mouseDown to restore image input")
    }

    func testMakingTheWindowKeyPreservesAControlBeingEdited() throws {
        let (controller, viewer) = try makeViewer()
        defer { TestAppKit.close(controller) }
        let window = try XCTUnwrap(controller.window)
        let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 100, height: 30))
        viewer.view.addSubview(editor)
        XCTAssertTrue(window.makeFirstResponder(editor))

        controller.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification,
                                                   object: window))

        XCTAssertTrue(window.firstResponder === editor,
                      "restoring image input must preserve the active editor")
    }

    func testClickingTheImageRestoresItsResponder() throws {
        let (controller, viewer) = try makeViewer()
        defer { TestAppKit.close(controller) }
        let window = try XCTUnwrap(controller.window)
        XCTAssertTrue(window.makeFirstResponder(viewer.view))
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: .zero,
                                                    modifierFlags: [], timestamp: 0,
                                                    windowNumber: window.windowNumber,
                                                    context: nil, eventNumber: 0,
                                                    clickCount: 1, pressure: 1))

        viewer.canvasViewForTesting.mouseDown(with: event)

        XCTAssertTrue(window.firstResponder === viewer.canvasViewForTesting)
    }

    func testWheelReachingTheViewerRootStillZoomsTheImage() throws {
        let (controller, viewer) = try makeViewer()
        defer { TestAppKit.close(controller) }
        let canvas = viewer.canvasViewForTesting
        let event = ViewerWheelEvent(point: canvas.convert(
            CGPoint(x: canvas.bounds.midX, y: canvas.bounds.midY), to: nil))

        viewer.view.scrollWheel(with: event)

        XCTAssertGreaterThan(canvas.viewport.zoomScale, 1,
                             "root delivery must reach the image after focus recovery")
    }

    func testPinchOverADockButtonStillZoomsTheImage() throws {
        let (controller, viewer) = try makeViewer()
        defer { TestAppKit.close(controller) }
        let dock = try XCTUnwrap(viewer.chromeViewsForTesting["toolDock"] as? ViewerToolDockView)
        dock.isHidden = false
        dock.alphaValue = 1
        viewer.view.layoutSubtreeIfNeeded()
        let button = try XCTUnwrap(dock.commandButtons.first)
        let event = ViewerPinchEvent(point: button.convert(
            CGPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil))

        button.magnify(with: event)

        XCTAssertEqual(viewer.canvasViewForTesting.viewport.zoomScale, 1.25, accuracy: 0.0001,
                       "dock visibility must not interrupt pinch routing")
    }

    func testWheelOverTheDockStillZoomsTheImage() throws {
        let (controller, viewer) = try makeViewer()
        defer { TestAppKit.close(controller) }
        let dock = try XCTUnwrap(viewer.chromeViewsForTesting["toolDock"] as? ViewerToolDockView)
        dock.isHidden = false
        dock.alphaValue = 1
        viewer.view.layoutSubtreeIfNeeded()
        let button = try XCTUnwrap(dock.commandButtons.first)
        let event = ViewerWheelEvent(point: button.convert(
            CGPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil))

        button.scrollWheel(with: event)

        XCTAssertGreaterThan(viewer.canvasViewForTesting.viewport.zoomScale, 1)
    }

    func testPinchOverAFloatingNavigationButtonStillZoomsTheImage() throws {
        let (controller, viewer) = try makeViewer()
        defer { TestAppKit.close(controller) }
        let navigation = try XCTUnwrap(viewer.chromeViewsForTesting["floatingNavigation"]
                                      as? FloatingNavigationView)
        navigation.setAvailable(previous: true, next: true)
        navigation.setVisible(previous: true, next: true, animated: false)
        viewer.view.layoutSubtreeIfNeeded()
        let button = navigation.previousControl
        let event = ViewerPinchEvent(point: button.convert(
            CGPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil))

        button.magnify(with: event)

        XCTAssertEqual(viewer.canvasViewForTesting.viewport.zoomScale, 1.25, accuracy: 0.0001)
    }

    func testTheRootDoesNotRouteGesturesIntoAHiddenImageMode() throws {
        let (controller, viewer) = try makeViewer()
        defer { TestAppKit.close(controller) }
        let canvas = viewer.canvasViewForTesting
        canvas.isHidden = true

        viewer.view.magnify(with: ViewerPinchEvent(point: .zero))
        viewer.view.scrollWheel(with: ViewerWheelEvent(point: .zero))

        XCTAssertEqual(canvas.viewport.zoomScale, 1,
                       "browser or other visible content owns input while the image is hidden")
    }
}

/// AppKit exposes no public factory for magnify events. These event fixtures
/// provide only the values consumed at our NSResponder boundary; production
/// views, responder chains and viewport changes remain real.
private final class ViewerPinchEvent: NSEvent {
    private let point: CGPoint
    init(point: CGPoint) { self.point = point; super.init() }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override var type: NSEvent.EventType { .magnify }
    override var locationInWindow: NSPoint { point }
    override var magnification: CGFloat { 0.25 }
}

private final class ViewerWheelEvent: NSEvent {
    private let point: CGPoint
    init(point: CGPoint) { self.point = point; super.init() }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override var type: NSEvent.EventType { .scrollWheel }
    override var locationInWindow: NSPoint { point }
    override var scrollingDeltaX: CGFloat { 0 }
    override var scrollingDeltaY: CGFloat { -10 }
    override var hasPreciseScrollingDeltas: Bool { false }
    override var phase: NSEvent.Phase { [] }
    override var momentumPhase: NSEvent.Phase { [] }
    override var modifierFlags: NSEvent.ModifierFlags { [] }
}
