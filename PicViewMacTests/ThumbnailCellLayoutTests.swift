import XCTest
import AppKit
@testable import PicViewMac

/// The drawer thumbnail: a cell configured with no image, then handed one asynchronously.
///
/// Reported symptom on the 48000x32000 item: the current-item border is about 8 px wide and the
/// thumbnail does not unfold. The border is constrained to `imageView.width + 8`, so an 8 px border
/// is exactly what a zero-width image view produces — the suspicion is that the width is only
/// bounded from above (`<= cell.width - 20`) and the image view has no intrinsic width while the
/// image is nil, so Auto Layout is free to solve it to zero and the later `setThumbnail` does not
/// reliably undo it.
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
    func testImageWidthDoesNotCollapseWhenTheThumbnailArrivesAsynchronously() {
        let subject = cell()
        subject.configure(item: item(), image: nil, isCurrent: true, filenameMode: .always)
        subject.layoutSubtreeIfNeeded()

        let imageView = subject.thumbnailImageView
        let border = subject.selectionBorderView
        // Before the thumbnail arrives the box must already be fully laid out: a zero-width box is
        // what produced the 8 px border the user saw.
        XCTAssertGreaterThan(imageView.frame.width, cellWidth(for: subject) * 0.5,
                             "the placeholder box must fill the cell, not collapse")

        subject.setThumbnail(image(width: 300, height: 200))
        subject.layoutSubtreeIfNeeded()

        XCTAssertGreaterThan(imageView.frame.width, 100,
                             "a 3:2 thumbnail in a 200 pt cell must be most of the cell width, "
                             + "got \(imageView.frame.width)")
        XCTAssertLessThanOrEqual(imageView.frame.width, 180.5,
                                 "and inside the width cap")
        XCTAssertEqual(border.frame.width, imageView.frame.width + 8,
                       "the current-item frame hugs the image box")
        XCTAssertGreaterThan(border.frame.width, 8 + 1,
                             "an ~8 px wide frame is the bug being fixed")
        XCTAssertLessThan(border.frame.width, subject.bounds.width)
        // Aspect ratio preserved: 3:2.
        XCTAssertEqual(imageView.frame.width / imageView.frame.height, 1.5, accuracy: 0.02)
    }

    private func cellWidth(for cell: ThumbnailCellView) -> CGFloat { cell.bounds.width }

    /// Aspect ratios: landscape, portrait, ultra wide, ultra tall, square.
    func testThumbnailAspectRatioIsPreservedForEveryShape() {
        let cases: [(name: String, width: Int, height: Int, aspect: CGFloat)] = [
            ("3:2 landscape", 300, 200, 1.5),
            ("2:3 portrait", 200, 300, 2.0 / 3.0),
            ("ultra wide 5:1", 500, 100, 5.0),
            ("ultra tall 1:5", 100, 500, 0.2),
            ("square", 200, 200, 1.0),
        ]
        for entry in cases {
            let subject = cell()
            subject.configure(item: item(), image: nil, isCurrent: true, filenameMode: .always)
            subject.layoutSubtreeIfNeeded()
            subject.setThumbnail(image(width: entry.width, height: entry.height))
            subject.layoutSubtreeIfNeeded()

            let imageView = subject.thumbnailImageView
            let border = subject.selectionBorderView
            let aspect = imageView.frame.width / imageView.frame.height
            XCTAssertEqual(aspect, entry.aspect, accuracy: 0.02,
                           "\(entry.name): aspect must be preserved, got \(aspect)")
            XCTAssertEqual(border.frame.width, imageView.frame.width + 8, entry.name)
            XCTAssertEqual(border.frame.height, imageView.frame.height + 8, entry.name)
            // Both caps respected: 132 pt tall, and inside the cell width.
            XCTAssertLessThanOrEqual(imageView.frame.height, ThumbnailCellView.thumbnailHeight + 0.5,
                                     "\(entry.name): the height cap must hold")
            XCTAssertLessThanOrEqual(imageView.frame.width, subject.bounds.width - 20 + 0.5,
                                     "\(entry.name): the width cap must hold")
            // The box is centred and never negative.
            XCTAssertGreaterThan(imageView.frame.width, 0, entry.name)
            XCTAssertEqual(imageView.frame.midX, subject.bounds.width / 2, accuracy: 0.5, entry.name)
        }
    }

    /// Cell reuse: landscape, then nil, then portrait must not leave the old aspect behind.
    func testReuseAcrossOppositeAspectsKeepsTheLayoutValid() {
        let subject = cell()
        subject.configure(item: item(), image: image(width: 300, height: 200), isCurrent: false,
                          filenameMode: .hover)
        subject.layoutSubtreeIfNeeded()
        XCTAssertEqual(subject.thumbnailImageView.frame.width
                       / subject.thumbnailImageView.frame.height, 1.5, accuracy: 0.02)

        // Reused for a row whose thumbnail is not ready yet.
        subject.configure(item: item("b.png"), image: nil, isCurrent: true, filenameMode: .hover)
        subject.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(subject.thumbnailImageView.frame.width, 0,
                             "the placeholder must not collapse during reuse")

        // And then the portrait thumbnail arrives.
        subject.setThumbnail(image(width: 200, height: 300))
        subject.layoutSubtreeIfNeeded()
        let aspect = subject.thumbnailImageView.frame.width / subject.thumbnailImageView.frame.height
        XCTAssertEqual(aspect, 2.0 / 3.0, accuracy: 0.02,
                       "the portrait aspect must replace the landscape one, got \(aspect)")
        XCTAssertEqual(subject.selectionBorderView.frame.width,
                       subject.thumbnailImageView.frame.width + 8)
        XCTAssertGreaterThan(subject.thumbnailImageView.frame.width, 0)
    }

    /// The filename follows the image box, so it must not be pushed out of the cell by a tall box.
    func testFilenameStaysInsideTheCellForEveryAspect() {
        for (width, height) in [(300, 200), (200, 300), (500, 100)] {
            let subject = cell()
            subject.configure(item: item("name.png"), image: nil, isCurrent: false,
                              filenameMode: .always)
            subject.layoutSubtreeIfNeeded()
            subject.setThumbnail(image(width: width, height: height))
            subject.layoutSubtreeIfNeeded()
            guard let label = subject.subviews.compactMap({ $0 as? NSTextField }).first else {
                return XCTFail("no filename label")
            }
            XCTAssertGreaterThanOrEqual(label.frame.minY, 0, "\(width)x\(height)")
            XCTAssertLessThanOrEqual(label.frame.maxY, subject.bounds.height + 0.5,
                                     "\(width)x\(height)")
        }
    }

    /// A cell narrower than the minimum box must still lay out sanely (drawer resized small).
    func testNarrowDrawerStillProducesAPositiveBox() {
        let subject = cell(width: 120, height: 168)
        subject.configure(item: item(), image: nil, isCurrent: true, filenameMode: .always)
        subject.layoutSubtreeIfNeeded()
        subject.setThumbnail(image(width: 400, height: 300))
        subject.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(subject.thumbnailImageView.frame.width, 0)
        XCTAssertLessThanOrEqual(subject.thumbnailImageView.frame.width, 120 - 20 + 0.5)
        XCTAssertEqual(subject.selectionBorderView.frame.width,
                       subject.thumbnailImageView.frame.width + 8)
    }

    // MARK: - Selection card geometry

    /// The selection card must wrap the thumbnail and its filename slot, not the whole row: the row
    /// is 168 pt tall, so a wide image left a large empty band painted in the selection colour.
    func testSelectionCardWrapsTheContentNotTheRow() {
        let cases: [(name: String, width: Int, height: Int)] = [
            ("3:2 landscape", 300, 200),
            ("1:1 square", 200, 200),
            ("2:3 portrait", 200, 300),
            ("4:1 ultra wide", 400, 100),
            ("1:4 ultra tall", 100, 400),
        ]
        for entry in cases {
            let subject = cell()
            subject.configure(item: item(), image: nil, isCurrent: true, filenameMode: .always)
            subject.layoutSubtreeIfNeeded()
            subject.setThumbnail(image(width: entry.width, height: entry.height))
            subject.layoutSubtreeIfNeeded()

            let card = subject.selectionBackgroundView.frame
            let box = subject.thumbnailImageView.frame
            let row = subject.bounds.height
            XCTAssertGreaterThan(card.width, box.width,
                                 "\(entry.name): the card is a card, not the bare box")
            XCTAssertLessThanOrEqual(card.height, row + 0.5,
                                     "\(entry.name): the card must fit the row")
            // The contract: the card is the image box plus the padding and the filename slot, so it
            // hugs the content instead of the row. (The row is 168 pt by design, so for a tall
            // thumbnail the card is necessarily close to it.)
            let expected = box.height + 2 * ThumbnailCellView.cardPadding
                + ThumbnailCellView.filenameSlotHeight
            XCTAssertEqual(card.height, expected, accuracy: 0.5,
                           "\(entry.name): the card must be the image box plus padding and slot")
            if entry.width > entry.height {
                XCTAssertLessThan(card.height, row - 4,
                                  "\(entry.name): a wide image's card is strictly shorter than "
                                  + "the row (card \(card.height) of row \(row))")
            }
            // The filename slot is inside the card, so the label sits within it.
            let label = subject.nameLabelView.frame
            XCTAssertGreaterThanOrEqual(label.minY, card.minY - 0.5, entry.name)
            XCTAssertLessThanOrEqual(label.maxY, card.maxY + 0.5, entry.name)
        }
    }

    /// Hiding the filename on hover must not resize the card.
    func testSelectionCardHeightIsStableAcrossFilenameModes() {
        let subject = cell()
        subject.configure(item: item(), image: image(width: 300, height: 200), isCurrent: true,
                          filenameMode: .always)
        subject.layoutSubtreeIfNeeded()
        let visible = subject.selectionBackgroundView.frame
        subject.filenameMode = .hover            // hidden until the pointer enters
        subject.layoutSubtreeIfNeeded()
        let hidden = subject.selectionBackgroundView.frame
        XCTAssertEqual(visible.height, hidden.height, accuracy: 0.5,
                       "the card must not change height when the filename is hidden")
        XCTAssertEqual(visible.minY, hidden.minY, accuracy: 0.5)
    }

    /// The card follows the image box for every shape, including the placeholder before an
    /// asynchronous thumbnail arrives.
    func testSelectionCardTracksTheImageBoxAcrossAsyncArrival() {
        let subject = cell()
        subject.configure(item: item(), image: nil, isCurrent: true, filenameMode: .always)
        subject.layoutSubtreeIfNeeded()
        let placeholder = subject.selectionBackgroundView.frame
        XCTAssertGreaterThan(placeholder.width, 100,
                             "the placeholder card must not collapse")
        XCTAssertLessThan(placeholder.height, subject.bounds.height - 4,
                          "nor fill the whole row")
        XCTAssertEqual(placeholder.height,
                       subject.thumbnailImageView.frame.height
                           + 2 * ThumbnailCellView.cardPadding
                           + ThumbnailCellView.filenameSlotHeight,
                       accuracy: 0.5,
                       "the placeholder card hugs the placeholder box")

        subject.setThumbnail(image(width: 200, height: 300))
        subject.layoutSubtreeIfNeeded()
        let portrait = subject.selectionBackgroundView.frame
        XCTAssertGreaterThan(portrait.height, placeholder.height,
                             "a portrait thumbnail's card is taller than the placeholder's")
        XCTAssertLessThanOrEqual(portrait.height, subject.bounds.height + 0.5)
        XCTAssertGreaterThan(portrait.width, 0)
    }

    /// Cell reuse: the card must not keep a stale geometry.
    func testSelectionCardFollowsReuse() {
        let subject = cell()
        subject.configure(item: item(), image: image(width: 400, height: 100), isCurrent: true,
                          filenameMode: .always)
        subject.layoutSubtreeIfNeeded()
        let wide = subject.selectionBackgroundView.frame.height
        subject.configure(item: item("b.png"), image: nil, isCurrent: true, filenameMode: .always)
        subject.layoutSubtreeIfNeeded()
        subject.setThumbnail(image(width: 200, height: 300))
        subject.layoutSubtreeIfNeeded()
        let tall = subject.selectionBackgroundView.frame.height
        XCTAssertGreaterThan(tall, wide, "the card must follow the new aspect after reuse")
        // The card is the wider of the image box plus padding and the minimum filename width.
        let expected = max(subject.thumbnailImageView.frame.width + 2 * ThumbnailCellView.cardPadding,
                           120)
        XCTAssertEqual(subject.selectionBackgroundView.frame.width, expected, accuracy: 0.5)
    }

    /// A portrait thumbnail's card is narrow, and the filename used to be bound to the cell: the
    /// label hung outside the selection colour. Both edges must be inside the card now.
    func testFilenameSitsInsideTheCardHorizontallyForPortraitShapes() {
        let cases: [(name: String, width: Int, height: Int)] = [
            ("2:3 portrait", 200, 300),
            ("1:4 ultra tall", 100, 400),
            ("1:5 ultra tall", 100, 500),
            ("extremely narrow 1:10", 40, 400),
            ("3:2 landscape", 300, 200),
        ]
        for entry in cases {
            let subject = cell()
            subject.configure(item: item(), image: nil, isCurrent: true, filenameMode: .always)
            subject.layoutSubtreeIfNeeded()
            subject.setThumbnail(image(width: entry.width, height: entry.height))
            subject.layoutSubtreeIfNeeded()

            let card = subject.selectionBackgroundView.frame
            let label = subject.nameLabelView.frame
            XCTAssertGreaterThanOrEqual(label.minX, card.minX - 0.5,
                                        "\(entry.name): the filename escapes the card on the left")
            XCTAssertLessThanOrEqual(label.maxX, card.maxX + 0.5,
                                     "\(entry.name): the filename escapes the card on the right")
            XCTAssertGreaterThanOrEqual(label.minY, card.minY - 0.5, entry.name)
            XCTAssertLessThanOrEqual(label.maxY, card.maxY + 0.5, entry.name)
            // An ultra-tall image must not shrink the card to a sliver around the thumbnail.
            XCTAssertGreaterThanOrEqual(card.width, 120 - 0.5,
                                        "\(entry.name): the card keeps a usable filename width")
            XCTAssertLessThan(card.width, subject.bounds.width,
                              "\(entry.name): and still does not span the row")
        }
    }

    /// The card's geometry must not depend on whether the filename is shown.
    func testCardGeometryIsIdenticalInEveryFilenameMode() {
        let subject = cell()
        let picture = image(width: 200, height: 300)
        var frames: [CGRect] = []
        for mode in [ThumbnailFilenameMode.always, .hover, .never] {
            subject.configure(item: item(), image: picture, isCurrent: true, filenameMode: mode)
            subject.layoutSubtreeIfNeeded()
            frames.append(subject.selectionBackgroundView.frame)
        }
        for frame in frames.dropFirst() {
            XCTAssertEqual(frame, frames[0],
                           "the card must not move or resize when the filename mode changes")
        }
        // And hovering (which toggles the label) changes nothing either.
        subject.filenameMode = .hover
        subject.layoutSubtreeIfNeeded()
        let hidden = subject.selectionBackgroundView.frame
        subject.layoutSubtreeIfNeeded()
        XCTAssertEqual(hidden, frames[0])
    }
}
