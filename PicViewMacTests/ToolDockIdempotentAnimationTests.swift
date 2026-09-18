import XCTest
import AppKit
@testable import PicViewMac

/// The dock's show/hide transition must be target-state idempotent.
///
/// `applyChromeVisibility` runs on every pointer move, and the dock's visibility is derived from
/// the hover model each time. The transition used to be issued unconditionally, so while the
/// pointer sat inside the reveal strip the fade and the slide were restarted on every event and
/// the dock never settled. The evidence is a transition counter: a pointer sweep must not move it.
@MainActor
final class ToolDockIdempotentAnimationTests: XCTestCase {

    override func setUp() async throws {
        try await super.setUp()
        TestAppKit.ensureApplication()
    }

    /// Polls the main run loop until `condition` holds. The condition is the evidence; a fixed
    /// sleep would only be evidence that time passed.
    @discardableResult
    private func waitUntil(_ condition: () -> Bool, timeout: TimeInterval = 3) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return condition()
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

    /// The headline requirement: 100 pointer moves with the dock already visible must not start
    /// the transition again, not even once.
    ///
    /// The counter is the evidence: it is incremented on the first line of the only method that
    /// touches the dock's alpha, its slide and its `isHidden`, so a counter that does not move is
    /// an animation that was not re-issued.
    func testAHundredPointerMovesDoNotRestartTheTransition() throws {
        let (controller, viewer, dock) = try makeViewer()
        defer { controller.close() }

        // Put the pointer in the dock's reveal strip so its target state is "visible".
        let revealZone = viewer.toolDockRevealZone
        XCTAssertGreaterThan(revealZone.width, 0, "the dock must have a reveal strip to hover")
        let inside = viewer.view.convert(CGPoint(x: revealZone.midX, y: revealZone.midY), to: nil)
        viewer.simulatePointer(atWindowPoint: inside)
        XCTAssertTrue(waitUntil { viewer.toolDockVisibilityForTesting.visible },
                      "the dock is showing")
        let transitionsAfterShow = viewer.dockVisibilityTransitionCount
        XCTAssertGreaterThan(transitionsAfterShow, 0,
                             "and getting it there took at least one transition")

        for _ in 0..<100 {
            viewer.simulatePointer(atWindowPoint: inside)
        }

        XCTAssertEqual(viewer.dockVisibilityTransitionCount, transitionsAfterShow,
                       "100 pointer moves restarted the dock's transition")
        XCTAssertTrue(viewer.toolDockVisibilityForTesting.visible)
        XCTAssertFalse(dock.isHidden)
    }

    /// Leaving and re-entering does transition, once per change — the guard must not be so
    /// aggressive that the dock stops responding.
    func testLeavingAndReturningTransitionsExactlyOncePerChange() throws {
        let (controller, viewer, dock) = try makeViewer()
        defer { controller.close() }

        let revealZone = viewer.toolDockRevealZone
        let inside = viewer.view.convert(CGPoint(x: revealZone.midX, y: revealZone.midY), to: nil)
        let outside = viewer.view.convert(CGPoint(x: viewer.view.bounds.midX,
                                                  y: viewer.view.bounds.maxY - 20), to: nil)

        viewer.simulatePointer(atWindowPoint: inside)
        XCTAssertTrue(waitUntil { viewer.toolDockVisibilityForTesting.visible })
        let afterShow = viewer.dockVisibilityTransitionCount
        XCTAssertGreaterThan(afterShow, 0, "the dock went through a transition to get here")

        // Pointer away: exactly one more transition, and the dock leaves the hierarchy.
        viewer.simulatePointer(atWindowPoint: outside)
        XCTAssertTrue(waitUntil { !viewer.toolDockVisibilityForTesting.visible },
                      "the dock's state hides")
        XCTAssertEqual(viewer.dockVisibilityTransitionCount, afterShow + 1,
                       "hiding is one transition")
        // The hierarchy change lands one fade after the state change, so wait for it rather than
        // for the state.
        XCTAssertTrue(waitUntil { dock.isHidden }, "and the dock leaves the hierarchy")

        // Re-entering shows it again: one more transition, and it is interactive again.
        viewer.simulatePointer(atWindowPoint: inside)
        XCTAssertTrue(waitUntil { viewer.toolDockVisibilityForTesting.visible })
        XCTAssertEqual(viewer.dockVisibilityTransitionCount, afterShow + 2)
        XCTAssertFalse(dock.isHidden)
    }

    /// A pointer sweep anywhere — including across the dock itself — must not move the counter
    /// while the dock's target state is unchanged.
    func testSweepingAcrossTheDockDoesNotRestartAnything() throws {
        let (controller, viewer, dock) = try makeViewer()
        defer { controller.close() }
        viewer.setToolDockPinned(true)
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        let pinned = viewer.dockVisibilityTransitionCount
        XCTAssertGreaterThan(pinned, 0, "pinning shows the dock")

        for x in stride(from: CGFloat(0), through: viewer.view.bounds.width, by: 11) {
            for y in stride(from: CGFloat(0), through: viewer.view.bounds.height, by: 17) {
                viewer.simulatePointer(atWindowPoint: NSPoint(x: x, y: y))
            }
        }

        XCTAssertTrue(viewer.toolDockVisibilityForTesting.visible, "a pinned dock stays")
        XCTAssertEqual(viewer.dockVisibilityTransitionCount, pinned,
                       "and a full sweep does not re-issue its transition")
    }

    /// Reduce Motion drops the slide and the fade, but not the show/hide itself.
    func testReduceMotionRemovesTheSlideWithoutRemovingTheTransition() throws {
        let (controller, viewer, dock) = try makeViewer()
        defer { controller.close() }
        // The pure helper is what the viewer consults, so the Reduce Motion contract is checked
        // there as well as at the call site.
        XCTAssertEqual(ViewerToolDockView.hiddenOffset(reduceMotion: true), 0)
        XCTAssertEqual(ViewerToolDockView.hiddenOffset(reduceMotion: false),
                       ViewerToolDockView.hiddenSlideDistance)
        XCTAssertEqual(ViewerToolDockView.hoverDuration(reduceMotion: true), 0)

        // And the dock still hides and shows: Reduce Motion is about the animation, not the state.
        let revealZone = viewer.toolDockRevealZone
        let inside = viewer.view.convert(CGPoint(x: revealZone.midX, y: revealZone.midY), to: nil)
        viewer.simulatePointer(atWindowPoint: inside)
        let deadline = Date().addingTimeInterval(3)
        while !viewer.toolDockVisibilityForTesting.visible, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertTrue(viewer.toolDockVisibilityForTesting.visible)
        XCTAssertFalse(dock.isHidden)
    }

    /// Press feedback composes with hover rather than replacing it.
    func testPressScaleComposesWithHoverScale() throws {
        let button = DockButton(symbol: "trash", tooltip: "移到废纸篓")
        XCTAssertEqual(button.effectiveScale, 1)

        button.setHoverScale(ViewerToolDockView.hoveredScale, duration: 0)
        XCTAssertEqual(button.effectiveScale, ViewerToolDockView.hoveredScale, accuracy: 1e-9)

        button.setPressed(true, reduceMotion: false)
        XCTAssertEqual(button.effectiveScale,
                       ViewerToolDockView.hoveredScale * ViewerToolDockView.pressedScale,
                       accuracy: 1e-9,
                       "pressing while hovered must multiply, not replace")

        button.setPressed(false, reduceMotion: false)
        XCTAssertEqual(button.effectiveScale, ViewerToolDockView.hoveredScale, accuracy: 1e-9,
                       "and releasing restores exactly the hover scale")

        button.setHoverScale(1, duration: 0)
        XCTAssertEqual(button.effectiveScale, 1)
    }

    /// The hover neighbour behaviour the spec keeps: the hovered item enlarges, its immediate
    /// neighbours lift slightly, and everything else collapses back.
    func testHoverEnlargementAppliesToTheHoveredItemAndItsNeighbours() throws {
        let (controller, viewer, dock) = try makeViewer()
        defer { controller.close() }
        let buttons = dock.allButtons
        guard let middle = buttons.indices.first(where: { $0 > 0 && $0 < buttons.count - 1 })
        else { return XCTFail("the dock needs at least three controls") }
        buttons[middle].onHoverChanged?(true)

        XCTAssertEqual(buttons[middle].hoverScale, ViewerToolDockView.hoveredScale, accuracy: 1e-9)
        XCTAssertEqual(buttons[middle - 1].hoverScale, ViewerToolDockView.neighbourScale,
                       accuracy: 1e-9)
        XCTAssertEqual(buttons[middle + 1].hoverScale, ViewerToolDockView.neighbourScale,
                       accuracy: 1e-9)
        if let far = buttons.indices.first(where: { abs($0 - middle) > 1 }) {
            XCTAssertEqual(buttons[far].hoverScale, 1, accuracy: 1e-9,
                           "a button further away is untouched")
        }

        buttons[middle].onHoverChanged?(false)
        XCTAssertEqual(buttons[middle].hoverScale, 1, accuracy: 1e-9)
        XCTAssertEqual(buttons[middle - 1].hoverScale, 1, accuracy: 1e-9)
    }
}
