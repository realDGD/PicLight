import XCTest
import AppKit
@testable import PicViewMac

/// Drawer filenames are always visible.
///
/// Hiding them was a preference (`never` / `hover` / `always`), and a preference that can hide
/// the only label identifying a thumbnail is a way to lose it. The setting is gone from
/// `AppSettings` outright, so this file checks the two things that matter: the cell always shows
/// the name, and a value left in the defaults by an older build cannot bring the old behaviour
/// back.
@MainActor
final class ThumbnailFilenameVisibilityTests: XCTestCase {

    override func setUp() async throws {
        try await super.setUp()
        TestAppKit.ensureApplication()
    }

    /// The key the old build wrote. Deliberately a literal: the production code must not have a
    /// constant for it, because it must not read it at all.
    private let legacyKey = "thumbnailFilenames"

    private func item(_ name: String = "picture.png") -> FolderItem {
        FolderItem(url: URL(fileURLWithPath: "/tmp/\(name)"))
    }

    private func cell() -> ThumbnailCellView {
        let cell = ThumbnailCellView(frame: NSRect(x: 0, y: 0, width: 200,
                                                  height: ThumbnailCellView.rowHeight))
        cell.configure(item: item(), image: nil, isCurrent: false)
        cell.layoutSubtreeIfNeeded()
        return cell
    }

    // MARK: - The cell

    func testTheNameIsVisibleWithoutAnyHover() {
        let cell = self.cell()
        XCTAssertFalse(cell.nameLabelView.isHidden, "the name is visible with no pointer in sight")
    }

    func testTheNameStaysVisibleForTheCurrentItemAndAcrossReuse() {
        let cell = self.cell()
        cell.setCurrent(true)
        XCTAssertFalse(cell.nameLabelView.isHidden)
        cell.setCurrent(false)
        XCTAssertFalse(cell.nameLabelView.isHidden)

        cell.configure(item: item("other.png"), image: nil, isCurrent: true)
        XCTAssertFalse(cell.nameLabelView.isHidden)
        cell.setThumbnail(Fixtures.thumbnail())
        XCTAssertFalse(cell.nameLabelView.isHidden)
    }

    func testTheNameIsLaidOutInsideTheCard() {
        let cell = self.cell()
        cell.setCurrent(true)
        cell.layoutSubtreeIfNeeded()
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

    /// A cell built by the drawer — through its real data source — shows the name.
    func testTheDrawersCellsShowTheName() throws {
        let (controller, drawer) = try drawer()
        defer { controller.close() }
        drawer.rebuild(items: [item("alpha.png"), item("beta.png")], currentIndex: 0)
        let cell = try XCTUnwrap(drawer.cellForTesting(row: 0))
        XCTAssertFalse(cell.nameLabelView.isHidden, "a drawer row always carries its filename")
        XCTAssertEqual((cell.nameLabelView as? NSTextField)?.stringValue, "alpha.png")
    }

    /// A stale "never" or "hover" in the user defaults changes nothing.
    func testAStalePreferenceCannotHideTheNames() throws {
        let defaults = UserDefaults.standard
        let previous = defaults.string(forKey: legacyKey)
        addTeardownBlock {
            if let previous { defaults.set(previous, forKey: self.legacyKey) }
            else { defaults.removeObject(forKey: self.legacyKey) }
        }

        for stale in ["never", "hover"] {
            defaults.set(stale, forKey: legacyKey)
            let (controller, drawer) = try drawer()
            defer { controller.close() }
            drawer.rebuild(items: [item("gamma.png")], currentIndex: nil)
            let cell = try XCTUnwrap(drawer.cellForTesting(row: 0))
            XCTAssertFalse(cell.nameLabelView.isHidden,
                           "a stale “\(stale)” in the preferences must not hide filenames")
        }
    }
}
