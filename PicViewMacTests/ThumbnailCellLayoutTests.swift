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
}
