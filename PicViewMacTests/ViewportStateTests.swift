import XCTest
import CoreGraphics
@testable import PicViewMac

final class ViewportStateTests: XCTestCase {
    func testFitScaleForLandscapeAndPortraitImages() {
        let landscape = ViewportState.fitScale(imagePixels: CGSize(width: 4000, height: 2000),
                                               viewPoints: CGSize(width: 1000, height: 800))
        XCTAssertEqual(landscape, 0.25, accuracy: 0.0001, "width is the binding constraint")

        let portrait = ViewportState.fitScale(imagePixels: CGSize(width: 2000, height: 4000),
                                              viewPoints: CGSize(width: 1000, height: 800))
        XCTAssertEqual(portrait, 0.2, accuracy: 0.0001, "height is the binding constraint")

        let tiny = ViewportState.fitScale(imagePixels: CGSize(width: 100, height: 100),
                                          viewPoints: CGSize(width: 1000, height: 800))
        XCTAssertEqual(tiny, 8, accuracy: 0.0001, "small images may be scaled up to fit")
    }

    func testActualPixelScaleMeansOneImagePixelPerPhysicalPixel() {
        XCTAssertEqual(ViewportState.actualPixelScale(backingScale: 2), 0.5, accuracy: 0.0001)
        XCTAssertEqual(ViewportState.actualPixelScale(backingScale: 1), 1, accuracy: 0.0001)
    }

    func testDoubleFitIsTwiceTheCurrentFitScaleNotTwoHundredPercentOfPixels() {
        let fit: CGFloat = 0.25
        XCTAssertEqual(ViewportState.doubleFitScale(fit: fit), 0.5, accuracy: 0.0001)
    }

    func testNormalizedCenterStaysStableWhileTheViewResizes() {
        let image = CGSize(width: 4000, height: 3000)
        var viewport = ViewportState(fitScale: 0.1, zoomScale: 0.5,
                                     normalizedCenter: CGPoint(x: 0.7, y: 0.3))
        viewport.clampCenter(imagePixels: image, viewPoints: CGSize(width: 800, height: 600), backingScale: 2)
        let afterFirst = viewport.normalizedCenter
        viewport.clampCenter(imagePixels: image, viewPoints: CGSize(width: 1200, height: 400), backingScale: 2)
        XCTAssertEqual(viewport.normalizedCenter.x, afterFirst.x, accuracy: 0.0001)
        XCTAssertEqual(viewport.normalizedCenter.y, afterFirst.y, accuracy: 0.0001)
    }

    func testClampCentersAnAxisThatIsSmallerThanTheView() {
        // Zoomed out: the whole image fits, so both axes snap to the middle.
        var viewport = ViewportState(fitScale: 1, zoomScale: 0.2,
                                     normalizedCenter: CGPoint(x: 0.95, y: 0.05))
        viewport.clampCenter(imagePixels: CGSize(width: 100, height: 100),
                             viewPoints: CGSize(width: 800, height: 600), backingScale: 2)
        XCTAssertEqual(viewport.normalizedCenter.x, 0.5, accuracy: 0.0001)
        XCTAssertEqual(viewport.normalizedCenter.y, 0.5, accuracy: 0.0001)
    }

    func testClampPreventsPanningBeyondTheImageEdge() {
        let image = CGSize(width: 1000, height: 1000)
        let view = CGSize(width: 400, height: 400)
        let clamped = ViewportState.clampCenter(CGPoint(x: 0.01, y: 0.99), imagePixels: image,
                                                viewPoints: view, zoomScale: 1, quarterTurns: 0)
        XCTAssertEqual(clamped.x, 0.2, accuracy: 0.0001)
        XCTAssertEqual(clamped.y, 0.8, accuracy: 0.0001)
    }

    func testPointerCenteredZoomKeepsTheAnchorPointUnderThePointer() {
        let image = CGSize(width: 1000, height: 1000)
        let view = CGSize(width: 500, height: 500)
        var viewport = ViewportState(fitScale: 0.5, zoomScale: 0.5,
                                     normalizedCenter: CGPoint(x: 0.5, y: 0.5))
        let anchor = CGPoint(x: 375, y: 125) // right of center, above center
        let beforeOffset = CGPoint(x: anchor.x - view.width / 2, y: anchor.y - view.height / 2)
        let scaledWidthBefore = image.width * viewport.zoomScale
        let normalizedUnderPointer = CGPoint(
            x: viewport.normalizedCenter.x + beforeOffset.x / scaledWidthBefore,
            y: viewport.normalizedCenter.y + beforeOffset.y / scaledWidthBefore
        )

        viewport.zoom(to: 1.0, around: anchor, viewPoints: view, imagePixels: image,
                      minScale: 0.1, maxScale: 8)

        let scaledWidthAfter = image.width * viewport.zoomScale
        let normalizedAfter = CGPoint(
            x: viewport.normalizedCenter.x + beforeOffset.x / scaledWidthAfter,
            y: viewport.normalizedCenter.y + beforeOffset.y / scaledWidthAfter
        )
        XCTAssertEqual(normalizedAfter.x, normalizedUnderPointer.x, accuracy: 0.0001)
        XCTAssertEqual(normalizedAfter.y, normalizedUnderPointer.y, accuracy: 0.0001)
    }

    func testZoomIsClampedToItsLimits() {
        var viewport = ViewportState(fitScale: 0.5, zoomScale: 0.5)
        viewport.zoom(to: 100, around: CGPoint(x: 250, y: 250),
                      viewPoints: CGSize(width: 500, height: 500),
                      imagePixels: CGSize(width: 1000, height: 1000),
                      minScale: 0.1, maxScale: 8)
        XCTAssertEqual(viewport.zoomScale, 8, accuracy: 0.0001)
        viewport.zoom(to: 0.0001, around: CGPoint(x: 250, y: 250),
                      viewPoints: CGSize(width: 500, height: 500),
                      imagePixels: CGSize(width: 1000, height: 1000),
                      minScale: 0.1, maxScale: 8)
        XCTAssertEqual(viewport.zoomScale, 0.1, accuracy: 0.0001)
    }

    func testVisibleNormalizedRectShrinksAsZoomGrows() {
        let image = CGSize(width: 1000, height: 1000)
        let view = CGSize(width: 500, height: 500)
        let atFit = ViewportState(fitScale: 0.5, zoomScale: 0.5).visibleNormalizedRect(
            imagePixels: image, viewPoints: view)
        XCTAssertEqual(atFit.width, 1, accuracy: 0.0001)
        let zoomed = ViewportState(fitScale: 0.5, zoomScale: 2).visibleNormalizedRect(
            imagePixels: image, viewPoints: view)
        XCTAssertEqual(zoomed.width, 0.25, accuracy: 0.0001)
    }

    func testViewOnlyRotationAndMirrorAreState() {
        var viewport = ViewportState()
        viewport.rotateClockwise()
        XCTAssertEqual(viewport.normalizedQuarterTurns, 1)
        viewport.rotateClockwise()
        viewport.rotateClockwise()
        viewport.rotateClockwise()
        XCTAssertEqual(viewport.normalizedQuarterTurns, 0, "quarter turns wrap around")
        viewport.rotateCounterClockwise()
        XCTAssertEqual(viewport.normalizedQuarterTurns, 3)
        XCTAssertFalse(viewport.mirroredHorizontally)
        viewport.toggleMirror()
        XCTAssertTrue(viewport.mirroredHorizontally)
    }

    func testRotationSwapsDisplayedDimensions() {
        XCTAssertEqual(ViewportState.displayedPixelSize(CGSize(width: 40, height: 20), quarterTurns: 0),
                       CGSize(width: 40, height: 20))
        XCTAssertEqual(ViewportState.displayedPixelSize(CGSize(width: 40, height: 20), quarterTurns: 1),
                       CGSize(width: 20, height: 40))
        XCTAssertEqual(ViewportState.displayedPixelSize(CGSize(width: 40, height: 20), quarterTurns: 2),
                       CGSize(width: 40, height: 20))
    }

    // MARK: - ViewerState integration

    @MainActor
    func testDoubleClickTogglesBetweenFitAndDoubleFit() {
        let state = ViewerState()
        state.updateFitScale(imagePixels: CGSize(width: 4000, height: 2000),
                             viewPoints: CGSize(width: 1000, height: 800))
        state.setZoomToFit(imagePixels: CGSize(width: 4000, height: 2000),
                           viewPoints: CGSize(width: 1000, height: 800))
        XCTAssertTrue(state.viewport.isAtFit)

        state.toggleFitAndDoubleFit(imagePixels: CGSize(width: 4000, height: 2000),
                                    viewPoints: CGSize(width: 1000, height: 800))
        XCTAssertEqual(state.viewport.zoomScale, 0.5, accuracy: 0.0001,
                       "Fit ×2 is twice the Fit scale (0.25), not 200% of original pixels")

        state.toggleFitAndDoubleFit(imagePixels: CGSize(width: 4000, height: 2000),
                                    viewPoints: CGSize(width: 1000, height: 800))
        XCTAssertTrue(state.viewport.isAtFit)
        XCTAssertEqual(state.viewport.normalizedCenter.x, 0.5, accuracy: 0.0001)
    }

    @MainActor
    func testImmersiveTogglingDoesNotTouchWindowGeometryState() {
        let state = ViewerState()
        state.updateFitScale(imagePixels: CGSize(width: 800, height: 600),
                             viewPoints: CGSize(width: 400, height: 300))
        state.viewport.zoomScale = 1.5
        state.viewport.normalizedCenter = CGPoint(x: 0.6, y: 0.4)
        let before = state.viewport

        state.toggleImmersive()
        XCTAssertTrue(state.isImmersive)
        XCTAssertEqual(state.viewport, before, "immersive mode is chrome policy only")

        state.toggleImmersive()
        XCTAssertFalse(state.isImmersive)
        XCTAssertEqual(state.viewport, before)
    }

    @MainActor
    func testPlaybackOnlyTogglesForAnimatedContent() {
        let state = ViewerState()
        state.togglePlayback()
        XCTAssertEqual(state.playback, .staticImage, "Space must not pretend a still image is playing")

        let descriptor = ImageDescriptor(sourceURL: URL(fileURLWithPath: "/tmp/a.gif"),
                                         pixelSize: CGSize(width: 10, height: 10),
                                         frameCount: 3, animated: true,
                                         frameDurations: [0.1, 0.1, 0.1])
        state.apply(head: DecodedImageHead(image: FakeDecoder.pixel, descriptor: descriptor,
                                           metadata: ImageMetadata()))
        state.playback = .playing
        state.togglePlayback()
        XCTAssertEqual(state.playback, .paused)
        state.togglePlayback()
        XCTAssertEqual(state.playback, .playing)
    }

    @MainActor
    func testAnimatedImageStartsPlayingAndStaticImageDoesNot() {
        let state = ViewerState()
        let animated = ImageDescriptor(sourceURL: URL(fileURLWithPath: "/tmp/a.gif"),
                                       pixelSize: CGSize(width: 4, height: 4),
                                       frameCount: 2, animated: true, frameDurations: [0.1, 0.1])
        state.apply(head: DecodedImageHead(image: FakeDecoder.pixel, descriptor: animated,
                                           metadata: ImageMetadata()))
        XCTAssertEqual(state.playback, .playing)

        let still = ImageDescriptor(sourceURL: URL(fileURLWithPath: "/tmp/a.png"),
                                    pixelSize: CGSize(width: 4, height: 4))
        state.apply(head: DecodedImageHead(image: FakeDecoder.pixel, descriptor: still,
                                           metadata: ImageMetadata()))
        XCTAssertEqual(state.playback, .staticImage)
    }

    @MainActor
    func testMultiPageDescriptionIsSeparateFromFolderIndex() {
        let state = ViewerState()
        let descriptor = ImageDescriptor(sourceURL: URL(fileURLWithPath: "/tmp/a.tiff"),
                                         pixelSize: CGSize(width: 4, height: 4), pageCount: 3)
        state.apply(head: DecodedImageHead(image: FakeDecoder.pixel, descriptor: descriptor,
                                           metadata: ImageMetadata()))
        XCTAssertEqual(state.pageDescription, "1 / 3")
        state.pageIndex = 2
        XCTAssertEqual(state.pageDescription, "3 / 3")
    }
}
