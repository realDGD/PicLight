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

    /// A real wheel: `hasPreciseScrollingDeltas == false`, which is what tells the canvas the deltas are
    /// a scroll command rather than a finger position.
    private func scrollEvent(wheel1: Int32, wheel2: Int32) throws -> NSEvent {
        // `.line` units are what a real wheel sends, and they are what makes
        // `hasPreciseScrollingDeltas` false (measured: `.pixel` reports precise).
        let cg = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 2,
                                       wheel1: wheel1, wheel2: wheel2, wheel3: 0))
        return try XCTUnwrap(NSEvent(cgEvent: cg))
    }

    /// The same event, marked continuous: this is what a trackpad sends.
    private func trackpadEvent(wheel1: Int32, wheel2: Int32) throws -> NSEvent {
        let cg = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                                       wheel1: wheel1, wheel2: wheel2, wheel3: 0))
        cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        // …and a gesture phase, which is what actually tells the canvas this is a trackpad: a wheel's
        // events carry none.
        cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(NSEvent.Phase.began.rawValue))
        return try XCTUnwrap(NSEvent(cgEvent: cg))
    }

    /// A vertical gesture moves the picture vertically, in the direction of the gesture.
    func testAVerticalPanMovesThePictureVertically() throws {
        let canvas = makeCanvas()
        for wheel in [Int32(20), Int32(-20)] {
            canvas.viewport = ViewportState(fitScale: 0.15, zoomScale: 1.0,
                                            normalizedCenter: CGPoint(x: 0.5, y: 0.5))
            let event = try trackpadEvent(wheel1: wheel, wheel2: 0)
            XCTAssertNotEqual(event.phase, [], "precondition: a trackpad sends a gesture phase")
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
            let event = try trackpadEvent(wheel1: 0, wheel2: wheel)
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

    /// A mouse wheel is a scroll command, not a finger: rolling it up moves the picture *down*, so the
    /// content that was above comes into view. This is the opposite of the trackpad rule above, on
    /// purpose, and it is what the report was about ("鼠标滚轮为平移模式的时候是不是反了").
    func testAMouseWheelScrollsTheDocumentRatherThanFollowingTheFingers() throws {
        let canvas = makeCanvas()
        for wheel in [Int32(20), Int32(-20)] {
            canvas.viewport = ViewportState(fitScale: 0.15, zoomScale: 1.0,
                                            normalizedCenter: CGPoint(x: 0.5, y: 0.5))
            let event = try scrollEvent(wheel1: wheel, wheel2: 0)
            let delta = event.scrollingDeltaY
            XCTAssertFalse(event.hasPreciseScrollingDeltas, "precondition: this is a wheel event")
            XCTAssertEqual(event.phase, [], "precondition: a wheel has no gesture phase")

            let before = canvas.viewport.imagePointUnderViewCenter(sourcePixelSize: source)
            canvas.scrollWheel(with: event)
            let after = canvas.viewport.imagePointUnderViewCenter(sourcePixelSize: source)

            // Wheel up (positive delta) = go up the picture: we end up looking at content that was
            // *higher* in the image, i.e. a larger source y.
            XCTAssertEqual(after.y > before.y, delta > 0,
                           "delta \(delta): a wheel must scroll the picture like a document "
                           + "(before y=\(before.y), after y=\(after.y))")
            XCTAssertEqual(after.x, before.x, accuracy: 0.5,
                           "and a vertical wheel must not move it sideways")
        }
    }

    /// A smooth-scrolling mouse sends continuous events with no phase — indistinguishable from a
    /// trackpad by delta shape, which is why the first fix did not change anything for the report
    /// ("滚轮现在还是反的"). The phase is what separates them, and the setting overrides the guess.
    func testASmoothScrollingMouseIsStillAWheel() throws {
        let cg = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                                       wheel1: 20, wheel2: 0, wheel3: 0))
        cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        let event = try XCTUnwrap(NSEvent(cgEvent: cg))
        XCTAssertTrue(event.hasPreciseScrollingDeltas, "precondition: its deltas look like a trackpad's")
        XCTAssertEqual(event.phase, [], "but it has no gesture phase")

        let canvas = makeCanvas()
        XCTAssertTrue(canvas.treatsAsAWheel(event), "so it is treated as a wheel")

        // And the user's answer beats the detection, both ways.
        canvas.wheelPanDirection = .followGesture
        XCTAssertFalse(canvas.treatsAsAWheel(event), "跟手式")
        let trackpad = try trackpadEvent(wheel1: 20, wheel2: 0)
        canvas.wheelPanDirection = .document
        XCTAssertTrue(canvas.treatsAsAWheel(trackpad), "文档式")

        // The direction each choice produces, on the same event.
        canvas.wheelPanDirection = .document
        canvas.viewport = ViewportState(fitScale: 0.15, zoomScale: 1.0,
                                        normalizedCenter: CGPoint(x: 0.5, y: 0.5))
        let before = canvas.viewport.imagePointUnderViewCenter(sourcePixelSize: source)
        canvas.scrollWheel(with: event)
        let documentAfter = canvas.viewport.imagePointUnderViewCenter(sourcePixelSize: source)
        XCTAssertGreaterThan(documentAfter.y, before.y, "文档式: wheel up looks further up the picture")

        canvas.wheelPanDirection = .followGesture
        canvas.viewport = ViewportState(fitScale: 0.15, zoomScale: 1.0,
                                        normalizedCenter: CGPoint(x: 0.5, y: 0.5))
        canvas.scrollWheel(with: event)
        let followAfter = canvas.viewport.imagePointUnderViewCenter(sourcePixelSize: source)
        XCTAssertLessThan(followAfter.y, before.y, "跟手式: the picture follows the wheel")
    }

    /// The horizontal and vertical conventions must be the same one, which is what "follows the
    /// gesture" means: the two axes cannot disagree about the sign.
    func testBothAxesUseTheSameConvention() throws {
        for device in ["wheel", "trackpad"] {
            try assertBothAxesAgree(device: device)
        }
    }

    private func assertBothAxesAgree(device: String) throws {
        let canvas = makeCanvas()
        let vertical = device == "wheel"
            ? try scrollEvent(wheel1: 20, wheel2: 0)
            : try trackpadEvent(wheel1: 20, wheel2: 0)
        let horizontal = device == "wheel"
            ? try scrollEvent(wheel1: 0, wheel2: 20)
            : try trackpadEvent(wheel1: 0, wheel2: 20)
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
                       "\(device): one convention — the same gesture direction must move both axes "
                       + "the same way")
    }
}
