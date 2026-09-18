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
        cell.configure(item: item, image: Fixtures.thumbnail(), isCurrent: false)
        cell.layoutSubtreeIfNeeded()

        let border = cell.selectionBorderView
        // The image now lives inside the square slot, so the ordering to check is the frame
        // against the slot that contains it.
        let slot = cell.thumbnailSlotView
        let slotIndex = cell.subviews.firstIndex(of: slot) ?? -1
        let borderIndex = cell.subviews.firstIndex(of: border) ?? -1
        XCTAssertGreaterThanOrEqual(slotIndex, 0)
        XCTAssertGreaterThan(borderIndex, slotIndex,
                             "the frame must be added above the thumbnail, not below it")
        XCTAssertTrue(border.wantsLayer)
        XCTAssertEqual(border.layer?.borderWidth, 2)
        XCTAssertEqual(border.layer?.borderColor, NSColor.controlAccentColor.cgColor)

        // The frame surrounds the fixed square rather than the whole row.
        XCTAssertEqual(border.frame.width,
                       ThumbnailCellView.thumbnailSlotSize + ThumbnailCellView.selectionBorderHalo,
                       accuracy: 0.5,
                       "the frame is the square plus its halo")
        XCTAssertLessThan(border.frame.width, cell.bounds.width,
                          "the frame does not span the entire row")
    }

    func testSelectionBorderTracksTheCurrentItemAndIgnoresClicks() {
        let item = FolderItem(url: URL(fileURLWithPath: "/tmp/a.png"))
        let cell = ThumbnailCellView(frame: NSRect(x: 0, y: 0, width: 200, height: 168))
        cell.configure(item: item, image: Fixtures.thumbnail(), isCurrent: false)
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


/// The navigator's viewport outline must actually be visible, not merely built.
@MainActor
final class NavigatorOverlayVisibilityTests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        TestAppKit.ensureApplication()
    }

    private func makeNavigator() -> NavigatorView {
        let navigator = NavigatorView()
        navigator.frame = NSRect(x: 0, y: 0, width: 168, height: 120)
        navigator.setPreviewImage(Fixtures.thumbnail())
        navigator.visibleNormalizedRect = CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
        navigator.layoutSubtreeIfNeeded()
        return navigator
    }

    /// The outline used to be a bare sublayer of the navigator's layer. The preview
    /// view's layer is created lazily, so it could be appended after the outline and
    /// cover it - which is exactly what made the frame disappear.
    func testViewportOutlineSitsAboveThePreviewInTheViewHierarchy() {
        let navigator = makeNavigator()
        let preview = navigator.previewSurface
        let overlay = navigator.viewportOverlaySurface
        let previewIndex = navigator.subviews.firstIndex(of: preview)
        let overlayIndex = navigator.subviews.firstIndex(of: overlay)
        XCTAssertNotNil(previewIndex)
        XCTAssertNotNil(overlayIndex)
        XCTAssertGreaterThan(overlayIndex ?? -1, previewIndex ?? .max,
                             "the outline view must come after the preview view")
        XCTAssertTrue(overlay.subviews.isEmpty)
        XCTAssertTrue(navigator.viewportOverlayLayer.superlayer === overlay.layer,
                      "the outline lives in its own overlay view's layer")
        XCTAssertFalse(overlay.hitTest(NSPoint(x: 10, y: 10)) != nil,
                       "the outline view is decoration and must not take clicks")
    }

    /// Renders the navigator and looks for the outline's accent pixels on the four
    /// edges of the expected rectangle, so "the frame is missing" cannot regress
    /// silently. Sampling must hit the *edges*: the interior is a 12 % fill, which is
    /// deliberately faint.
    func testViewportOutlineIsActuallyRendered() throws {
        let navigator = makeNavigator()
        let target = NavigatorView.imageRect(in: navigator.bounds.insetBy(dx: 4, dy: 4),
                                            imagePixels: CGSize(width: 64, height: 48))
        let expected = NavigatorView.viewportRect(in: target,
                                                  normalized: navigator.visibleNormalizedRect)

        let rep = try XCTUnwrap(navigator.bitmapImageRepForCachingDisplay(in: navigator.bounds))
        navigator.cacheDisplay(in: navigator.bounds, to: rep)
        let image = try XCTUnwrap(rep.cgImage)
        let data = try XCTUnwrap(image.dataProvider?.data as Data?)
        let bytesPerRow = image.bytesPerRow
        let bytesPerPixel = image.bitsPerPixel / 8
        let scale = CGFloat(image.width) / max(navigator.bounds.width, 1)
        // Cached display is a top-down RGBA raster.
        func isAccent(atX x: Int, y: Int) -> Bool {
            let row = image.height - 1 - y
            guard x >= 0, x < image.width, row >= 0, row < image.height else { return false }
            let offset = row * bytesPerRow + x * bytesPerPixel
            guard offset + 3 < data.count else { return false }
            let r = Int(data[offset]), g = Int(data[offset + 1])
            let b = Int(data[offset + 2]), a = Int(data[offset + 3])
            guard a > 120 else { return false }
            // The accent-coloured stroke is clearly bluer than the red-ish fixture.
            return b > r + 40 && b > g + 30
        }
        func countAlongHorizontalEdge(viewY: CGFloat) -> Int {
            let y = Int((viewY * scale).rounded())
            let xs = stride(from: Int(expected.minX * scale), to: Int(expected.maxX * scale), by: 2)
            return xs.reduce(0) { total, x in
                (0...2).contains(where: { isAccent(atX: x, y: y + $0) || isAccent(atX: x, y: y - $0) })
                    ? total + 1 : total
            }
        }
        func countAlongVerticalEdge(viewX: CGFloat) -> Int {
            let x = Int((viewX * scale).rounded())
            let ys = stride(from: Int(expected.minY * scale), to: Int(expected.maxY * scale), by: 2)
            return ys.reduce(0) { total, y in
                (0...2).contains(where: { isAccent(atX: x + $0, y: y) || isAccent(atX: x - $0, y: y) })
                    ? total + 1 : total
            }
        }

        XCTAssertGreaterThan(countAlongHorizontalEdge(viewY: expected.maxY), 5,
                             "the top edge of the viewport frame must be drawn")
        XCTAssertGreaterThan(countAlongHorizontalEdge(viewY: expected.minY), 5,
                             "the bottom edge of the viewport frame must be drawn")
        XCTAssertGreaterThan(countAlongVerticalEdge(viewX: expected.minX), 5,
                             "the left edge of the viewport frame must be drawn")
        XCTAssertGreaterThan(countAlongVerticalEdge(viewX: expected.maxX), 5,
                             "the right edge of the viewport frame must be drawn")
    }

    func testOutlineFollowsViewportWithoutRebuildingThePreview() {
        let navigator = makeNavigator()
        let generations = navigator.previewGenerationCount
        navigator.visibleNormalizedRect = CGRect(x: 0.1, y: 0.1, width: 0.3, height: 0.2)
        navigator.layoutSubtreeIfNeeded()
        XCTAssertNotNil(navigator.viewportOverlayLayer.path, "the outline follows the viewport")
        XCTAssertEqual(navigator.previewGenerationCount, generations,
                       "moving the viewport must not rebuild the preview")
    }
}
