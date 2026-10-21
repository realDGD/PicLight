import XCTest
import AppKit
@testable import PicViewMac

/// The dock's first control that is not an image action: the pin. Plus the press/hover
/// animations, which must compose instead of fighting, and must never move the image.
@MainActor
final class ToolDockInteractionTests: XCTestCase {

    override func setUp() async throws {
        try await super.setUp()
        TestAppKit.ensureApplication()
    }

    private func dock() -> ViewerToolDockView {
        let dock = ViewerToolDockView()
        dock.frame = NSRect(x: 0, y: 0, width: 420, height: ViewerToolDockView.height)
        dock.layoutSubtreeIfNeeded()
        return dock
    }

    // MARK: - Placement

    func testThePinIsTheLastControlBehindItsOwnSeparator() throws {
        let dock = self.dock()
        let stack = try XCTUnwrap(dock.subviews.compactMap { $0 as? NSStackView }.first)
        XCTAssertTrue(stack.arrangedSubviews.last === dock.pinControl,
                      "the pin is the rightmost control in the dock")
        let separator = try XCTUnwrap(stack.arrangedSubviews.dropLast().last)
        XCTAssertTrue(separator is NSBox, "and it is set off by a hairline separator")
    }

    func testThePinIsNotAnImageCommand() {
        let dock = self.dock()
        XCTAssertEqual(dock.commands, ViewerToolDockView.layout.compactMap {
                           if case let .command(_, command, _) = $0 { return command }
                           return nil
                       },
                       "the pin and the playback button are not viewer commands")
        // Clicking it must not run a viewer command either.
        var commands: [ViewerCommand] = []
        dock.onCommand = { commands.append($0) }
        dock.setAnimated(true, isPlaying: true)
        dock.pinControl.onActivate?()
        XCTAssertTrue(commands.isEmpty, "the pin is not a ViewerCommand")
    }

    // MARK: - States

    func testThePinReadsAsAnOutlineUntilItIsEngaged() throws {
        let dock = self.dock()
        XCTAssertNotNil(NSImage(systemSymbolName: ViewerToolDockView.pinSymbol,
                                accessibilityDescription: nil),
                        "the outline symbol must exist on this system")
        XCTAssertNotNil(NSImage(systemSymbolName: ViewerToolDockView.pinnedSymbol,
                                accessibilityDescription: nil),
                        "and so must the filled one")
        XCTAssertEqual(dock.pinControl.symbolName, ViewerToolDockView.pinSymbol)
        XCTAssertEqual(dock.pinControl.toolTip, ViewerToolDockView.pinTooltip)
        XCTAssertEqual(dock.pinControl.iconTint, .labelColor)
        XCTAssertEqual(dock.pinControl.symbolImage?.isTemplate, true,
                       "a template icon follows the surface behind it")
        XCTAssertFalse(dock.isPinned)

        dock.setPinned(true)
        XCTAssertTrue(dock.isPinned)
        XCTAssertEqual(dock.pinControl.symbolName, ViewerToolDockView.pinnedSymbol)
        XCTAssertEqual(dock.pinControl.toolTip, ViewerToolDockView.unpinTooltip)
        XCTAssertEqual(dock.pinControl.iconTint, .systemBlue,
                       "engaged state is the system blue, not the label colour")
        XCTAssertEqual(dock.pinControl.accessibilityLabel(), ViewerToolDockView.unpinTooltip)

        dock.setPinned(false)
        XCTAssertEqual(dock.pinControl.symbolName, ViewerToolDockView.pinSymbol)
        XCTAssertEqual(dock.pinControl.iconTint, .labelColor)
        XCTAssertEqual(dock.pinControl.accessibilityLabel(), ViewerToolDockView.pinTooltip)
    }

    func testTheEngagedTintSurvivesAnAppearanceChange() throws {
        let dock = self.dock()
        dock.setPinned(true)
        dock.pinControl.viewDidChangeEffectiveAppearance()
        XCTAssertEqual(dock.pinControl.iconTint, .systemBlue,
                       "re-applying the tint must keep the engaged colour")
    }

    func testTheSymbolSwapCrossfadesInTheIntendedRange() throws {
        let dock = self.dock()
        dock.setPinned(true)
        let transition = try XCTUnwrap(dock.pinControl.symbolCrossfade,
                                       "the glyph swap must fade, not cut")
        XCTAssertEqual(transition.type, .fade)
        XCTAssertGreaterThanOrEqual(transition.duration, 0.1)
        XCTAssertLessThanOrEqual(transition.duration, 0.15)
    }

    func testReduceMotionRemovesTheCrossfade() {
        XCTAssertEqual(ViewerToolDockView.pinCrossfadeDuration(reduceMotion: true), 0)
        XCTAssertGreaterThan(ViewerToolDockView.pinCrossfadeDuration(reduceMotion: false), 0)

        let button = DockButton(symbol: ViewerToolDockView.pinSymbol, tooltip: "t")
        button.setSymbol(ViewerToolDockView.pinnedSymbol, crossfade: 0)
        XCTAssertFalse(button.symbolCrossfadeIsRunning,
                       "no animation at all when the duration is zero")
    }

    func testThePinReportsTheClickAndLetsTheCallerDecide() {
        let dock = self.dock()
        var reported: [Bool] = []
        dock.onPinChanged = { reported.append($0) }

        dock.pinControl.onActivate?()
        XCTAssertEqual(reported, [true])
        XCTAssertTrue(dock.isPinned)
        dock.pinControl.onActivate?()
        XCTAssertEqual(reported, [true, false])
        XCTAssertFalse(dock.isPinned)
    }

    /// The dock mirrors the model rather than owning the state, so a caller that sets the
    /// state does not get its own notification back.
    func testSettingThePinStateDirectlyDoesNotReportAChange() {
        let dock = self.dock()
        var reported = 0
        dock.onPinChanged = { _ in reported += 1 }
        dock.setPinned(true)
        dock.setPinned(true)
        XCTAssertEqual(reported, 0)
        XCTAssertTrue(dock.isPinned)
    }

    // MARK: - Press and hover composition

    func testPressDipsTheButtonAndComposesWithHover() throws {
        let dock = self.dock()
        let button = try XCTUnwrap(dockButtonsForTesting(dock).first)

        button.setHoverScale(ViewerToolDockView.hoveredScale, duration: 0)
        XCTAssertEqual(button.currentScale, ViewerToolDockView.hoveredScale, accuracy: 0.001)

        button.setPressed(true, reduceMotion: false)
        XCTAssertTrue(button.isPressed)
        XCTAssertEqual(button.effectiveScale,
                       ViewerToolDockView.hoveredScale * ViewerToolDockView.pressedScale,
                       accuracy: 0.0001,
                       "press composes with hover instead of replacing it")
        XCTAssertEqual(button.currentScale, button.effectiveScale, accuracy: 0.001)

        button.setPressed(false, reduceMotion: false)
        XCTAssertEqual(button.currentScale, ViewerToolDockView.hoveredScale, accuracy: 0.001,
                       "releasing returns to the hover scale, not to 1")
    }

    func testPressWithoutHoverStillDips() throws {
        let dock = self.dock()
        let button = try XCTUnwrap(dockButtonsForTesting(dock).first)
        button.setPressed(true, reduceMotion: false)
        XCTAssertEqual(button.currentScale, ViewerToolDockView.pressedScale, accuracy: 0.001)
    }

    func testPressDurationsAreInTheIntendedRanges() {
        XCTAssertGreaterThanOrEqual(ViewerToolDockView.pressDuration(pressed: true, reduceMotion: false),
                                    0.05)
        XCTAssertLessThanOrEqual(ViewerToolDockView.pressDuration(pressed: true, reduceMotion: false),
                                 0.08)
        XCTAssertGreaterThanOrEqual(ViewerToolDockView.pressDuration(pressed: false, reduceMotion: false),
                                    0.10)
        XCTAssertLessThanOrEqual(ViewerToolDockView.pressDuration(pressed: false, reduceMotion: false),
                                 0.16)
        XCTAssertEqual(ViewerToolDockView.pressDuration(pressed: true, reduceMotion: true), 0)
        XCTAssertEqual(ViewerToolDockView.pressDuration(pressed: false, reduceMotion: true), 0)
        XCTAssertEqual(ViewerToolDockView.hoverDuration(reduceMotion: true), 0)
        XCTAssertGreaterThan(ViewerToolDockView.hoverDuration(reduceMotion: false), 0)
        XCTAssertGreaterThanOrEqual(ViewerToolDockView.pressedScale, 0.90)
        XCTAssertLessThanOrEqual(ViewerToolDockView.pressedScale, 0.94)
    }

    func testNeighbourHoverStillLiftsOnlyTheImmediateNeighbours() {
        let dock = self.dock()
        let buttons = dockButtonsForTesting(dock)
        buttons[2].onHoverChanged?(true)
        XCTAssertEqual(buttons[2].currentScale, ViewerToolDockView.hoveredScale, accuracy: 0.001)
        XCTAssertEqual(buttons[1].currentScale, ViewerToolDockView.neighbourScale, accuracy: 0.001)
        XCTAssertEqual(buttons[3].currentScale, ViewerToolDockView.neighbourScale, accuracy: 0.001)
        XCTAssertEqual(buttons[5].currentScale, 1, accuracy: 0.001)
        buttons[2].onHoverChanged?(false)
        XCTAssertEqual(buttons[2].currentScale, 1, accuracy: 0.001)
    }

    /// Hovering or pressing the dock must leave the image area exactly where it was: the
    /// enlargement is a layer transform, not a layout change.
    func testHoverAndPressNeverChangeCanvasGeometry() throws {
        let controller = ViewerWindowController()
        TestAppKit.presentOffScreen(controller)
        defer { controller.close() }
        let viewer = controller.viewerViewController
        _ = viewer.view
        viewer.open(url: Fixtures.url("static.png"))
        let deadline = Date().addingTimeInterval(10)
        while viewer.viewerState.currentImage == nil, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        let settle = { RunLoop.current.run(until: Date().addingTimeInterval(0.2)) }
        settle()

        let canvas = try XCTUnwrap(viewer.chromeViewsForTesting["canvas"] as? ImageCanvasView)
        let dock = try XCTUnwrap(viewer.chromeViewsForTesting["toolDock"] as? ViewerToolDockView)
        revealToolDock(viewer, dock)
        settle()
        let canvasFrame = canvas.frame
        let dockFrame = dock.frame
        let zoomBefore = canvas.viewport.zoomScale
        let fitBefore = canvas.viewport.fitScale
        let button = try XCTUnwrap(dockButtonsForTesting(dock).first)

        button.onHoverChanged?(true)
        button.setPressed(true, reduceMotion: false)
        settle()
        button.setPressed(false, reduceMotion: false)
        button.onHoverChanged?(false)
        settle()

        XCTAssertEqual(canvas.frame, canvasFrame, "hover/press must not reflow the canvas")
        XCTAssertEqual(dock.frame, dockFrame, "nor the dock itself")
        XCTAssertEqual(canvas.viewport.zoomScale, zoomBefore, accuracy: 0.0001)
        XCTAssertEqual(canvas.viewport.fitScale, fitBefore, accuracy: 0.0001)
        XCTAssertEqual(viewer.viewerState.viewport.zoomScale, zoomBefore, accuracy: 0.0001)
    }
}
