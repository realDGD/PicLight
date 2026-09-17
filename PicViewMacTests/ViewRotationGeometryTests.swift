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

    func testAQuarterTurnRotatesTheImageIntoItsDisplayedExtent() {
        // The image is 4000×2000; after one clockwise quarter turn the displayed
        // extent is 2000×4000, and the corner that used to be at +x now lies at +y.
        let state = viewport(zoom: 0.5, quarterTurns: 1)
        let transform = state.imageToViewTransform(sourcePixelSize: source, viewSize: view)
        let rightEdge = CGPoint(x: 2000, y: 0).applying(transform)
        let center = CGPoint(x: 0, y: 0).applying(transform)
        XCTAssertEqual(rightEdge.x, center.x, accuracy: 0.001, "the +x edge swings onto the y axis")
        XCTAssertEqual(rightEdge.y, center.y + 1000, accuracy: 0.001, "clockwise: +x goes up")
    }

    func testTheOffsetIsTheInverseRotationOfTheDisplayedOffset() {
        // Direct values, so a refactor that "simplifies" this back cannot pass.
        let center = CGPoint(x: 0.75, y: 0.25)
        let displayed = ViewportState.displayedPixelSize(source, quarterTurns: 1)
        let raw = CGPoint(x: (center.x - 0.5) * displayed.width,
                          y: (center.y - 0.5) * displayed.height)
        let offset = ViewportState.imageSpaceOffset(normalizedCenter: center,
                                                    displayedPixelSize: displayed,
                                                    quarterTurns: 1,
                                                    mirroredHorizontally: false)
        XCTAssertEqual(offset.x, raw.y, accuracy: 0.001)
        XCTAssertEqual(offset.y, -raw.x, accuracy: 0.001)
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
}
