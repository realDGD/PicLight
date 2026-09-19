import XCTest
import AppKit
@testable import PicViewMac

/// The traffic-light reveal: which real AppKit controls appear, and when.
///
/// The invariant the spec is most emphatic about is that these are
/// `window.standardWindowButton(...)` and never anything drawn. That is checked here by object
/// identity against the window's own controls, by the absence of any viewer-owned titlebar view,
/// and by a source scan: a hand-drawn replacement would have to appear somewhere in the production
/// code, and it does not.
@MainActor
final class TrafficLightRevealTests: XCTestCase {

    override func setUp() async throws {
        try await super.setUp()
        TestAppKit.ensureApplication()
    }

    private static let buttonTypes: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton,
                                                            .zoomButton]

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

    /// The controls are the window's own, and applying a state never replaces them.
    func testTheRevealedControlsAreTheWindowsOwnStandardButtons() throws {
        let (controller, viewer, window) = try makeViewer()
        defer { controller.close() }

        let before = Self.buttonTypes.map { window.standardWindowButton($0) }
        XCTAssertFalse(before.contains(where: { $0 == nil }),
                       "all three standard controls must exist")

        let zones = viewer.titlebarRevealZones
        viewer.simulatePointer(atWindowPoint: viewer.view.convert(
            CGPoint(x: zones.a.midX, y: zones.a.midY), to: nil))
        settle()

        let after = Self.buttonTypes.map { window.standardWindowButton($0) }
        for (index, button) in after.enumerated() {
            XCTAssertTrue(button === before[index],
                          "the revealed control must be the same object, not a replacement")
        }
        XCTAssertEqual(window.titlebarState, .trafficLightsOnly)
    }

    /// Zone A: the controls appear, the titlebar's background and title do not.
    func testZoneAShowsTheControlsWithoutTheTitlebarChrome() throws {
        let (controller, viewer, window) = try makeViewer()
        defer { controller.close() }
        XCTAssertEqual(window.titlebarState, .hidden, "the bar starts away")

        let zones = viewer.titlebarRevealZones
        viewer.simulatePointer(atWindowPoint: viewer.view.convert(
            CGPoint(x: zones.a.midX, y: zones.a.midY), to: nil))
        settle()

        XCTAssertEqual(window.titlebarState, .trafficLightsOnly)
        XCTAssertTrue(window.titlebarAppearsTransparent,
                      "the bar's background stays away in the lights-only state")
        XCTAssertEqual(window.titleVisibility, .hidden, "and so does the title")
        for type in Self.buttonTypes {
            let button = try XCTUnwrap(window.standardWindowButton(type))
            XCTAssertFalse(button.isHidden, "\(type) must be revealed")
            XCTAssertEqual(button.alphaValue, 1, accuracy: 0.01, "\(type) must be fully opaque")
        }
    }

    /// Zone B: the whole titlebar, which is the bar's background and title as well as the controls.
    func testZoneBShowsTheWholeTitlebar() throws {
        let (controller, viewer, window) = try makeViewer()
        defer { controller.close() }

        let zones = viewer.titlebarRevealZones
        XCTAssertGreaterThan(zones.b.width, 100, "there must be room in zone B to test it")
        viewer.simulatePointer(atWindowPoint: viewer.view.convert(
            CGPoint(x: zones.b.midX, y: zones.b.midY), to: nil))
        settle()

        XCTAssertEqual(window.titlebarState, .full)
        XCTAssertFalse(window.titlebarAppearsTransparent, "the bar itself is on screen")
        XCTAssertEqual(window.titleVisibility, .visible, "with its title")
        for type in Self.buttonTypes {
            XCTAssertEqual(window.standardWindowButton(type)?.isHidden, false)
        }
    }

    /// Away again: after the delay, both the bar and the controls are gone.
    func testTheControlsGoAwayWithTheBar() throws {
        let (controller, viewer, window) = try makeViewer()
        defer { controller.close() }
        let zones = viewer.titlebarRevealZones
        viewer.simulatePointer(atWindowPoint: viewer.view.convert(
            CGPoint(x: zones.b.midX, y: zones.b.midY), to: nil))
        settle()
        XCTAssertEqual(window.titlebarState, .full)

        // Leave the strip: the middle of the image.
        viewer.simulatePointer(atWindowPoint: viewer.view.convert(
            CGPoint(x: viewer.view.bounds.midX, y: viewer.view.bounds.midY), to: nil))
        settle(TitlebarVisibilityModel.Timing().hideDelay + 0.4)

        XCTAssertEqual(window.titlebarState, .hidden)
        for type in Self.buttonTypes {
            let button = try XCTUnwrap(window.standardWindowButton(type))
            XCTAssertTrue(button.isHidden, "\(type) must be hidden with the bar")
            XCTAssertEqual(button.alphaValue, 0, accuracy: 0.01)
        }
    }

    /// A hidden control is not clickable either: `isHidden` takes it out of hit-testing, which an
    /// alpha of zero would not.
    func testAHiddenControlCannotBeClicked() throws {
        let (controller, viewer, window) = try makeViewer()
        defer { controller.close() }
        _ = viewer
        XCTAssertEqual(window.titlebarState, .hidden)
        for type in Self.buttonTypes {
            let button = try XCTUnwrap(window.standardWindowButton(type))
            XCTAssertNil(button.hitTest(button.convert(CGPoint(x: button.bounds.midX,
                                                              y: button.bounds.midY),
                                                       to: button.superview)),
                         "\(type) must not be hit-testable while hidden")
        }
    }

    /// A pointer sweeping the image must not reveal anything: the top strip is where the gesture
    /// is, and nowhere else.
    func testAPointerSweepBelowTheTopStripRevealsNothing() throws {
        let (controller, viewer, window) = try makeViewer()
        defer { controller.close() }
        let zones = viewer.titlebarRevealZones
        // One transition has happened already: the window applied the default hidden state. What
        // matters is that the sweep adds none.
        let transitionsBefore = viewer.titlebarTransitionCount

        for x in stride(from: CGFloat(20), through: viewer.view.bounds.width - 20, by: 60) {
            for y in stride(from: CGFloat(20), through: zones.a.minY - 20, by: 60) {
                viewer.simulatePointer(atWindowPoint: viewer.view.convert(CGPoint(x: x, y: y),
                                                                        to: nil))
            }
        }
        settle()

        XCTAssertEqual(window.titlebarState, .hidden,
                       "only the top strip may summon the titlebar")
        XCTAssertEqual(viewer.titlebarTransitionCount, transitionsBefore,
                       "the sweep issued no transition")
    }

    /// Revealing and hiding is target-state idempotent: a run of pointer moves inside the strip
    /// does not re-issue the transition.
    func testRepeatedPointerMovesDoNotReissueTheTransition() throws {
        let (controller, viewer, window) = try makeViewer()
        defer { controller.close() }
        let zones = viewer.titlebarRevealZones
        let insideB = viewer.view.convert(CGPoint(x: zones.b.midX, y: zones.b.midY), to: nil)

        viewer.simulatePointer(atWindowPoint: insideB)
        settle()
        let transitions = viewer.titlebarTransitionCount
        XCTAssertGreaterThan(transitions, 0)

        for _ in 0..<100 { viewer.simulatePointer(atWindowPoint: insideB) }
        XCTAssertEqual(viewer.titlebarTransitionCount, transitions,
                       "100 moves inside the strip must not re-issue anything")
        XCTAssertEqual(window.titlebarState, .full)
    }

    /// The viewer's own titlebar accessory — the drawer button — goes with the bar it lives in, so a
    /// hidden titlebar leaves nothing floating over the image. Visibility is presence in the
    /// titlebar, not a flag: `isHidden` alone does not take an accessory's view out of a
    /// `.fullSizeContentView` window.
    func testTheTitlebarAccessoryHidesWithTheBar() throws {
        let (controller, viewer, window) = try makeViewer()
        defer { controller.close() }
        let button = try XCTUnwrap(controller.drawerTitlebarButton)
        XCTAssertFalse(window.titlebarAccessoryViewControllers.contains { $0.view === button },
                       "with the bar away the drawer button is not in the titlebar at all")
        XCTAssertTrue(button.isHidden)

        let zones = viewer.titlebarRevealZones
        viewer.simulatePointer(atWindowPoint: viewer.view.convert(
            CGPoint(x: zones.b.midX, y: zones.b.midY), to: nil))
        settle()
        XCTAssertTrue(window.titlebarAccessoryViewControllers.contains { $0.view === button },
                      "and it comes back with the bar")
        XCTAssertFalse(button.isHidden)
    }

    /// The drawer button rides with the *full* titlebar only: in the lights-only state the bar
    /// itself is invisible, and a lone button floating beside the traffic lights reads as a
    /// control on the page instead of a titlebar control.
    func testTheAccessoryDoesNotFloatInTheLightsOnlyState() throws {
        let (controller, viewer, window) = try makeViewer()
        defer { controller.close() }
        let button = try XCTUnwrap(controller.drawerTitlebarButton)

        let zones = viewer.titlebarRevealZones
        viewer.simulatePointer(atWindowPoint: viewer.view.convert(
            CGPoint(x: zones.a.midX, y: zones.a.midY), to: nil))
        settle()
        XCTAssertEqual(window.titlebarState, .trafficLightsOnly)
        XCTAssertFalse(window.titlebarAccessoryViewControllers.contains { $0.view === button },
                       "the lights-only state must not leave the drawer button floating "
                       + "over the content")

        viewer.simulatePointer(atWindowPoint: viewer.view.convert(
            CGPoint(x: zones.b.midX, y: zones.b.midY), to: nil))
        settle()
        XCTAssertEqual(window.titlebarState, .full)
        XCTAssertTrue(window.titlebarAccessoryViewControllers.contains { $0.view === button },
                      "with the full bar the button is part of the titlebar again")
        XCTAssertFalse(button.isHidden)
    }

    /// An open left column brings the bar with it: the column's own control lives in the titlebar,
    /// so the bar cannot hide while the column is open.
    func testAnOpenDrawerKeepsTheTitlebarUp() throws {
        let (controller, viewer, window) = try makeViewer()
        defer { controller.close() }
        // Pointer away first, so the bar starts from its hidden state.
        viewer.simulatePointer(atWindowPoint: viewer.view.convert(
            CGPoint(x: viewer.view.bounds.midX, y: viewer.view.bounds.midY), to: nil))
        settle(TitlebarVisibilityModel.Timing().hideDelay + 0.4)
        XCTAssertEqual(window.titlebarState, .hidden, "precondition: the bar is away")

        viewer.setDrawerOpen(true)
        settle(0.4)
        XCTAssertTrue(viewer.isDrawerOpen)
        XCTAssertEqual(window.titlebarState, .full,
                       "opening the column shows the bar that carries its control")

        // Idle with the pointer away: the open column holds the bar.
        viewer.simulatePointer(atWindowPoint: viewer.view.convert(
            CGPoint(x: viewer.view.bounds.midX, y: viewer.view.bounds.midY), to: nil))
        settle(TitlebarVisibilityModel.Timing().hideDelay + 0.5)
        XCTAssertNotEqual(window.titlebarState, .hidden, "the bar stays while the column is open")

        viewer.setDrawerOpen(false)
        viewer.simulatePointer(atWindowPoint: viewer.view.convert(
            CGPoint(x: viewer.view.bounds.midX, y: viewer.view.bounds.midY), to: nil))
        settle(TitlebarVisibilityModel.Timing().hideDelay + 0.5)
        XCTAssertEqual(window.titlebarState, .hidden, "and leaves once the column is closed")
    }

    /// Nothing viewer-owned is a titlebar, and nothing draws a replacement control.
    func testThereIsNoViewerOwnedTitlebarOrFakeControl() throws {
        let (controller, viewer, _) = try makeViewer()
        defer { controller.close() }
        for (name, view) in viewer.chromeViewsForTesting {
            XCTAssertFalse(String(describing: type(of: view)).contains("Titlebar"),
                           "\(name) looks like a viewer-owned titlebar")
        }

        // The one thing a fake control would need: a view that draws a red/yellow/green circle.
        // A source scan is the only way to check "nothing draws one" from inside a test.
        let production = try Self.productionSources()
        let forbidden = ["fakeTrafficLight", "TrafficLightButton", "trafficLightView",
                         "drawTrafficLight"]
        for needle in forbidden {
            XCTAssertFalse(production.contains(needle),
                           "production code mentions \(needle)")
        }
        // And the real API is what it uses.
        XCTAssertTrue(production.contains("standardWindowButton"),
                      "the real standard-window-button API is what the window uses")
    }

    /// Every Swift file in the production target, concatenated.
    private static func productionSources() throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // PicViewMacTests
            .deletingLastPathComponent()   // repository root
        let directory = root.appendingPathComponent("PicViewMac")
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: directory,
                                                                     includingPropertiesForKeys: nil))
        var text = ""
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            text += (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        }
        XCTAssertGreaterThan(text.count, 10_000, "the scan must actually read the sources")
        return text
    }
}
