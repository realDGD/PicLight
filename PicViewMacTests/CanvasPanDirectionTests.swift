import XCTest
import AppKit
import CoreGraphics
@testable import PicViewMac

/// Panning follows the gesture on both axes, through the whole path: event → router → viewport.
///
/// The vertical sign used to be the mirror of the horizontal one, so a two-finger pan in a zoomed
/// view tracked the fingers sideways and ran backwards up and down. The absolute direction had never
/// been pinned — the rotation tests only ever asserted that a drag moves content the *same* way at
/// every rotation. These tests pin it, with synthesized scroll events (`CGEvent` → `NSEvent`, which
/// is the same event the window delivers) so the sign cannot drift again.
@MainActor
final class CanvasPanDirectionTests: XCTestCase {

    private let source = CGSize(width: 4000, height: 2000)

    private func makeCanvas() -> ImageCanvasView {
        let context = CGContext(data: nil, width: 200, height: 100, bitsPerComponent: 8,
                                bytesPerRow: 200 * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 200, height: 100))
        let canvas = ImageCanvasView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        canvas.renderImage = RenderImage(
            bitmap: context.makeImage()!,
            descriptor: ImageDescriptor(sourceURL: URL(fileURLWithPath: "/tmp/pan.png"),
                                        pixelSize: source))
        canvas.wheelMode = .pan
        canvas.swipeMode = .alwaysPan
        // Zoomed in, and away from the edges so the pan is not clamped into a no-op.
        canvas.viewport = ViewportState(fitScale: 0.15, zoomScale: 1.0,
                                        normalizedCenter: CGPoint(x: 0.5, y: 0.5))
        canvas.layoutSubtreeIfNeeded()
        return canvas
    }

    private func scrollEvent(wheel1: Int32, wheel2: Int32) throws -> NSEvent {
        let cg = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                                       wheel1: wheel1, wheel2: wheel2, wheel3: 0))
        return try XCTUnwrap(NSEvent(cgEvent: cg))
    }

    /// A vertical gesture moves the picture vertically, in the direction of the gesture.
    func testAVerticalPanMovesThePictureVertically() throws {
        let canvas = makeCanvas()
        for wheel in [Int32(20), Int32(-20)] {
            canvas.viewport = ViewportState(fitScale: 0.15, zoomScale: 1.0,
                                            normalizedCenter: CGPoint(x: 0.5, y: 0.5))
            let event = try scrollEvent(wheel1: wheel, wheel2: 0)
            let delta = event.scrollingDeltaY
            XCTAssertNotEqual(delta, 0, "precondition: the synthetic event carries a delta")

            let before = canvas.viewport.imagePointUnderViewCenter(sourcePixelSize: source)
            canvas.scrollWheel(with: event)
            let after = canvas.viewport.imagePointUnderViewCenter(sourcePixelSize: source)

            XCTAssertEqual(after.x, before.x, accuracy: 0.5,
                           "a vertical gesture must not move the picture sideways")
            // Positive delta = the gesture asked to move the picture up = we are now looking at
            // content that was lower in the image (smaller source y in the centred y-up space).
            XCTAssertEqual(after.y < before.y, delta > 0,
                           "delta \(delta): the picture moved the wrong way vertically "
                           + "(before y=\(before.y), after y=\(after.y))")
        }
    }

    /// And a horizontal one moves it horizontally, with the same convention.
    func testAHorizontalPanMovesThePictureHorizontally() throws {
        let canvas = makeCanvas()
        for wheel in [Int32(20), Int32(-20)] {
            canvas.viewport = ViewportState(fitScale: 0.15, zoomScale: 1.0,
                                            normalizedCenter: CGPoint(x: 0.5, y: 0.5))
            let event = try scrollEvent(wheel1: 0, wheel2: wheel)
            let delta = event.scrollingDeltaX
            XCTAssertNotEqual(delta, 0, "precondition: the synthetic event carries a delta")

            let before = canvas.viewport.imagePointUnderViewCenter(sourcePixelSize: source)
            canvas.scrollWheel(with: event)
            let after = canvas.viewport.imagePointUnderViewCenter(sourcePixelSize: source)

            XCTAssertEqual(after.y, before.y, accuracy: 0.5,
                           "a horizontal gesture must not move the picture vertically")
            XCTAssertEqual(after.x < before.x, delta > 0,
                           "delta \(delta): the picture moved the wrong way horizontally "
                           + "(before x=\(before.x), after x=\(after.x))")
        }
    }

    /// The horizontal and vertical conventions must be the same one, which is what "follows the
    /// gesture" means: the two axes cannot disagree about the sign.
    func testBothAxesUseTheSameConvention() throws {
        let canvas = makeCanvas()
        let vertical = try scrollEvent(wheel1: 20, wheel2: 0)
        let horizontal = try scrollEvent(wheel1: 0, wheel2: 20)
        XCTAssertEqual(vertical.scrollingDeltaY > 0, horizontal.scrollingDeltaX > 0,
                       "the fixture events ask for the same direction on both axes")

        canvas.viewport = ViewportState(fitScale: 0.15, zoomScale: 1.0,
                                        normalizedCenter: CGPoint(x: 0.5, y: 0.5))
        let verticalBefore = canvas.viewport.imagePointUnderViewCenter(sourcePixelSize: source)
        canvas.scrollWheel(with: vertical)
        let verticalAfter = canvas.viewport.imagePointUnderViewCenter(sourcePixelSize: source)

        canvas.viewport = ViewportState(fitScale: 0.15, zoomScale: 1.0,
                                        normalizedCenter: CGPoint(x: 0.5, y: 0.5))
        let horizontalBefore = canvas.viewport.imagePointUnderViewCenter(sourcePixelSize: source)
        canvas.scrollWheel(with: horizontal)
        let horizontalAfter = canvas.viewport.imagePointUnderViewCenter(sourcePixelSize: source)

        XCTAssertEqual(verticalAfter.y < verticalBefore.y,
                       horizontalAfter.x < horizontalBefore.x,
                       "one convention: the same gesture direction must move both axes the same way")
    }
}
