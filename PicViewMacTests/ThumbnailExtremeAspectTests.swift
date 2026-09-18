import XCTest
import AppKit
@testable import PicViewMac

/// Extreme aspect ratios in the fixed square slot.
///
/// The reported symptom was a very wide image sitting pinned to the top of the drawer row
/// instead of being centred. It happened because the old cell let the image's aspect ratio
/// decide the image view's width, so a 10:1 strip hit the cell-width cap, became a short box,
/// and — being top-anchored — stayed there. The square slot removes the whole class of problem,
/// and the two ratios most likely to expose it are 10:1 and 1:10.
@MainActor
final class ThumbnailExtremeAspectTests: XCTestCase {

    override func setUp() async throws {
        try await super.setUp()
        TestAppKit.ensureApplication()
    }

    /// The ratios the spec names, plus the ones either side of them.
    private static let shapes: [(name: String, width: Int, height: Int, aspect: CGFloat)] = [
        ("1:1", 200, 200, 1),
        ("3:2", 300, 200, 1.5),
        ("16:9", 1600, 900, 16.0 / 9.0),
        ("3:1", 300, 100, 3),
        ("5:1", 500, 100, 5),
        ("10:1", 1000, 100, 10),
        ("2:3", 200, 300, 2.0 / 3.0),
        ("1:4", 100, 400, 0.25),
        ("1:10", 100, 1000, 0.1),
    ]

    private func cell() -> ThumbnailCellView {
        let cell = ThumbnailCellView(frame: NSRect(x: 0, y: 0, width: 200,
                                                  height: ThumbnailCellView.rowHeight))
        cell.translatesAutoresizingMaskIntoConstraints = false
        cell.widthAnchor.constraint(equalToConstant: 200).isActive = true
        cell.heightAnchor.constraint(equalToConstant: ThumbnailCellView.rowHeight).isActive = true
        return cell
    }

    private func image(width: Int, height: Int) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                bytesPerRow: width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.8, green: 0.2, blue: 0.2, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    private func configured(_ shape: (name: String, width: Int, height: Int, aspect: CGFloat))
        -> ThumbnailCellView {
        let cell = self.cell()
        cell.configure(item: FolderItem(url: URL(fileURLWithPath: "/tmp/\(shape.name).png")),
                       image: nil, isCurrent: false)
        cell.layoutSubtreeIfNeeded()
        cell.setThumbnail(image(width: shape.width, height: shape.height))
        cell.layoutSubtreeIfNeeded()
        return cell
    }

    // MARK: - Centring

    /// The headline requirement: every shape is centred in the square, on both axes.
    func testEveryShapeIsCentredInTheSquare() {
        for shape in Self.shapes {
            let cell = configured(shape)
            let slot = cell.thumbnailSlotView.bounds
            let box = cell.thumbnailImageView.frame
            XCTAssertEqual(box.midX, slot.midX, accuracy: 0.5,
                           "\(shape.name) is not centred horizontally")
            XCTAssertEqual(box.midY, slot.midY, accuracy: 0.5,
                           "\(shape.name) is not centred vertically")
        }
    }

    /// 10:1 specifically, and in the strongest form: the gap above the strip equals the gap
    /// below it. The bug being fixed put the whole gap below.
    func testATenToOneStripIsCentredVerticallyNotPinnedToTheTop() throws {
        let shape = try XCTUnwrap(Self.shapes.first { $0.name == "10:1" })
        let cell = configured(shape)
        let slot = cell.thumbnailSlotView.bounds
        let box = cell.thumbnailImageView.frame

        let above = slot.maxY - box.maxY
        let below = box.minY - slot.minY
        XCTAssertEqual(above, below, accuracy: 0.5,
                       "the strip is off-centre: \(above) pt above, \(below) pt below")
        XCTAssertGreaterThan(above, 1,
                             "a 10:1 strip cannot be flush with the top of the square")
        XCTAssertEqual(box.width, ThumbnailCellView.thumbnailSlotSize, accuracy: 0.5,
                       "a 10:1 image is width-limited and fills the square's width")
        XCTAssertEqual(box.width / box.height, 10, accuracy: 1e-9,
                       "and keeps its aspect exactly")
    }

    /// The mirror case: 1:10 must be centred horizontally rather than pinned to one side.
    func testAOneToTenStripIsCentredHorizontally() throws {
        let shape = try XCTUnwrap(Self.shapes.first { $0.name == "1:10" })
        let cell = configured(shape)
        let slot = cell.thumbnailSlotView.bounds
        let box = cell.thumbnailImageView.frame

        let left = box.minX - slot.minX
        let right = slot.maxX - box.maxX
        XCTAssertEqual(left, right, accuracy: 0.5,
                       "the strip is off-centre: \(left) pt left, \(right) pt right")
        XCTAssertGreaterThan(left, 1)
        XCTAssertEqual(box.height, ThumbnailCellView.thumbnailSlotSize, accuracy: 0.5,
                       "a 1:10 image is height-limited and fills the square's height")
        XCTAssertEqual(box.width / box.height, 0.1, accuracy: 1e-9)
    }

    // MARK: - Fit, not fill

    /// Aspect preserved and inside the square for all of them: no stretch, no crop.
    func testEveryShapeKeepsItsAspectInsideTheSquare() {
        for shape in Self.shapes {
            let cell = configured(shape)
            let box = cell.thumbnailImageView.frame
            let slot = cell.thumbnailSlotView.bounds
            XCTAssertEqual(box.width / box.height, shape.aspect, accuracy: 1e-9,
                           "\(shape.name) was stretched")
            XCTAssertLessThanOrEqual(box.width, slot.width + 0.5, "\(shape.name) is cropped")
            XCTAssertLessThanOrEqual(box.height, slot.height + 0.5, "\(shape.name) is cropped")
            // At least one axis is filled, which is what "fitted" means as opposed to "shrunk".
            let fillsWidth = abs(box.width - slot.width) < 0.5
            let fillsHeight = abs(box.height - slot.height) < 0.5
            XCTAssertTrue(fillsWidth || fillsHeight,
                          "\(shape.name) is smaller than it needs to be: \(box) in \(slot)")
            if shape.aspect > 1 {
                XCTAssertTrue(fillsWidth, "\(shape.name) is width-limited")
            } else if shape.aspect < 1 {
                XCTAssertTrue(fillsHeight, "\(shape.name) is height-limited")
            }
        }
    }

    /// Nothing escapes the cell: a 10:1 strip's box, card and frame all stay inside the row.
    func testExtremeShapesStayInsideTheRow() {
        for shape in Self.shapes {
            let cell = configured(shape)
            cell.setCurrent(true)
            cell.layoutSubtreeIfNeeded()
            let bounds = cell.bounds
            for (label, frame) in [("box", cell.thumbnailImageView.frame),
                                   ("card", cell.selectionBackgroundView.frame),
                                   ("frame", cell.selectionBorderView.frame)] {
                XCTAssertGreaterThanOrEqual(frame.minX, bounds.minX - 0.5, "\(shape.name) \(label)")
                XCTAssertLessThanOrEqual(frame.maxX, bounds.maxX + 0.5, "\(shape.name) \(label)")
                XCTAssertGreaterThanOrEqual(frame.minY, bounds.minY - 0.5, "\(shape.name) \(label)")
                XCTAssertLessThanOrEqual(frame.maxY, bounds.maxY + 0.5, "\(shape.name) \(label)")
            }
        }
    }

    /// Cell reuse walks a wide, a tall and an absent thumbnail through one cell. Each must land
    /// in the same square, with no stale aspect left behind.
    func testReuseAcrossExtremeAspectsLeavesNoStaleGeometry() {
        let cell = self.cell()
        cell.configure(item: FolderItem(url: URL(fileURLWithPath: "/tmp/a.png")), image: nil,
                       isCurrent: false)
        cell.layoutSubtreeIfNeeded()
        let square = cell.thumbnailSlotView.frame.size

        for shape in [Self.shapes[5], Self.shapes[8], Self.shapes[2], Self.shapes[0]] {
            cell.setThumbnail(image(width: shape.width, height: shape.height))
            cell.layoutSubtreeIfNeeded()
            XCTAssertEqual(cell.thumbnailSlotView.frame.size, square,
                           "\(shape.name): the slot changed size")
            let box = cell.thumbnailImageView.frame
            let slot = cell.thumbnailSlotView.bounds
            XCTAssertEqual(box.midX, slot.midX, accuracy: 0.5, shape.name)
            XCTAssertEqual(box.midY, slot.midY, accuracy: 0.5, shape.name)
            XCTAssertEqual(box.width / box.height, shape.aspect, accuracy: 1e-9, shape.name)
        }
    }

    /// A one-pixel-high source is degenerate but must not produce a zero or negative box.
    func testADegenerateShapeStillProducesAPositiveBox() {
        let cell = self.cell()
        cell.configure(item: FolderItem(url: URL(fileURLWithPath: "/tmp/x.png")), image: nil,
                       isCurrent: false)
        cell.layoutSubtreeIfNeeded()
        cell.setThumbnail(image(width: 4000, height: 4))
        cell.layoutSubtreeIfNeeded()
        let box = cell.thumbnailImageView.frame
        XCTAssertGreaterThan(box.width, 0)
        XCTAssertGreaterThan(box.height, 0)
        XCTAssertEqual(box.width, ThumbnailCellView.thumbnailSlotSize, accuracy: 0.5)
    }
}
