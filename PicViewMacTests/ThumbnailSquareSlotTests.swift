import XCTest
import AppKit
@testable import PicViewMac

/// The drawer thumbnail slot is a fixed square, and the filename is always visible under it.
///
/// These are the two properties the redesign turns on. The previous cell derived the image
/// view's width from the source aspect ratio and the row's content height followed it, so the
/// slot was whatever the picture happened to make it and the filename could be hidden by a
/// preference.
@MainActor
final class ThumbnailSquareSlotTests: XCTestCase {

    override func setUp() async throws {
        try await super.setUp()
        TestAppKit.ensureApplication()
    }

    // MARK: - Fixtures

    private func cell(width: CGFloat = 200) -> ThumbnailCellView {
        let cell = ThumbnailCellView(frame: NSRect(x: 0, y: 0, width: width,
                                                  height: ThumbnailCellView.rowHeight))
        cell.translatesAutoresizingMaskIntoConstraints = false
        cell.widthAnchor.constraint(equalToConstant: width).isActive = true
        cell.heightAnchor.constraint(equalToConstant: ThumbnailCellView.rowHeight).isActive = true
        return cell
    }

    private func image(width: Int, height: Int) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                bytesPerRow: width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.3, green: 0.5, blue: 0.7, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    private func item(_ name: String = "a.png") -> FolderItem {
        FolderItem(url: URL(fileURLWithPath: "/tmp/" + name))
    }

    private func configuredCell() -> ThumbnailCellView {
        let cell = cell()
        cell.configure(item: item(), image: nil, isCurrent: false)
        cell.layoutSubtreeIfNeeded()
        return cell
    }

    // MARK: - The slot itself

    /// The documented numbers, asserted rather than described: the slot, the filename slot, the
    /// row, and the card that wraps them.
    func testTheSlotAndRowMatchTheSpecifiedGeometry() {
        XCTAssertEqual(ThumbnailCellView.thumbnailSlotSize, 132)
        XCTAssertEqual(ThumbnailCellView.filenameSlotHeight, 18)
        XCTAssertEqual(ThumbnailCellView.rowHeight, 168)
        XCTAssertEqual(ThumbnailCellView.cardHeight,
                       132 + 2 * ThumbnailCellView.cardPadding + 18,
                       "the card is the square plus its padding and the filename slot")
        XCTAssertEqual(ThumbnailCellView.rowHeight - ThumbnailCellView.cardHeight, 2,
                       "one point of slack above and below, so the card does not touch the row edges")
    }

    /// The square is fixed no matter what the image is — including before one arrives.
    func testTheSlotIsASquareOfTheDocumentedSizeBeforeAndAfterAThumbnail() {
        let subject = configuredCell()
        let slot = subject.thumbnailSlotView.frame
        XCTAssertEqual(slot.width, ThumbnailCellView.thumbnailSlotSize, accuracy: 0.5)
        XCTAssertEqual(slot.height, ThumbnailCellView.thumbnailSlotSize, accuracy: 0.5)

        subject.setThumbnail(image(width: 300, height: 200))
        subject.layoutSubtreeIfNeeded()
        XCTAssertEqual(subject.thumbnailSlotView.frame.size,
                       NSSize(width: ThumbnailCellView.thumbnailSlotSize,
                              height: ThumbnailCellView.thumbnailSlotSize),
                       "the slot is the cell's geometry, not the image's")
    }

    /// The thumbnail never draws outside the square, for any shape.
    func testEveryThumbnailFitsInsideTheSquare() {
        for (width, height) in [(300, 200), (200, 300), (500, 100), (100, 500), (200, 200)] {
            let subject = configuredCell()
            subject.setThumbnail(image(width: width, height: height))
            subject.layoutSubtreeIfNeeded()
            let box = subject.thumbnailImageView.frame
            let slot = subject.thumbnailSlotView.bounds
            XCTAssertLessThanOrEqual(box.width, slot.width + 0.5, "\(width)x\(height) is cropped")
            XCTAssertLessThanOrEqual(box.height, slot.height + 0.5, "\(width)x\(height) is cropped")
            XCTAssertGreaterThan(box.width, 0, "\(width)x\(height)")
            XCTAssertGreaterThan(box.height, 0, "\(width)x\(height)")
        }
    }

    // MARK: - The card

    /// The card's height is a constant. This is the property that used to fail: it was computed
    /// from the image box, so a 4:1 row and a 1:4 row had differently sized selection cards.
    func testTheCardHeightDoesNotDependOnTheSourceAspect() {
        let shapes = [(300, 200), (200, 300), (500, 100), (100, 500), (200, 200)]
        var heights: [CGFloat] = []
        for (width, height) in shapes {
            let subject = configuredCell()
            subject.setThumbnail(image(width: width, height: height))
            subject.layoutSubtreeIfNeeded()
            heights.append(subject.selectionBackgroundView.frame.height)
        }
        for value in heights {
            XCTAssertEqual(value, ThumbnailCellView.cardHeight, accuracy: 0.5,
                           "the card is a fixed height, got \(heights)")
        }
    }

    func testTheCardWrapsTheSquareAndTheFilenameSlot() {
        let subject = configuredCell()
        subject.setThumbnail(image(width: 400, height: 100))
        subject.layoutSubtreeIfNeeded()

        let card = subject.selectionBackgroundView.frame
        let slot = subject.thumbnailSlotView.frame
        let label = subject.nameLabelView.frame
        // Vertically the card is exactly padding + square + filename slot + padding. These views
        // are not flipped, so "top" is the maxY edge: the square hangs from the card's top and
        // the filename slot from the square's bottom.
        XCTAssertEqual(card.maxY - slot.maxY, ThumbnailCellView.cardPadding, accuracy: 0.5,
                       "the square is padded inside the card's top")
        XCTAssertEqual(label.minY - card.minY, ThumbnailCellView.cardPadding, accuracy: 0.5,
                       "and the filename slot is padded above the card's bottom")
        XCTAssertEqual(label.maxY, slot.minY, accuracy: 0.5,
                       "the filename slot starts where the square ends")
        XCTAssertEqual(label.height, ThumbnailCellView.filenameSlotHeight, accuracy: 0.5)
        // Horizontally the square is centred with at least the padding either side; the extra
        // width is the room a long filename needs.
        XCTAssertGreaterThanOrEqual(slot.minX - card.minX, ThumbnailCellView.cardPadding - 0.5)
        XCTAssertEqual(slot.minX - card.minX, card.maxX - slot.maxX, accuracy: 0.5,
                       "the square is centred in the card")
        XCTAssertGreaterThanOrEqual(label.minX, card.minX - 0.5)
        XCTAssertLessThanOrEqual(label.maxX, card.maxX + 0.5)
    }

    /// The card never spans the full row width, and never exceeds the drawer.
    func testTheCardStaysInsideTheCellAndLeavesAGutter() {
        for width in [180, 200, 220] as [CGFloat] {
            let subject = cell(width: width)
            subject.configure(item: item("a-very-long-file-name-indeed.png"), image: nil,
                              isCurrent: true)
            subject.layoutSubtreeIfNeeded()
            let card = subject.selectionBackgroundView.frame
            XCTAssertGreaterThanOrEqual(card.width, ThumbnailCellView.cardMinimumWidth - 0.5)
            XCTAssertLessThanOrEqual(card.width, ThumbnailCellView.cardMaximumWidth + 0.5)
            XCTAssertLessThan(card.width, width,
                              "the card keeps a gutter inside the drawer (width \(width))")
            XCTAssertGreaterThan(card.width, 0)
        }
    }

    /// The card widens with the drawer up to its cap, so a longer name has room where there is
    /// room for one.
    func testTheCardGrowsWithTheDrawerUpToItsCap() {
        let narrow = cell(width: 180)
        narrow.configure(item: item(), image: nil, isCurrent: false)
        narrow.layoutSubtreeIfNeeded()
        let wide = cell(width: 220)
        wide.configure(item: item(), image: nil, isCurrent: false)
        wide.layoutSubtreeIfNeeded()

        XCTAssertLessThan(narrow.selectionBackgroundView.frame.width,
                          wide.selectionBackgroundView.frame.width)
        XCTAssertEqual(wide.selectionBackgroundView.frame.width,
                       ThumbnailCellView.cardMaximumWidth, accuracy: 0.5,
                       "and stops at the cap rather than filling a wide drawer")
    }

    // MARK: - Filenames

    /// The name is on screen in every state — no pointer, not current, mid-reuse.
    func testTheFilenameIsAlwaysVisible() throws {
        let subject = configuredCell()
        XCTAssertFalse(subject.nameLabelView.isHidden, "visible with no pointer in sight")

        subject.setCurrent(true)
        XCTAssertFalse(subject.nameLabelView.isHidden)
        subject.setCurrent(false)
        XCTAssertFalse(subject.nameLabelView.isHidden)

        // Reuse, including a nil image on the way through.
        subject.configure(item: item("b.png"), image: nil, isCurrent: true)
        subject.layoutSubtreeIfNeeded()
        XCTAssertFalse(subject.nameLabelView.isHidden)
        subject.setThumbnail(image(width: 100, height: 400))
        subject.layoutSubtreeIfNeeded()
        XCTAssertFalse(subject.nameLabelView.isHidden)
    }

    /// A long name truncates in the middle and stays inside the card.
    func testALongFilenameIsMiddleTruncatedInsideTheCard() throws {
        let subject = cell(width: 200)
        let long = "2024-05-17-some-very-long-camera-file-name-0001.png"
        subject.configure(item: item(long), image: nil, isCurrent: false)
        subject.layoutSubtreeIfNeeded()

        let label = try XCTUnwrap(subject.nameLabelView as? NSTextField)
        XCTAssertEqual(label.lineBreakMode, .byTruncatingMiddle)
        XCTAssertEqual(label.stringValue, long, "the value is whole; only the drawing truncates")
        let card = subject.selectionBackgroundView.frame
        XCTAssertGreaterThanOrEqual(label.frame.minX, card.minX - 0.5)
        XCTAssertLessThanOrEqual(label.frame.maxX, card.maxX + 0.5)
        XCTAssertLessThanOrEqual(label.frame.maxX, subject.bounds.width + 0.5,
                                 "the name cannot push out of the drawer")
    }

    /// Whatever the name, the card keeps the same geometry: the label truncates, it does not push.
    func testTheCardGeometryIsUnaffectedByTheFilenameLength() {
        var frames: [CGRect] = []
        for name in ["a.png", String(repeating: "very-long-name-", count: 8) + ".png"] {
            let subject = cell()
            subject.configure(item: item(name), image: nil, isCurrent: true)
            subject.layoutSubtreeIfNeeded()
            frames.append(subject.selectionBackgroundView.frame)
        }
        XCTAssertEqual(frames[0], frames[1],
                       "a long filename must not resize or move the card")
    }

    // MARK: - The current-item frame

    /// The frame marks the square, so it is identical for every source shape.
    func testTheSelectionFrameMarksTheSquareNotTheImage() {
        var frames: [CGRect] = []
        for (width, height) in [(300, 200), (100, 500), (500, 100)] {
            let subject = configuredCell()
            subject.setCurrent(true)
            subject.setThumbnail(image(width: width, height: height))
            subject.layoutSubtreeIfNeeded()
            frames.append(subject.selectionBorderView.frame)
        }
        for frame in frames {
            XCTAssertEqual(frame.width,
                           ThumbnailCellView.thumbnailSlotSize
                               + ThumbnailCellView.selectionBorderHalo, accuracy: 0.5)
            XCTAssertEqual(frame.height,
                           ThumbnailCellView.thumbnailSlotSize
                               + ThumbnailCellView.selectionBorderHalo, accuracy: 0.5)
        }
        XCTAssertEqual(frames[0], frames[1])
        XCTAssertEqual(frames[1], frames[2])
    }

    /// The frame follows the square's centre exactly, rather than the thumbnail's.
    func testTheSelectionFrameIsCentredOnTheSlot() {
        let subject = configuredCell()
        subject.setCurrent(true)
        subject.setThumbnail(image(width: 500, height: 100))
        subject.layoutSubtreeIfNeeded()
        let slot = subject.thumbnailSlotView.frame
        let frame = subject.selectionBorderView.frame
        XCTAssertEqual(frame.midX, slot.midX, accuracy: 0.5)
        XCTAssertEqual(frame.midY, slot.midY, accuracy: 0.5)
    }
}
