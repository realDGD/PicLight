import XCTest
import CoreGraphics
@testable import PicViewMac

/// The uniform grid's stepped sizes.
///
/// The slider used to be continuous in both layouts, which in a uniform grid means most positions ask
/// for a size that cannot fill the row: the columns are computed from the size, so a size between two
/// "fits exactly" values leaves a margin at the right edge. The sizes that *do* fill the row are a
/// function of the window width alone — one per column count — and those are the levels the slider
/// steps through. The adaptive layout is unchanged: its items are each their own width, so there is no
/// column count to snap to.
final class GallerySizeLevelTests: XCTestCase {

    /// Each level is exactly the size that makes its own column count fill the row.
    func testEveryLevelFillsItsRowExactly() {
        for width in stride(from: 360, through: 2200, by: 37) {
            let levels = GalleryLayout.uniformSizeLevels(containerWidth: CGFloat(width))
            guard !levels.isEmpty else { continue }
            for level in levels {
                // The same tolerance the layout uses: a level is *exactly* `n` columns wide, and
                // floating point lands a hair below the integer.
                let columns = Int((CGFloat(width) - 2 * GalleryLayout.contentInset
                                   + GalleryLayout.itemSpacing + 0.01)
                                  / (level + GalleryLayout.itemSpacing))
                XCTAssertGreaterThanOrEqual(columns, 1)
                let rows = GalleryLayout.uniformRows(
                    aspects: Array(repeating: 1.5, count: columns * 2),
                    containerWidth: CGFloat(width), thumbnailSize: level)
                guard let row = rows.first else {
                    XCTFail("width \(width), level \(level): the layout produced no rows")
                    continue
                }
                XCTAssertEqual(row.cells.count, columns,
                               "width \(width), level \(level): the level's own column count is what "
                               + "the layout produces")
                guard let last = row.cells.last else { continue }
                XCTAssertEqual(last.frame.maxX + GalleryLayout.contentInset, CGFloat(width),
                               accuracy: 0.51,
                               "width \(width), level \(level): the row reaches the right edge")
            }
        }
    }

    /// The levels are ordered, inside the slider's range, and one per column count.
    func testLevelsAreOrderedInsideTheRangeAndDistinct() {
        let levels = GalleryLayout.uniformSizeLevels(containerWidth: 1200)
        XCTAssertGreaterThan(levels.count, 1)
        XCTAssertEqual(levels, levels.sorted(), "ascending, so a slider can index them")
        for level in levels {
            XCTAssertGreaterThanOrEqual(level, GalleryLayout.minimumThumbnailSize - 0.001)
            XCTAssertLessThanOrEqual(level, GalleryLayout.maximumThumbnailSize + 0.001)
        }
        XCTAssertEqual(Set(levels.map { Int($0.rounded()) }).count, levels.count,
                       "each column count gives its own size")
        // A wider window can hold more columns, so it offers more levels.
        XCTAssertGreaterThan(GalleryLayout.uniformSizeLevels(containerWidth: 1800).count,
                             GalleryLayout.uniformSizeLevels(containerWidth: 700).count)
    }

    /// A window too narrow for even one thumbnail has no levels, and the slider must not be stepped
    /// into a range it cannot represent.
    func testANarrowWindowHasNoLevels() {
        XCTAssertTrue(GalleryLayout.uniformSizeLevels(containerWidth: 0).isEmpty)
        XCTAssertTrue(GalleryLayout.uniformSizeLevels(containerWidth: 100).isEmpty)
    }

    /// Snapping picks the nearest level, which is what the slider and a saved size use.
    func testNearestLevelSnapsToTheClosestSize() {
        let levels = GalleryLayout.uniformSizeLevels(containerWidth: 1200)
        for level in levels {
            XCTAssertEqual(GalleryLayout.nearestSizeLevel(to: level, in: levels), level)
            XCTAssertEqual(GalleryLayout.nearestSizeLevel(to: level + 2, in: levels), level,
                           accuracy: 0.001, "just above a level still snaps back to it")
        }
        XCTAssertEqual(GalleryLayout.nearestSizeLevel(to: 160, in: []), 160,
                       "with no levels the size is passed through")
    }
}
