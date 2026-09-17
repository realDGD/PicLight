import XCTest
import AppKit
@testable import PicViewMac

/// The current-item frame in the thumbnail drawer.
@MainActor
final class ThumbnailSelectionBorderTests: XCTestCase {

    override func setUp() async throws {
        try await super.setUp()
        TestAppKit.ensureApplication()
    }
    func testSelectionBorderIsTheTopmostLayerAroundTheThumbnail() {
        let item = FolderItem(url: URL(fileURLWithPath: "/tmp/a.png"))
        let cell = ThumbnailCellView(frame: NSRect(x: 0, y: 0, width: 200, height: 168))
        cell.configure(item: item, image: Fixtures.thumbnail(), isCurrent: false,
                       filenameMode: .hover)
        cell.layoutSubtreeIfNeeded()

        let border = cell.selectionBorderView
        let image = cell.thumbnailImageView
        let imageIndex = cell.subviews.firstIndex(of: image) ?? -1
        let borderIndex = cell.subviews.firstIndex(of: border) ?? -1
        XCTAssertGreaterThanOrEqual(imageIndex, 0)
        XCTAssertGreaterThan(borderIndex, imageIndex,
                             "the frame must be added above the thumbnail, not below it")
        XCTAssertTrue(border.wantsLayer)
        XCTAssertEqual(border.layer?.borderWidth, 2)
        XCTAssertEqual(border.layer?.borderColor, NSColor.controlAccentColor.cgColor)

        // The frame surrounds the image area rather than the whole row.
        XCTAssertGreaterThan(border.frame.width, image.frame.width,
                             "the frame is slightly larger than the image it frames")
        XCTAssertLessThan(border.frame.width, cell.bounds.width,
                          "the frame does not span the entire row")
    }

    func testSelectionBorderTracksTheCurrentItemAndIgnoresClicks() {
        let item = FolderItem(url: URL(fileURLWithPath: "/tmp/a.png"))
        let cell = ThumbnailCellView(frame: NSRect(x: 0, y: 0, width: 200, height: 168))
        cell.configure(item: item, image: Fixtures.thumbnail(), isCurrent: false,
                       filenameMode: .hover)
        XCTAssertTrue(cell.selectionBorderView.isHidden, "not the current item: no frame")

        cell.setCurrent(true)
        XCTAssertFalse(cell.selectionBorderView.isHidden, "the current item is framed")

        cell.setCurrent(false)
        XCTAssertTrue(cell.selectionBorderView.isHidden)

        // A passive overlay must never swallow the click that selects the row.
        let border = cell.selectionBorderView
        border.setCurrentForTestingIfPossible()
        XCTAssertNil(border.hitTest(CGPoint(x: border.bounds.midX, y: border.bounds.midY)),
                     "the frame is decoration and must not intercept clicks")
    }
}

private extension NSView {
    /// Convenience so the hit-test assertion above also covers a visible border.
    func setCurrentForTestingIfPossible() {
        isHidden = false
    }
}
