import XCTest
import AppKit
@testable import PicViewMac

/// The drawer cell's layout under the asynchronous conditions the drawer actually produces:
/// a cell configured with no image, then handed one; a cell reused for a different shape; and a
/// drawer narrower than the square it wants to show.
///
/// Reported symptom on the 48000x32000 item: the current-item border is about 8 px wide and the
/// thumbnail does not unfold. The border was constrained to `imageView.width + 8`, so an 8 px
/// border is exactly what a zero-width image view produces — the width was only bounded from
/// above and the image view has no intrinsic width while the image is nil, so Auto Layout was
/// free to solve it to zero and the later `setThumbnail` did not reliably undo it. That is why
/// the square is now a view of its own with required dimensions.
///
/// Shape-specific geometry is covered by `ThumbnailSquareSlotTests` and
/// `ThumbnailExtremeAspectTests`; this file is about timing and reuse.
@MainActor
final class ThumbnailCellLayoutTests: XCTestCase {

    override func setUp() async throws {
        try await super.setUp()
        TestAppKit.ensureApplication()
    }

    /// The drawer's row gives the cell its width and the solver may not trade that away; a cell
    /// created with a bare frame leaves its own width free, and the engine then satisfies the
    /// thumbnail constraints by growing the cell (measured: 218 pt for a 200 pt cell).
    private func cell(width: CGFloat = 200, height: CGFloat = 168) -> ThumbnailCellView {
        let cell = ThumbnailCellView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        cell.translatesAutoresizingMaskIntoConstraints = false
        cell.widthAnchor.constraint(equalToConstant: width).isActive = true
        cell.heightAnchor.constraint(equalToConstant: height).isActive = true
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

    /// The reported bug: nil first, image later.
    func testTheSquareDoesNotCollapseWhenTheThumbnailArrivesAsynchronously() {
        let subject = cell()
        subject.configure(item: item(), image: nil, isCurrent: true)
        subject.layoutSubtreeIfNeeded()

        let slot = subject.thumbnailSlotView
        XCTAssertEqual(slot.frame.width, ThumbnailCellView.thumbnailSlotSize, accuracy: 0.5,
                       "a zero-width slot is what produced the 8 px border the user saw")
        XCTAssertEqual(slot.frame.height, ThumbnailCellView.thumbnailSlotSize, accuracy: 0.5)
        // The frame is already the full size before the image exists, so it never appears to
        // "unfold" when one arrives.
        XCTAssertEqual(subject.selectionBorderView.frame.width,
                       ThumbnailCellView.thumbnailSlotSize + ThumbnailCellView.selectionBorderHalo,
                       accuracy: 0.5)

        subject.setThumbnail(image(width: 300, height: 200))
        subject.layoutSubtreeIfNeeded()

        let box = subject.thumbnailImageView.frame
        XCTAssertEqual(box.width / box.height, 1.5, accuracy: 1e-9, "3:2 preserved")
        XCTAssertEqual(box.width, ThumbnailCellView.thumbnailSlotSize, accuracy: 0.5,
                       "a 3:2 image is width-limited in the square")
        XCTAssertEqual(slot.frame.size,
                       NSSize(width: ThumbnailCellView.thumbnailSlotSize,
                              height: ThumbnailCellView.thumbnailSlotSize),
                       "and the square is unmoved by the arrival")
    }

    /// Cell reuse: landscape, then nil, then portrait must not leave the old aspect behind, and
    /// the square must not move through any of it.
    func testReuseAcrossOppositeAspectsKeepsTheLayoutValid() {
        let subject = cell()
        subject.configure(item: item(), image: image(width: 300, height: 200), isCurrent: false)
        subject.layoutSubtreeIfNeeded()
        let square = subject.thumbnailSlotView.frame
        XCTAssertEqual(subject.thumbnailImageView.frame.width
                       / subject.thumbnailImageView.frame.height, 1.5, accuracy: 1e-9)

        // Reused for a row whose thumbnail is not ready yet.
        subject.configure(item: item("b.png"), image: nil, isCurrent: true)
        subject.layoutSubtreeIfNeeded()
        XCTAssertEqual(subject.thumbnailSlotView.frame, square,
                       "the placeholder keeps the square exactly")
        XCTAssertGreaterThan(subject.thumbnailImageView.frame.width, 0,
                             "the placeholder must not collapse during reuse")

        // And then the portrait thumbnail arrives.
        subject.setThumbnail(image(width: 200, height: 300))
        subject.layoutSubtreeIfNeeded()
        XCTAssertEqual(subject.thumbnailSlotView.frame, square, "still the same square")
        let box = subject.thumbnailImageView.frame
        XCTAssertEqual(box.width / box.height, 2.0 / 3.0, accuracy: 1e-9,
                       "the portrait aspect must replace the landscape one")
        XCTAssertEqual(box.height, ThumbnailCellView.thumbnailSlotSize, accuracy: 0.5)
        XCTAssertGreaterThan(box.width, 0)
    }

    /// The filename follows the square, so it must not be pushed out of the cell by a tall image.
    func testFilenameStaysInsideTheCellForEveryAspect() {
        for (width, height) in [(300, 200), (200, 300), (500, 100), (100, 500)] {
            let subject = cell()
            subject.configure(item: item("name.png"), image: nil, isCurrent: false)
            subject.layoutSubtreeIfNeeded()
            subject.setThumbnail(image(width: width, height: height))
            subject.layoutSubtreeIfNeeded()
            let label = subject.nameLabelView
            XCTAssertGreaterThanOrEqual(label.frame.minY, 0, "\(width)x\(height)")
            XCTAssertLessThanOrEqual(label.frame.maxY, subject.bounds.height + 0.5,
                                     "\(width)x\(height)")
        }
    }

    /// A cell narrower than the square must still lay out sanely (drawer resized small).
    func testNarrowDrawerStillProducesAPositiveBox() {
        let subject = cell(width: 120, height: 168)
        subject.configure(item: item(), image: nil, isCurrent: true)
        subject.layoutSubtreeIfNeeded()
        subject.setThumbnail(image(width: 400, height: 300))
        subject.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(subject.thumbnailImageView.frame.width, 0)
        XCTAssertGreaterThan(subject.thumbnailSlotView.frame.width, 0)
        XCTAssertEqual(subject.selectionBorderView.frame.width,
                       subject.thumbnailSlotView.frame.width + ThumbnailCellView.selectionBorderHalo,
                       accuracy: 0.5)
        // The card may be narrower than its preferred minimum here; what it may not do is push
        // past the cell.
        XCTAssertLessThanOrEqual(subject.selectionBackgroundView.frame.width,
                                 subject.bounds.width + 0.5)
    }

    // MARK: - Selection card geometry

    /// The card must wrap the square and its filename slot, not the whole row: the row is 168 pt
    /// tall, so a wide image used to leave a large empty band painted in the selection colour.
    func testSelectionCardWrapsTheContentNotTheRow() {
        let subject = cell()
        subject.configure(item: item(), image: nil, isCurrent: true)
        subject.layoutSubtreeIfNeeded()
        subject.setThumbnail(image(width: 400, height: 100))
        subject.layoutSubtreeIfNeeded()

        let card = subject.selectionBackgroundView.frame
        let slot = subject.thumbnailSlotView.frame
        let row = subject.bounds.height
        XCTAssertEqual(card.height, ThumbnailCellView.cardHeight, accuracy: 0.5,
                       "the card is the square plus padding and the filename slot")
        XCTAssertLessThan(card.height, row,
                          "and strictly shorter than the row, so no band is painted")
        XCTAssertEqual(card.midX, slot.midX, accuracy: 0.5, "the card is centred on the square")
        // The filename slot is inside the card, so the label sits within it.
        let label = subject.nameLabelView.frame
        XCTAssertGreaterThanOrEqual(label.minY, card.minY - 0.5)
        XCTAssertLessThanOrEqual(label.maxY, card.maxY + 0.5)
    }

    /// The card follows the square through an asynchronous arrival, and its height never changes.
    func testSelectionCardTracksTheSquareAcrossAsyncArrival() {
        let subject = cell()
        subject.configure(item: item(), image: nil, isCurrent: true)
        subject.layoutSubtreeIfNeeded()
        let placeholder = subject.selectionBackgroundView.frame
        XCTAssertEqual(placeholder.height, ThumbnailCellView.cardHeight, accuracy: 0.5)
        XCTAssertLessThan(placeholder.height, subject.bounds.height)
        XCTAssertEqual(placeholder.midX, subject.thumbnailSlotView.frame.midX, accuracy: 0.5)

        subject.setThumbnail(image(width: 200, height: 300))
        subject.layoutSubtreeIfNeeded()
        let portrait = subject.selectionBackgroundView.frame
        XCTAssertEqual(portrait, placeholder,
                       "the card's geometry cannot depend on the image's shape")
    }

    /// Cell reuse: the card must not keep a stale geometry.
    func testSelectionCardFollowsReuse() {
        let subject = cell()
        subject.configure(item: item(), image: image(width: 400, height: 100), isCurrent: true)
        subject.layoutSubtreeIfNeeded()
        let wide = subject.selectionBackgroundView.frame
        subject.configure(item: item("b.png"), image: nil, isCurrent: true)
        subject.layoutSubtreeIfNeeded()
        subject.setThumbnail(image(width: 200, height: 300))
        subject.layoutSubtreeIfNeeded()
        XCTAssertEqual(subject.selectionBackgroundView.frame, wide,
                       "a reused cell keeps exactly the same card")
    }

    /// A portrait thumbnail's card is the same width as a landscape one's, and the filename is
    /// bound to the card rather than to the cell.
    func testFilenameSitsInsideTheCardHorizontallyForEveryShape() {
        let cases: [(name: String, width: Int, height: Int)] = [
            ("2:3 portrait", 200, 300),
            ("1:4 ultra tall", 100, 400),
            ("1:10 extremely narrow", 40, 400),
            ("3:2 landscape", 300, 200),
        ]
        for entry in cases {
            let subject = cell()
            subject.configure(item: item(), image: nil, isCurrent: true)
            subject.layoutSubtreeIfNeeded()
            subject.setThumbnail(image(width: entry.width, height: entry.height))
            subject.layoutSubtreeIfNeeded()

            let card = subject.selectionBackgroundView.frame
            let label = subject.nameLabelView.frame
            XCTAssertGreaterThanOrEqual(label.minX, card.minX - 0.5, entry.name)
            XCTAssertLessThanOrEqual(label.maxX, card.maxX + 0.5, entry.name)
            XCTAssertGreaterThanOrEqual(label.minY, card.minY - 0.5, entry.name)
            XCTAssertLessThanOrEqual(label.maxY, card.maxY + 0.5, entry.name)
            XCTAssertLessThan(card.width, subject.bounds.width,
                              "\(entry.name): the card still does not span the row")
        }
    }
}
