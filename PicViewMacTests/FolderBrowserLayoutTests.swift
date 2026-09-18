import XCTest
import AppKit
@testable import PicViewMac

/// The gallery's two layouts, as geometry.
///
/// Everything here is a pure function of the item aspects, the container width and the thumbnail
/// size, which is what makes the two layouts' contracts checkable without rendering anything.
@MainActor
final class FolderBrowserLayoutTests: XCTestCase {

    override func setUp() async throws {
        try await super.setUp()
        TestAppKit.ensureApplication()
    }

    private let width: CGFloat = 800

    // MARK: - The slider's range

    /// The spec's range and default, and the clamp that enforces them.
    func testTheThumbnailSizeRangeIsTheSpecifiedOne() {
        XCTAssertEqual(GalleryLayout.minimumThumbnailSize, 80)
        XCTAssertEqual(GalleryLayout.maximumThumbnailSize, 320)
        XCTAssertEqual(GalleryLayout.defaultThumbnailSize, 160)
        XCTAssertEqual(GalleryLayout.clampThumbnailSize(10), 80)
        XCTAssertEqual(GalleryLayout.clampThumbnailSize(1000), 320)
        XCTAssertEqual(GalleryLayout.clampThumbnailSize(160), 160)
    }

    // MARK: - Layout A: the uniform grid

    /// Every slot is identical, whatever the source aspects are.
    func testUniformGridUsesIdenticalSlotsForEveryShape() {
        let aspects: [CGFloat] = [1, 1.5, 16.0 / 9, 3, 10, 2.0 / 3, 0.25, 0.1]
        let rows = GalleryLayout.uniformRows(aspects: aspects, containerWidth: width,
                                             thumbnailSize: 160)
        let cells = rows.flatMap(\.cells)
        XCTAssertEqual(cells.count, aspects.count, "every item is placed")

        let size = cells[0].frame.size
        for cell in cells {
            XCTAssertEqual(cell.frame.size, size, "a uniform grid has one slot size")
        }
        XCTAssertEqual(size.height, 160 + GalleryLayout.filenameSlotHeight, "the slot plus its label")
    }

    /// The image is aspect-fitted inside its slot, centred, never cropped and never stretched.
    func testUniformGridAspectFitsInsideTheIdenticalSlot() {
        let aspects: [CGFloat] = [1, 1.5, 10, 0.1]
        let rows = GalleryLayout.uniformRows(aspects: aspects, containerWidth: width,
                                             thumbnailSize: 160)
        let cells = rows.flatMap(\.cells)
        for cell in cells {
            let slot = CGRect(x: cell.frame.minX, y: cell.frame.minY,
                              width: cell.frame.width, height: cell.frame.height
                                - GalleryLayout.filenameSlotHeight)
            XCTAssertLessThanOrEqual(cell.imageFrame.width, slot.width + 0.5)
            XCTAssertLessThanOrEqual(cell.imageFrame.height, slot.height + 0.5)
            XCTAssertEqual(cell.imageFrame.midX, slot.midX, accuracy: 0.5, "centred")
            XCTAssertEqual(cell.imageFrame.midY, slot.midY, accuracy: 0.5, "centred")
        }
    }

    /// Layout A's whole point: a 10:1 and a 1:10 image get the *same* cell, so the grid stays a grid.
    func testUniformGridGivesExtremeShapesTheSameCell() {
        let rows = GalleryLayout.uniformRows(aspects: [10, 0.1], containerWidth: width,
                                             thumbnailSize: 160)
        let wide = rows.flatMap(\.cells).first { $0.index == 0 }!
        let tall = rows.flatMap(\.cells).first { $0.index == 1 }!
        XCTAssertEqual(wide.frame.size, tall.frame.size)
        XCTAssertNotEqual(wide.imageFrame.size, tall.imageFrame.size,
                          "the *image* inside the slot is where the aspect shows")
        XCTAssertEqual(wide.imageFrame.width, wide.frame.width, accuracy: 0.5,
                       "a 10:1 image is width-limited inside the slot")
        XCTAssertEqual(tall.imageFrame.height,
                       160, accuracy: 0.5, "a 1:10 image is height-limited")
    }

    /// More columns fit as the thumbnails shrink, which is what makes the slider feel live.
    func testUniformGridColumnsFollowTheThumbnailSize() {
        let aspects = Array(repeating: CGFloat(1.5), count: 24)
        let small = GalleryLayout.uniformRows(aspects: aspects, containerWidth: width,
                                             thumbnailSize: 80)
        let large = GalleryLayout.uniformRows(aspects: aspects, containerWidth: width,
                                             thumbnailSize: 320)
        XCTAssertGreaterThan(small.flatMap(\.cells).count, 0)
        XCTAssertLessThan(small.count, large.count,
                          "smaller thumbnails need fewer rows for the same items")
        let smallPerRow = small.first?.cells.count ?? 0
        let largePerRow = large.first?.cells.count ?? 0
        XCTAssertGreaterThan(smallPerRow, largePerRow)
    }

    // MARK: - Layout B: the adaptive grid

    /// Rows are aligned and full-width, and an item is as wide as its aspect asks for.
    func testAdaptiveGridGivesWideItemsWideCellsAndTallItemsNarrowOnes() {
        let aspects: [CGFloat] = [3, 1, 0.5, 3, 1]
        let rows = GalleryLayout.adaptiveRows(aspects: aspects, containerWidth: width,
                                              thumbnailSize: 160)
        let cells = rows.flatMap(\.cells)
        XCTAssertEqual(cells.count, aspects.count)

        let wide = cells.first { $0.index == 0 }!
        let tall = cells.first { $0.index == 2 }!
        XCTAssertGreaterThan(wide.frame.width, tall.frame.width,
                             "a 3:1 item is wider than a 1:2 item at the same row height")
        // Within a row every cell shares the row's height and does not interlock: this is what makes
        // it a justified grid rather than masonry.
        for row in rows {
            let heights = Set(row.cells.map { $0.frame.height })
            XCTAssertEqual(heights.count, 1, "one row, one height")
            for cell in row.cells {
                XCTAssertEqual(cell.frame.minY, row.frame.minY, accuracy: 0.5)
            }
        }
    }

    /// Every row stays inside the container, and consecutive rows do not overlap.
    func testAdaptiveGridRowsFitTheWidthAndDoNotOverlap() {
        let aspects: [CGFloat] = [1, 3, 0.5, 1.5, 0.8, 2, 0.3, 1.2, 4, 0.6]
        let rows = GalleryLayout.adaptiveRows(aspects: aspects, containerWidth: width,
                                              thumbnailSize: 160)
        for row in rows {
            let last = row.cells.last
            XCTAssertLessThanOrEqual((last?.frame.maxX ?? 0) + GalleryLayout.contentInset,
                                     width + 0.5, "a row must not overflow the container")
            XCTAssertGreaterThanOrEqual(row.cells.first?.frame.minX ?? 0,
                                        GalleryLayout.contentInset - 0.5)
        }
        for (previous, next) in zip(rows, rows.dropFirst()) {
            XCTAssertLessThanOrEqual(previous.frame.maxY, next.frame.minY + 0.5,
                                     "rows do not overlap")
        }
    }

    /// One extreme item cannot take a whole row on its own or collapse to a sliver.
    func testAdaptiveGridClampsExtremeItems() {
        let rows = GalleryLayout.adaptiveRows(aspects: [1000, 0.001], containerWidth: width,
                                             thumbnailSize: 160)
        let cells = rows.flatMap(\.cells)
        for cell in cells {
            XCTAssertLessThanOrEqual(cell.frame.width, GalleryLayout.adaptiveMaximumItemWidth + 0.5)
            XCTAssertGreaterThanOrEqual(cell.frame.width,
                                        GalleryLayout.adaptiveMinimumItemWidth - 0.5)
        }
    }

    /// The adaptive layout is deterministic: the same inputs give the same geometry, every time.
    /// The spec asks for deterministic rather than merely plausible.
    func testBothLayoutsAreDeterministic() {
        let aspects: [CGFloat] = [1, 3, 0.5, 1.5, 0.8, 2]
        for kind in GalleryLayoutKind.allCases {
            let first = GalleryLayout.rows(for: kind, aspects: aspects, containerWidth: width,
                                           thumbnailSize: 160)
            let second = GalleryLayout.rows(for: kind, aspects: aspects, containerWidth: width,
                                            thumbnailSize: 160)
            XCTAssertEqual(first, second, "\(kind) must be deterministic")
        }
    }

    /// It is not masonry: in masonry, items would stack in columns and rows would interlock
    /// vertically. Here every row begins below the previous one at the same left edge.
    func testTheAdaptiveLayoutIsNotMasonry() {
        let aspects: [CGFloat] = [0.4, 3, 0.4, 3, 0.4, 3]
        let rows = GalleryLayout.adaptiveRows(aspects: aspects, containerWidth: width,
                                             thumbnailSize: 160)
        // Every row's cells share the row's top edge, so items do not interlock.
        for row in rows {
            for cell in row.cells {
                XCTAssertEqual(cell.frame.minY, row.frame.minY, accuracy: 0.5)
            }
        }
        // And each row's cells are laid out end to end in one line.
        for row in rows {
            let sorted = row.cells.sorted { $0.frame.minX < $1.frame.minX }
            for (left, right) in zip(sorted, sorted.dropFirst()) {
                XCTAssertLessThanOrEqual(left.frame.maxX, right.frame.minX + 0.5)
            }
        }
    }

    // MARK: - The filename slot

    /// Every cell reserves room for a name in both layouts: a grid of unlabelled pictures does not
    /// let anyone identify a file.
    func testEveryCellReservesAFilenameSlot() {
        for kind in GalleryLayoutKind.allCases {
            let rows = GalleryLayout.layoutRowsForTests(kind, aspects: [1, 1.5, 3],
                                                        containerWidth: width, thumbnailSize: 120)
            for cell in rows.flatMap(\.cells) {
                let slot = cell.frame.height - cell.imageFrame.height
                XCTAssertGreaterThanOrEqual(slot, GalleryLayout.filenameSlotHeight - 0.5,
                                            "\(kind): the label needs its room")
            }
        }
    }

    // MARK: - Empty and degenerate inputs

    func testAnEmptyFolderProducesNoRows() {
        for kind in GalleryLayoutKind.allCases {
            XCTAssertTrue(GalleryLayout.rows(for: kind, aspects: [], containerWidth: width,
                                             thumbnailSize: 160).isEmpty)
        }
    }

    func testANarrowContainerProducesNoOverflow() {
        for kind in GalleryLayoutKind.allCases {
            let rows = GalleryLayout.rows(for: kind, aspects: [1, 1.5, 0.5],
                                          containerWidth: 100, thumbnailSize: 160)
            for cell in rows.flatMap(\.cells) {
                XCTAssertLessThanOrEqual(cell.frame.maxX, 100 + 0.5,
                                         "\(kind): nothing may be laid out off-screen")
            }
        }
    }
}

extension GalleryLayout {
    /// `rows(for:)` under a name the tests read more easily.
    static func layoutRowsForTests(_ kind: GalleryLayoutKind, aspects: [CGFloat],
                                   containerWidth: CGFloat,
                                   thumbnailSize: CGFloat) -> [GalleryRow] {
        rows(for: kind, aspects: aspects, containerWidth: containerWidth,
             thumbnailSize: thumbnailSize)
    }
}
