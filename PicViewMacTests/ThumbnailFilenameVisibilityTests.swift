import XCTest
import AppKit
@testable import PicViewMac

/// Drawer filenames are always visible. Hiding them was a preference, and a preference
/// that can hide the only label identifying a thumbnail is a way to lose it.
@MainActor
final class ThumbnailFilenameVisibilityTests: XCTestCase {

    override func setUp() async throws {
        try await super.setUp()
        TestAppKit.ensureApplication()
    }

    private func item(_ name: String = "picture.png") -> FolderItem {
        FolderItem(url: URL(fileURLWithPath: "/tmp/\(name)"))
    }

    private func cell(_ mode: ThumbnailFilenameMode,
                      current: Bool = false) -> ThumbnailCellView {
        let cell = ThumbnailCellView(frame: NSRect(x: 0, y: 0, width: 200,
                                                  height: ThumbnailCellView.rowHeight))
        cell.configure(item: item(), image: nil, isCurrent: current, filenameMode: mode)
        cell.layoutSubtreeIfNeeded()
        return cell
    }

    /// A mouse event good enough to call the tracking handlers with. AppKit refuses to
    /// synthesise `.mouseEntered`/`.mouseExited` through this API — they are produced by
    /// the tracking machinery — and the handlers ignore the event anyway.
    private func mouseEvent() throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(with: .mouseMoved, location: .zero, modifierFlags: [],
                                         timestamp: 0, windowNumber: 0, context: nil,
                                         eventNumber: 0, clickCount: 1, pressure: 0))
    }

    // MARK: - The cell

    func testAlwaysShowsTheNameWithoutAnyHover() throws {
        let cell = self.cell(.always)
        XCTAssertFalse(cell.nameLabelView.isHidden, "the name is visible with no pointer in sight")

        cell.mouseExited(with: try mouseEvent())
        XCTAssertFalse(cell.nameLabelView.isHidden, "and leaving does not hide it")
    }

    /// The mode still exists — this is the behaviour that was removed, kept as a cell
    /// capability so the change is a policy decision in one place rather than a deleted path.
    func testHoverModeStillHidesTheNameUntilThePointerArrives() throws {
        let cell = self.cell(.hover)
        XCTAssertTrue(cell.nameLabelView.isHidden)
        cell.mouseEntered(with: try mouseEvent())
        XCTAssertFalse(cell.nameLabelView.isHidden)
        cell.mouseExited(with: try mouseEvent())
        XCTAssertTrue(cell.nameLabelView.isHidden)
    }

    func testTheNameIsStillLaidOutInsideTheCard() {
        let cell = self.cell(.always, current: true)
        let card = cell.selectionBackgroundView.frame
        let label = cell.nameLabelView.frame
        XCTAssertGreaterThan(label.height, 0, "the label occupies its slot")
        XCTAssertGreaterThanOrEqual(label.minY, card.minY - 0.5)
        XCTAssertLessThanOrEqual(label.maxY, card.maxY + 0.5)
    }

    // MARK: - The drawer

    private func drawer() throws -> (controller: ViewerWindowController, drawer: ThumbnailDrawerView) {
        let controller = ViewerWindowController()
        TestAppKit.presentOffScreen(controller)
        let viewer = controller.viewerViewController
        _ = viewer.view
        viewer.applySettings()
        let drawer = try XCTUnwrap(viewer.chromeViewsForTesting["drawer"] as? ThumbnailDrawerView)
        return (controller, drawer)
    }

    func testTheDrawerAlwaysUsesAlwaysMode() throws {
        let (controller, drawer) = try drawer()
        defer { controller.close() }
        XCTAssertEqual(drawer.filenameMode, .always,
                       "the viewer decides the mode, not a stored preference")
    }

    /// Even a value left over in the preferences cannot bring the old behaviour back.
    func testAStoredPreferenceCannotHideTheNames() throws {
        let settings = AppSettings.shared
        let previous = settings.thumbnailFilenames
        settings.thumbnailFilenames = .never
        defer { settings.thumbnailFilenames = previous }

        let (controller, drawer) = try drawer()
        defer { controller.close() }
        XCTAssertEqual(drawer.filenameMode, .always,
                       "a stale “从不” in the preferences must not hide filenames")
    }
}
