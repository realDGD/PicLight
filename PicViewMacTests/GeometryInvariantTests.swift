import XCTest
import AppKit
@testable import PicViewMac

/// Pure geometry: 100 % on Retina, Fit, Fit ×2, pointer-centered zoom, and the
/// minimap mapping derived from the same viewport model.
final class GeometryInvariantTests: XCTestCase {
    func testActualPixelScaleOnBothBackingScales() {
        // 100 % means one image pixel per physical display pixel.
        XCTAssertEqual(ViewportState.actualPixelScale(backingScale: 1), 1, accuracy: 0.0001)
        XCTAssertEqual(ViewportState.actualPixelScale(backingScale: 2), 0.5, accuracy: 0.0001)
        // A 1000 px wide image is 1000 physical pixels wide in both cases.
        for scale in [CGFloat(1), CGFloat(2)] {
            let points = 1000 * ViewportState.actualPixelScale(backingScale: scale)
            XCTAssertEqual(points * scale, 1000, accuracy: 0.0001,
                           "points × backingScale must equal the image's physical pixels")
        }
    }

    func testFitAndDoubleFitAcrossBackingScales() {
        let image = CGSize(width: 3000, height: 2000)
        for scale in [CGFloat(1), CGFloat(2)] {
            let view = CGSize(width: 900 * scale, height: 600 * scale)
            let fit = ViewportState.fitScale(imagePixels: image, viewPoints: view)
            XCTAssertLessThanOrEqual(image.width * fit, view.width + 0.0001)
            XCTAssertLessThanOrEqual(image.height * fit, view.height + 0.0001)
            XCTAssertEqual(ViewportState.doubleFitScale(fit: fit), fit * 2, accuracy: 0.0001,
                           "Fit ×2 scales with Fit, never with pixel ratio")
        }
    }

    func testNormalizedCenterSurvivesWindowResizeAndScreenChange() {
        // The image stays far larger than every view below, so no clamping binds
        // and the focal point must be preserved exactly.
        let image = CGSize(width: 20_000, height: 15_000)
        var viewport = ViewportState(fitScale: 0.01, zoomScale: 1.0,
                                     normalizedCenter: CGPoint(x: 0.72, y: 0.28))
        let sizes = [CGSize(width: 1200, height: 800),
                     CGSize(width: 1600, height: 900),
                     CGSize(width: 2560, height: 1440),  // a different screen
                     CGSize(width: 800, height: 1000)]
        for size in sizes {
            viewport.clampCenter(imagePixels: image, viewPoints: size, backingScale: 2)
            XCTAssertEqual(viewport.normalizedCenter.x, 0.72, accuracy: 0.0001,
                           "the focal point must survive a resize to \(size)")
            XCTAssertEqual(viewport.normalizedCenter.y, 0.28, accuracy: 0.0001)
        }
    }

    func testClampingIsWhatMovesTheCenterWhenTheImageEdgeWouldShow() {
        // A smaller image at 100 % legitimately clamps: the viewer must not show
        // empty space beyond the image edge.
        let image = CGSize(width: 4000, height: 3000)
        var viewport = ViewportState(fitScale: 0.1, zoomScale: 1.0,
                                     normalizedCenter: CGPoint(x: 0.72, y: 0.28))
        viewport.clampCenter(imagePixels: image, viewPoints: CGSize(width: 2560, height: 1440),
                             backingScale: 2)
        XCTAssertLessThan(viewport.normalizedCenter.x, 0.72,
                          "the center is pulled back so the edge aligns with the view")
        let visible = viewport.visibleNormalizedRect(imagePixels: image,
                                                    viewPoints: CGSize(width: 2560, height: 1440))
        // Clamping to the largest allowed center aligns the view's right edge with
        // the image's right edge; nothing beyond the image is ever visible.
        XCTAssertEqual(visible.maxX, 1, accuracy: 0.0001,
                       "the visible rect stops exactly at the image edge")
        XCTAssertGreaterThanOrEqual(visible.minX, 0)
    }

    func testRotationAndMirrorKeepTheViewportConsistent() {
        let image = CGSize(width: 4000, height: 2000)
        let view = CGSize(width: 800, height: 600)
        var viewport = ViewportState(fitScale: 0.2, zoomScale: 0.5,
                                     normalizedCenter: CGPoint(x: 0.6, y: 0.4))
        viewport.rotateClockwise()
        XCTAssertEqual(ViewportState.displayedPixelSize(image, quarterTurns: viewport.normalizedQuarterTurns),
                       CGSize(width: 2000, height: 4000))
        viewport.clampCenter(imagePixels: image, viewPoints: view, backingScale: 2)
        let rotatedRect = viewport.visibleNormalizedRect(imagePixels: image, viewPoints: view)
        XCTAssertLessThanOrEqual(rotatedRect.width, 1.0001)
        XCTAssertLessThanOrEqual(rotatedRect.height, 1.0001)

        viewport.toggleMirror()
        XCTAssertTrue(viewport.mirroredHorizontally)
        // Mirroring is a flip, not a translation: the visible rect is unchanged.
        XCTAssertEqual(viewport.visibleNormalizedRect(imagePixels: image, viewPoints: view), rotatedRect)
    }

    /// The image point under the pointer must stay under the pointer, at both
    /// backing scales, with no clamping in play.
    func testPointerCenteredZoomHoldsAtBothBackingScales() {
        let image = CGSize(width: 4000, height: 3000)
        for scale in [CGFloat(1), CGFloat(2)] {
            let view = CGSize(width: 800 * scale, height: 600 * scale)
            var viewport = ViewportState(fitScale: 0.2, zoomScale: 0.5,
                                         normalizedCenter: CGPoint(x: 0.5, y: 0.5))
            let anchor = CGPoint(x: view.width * 0.75, y: view.height * 0.25)
            let dx = anchor.x - view.width / 2
            let dy = anchor.y - view.height / 2

            func normalizedUnderPointer(_ viewport: ViewportState) -> CGPoint {
                CGPoint(
                    x: viewport.normalizedCenter.x + dx / (image.width * viewport.zoomScale),
                    y: viewport.normalizedCenter.y + dy / (image.height * viewport.zoomScale)
                )
            }
            let before = normalizedUnderPointer(viewport)
            XCTAssertGreaterThan(before.x, 0.1)
            XCTAssertLessThan(before.x, 0.9)

            viewport.zoom(to: 1.0, around: anchor, viewPoints: view, imagePixels: image,
                          minScale: 0.05, maxScale: 8)

            let after = normalizedUnderPointer(viewport)
            XCTAssertEqual(after.x, before.x, accuracy: 0.0001,
                           "backing scale \(scale) must keep the anchor point in place")
            XCTAssertEqual(after.y, before.y, accuracy: 0.0001,
                           "backing scale \(scale) must keep the anchor point in place")
            // The center really moved, so the assertion above is not vacuous.
            XCTAssertNotEqual(viewport.normalizedCenter, CGPoint(x: 0.5, y: 0.5))
        }
    }

    // MARK: - Minimap mapping

    func testMinimapImageRectPreservesAspectRatioAndCenters() {
        let bounds = NSRect(x: 0, y: 0, width: 168, height: 120)
        let source = CGSize(width: 0, height: 0)
        XCTAssertEqual(NavigatorView.imageRect(in: bounds, imagePixels: source), .zero,
                       "a zero-sized image maps to nothing")

        let landscape = NavigatorView.imageRect(in: bounds.insetBy(dx: 4, dy: 4),
                                                imagePixels: CGSize(width: 400, height: 100))
        XCTAssertEqual(landscape.width / landscape.height, 4, accuracy: 0.01,
                       "the minimap preview keeps the image aspect ratio")
        XCTAssertEqual(landscape.midX, bounds.midX, accuracy: 0.01)
        XCTAssertEqual(landscape.midY, bounds.midY, accuracy: 0.01)

        let portrait = NavigatorView.imageRect(in: bounds.insetBy(dx: 4, dy: 4),
                                               imagePixels: CGSize(width: 100, height: 400))
        XCTAssertEqual(portrait.height / portrait.width, 4, accuracy: 0.01)
    }

    func testMinimapViewportRectMatchesTheVisibleNormalizedRect() {
        let bounds = NSRect(x: 0, y: 0, width: 168, height: 120)
        let imageRect = NavigatorView.imageRect(in: bounds.insetBy(dx: 4, dy: 4),
                                                imagePixels: CGSize(width: 1000, height: 1000))
        let normalized = CGRect(x: 0.25, y: 0.5, width: 0.5, height: 0.25)
        let rect = NavigatorView.viewportRect(in: imageRect, normalized: normalized)

        XCTAssertEqual(rect.width, imageRect.width * 0.5, accuracy: 0.01)
        XCTAssertEqual(rect.height, imageRect.height * 0.25, accuracy: 0.01)
        XCTAssertEqual(rect.minX, imageRect.minX + imageRect.width * 0.25, accuracy: 0.01)
        // The minimap is drawn bottom-up, so a higher normalized Y is higher up.
        XCTAssertEqual(rect.minY, imageRect.minY + imageRect.height * (1 - 0.75), accuracy: 0.01)
    }

    func testMinimapRectTracksZoomLevelsFromTheViewportModel() {
        let image = CGSize(width: 4000, height: 2000)
        let view = CGSize(width: 1000, height: 500)
        let fit = ViewportState.fitScale(imagePixels: image, viewPoints: view)
        let minimap = NSRect(x: 0, y: 0, width: 168, height: 120)

        var viewport = ViewportState(fitScale: fit, zoomScale: fit)
        let atFit = viewport.visibleNormalizedRect(imagePixels: image, viewPoints: view)
        XCTAssertEqual(atFit.width, 1, accuracy: 0.0001, "at Fit the whole image is visible")

        viewport.zoomScale = fit * 4
        let zoomed = viewport.visibleNormalizedRect(imagePixels: image, viewPoints: view)
        XCTAssertEqual(zoomed.width, 1 / 4, accuracy: 0.0001)

        let imageRect = NavigatorView.imageRect(in: minimap.insetBy(dx: 4, dy: 4), imagePixels: image)
        let rectAtFit = NavigatorView.viewportRect(in: imageRect, normalized: atFit)
        let rectZoomed = NavigatorView.viewportRect(in: imageRect, normalized: zoomed)
        XCTAssertEqual(rectAtFit.width, imageRect.width, accuracy: 0.01)
        XCTAssertLessThan(rectZoomed.width, rectAtFit.width,
                          "the minimap viewport shrinks as the image is zoomed in")
    }

    func testRotatedImageChangesTheMinimapAspect() {
        let image = CGSize(width: 4000, height: 1000)
        let minimap = NSRect(x: 0, y: 0, width: 168, height: 120).insetBy(dx: 4, dy: 4)
        let upright = NavigatorView.imageRect(
            in: minimap,
            imagePixels: ViewportState.displayedPixelSize(image, quarterTurns: 0))
        let rotated = NavigatorView.imageRect(
            in: minimap,
            imagePixels: ViewportState.displayedPixelSize(image, quarterTurns: 1))
        XCTAssertGreaterThan(upright.width / upright.height, 1)
        XCTAssertLessThan(rotated.width / rotated.height, 1,
                          "a quarter turn must swap the minimap preview's shape")
    }
}
