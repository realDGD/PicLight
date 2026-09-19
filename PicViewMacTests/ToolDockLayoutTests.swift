import XCTest
import AppKit
@testable import PicViewMac

/// The dock's layout: which controls exist, in which order, and which groups they form.
///
/// The list is the layout — the stack is built from it — so these assertions are about the
/// control set a user sees, not about pixels.
@MainActor
final class ToolDockLayoutTests: XCTestCase {

    override func setUp() async throws {
        try await super.setUp()
        TestAppKit.ensureApplication()
    }

    private func dock() -> ViewerToolDockView {
        let dock = ViewerToolDockView(style: .dock)
        dock.layoutSubtreeIfNeeded()
        return dock
    }

    /// The four groups, in the documented order, with the pin last.
    func testTheDockIsTheDocumentedGroupsInOrder() {
        let items = ViewerToolDockView.layout

        // Zoom: out, the number, in, then fit / fit-width / actual pixels.
        XCTAssertEqual(Array(items.prefix(6)), [
            .command(symbol: ViewerToolDockView.zoomOutSymbol, command: .zoomOut, tooltip: "缩小"),
            .zoomReadout,
            .command(symbol: ViewerToolDockView.zoomInSymbol, command: .zoomIn, tooltip: "放大"),
            .command(symbol: ViewerToolDockView.fitSymbol, command: .zoomToFit, tooltip: "适应窗口"),
            .command(symbol: ViewerToolDockView.fitWidthSymbol, command: .zoomToFitWidth,
                     tooltip: "适应宽度"),
            .command(symbol: ViewerToolDockView.actualPixelsSymbol, command: .zoomActualPixels,
                     tooltip: "实际像素 100%"),
        ])
        XCTAssertEqual(Array(items[6...9]), [
            .separator,
            .command(symbol: ViewerToolDockView.previousSymbol, command: .previousImage,
                     tooltip: "上一张"),
            .positionReadout,
            .command(symbol: ViewerToolDockView.nextSymbol, command: .nextImage, tooltip: "下一张"),
        ])
        XCTAssertEqual(Array(items[10...13]), [
            .separator,
            .command(symbol: ViewerToolDockView.rotateSymbol, command: .rotateClockwise,
                     tooltip: "顺时针旋转"),
            .command(symbol: ViewerToolDockView.mirrorSymbol, command: .toggleMirror,
                     tooltip: "水平镜像"),
            .command(symbol: ViewerToolDockView.trashSymbol, command: .moveToTrash,
                     tooltip: "移到废纸篓"),
        ])
        XCTAssertEqual(Array(items[14...]), [
            .separator,
            .command(symbol: ViewerToolDockView.browserSymbol, command: .browseFolder,
                     tooltip: "浏览文件夹"),
            .command(symbol: ViewerToolDockView.drawerSymbol, command: .toggleThumbnailDrawer,
                     tooltip: "显示 / 隐藏缩略图抽屉"),
            .command(symbol: ViewerToolDockView.infoSymbol, command: .showImageInfo,
                     tooltip: "图像信息"),
            .separator,
            .pin,
        ])
    }

    /// The pin is the last *control* in the strip, behind its own separator.
    func testThePinIsTheRightmostControlBehindItsOwnSeparator() {
        XCTAssertEqual(ViewerToolDockView.layout.last, .pin,
                       "the pin is the last entry in the layout")
        let dock = self.dock()
        XCTAssertTrue(dock.arrangedViewsForTesting.last === dock.pinControl,
                      "and the last view in the stack")

        // The entry before it is a separator, so the pin reads as governing the dock rather than
        // the image.
        XCTAssertEqual(ViewerToolDockView.layout[ViewerToolDockView.layout.count - 2], .separator)
    }

    /// The readouts are in the middle of their groups, where the number they report belongs.
    func testTheReadoutsSitInsideTheirGroups() throws {
        let items = ViewerToolDockView.layout
        let zoomIndex = try XCTUnwrap(items.firstIndex(of: .zoomReadout))
        let zoomOut = try XCTUnwrap(items.firstIndex(of: .command(
            symbol: ViewerToolDockView.zoomOutSymbol, command: .zoomOut, tooltip: "缩小")))
        let zoomIn = try XCTUnwrap(items.firstIndex(of: .command(
            symbol: ViewerToolDockView.zoomInSymbol, command: .zoomIn, tooltip: "放大")))
        XCTAssertEqual(zoomIndex, zoomOut + 1, "zoom out, then the percentage")
        XCTAssertEqual(zoomIndex, zoomIn - 1, "then zoom in")

        let positionIndex = try XCTUnwrap(items.firstIndex(of: .positionReadout))
        let previous = try XCTUnwrap(items.firstIndex(of: .command(
            symbol: ViewerToolDockView.previousSymbol, command: .previousImage, tooltip: "上一张")))
        let next = try XCTUnwrap(items.firstIndex(of: .command(
            symbol: ViewerToolDockView.nextSymbol, command: .nextImage, tooltip: "下一张")))
        XCTAssertEqual(positionIndex, previous + 1, "previous, then the position")
        XCTAssertEqual(positionIndex, next - 1, "then next")
    }

    /// The group separators are the only separators, and the groups are separated once each.
    func testGroupsAreSeparatedExactlyOnce() {
        let separators = ViewerToolDockView.layout.filter { $0 == .separator }.count
        XCTAssertEqual(separators, 4, "four group boundaries, plus the pin's own")
    }

    /// The dock's command list is exactly the commands the layout declares — the pin and the
    /// playback button are not viewer commands.
    func testTheCommandListMatchesTheLayout() {
        let dock = self.dock()
        XCTAssertEqual(dock.commands, ViewerToolDockView.layout.compactMap {
            if case let .command(_, command, _) = $0 { return command }
            return nil
        })
        XCTAssertEqual(dock.commandButtons.count, 13)
        XCTAssertFalse(dock.commands.contains(.togglePlayback), "playback is not a ViewerCommand")
        XCTAssertEqual(dock.allButtons.count, dock.commandButtons.count + 2,
                       "plus the playback button and the pin")
        XCTAssertTrue(dock.allButtons.last === dock.pinControl, "and the pin is last")
    }

    /// Every command button carries its symbol and its tooltip, so no control is a blank square.
    func testEveryCommandButtonHasASymbolAndATooltip() {
        let dock = self.dock()
        for case let .command(symbol, _, tooltip) in ViewerToolDockView.layout {
            let button = dock.commandButtons.first { $0.symbolName == symbol }
            XCTAssertNotNil(button, "no button for \(symbol)")
            XCTAssertEqual(button?.toolTip, tooltip)
            XCTAssertNotNil(button?.symbolImage, "\(symbol) has no image")
        }
    }

    /// The readouts are labels, not controls: the dock reports the zoom and the position, it does
    /// not own them.
    func testTheReadoutsAreTextNotControls() {
        let dock = self.dock()
        XCTAssertTrue(dock.zoomReadoutView.isKind(of: NSTextField.self))
        XCTAssertTrue(dock.positionReadoutView.isKind(of: NSTextField.self))
        for button in dock.allButtons {
            XCTAssertFalse(button === dock.zoomReadoutView as NSView,
                           "a readout must not be a dock button")
            XCTAssertFalse(button === dock.positionReadoutView as NSView)
        }
        XCTAssertNil(dock.zoomReadoutView.target, "and must not carry an action")
        XCTAssertNil(dock.positionReadoutView.target)
        // Monospaced *digits* (not a fixed-pitch face): the number changes width the same way
        // every time it counts up, so the pill does not twitch.
        XCTAssertEqual(dock.zoomReadoutView.font,
                       NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium))
        XCTAssertEqual(dock.positionReadoutView.font, dock.zoomReadoutView.font)
        // And it has a floor width, so a two-digit percentage does not shrink the pill.
        XCTAssertGreaterThanOrEqual(dock.zoomReadoutView.frame.width, 40 - 0.5)
    }
}
