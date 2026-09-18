import XCTest
import CoreGraphics
@testable import PicViewMac

/// View-only rotation has to mean one thing in both renderers.
///
/// `normalizedCenter` lives in displayed (post-rotation) space, but a renderer
/// subtracts its offset before applying the rotation, so the offset must be rotated
/// back through the inverse rotation. Before this was pinned, rotating the view left
/// the offset on the wrong axis: dragging right moved the image along its own x axis,
/// which after a quarter turn is the view's y axis, so panning after a rotation went
/// the wrong way (and a 180° turn mirrored the visible region).
final class ViewRotationGeometryTests: XCTestCase {
    private let source = CGSize(width: 4000, height: 2000)
    private let view = CGSize(width: 800, height: 600)
    private let turns = [0, 1, 2, 3]

    private func viewport(zoom: CGFloat = 2, center: CGPoint = CGPoint(x: 0.5, y: 0.5),
                          quarterTurns: Int = 0, mirrored: Bool = false) -> ViewportState {
        ViewportState(fitScale: 0.1, zoomScale: zoom, normalizedCenter: center,
                      viewRotationQuarterTurns: quarterTurns,
                      mirroredHorizontally: mirrored)
    }

    /// The displayed-space point the viewport claims to be looking at.
    private func requestedPointImageSpace(_ state: ViewportState) -> CGPoint {
        let displayed = ViewportState.displayedPixelSize(source,
                                                        quarterTurns: state.normalizedQuarterTurns)
        return ViewportState.imageSpaceOffset(
            normalizedCenter: state.normalizedCenter,
            displayedPixelSize: displayed,
            quarterTurns: state.normalizedQuarterTurns,
            mirroredHorizontally: state.mirroredHorizontally
        )
    }

    func testTheRequestedCenterLandsAtTheViewCenterForEveryRotationAndMirror() {
        for turn in turns {
            for mirrored in [false, true] {
                let state = viewport(quarterTurns: turn, mirrored: mirrored)
                let point = requestedPointImageSpace(state)
                    .applying(state.imageToViewTransform(sourcePixelSize: source, viewSize: view))
                XCTAssertEqual(point.x, view.width / 2, accuracy: 0.001,
                               "turn \(turn) mirrored \(mirrored)")
                XCTAssertEqual(point.y, view.height / 2, accuracy: 0.001,
                               "turn \(turn) mirrored \(mirrored)")
            }
        }
    }

    /// The user's report, as an assertion: a drag must carry the image the same way
    /// in view space no matter how the view is rotated or mirrored.
    func testDraggingRightMovesTheContentRightForEveryRotationAndMirror() {
        for turn in turns {
            for mirrored in [false, true] {
                // A reference point inside the image, so "how the content moved" is
                // measurable rather than inferred from the viewport fields.
                let reference = CGPoint(x: 300, y: -150)

                var before = viewport(quarterTurns: turn, mirrored: mirrored)
                before.zoomScale = 2
                let start = reference.applying(
                    before.imageToViewTransform(sourcePixelSize: source, viewSize: view))

                var after = before
                after.pan(byViewDelta: CGSize(width: 60, height: 0),
                          imagePixels: source, viewPoints: view)
                let end = reference.applying(
                    after.imageToViewTransform(sourcePixelSize: source, viewSize: view))

                XCTAssertGreaterThan(end.x, start.x + 1,
                                    "turn \(turn) mirrored \(mirrored): a rightward drag must move "
                                    + "the content right, \(start) -> \(end)")
                XCTAssertEqual(end.y, start.y, accuracy: 1,
                               "turn \(turn) mirrored \(mirrored): a horizontal drag must not "
                               + "move the content vertically, \(start) -> \(end)")
            }
        }
    }

    /// Same invariant for the vertical axis, expressed against the unrotated view so
    /// the test does not depend on which sign AppKit's vertical delta uses: whatever a
    /// drag does to an unrotated image, it must do to a rotated one.
    func testAVerticalDragMovesContentTheSameWayAtEveryRotationAndMirror() {
        let reference = CGPoint(x: -300, y: 150)
        let delta = CGSize(width: 0, height: -40)

        func movement(quarterTurns: Int, mirrored: Bool) -> CGPoint {
            var state = viewport(quarterTurns: quarterTurns, mirrored: mirrored)
            let start = reference.applying(
                state.imageToViewTransform(sourcePixelSize: source, viewSize: view))
            state.pan(byViewDelta: delta, imagePixels: source, viewPoints: view)
            let end = reference.applying(
                state.imageToViewTransform(sourcePixelSize: source, viewSize: view))
            return CGPoint(x: end.x - start.x, y: end.y - start.y)
        }

        let plain = movement(quarterTurns: 0, mirrored: false)
        XCTAssertNotEqual(plain.y, 0, accuracy: 0.001, "the fixture drag must move something")
        for turn in turns {
            for mirrored in [false, true] {
                let moved = movement(quarterTurns: turn, mirrored: mirrored)
                XCTAssertEqual(moved.x, plain.x, accuracy: 1,
                               "turn \(turn) mirrored \(mirrored): horizontal drift")
                XCTAssertEqual(moved.y, plain.y, accuracy: 1,
                               "turn \(turn) mirrored \(mirrored): vertical movement must match "
                               + "the unrotated view, \(moved) vs \(plain)")
            }
        }
    }

    func testAQuarterTurnSwapsTheDisplayedExtentAndTurnsClockwise() {
        // The image is 4000×2000; after one 顺时针 (clockwise) quarter turn the displayed
        // extent is 2000×4000, and the edge that used to be on the right is now at the
        // bottom: clockwise means the top goes right, i.e. +x goes down.
        let state = viewport(zoom: 0.5, quarterTurns: 1)
        let transform = state.imageToViewTransform(sourcePixelSize: source, viewSize: view)
        let rightEdge = CGPoint(x: 2000, y: 0).applying(transform)
        let center = CGPoint(x: 0, y: 0).applying(transform)
        XCTAssertEqual(rightEdge.x, center.x, accuracy: 0.001, "the +x edge swings onto the y axis")
        XCTAssertEqual(rightEdge.y, center.y - 1000, accuracy: 0.001, "clockwise: +x goes down")
    }

    /// The property that matters, stated without a sign table: mapping the offset back
    /// through the content rotation returns the displayed offset it came from. This is
    /// what breaks when the offset and the renderer disagree about the direction.
    func testTheOffsetRoundTripsThroughTheContentRotation() {
        let center = CGPoint(x: 0.75, y: 0.25)
        for turn in turns {
            for mirrored in [false, true] {
                let displayed = ViewportState.displayedPixelSize(source, quarterTurns: turn)
                let raw = CGPoint(x: (center.x - 0.5) * displayed.width,
                                  y: (center.y - 0.5) * displayed.height)
                let offset = ViewportState.imageSpaceOffset(
                    normalizedCenter: center, displayedPixelSize: displayed,
                    quarterTurns: turn, mirroredHorizontally: mirrored)
                let roundTripped = offset.applying(
                    ViewportState.contentRotation(quarterTurns: turn,
                                                  mirroredHorizontally: mirrored))
                XCTAssertEqual(roundTripped.x, raw.x, accuracy: 0.001, "turn \(turn) mirrored \(mirrored)")
                XCTAssertEqual(roundTripped.y, raw.y, accuracy: 0.001, "turn \(turn) mirrored \(mirrored)")
            }
        }
    }

    func testMirroringFlipsTheOffsetHorizontally() {
        let center = CGPoint(x: 0.75, y: 0.5)
        let plain = ViewportState.imageSpaceOffset(
            normalizedCenter: center, displayedPixelSize: source,
            quarterTurns: 0, mirroredHorizontally: false)
        let mirrored = ViewportState.imageSpaceOffset(
            normalizedCenter: center, displayedPixelSize: source,
            quarterTurns: 0, mirroredHorizontally: true)
        XCTAssertEqual(mirrored.x, -plain.x, accuracy: 0.001)
        XCTAssertEqual(mirrored.y, plain.y, accuracy: 0.001)
    }

    /// Where does a marked corner actually land? The command is called 顺时针旋转
    /// (clockwise), so the content must turn clockwise: the top-left corner ends up
    /// top-right. This renders through the same transform the canvas uses, so it
    /// measures the visible result rather than re-deriving the matrix.
    func testTheRenderedDirectionMatchesTheClockwiseName() throws {
        for (turns, expected) in [(0, "topLeft"), (1, "topRight"), (2, "bottomRight"), (3, "bottomLeft")] {
            XCTAssertEqual(markerCorner(turns: turns), expected,
                           "\(turns) quarter turn(s) of 顺时针旋转 landed the top-left corner at "
                           + "\(markerCorner(turns: turns))")
        }
    }

    /// Renders a 4×4 image whose top-left pixel is white and reports which corner of an
    /// 8×8 view that pixel lands in.
    private func markerCorner(turns: Int) -> String {
        let size = 4
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        for i in 0..<(size * size) { pixels[i * 4 + 3] = 255 }
        pixels[0] = 255; pixels[1] = 255; pixels[2] = 255
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        let bitmap = CGImage(width: size, height: size, bitsPerComponent: 8, bitsPerPixel: 32,
                             bytesPerRow: size * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                             bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                             provider: provider, decode: nil, shouldInterpolate: false,
                             intent: .defaultIntent)!
        let square = CGSize(width: Double(size), height: Double(size))
        var state = ViewportState(fitScale: 1, zoomScale: 1,
                                  normalizedCenter: CGPoint(x: 0.5, y: 0.5),
                                  viewRotationQuarterTurns: turns, mirroredHorizontally: false)
        state.fitScale = 1
        let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                                bytesPerRow: size * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.concatenate(state.imageToViewTransform(sourcePixelSize: square, viewSize: square))
        context.interpolationQuality = .none
        context.draw(bitmap, in: CGRect(x: -square.width / 2, y: -square.height / 2,
                                        width: square.width, height: square.height))
        let rendered = context.data!.bindMemory(to: UInt8.self, capacity: size * size * 4)
        func isWhite(x: Int, y: Int) -> Bool { rendered[(y * size + x) * 4] > 128 }
        if isWhite(x: 0, y: 0) { return "topLeft" }
        if isWhite(x: size - 1, y: 0) { return "topRight" }
        if isWhite(x: 0, y: size - 1) { return "bottomLeft" }
        if isWhite(x: size - 1, y: size - 1) { return "bottomRight" }
        return "nowhere"
    }

    /// The reported bug: rotating while zoomed in dropped the user somewhere else. The
    /// image point under the view centre has to survive the rotation, for every step of
    /// a full turn and for mirroring.
    func testRotatingAndMirroringKeepTheSameImagePointUnderTheViewCentre() {
        let source = CGSize(width: 4000, height: 2000)
        let view = CGSize(width: 800, height: 600)
        var state = ViewportState(fitScale: 0.1, zoomScale: 3,
                                  normalizedCenter: CGPoint(x: 0.5, y: 0.5),
                                  viewRotationQuarterTurns: 0, mirroredHorizontally: false)
        // Pan somewhere recognisable first: a zoomed-in view off the centre.
        state.pan(byViewDelta: CGSize(width: -120, height: 60),
                  imagePixels: source, viewPoints: view)

        for step in 1...4 {
            let before = state.imagePointUnderViewCenter(sourcePixelSize: source)
            let turns = state.normalizedQuarterTurns
            state.viewRotationQuarterTurns = turns + 1
            state.normalizedCenter = ViewportState.normalizedCenter(
                keeping: before, sourcePixelSize: source,
                quarterTurns: state.normalizedQuarterTurns,
                mirroredHorizontally: state.mirroredHorizontally)
            state.clampCenter(imagePixels: source, viewPoints: view, backingScale: 1)
            let after = state.imagePointUnderViewCenter(sourcePixelSize: source)
            XCTAssertEqual(after.x, before.x, accuracy: 0.5, "step \(step) x")
            XCTAssertEqual(after.y, before.y, accuracy: 0.5, "step \(step) y")
        }

        let beforeMirror = state.imagePointUnderViewCenter(sourcePixelSize: source)
        state.mirroredHorizontally.toggle()
        state.normalizedCenter = ViewportState.normalizedCenter(
            keeping: beforeMirror, sourcePixelSize: source,
            quarterTurns: state.normalizedQuarterTurns,
            mirroredHorizontally: state.mirroredHorizontally)
        let afterMirror = state.imagePointUnderViewCenter(sourcePixelSize: source)
        XCTAssertEqual(afterMirror.x, beforeMirror.x, accuracy: 0.5, "mirror keeps the point")
        XCTAssertEqual(afterMirror.y, beforeMirror.y, accuracy: 0.5, "mirror keeps the point")
    }

    /// Without the fix the same normalized pair pointed at a different image point after
    /// a rotation, which is the jump the user saw.
    func testReusingTheNormalizedPairWouldMoveTheUserElsewhere() {
        let source = CGSize(width: 4000, height: 2000)
        var state = ViewportState(fitScale: 0.1, zoomScale: 3,
                                  normalizedCenter: CGPoint(x: 0.7, y: 0.3),
                                  viewRotationQuarterTurns: 0, mirroredHorizontally: false)
        let before = state.imagePointUnderViewCenter(sourcePixelSize: source)
        state.viewRotationQuarterTurns = 1
        let after = state.imagePointUnderViewCenter(sourcePixelSize: source)
        XCTAssertGreaterThan(hypot(after.x - before.x, after.y - before.y), 100,
                             "the naive reinterpretation really does move the view")
    }

}
