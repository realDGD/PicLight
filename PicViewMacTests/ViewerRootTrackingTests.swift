import XCTest
import AppKit
@testable import PicViewMac

/// A standard opaque titlebar lies outside the viewer root's tracking bounds.
/// Its hover still belongs to this window's reveal state.
@MainActor
final class ViewerRootTrackingTests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        TestAppKit.ensureApplication()
    }

    private func makeWindow() -> (NSWindow, ViewerRootView) {
        let window = TrackingKeyWindow(contentRect: NSRect(x: -30000, y: -30000, width: 800, height: 600),
                                       styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        TestAppKit.prepareForOffScreen(window)
        let root = ViewerRootView(frame: .zero)
        window.contentView = root
        window.acceptsMouseMovedEvents = true
        window.makeKeyAndOrderFront(nil)
        TestAppKit.moveOffScreen(window)
        return (window, root)
    }

    private func mouseMoved(in window: NSWindow, at point: CGPoint) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(with: .mouseMoved, location: point,
                                        modifierFlags: [], timestamp: 0,
                                        windowNumber: window.windowNumber, context: nil,
                                        eventNumber: 0, clickCount: 0, pressure: 0))
    }

    func testPointerMovementInTheNativeTitlebarReachesTheRoot() throws {
        let (window, root) = makeWindow()
        defer { window.close() }
        XCTAssertTrue(window.isKeyWindow)
        let point = CGPoint(x: root.bounds.midX, y: root.bounds.maxY + 8)
        XCTAssertGreaterThan(point.y, root.bounds.maxY,
                             "the native titlebar is outside the content tracking rectangle")
        var observed: [CGPoint] = []
        root.onPointerMoved = { observed.append($0) }

        NSApp.sendEvent(try mouseMoved(in: window, at: point))

        XCTAssertEqual(observed, [point], "the passive window monitor must retain titlebar hover")
    }

    func testTheMonitorIgnoresAnUnrelatedWindow() throws {
        let (window, root) = makeWindow()
        let other = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 400, height: 300),
                             styleMask: [.titled], backing: .buffered, defer: false)
        other.isReleasedWhenClosed = false
        TestAppKit.prepareForOffScreen(other)
        defer { window.close(); other.close() }
        var observed = 0
        root.onPointerMoved = { _ in observed += 1 }

        NSApp.sendEvent(try mouseMoved(in: other, at: CGPoint(x: 100, y: 310)))

        XCTAssertEqual(observed, 0)
    }

    func testDetachingTheRootRemovesItsWindowMonitor() throws {
        let (window, root) = makeWindow()
        defer { window.close() }
        let frameView = try XCTUnwrap(window.contentView?.superview)
        let boundary = try XCTUnwrap(frameView.trackingAreas.first { $0.owner === root })
        var observed = 0
        root.onPointerMoved = { _ in observed += 1 }
        window.contentView = NSView(frame: .zero)
        XCTAssertNil(root.window)
        XCTAssertFalse(frameView.trackingAreas.contains { $0 === boundary },
                       "detaching removes the boundary route from its recorded frame")

        NSApp.sendEvent(try mouseMoved(in: window, at: CGPoint(x: 100, y: 610)))

        XCTAssertEqual(observed, 0)
    }

    func testMovingIntoTheNativeTitlebarDoesNotCountAsLeavingTheWindow() throws {
        let (window, root) = makeWindow()
        defer { window.close() }
        let point = CGPoint(x: root.bounds.midX, y: root.bounds.maxY + 8)
        let event = try XCTUnwrap(NSEvent.enterExitEvent(
            with: .mouseExited, location: point, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0,
            trackingNumber: 0, userData: nil))
        var exits = 0
        var observed: [CGPoint] = []
        root.onPointerExited = { exits += 1 }
        root.onPointerMoved = { observed.append($0) }

        root.mouseExited(with: event)

        XCTAssertEqual(exits, 0, "the visible native titlebar still belongs to this window")
        XCTAssertEqual(observed, [point], "the reveal state must keep this stationary hover")
    }

    func testMovingOutsideTheEntireWindowStillReportsAnExit() throws {
        let (window, root) = makeWindow()
        defer { window.close() }
        let event = try XCTUnwrap(NSEvent.enterExitEvent(
            with: .mouseExited, location: CGPoint(x: -5, y: 100), modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0,
            trackingNumber: 0, userData: nil))
        var exits = 0
        root.onPointerExited = { exits += 1 }

        root.mouseExited(with: event)

        XCTAssertEqual(exits, 1)
    }

    func testLeavingTheWindowThroughItsNativeTitlebarReportsTheFinalExit() throws {
        let (window, root) = makeWindow()
        defer { window.close() }
        let frameView = try XCTUnwrap(window.contentView?.superview)
        let boundaries = frameView.trackingAreas.filter { $0.owner === root }
        XCTAssertEqual(boundaries.count, 1, "the enclosing frame must retain the whole-window boundary")
        let boundary = try XCTUnwrap(boundaries.first)
        XCTAssertTrue(boundary.options.contains(.mouseEnteredAndExited))
        XCTAssertTrue(boundary.options.contains(.activeInKeyWindow))
        XCTAssertTrue(boundary.options.contains(.inVisibleRect))
        XCTAssertFalse(boundary.options.contains(.mouseMoved), "the frame only owns boundary events")
        let owner = try XCTUnwrap(boundary.owner as? NSResponder)
        var exits = 0
        root.onPointerExited = { exits += 1 }
        let titlebar = CGPoint(x: root.bounds.midX, y: root.bounds.maxY + 8)
        let outside = CGPoint(x: root.bounds.midX, y: window.frame.height + 8)
        XCTAssertTrue(frameView.bounds.contains(frameView.convert(titlebar, from: nil)),
                      "the registered frame includes the native titlebar")
        XCTAssertFalse(frameView.bounds.contains(frameView.convert(outside, from: nil)))

        // Synthetic mouseMoved does not move the system pointer or generate
        // AppKit boundary transitions in an inactive offscreen test runner.
        // Deliver actual exit events through the application's registered owner.
        root.mouseExited(with: try XCTUnwrap(NSEvent.enterExitEvent(
            with: .mouseExited, location: titlebar, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0,
            trackingNumber: 0, userData: nil)))
        XCTAssertEqual(exits, 0, "leaving content for the native titlebar keeps hover alive")
        owner.mouseExited(with: try XCTUnwrap(NSEvent.enterExitEvent(
            with: .mouseExited, location: outside, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0,
            trackingNumber: 0, userData: nil)))

        XCTAssertEqual(exits, 1, "the frame boundary owns the exit after content has already exited")
    }

    func testMovingTheRootToAnotherFrameRemovesItsOldBoundary() throws {
        let (first, root) = makeWindow()
        let second = TrackingKeyWindow(
            contentRect: NSRect(x: -30000, y: -30000, width: 800, height: 600),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        second.isReleasedWhenClosed = false
        TestAppKit.prepareForOffScreen(second)
        defer { first.close(); second.close() }
        let oldFrame = try XCTUnwrap(first.contentView?.superview)
        let oldBoundary = try XCTUnwrap(oldFrame.trackingAreas.first { $0.owner === root })

        second.contentView = root
        root.refreshWindowBoundaryTracking()

        let newFrame = try XCTUnwrap(second.contentView?.superview)
        XCTAssertTrue(root.window === second)
        XCTAssertFalse(oldFrame.trackingAreas.contains { $0 === oldBoundary })
        XCTAssertEqual(newFrame.trackingAreas.filter { $0.owner === root }.count, 1)
        root.refreshWindowBoundaryTracking()
        XCTAssertEqual(newFrame.trackingAreas.filter { $0.owner === root }.count, 1,
                       "a frame refresh does not install duplicate boundary routes")
    }
}

/// The test runner may remain inactive while its windows are off screen. Model
/// the key state at the AppKit boundary without activating the runner in front
/// of the user's current application; event dispatch and viewer views are real.
private final class TrackingKeyWindow: NSWindow {
    override var isKeyWindow: Bool { true }
}
