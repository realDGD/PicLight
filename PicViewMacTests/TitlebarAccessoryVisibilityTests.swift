import XCTest
import AppKit
@testable import PicViewMac

/// The drawer button's real visibility across the titlebar states.
///
/// Reported from a real GUI pass: with the bar away the traffic lights were gone but the drawer
/// button was still on screen, and when the pointer arrived the controls overlapped. The cause was
/// that `NSTitlebarAccessoryViewController.isHidden` does not remove an accessory's view from a
/// `.fullSizeContentView` window whose title is hidden — the view stayed in the window and merely
/// moved between the floating position (x=18) and the titlebar position (x=78), which is what made
/// the two overlap. These assertions are on the *view*, which is what the user sees.
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

    /// What the user sees: the button's own view, not the accessory controller's flag.
    private func assertButton(_ controller: ViewerWindowController, visible: Bool, _ message: String) {
        let button = controller.drawerTitlebarButton
        XCTAssertNotNil(button, "the drawer button exists")
        XCTAssertEqual(button?.isHidden, !visible, message)
        XCTAssertEqual(button?.alphaValue ?? -1, visible ? 1 : 0, accuracy: 0.01, message)
    }

    /// The reported bug: with the bar away the button must be gone from the screen — the traffic
    /// lights are hidden, and a lone control left floating over the image is not a titlebar.
    func testTheDrawerButtonIsInvisibleWhileTheBarIsAway() throws {
        let (controller, viewer, window) = try makeViewer()
        defer { controller.close() }
        XCTAssertEqual(window.titlebarState, .hidden, "precondition: the bar starts away")
        assertButton(controller, visible: false,
                     "the drawer button must not outlive the hidden bar")

        let zones = viewer.titlebarRevealZones
        viewer.simulatePointer(atWindowPoint: viewer.view.convert(
            CGPoint(x: zones.a.midX, y: zones.a.midY), to: nil))
        settle()
        XCTAssertEqual(window.titlebarState, .trafficLightsOnly)
        XCTAssertFalse(window.standardWindowButton(.closeButton)?.isHidden ?? true,
                       "the lights themselves are revealed in zone A")
        assertButton(controller, visible: false,
                     "the lights-only state must not leave the button floating beside them")
    }

    /// And it comes back with the full titlebar it belongs to.
    func testTheDrawerButtonReturnsWithTheFullTitlebar() throws {
        let (controller, viewer, window) = try makeViewer()
        defer { controller.close() }
        let zones = viewer.titlebarRevealZones
        viewer.simulatePointer(atWindowPoint: viewer.view.convert(
            CGPoint(x: zones.b.midX, y: zones.b.midY), to: nil))
        settle()
        XCTAssertEqual(window.titlebarState, .full)
        assertButton(controller, visible: true, "with the full bar the button is part of it")

        // Away again: it leaves with the bar, after the model's own delay.
        viewer.simulatePointer(atWindowPoint: viewer.view.convert(
            CGPoint(x: viewer.view.bounds.midX, y: viewer.view.bounds.midY), to: nil))
        settle(TitlebarVisibilityModel.Timing().hideDelay + 0.5)
        XCTAssertEqual(window.titlebarState, .hidden)
        assertButton(controller, visible: false, "and it leaves with the bar")
    }

    /// The lights-only state is not a place where the button may sit: the button occupies the same
    /// strip the lights appear in, so both being visible there is exactly the overlap reported.
    func testTheButtonAndTheLightsAreNeverBothFloating() throws {
        let (controller, viewer, window) = try makeViewer()
        defer { controller.close() }
        let zones = viewer.titlebarRevealZones
        var sawLightsOnly = false
        for (name, zone) in [("A", zones.a), ("B", zones.b)] {
            viewer.simulatePointer(atWindowPoint: viewer.view.convert(
                CGPoint(x: zone.midX, y: zone.midY), to: nil))
            settle()
            let lightsShown = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton]
                .contains { window.standardWindowButton($0)?.isHidden == false }
            let buttonShown = controller.drawerTitlebarButton?.isHidden == false
            if window.titlebarState == .trafficLightsOnly {
                sawLightsOnly = true
                XCTAssertFalse(lightsShown && buttonShown,
                               "zone \(name): floating lights and a floating button at once is "
                               + "the overlap that was reported")
            }
        }
        XCTAssertTrue(sawLightsOnly, "the lights-only state must have been exercised")
    }
}