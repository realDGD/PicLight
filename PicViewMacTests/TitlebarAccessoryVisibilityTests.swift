import XCTest
import AppKit
@testable import PicViewMac

/// The drawer button's real visibility across the titlebar states.
///
/// Reported from a real GUI pass: with the bar away the traffic lights were gone but the drawer
/// button was still on screen, and once the lights appeared the two overlapped. Two mechanisms
/// were measured, and the fix has to answer both:
///
/// - `NSTitlebarAccessoryViewController.isHidden` does not take an accessory's view out of a
///   `.fullSizeContentView` window whose title is hidden; the view stayed in the window.
/// - AppKit *moves* that view between two positions: (18, …) — floating over the traffic lights'
///   own (9…69) strip — while the bar is away, and (78, …) inside the bar when it is up. A view
///   left at the floating position is what landed on top of the lights.
///
/// So visibility is presence in the titlebar, not a flag: the accessory is removed while the bar is
/// away and added back with it. These assertions are on the window's real accessory list and on
/// the button's own view, which is what the user sees.
@MainActor
final class TitlebarAccessoryVisibilityTests: XCTestCase {

    override func setUp() async throws {
        try await super.setUp()
        TestAppKit.ensureApplication()
    }

    private func makeViewer() throws -> (controller: ViewerWindowController,
                                         viewer: ViewerViewController,
                                         window: ViewerWindow) {
        let controller = ViewerWindowController()
        TestAppKit.presentOffScreen(controller)
        let viewer = controller.viewerViewController
        controller.showWindow(nil)
        _ = viewer.view
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        return (controller, viewer, try XCTUnwrap(controller.window as? ViewerWindow))
    }

    private func settle(_ seconds: TimeInterval = 0.3) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    private func isInTitlebar(_ controller: ViewerWindowController, _ window: ViewerWindow) -> Bool {
        guard let button = controller.drawerTitlebarButton else { return false }
        return window.titlebarAccessoryViewControllers.contains { $0.view === button }
    }

    private func lightsFrame(_ window: ViewerWindow) -> CGRect {
        let lights = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton]
            .compactMap { window.standardWindowButton($0) }
        guard let first = lights.first, let container = first.superview else { return .null }
        let union = lights.dropFirst().reduce(first.frame) { $0.union($1.frame) }
        return container.convert(union, to: nil)
    }

    private func assertClearOfTheLights(_ button: NSButton, _ window: ViewerWindow,
                                        _ message: String) {
        let buttonFrame = button.convert(button.bounds, to: nil)
        let overlap = lightsFrame(window).intersection(buttonFrame)
        XCTAssertTrue(overlap.isNull || overlap.width <= 0 || overlap.height <= 0,
                      "\(message) (button \(buttonFrame), lights \(lightsFrame(window)))")
    }

    /// The reported bug: with the bar away the button must be gone from the screen — the traffic
    /// lights are hidden, and a lone control left floating over the image is not a titlebar.
    func testTheDrawerButtonIsNotInTheTitlebarWhileTheBarIsAway() throws {
        let (controller, viewer, window) = try makeViewer()
        defer { controller.close() }
        XCTAssertEqual(window.titlebarState, .hidden, "precondition: the bar starts away")
        XCTAssertFalse(isInTitlebar(controller, window),
                       "the accessory must be taken out of the titlebar with the bar")
        XCTAssertEqual(controller.drawerTitlebarButton?.isHidden, true)

        let zones = viewer.titlebarRevealZones
        viewer.simulatePointer(atWindowPoint: viewer.view.convert(
            CGPoint(x: zones.a.midX, y: zones.a.midY), to: nil))
        settle()
        XCTAssertEqual(window.titlebarState, .trafficLightsOnly)
        XCTAssertFalse(window.standardWindowButton(.closeButton)?.isHidden ?? true,
                       "the lights themselves are revealed in zone A")
        XCTAssertFalse(isInTitlebar(controller, window),
                       "the lights-only state must not put the button back beside them")
    }

    /// And it comes back inside the full titlebar, beside the lights rather than on top of them.
    func testTheDrawerButtonReturnsInsideTheFullTitlebarClearOfTheLights() throws {
        let (controller, viewer, window) = try makeViewer()
        defer { controller.close() }
        let zones = viewer.titlebarRevealZones
        viewer.simulatePointer(atWindowPoint: viewer.view.convert(
            CGPoint(x: zones.b.midX, y: zones.b.midY), to: nil))
        settle()
        XCTAssertEqual(window.titlebarState, .full)
        XCTAssertTrue(isInTitlebar(controller, window),
                      "with the full bar the button is part of it")
        let button = try XCTUnwrap(controller.drawerTitlebarButton)
        XCTAssertFalse(button.isHidden)
        XCTAssertEqual(button.alphaValue, 1, accuracy: 0.01)
        assertClearOfTheLights(button, window, "the button must sit beside the lights, not over them")

        // Away again: it leaves with the bar, after the model's own delay.
        viewer.simulatePointer(atWindowPoint: viewer.view.convert(
            CGPoint(x: viewer.view.bounds.midX, y: viewer.view.bounds.midY), to: nil))
        settle(TitlebarVisibilityModel.Timing().hideDelay + 0.5)
        XCTAssertEqual(window.titlebarState, .hidden)
        XCTAssertFalse(isInTitlebar(controller, window), "and it leaves with the bar")
    }

    /// A reveal after a hide cycle is the sequence that exposed the stale floating position: the
    /// button must land inside the bar every time, never over the lights.
    func testRepeatedRevealsNeverLeaveTheButtonOverTheLights() throws {
        let (controller, viewer, window) = try makeViewer()
        defer { controller.close() }
        let zones = viewer.titlebarRevealZones
        let insideB = viewer.view.convert(CGPoint(x: zones.b.midX, y: zones.b.midY), to: nil)
        let middle = viewer.view.convert(
            CGPoint(x: viewer.view.bounds.midX, y: viewer.view.bounds.midY), to: nil)

        for cycle in 0..<3 {
            viewer.simulatePointer(atWindowPoint: insideB)
            settle()
            XCTAssertEqual(window.titlebarState, .full, "cycle \(cycle)")
            let button = try XCTUnwrap(controller.drawerTitlebarButton)
            assertClearOfTheLights(button, window, "cycle \(cycle): the button overlapped the lights")
            viewer.simulatePointer(atWindowPoint: middle)
            settle(TitlebarVisibilityModel.Timing().hideDelay + 0.3)
            XCTAssertEqual(window.titlebarState, .hidden, "cycle \(cycle)")
        }
    }

    /// The folder browser pins the bar visible: the button is part of that bar and clear of the
    /// lights there too.
    func testTheButtonSitsInThePinnedBarWhileBrowsing() throws {
        let directory = try Fixtures.makeScratchDirectory("accessory-browse")
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        for index in 0..<3 {
            try FileManager.default.copyItem(at: Fixtures.url("static.png"),
                                             to: directory.appendingPathComponent("img\(index).png"))
        }
        let (controller, viewer, window) = try makeViewer()
        defer { controller.close() }
        viewer.open(url: directory.appendingPathComponent("img0.png"))
        let deadline = Date().addingTimeInterval(10)
        while viewer.viewerState.currentImage == nil, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        viewer.perform(.browseFolder)
        settle(0.6)

        XCTAssertEqual(window.titlebarMode, .alwaysVisible)
        XCTAssertTrue(isInTitlebar(controller, window), "the pinned bar carries the button")
        let button = try XCTUnwrap(controller.drawerTitlebarButton)
        assertClearOfTheLights(button, window, "and it is still clear of the lights")
    }
}