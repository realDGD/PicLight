import Foundation
import CoreGraphics

/// Normalized viewport model. The image center stays normalized (0...1) so a
/// window resize or screen change preserves the user's focal point.
public struct ViewportState: Equatable, Sendable {
    public var fitScale: CGFloat
    public var zoomScale: CGFloat
    public var normalizedCenter: CGPoint
    public var viewRotationQuarterTurns: Int
    public var mirroredHorizontally: Bool

    public init(fitScale: CGFloat = 1, zoomScale: CGFloat = 1,
                normalizedCenter: CGPoint = CGPoint(x: 0.5, y: 0.5),
                viewRotationQuarterTurns: Int = 0,
                mirroredHorizontally: Bool = false) {
        self.fitScale = fitScale
        self.zoomScale = zoomScale
        self.normalizedCenter = normalizedCenter
        self.viewRotationQuarterTurns = viewRotationQuarterTurns
        self.mirroredHorizontally = mirroredHorizontally
    }

    public var isAtFit: Bool { abs(zoomScale - fitScale) < 0.0001 }
    public var isZoomedIn: Bool { zoomScale > fitScale + 0.0001 }
    public var zoomPercent: Int { Int((zoomScale * 100).rounded()) }

    /// Quarter turns folded into 0...3.
    public var normalizedQuarterTurns: Int {
        let turns = viewRotationQuarterTurns % 4
        return turns < 0 ? turns + 4 : turns
    }

    // MARK: - Scale math

    /// Fit scale for an image inside a view, considering view-only rotation.
    public static func fitScale(imagePixels: CGSize, viewPoints: CGSize) -> CGFloat {
        guard imagePixels.width > 0, imagePixels.height > 0,
              viewPoints.width > 0, viewPoints.height > 0 else { return 1 }
        return min(viewPoints.width / imagePixels.width, viewPoints.height / imagePixels.height)
    }

    /// Fit to the view's width, allowing the image to be taller than the view.
    public static func fitWidthScale(imagePixels: CGSize, viewPoints: CGSize) -> CGFloat {
        guard imagePixels.width > 0, viewPoints.width > 0 else { return 1 }
        return viewPoints.width / imagePixels.width
    }

    /// `100%` means one image pixel per physical display pixel.
    public static func actualPixelScale(backingScale: CGFloat) -> CGFloat {
        backingScale > 0 ? 1 / backingScale : 1
    }

    /// `Fit × 2` is twice the current fit scale, not 200% of original pixels.
    public static func doubleFitScale(fit: CGFloat) -> CGFloat { fit * 2 }

    /// Effective pixel size after view-only rotation.
    public static func displayedPixelSize(_ pixelSize: CGSize, quarterTurns: Int) -> CGSize {
        quarterTurns % 2 == 0
            ? pixelSize
            : CGSize(width: pixelSize.height, height: pixelSize.width)
    }

    // MARK: - Render transform

    /// The rotation and mirror a renderer applies to the image, in view space.
    ///
    /// Positive quarter turns rotate the *content clockwise on screen*, which is what
    /// the 顺时针旋转 command promises and what a viewer expects; in the y-up drawing
    /// space that is a negative angle. One definition, used by the transform below and
    /// by the centre conversions, so the direction cannot disagree with itself.
    public static func contentRotation(quarterTurns: Int, mirroredHorizontally: Bool) -> CGAffineTransform {
        let turns = ((quarterTurns % 4) + 4) % 4
        var transform = CGAffineTransform(rotationAngle: -CGFloat(turns) * .pi / 2)
        if mirroredHorizontally { transform = transform.scaledBy(x: -1, y: 1) }
        return transform
    }

    /// The offset a renderer subtracts **in the image's own axes** so the displayed
    /// point at `normalizedCenter` lands at the view centre.
    ///
    /// `normalizedCenter` lives in displayed (post-rotation) space, but a renderer
    /// subtracts its offset *before* applying the rotation, so the vector is the
    /// inverse-mapped one. Expressed through `contentRotation().inverted()` rather than
    /// a hand-written sign table: getting this wrong moves the image along the wrong
    /// axis, which is exactly how a drag ends up going the wrong way.
    public static func imageSpaceOffset(normalizedCenter: CGPoint,
                                        displayedPixelSize: CGSize,
                                        quarterTurns: Int,
                                        mirroredHorizontally: Bool) -> CGPoint {
        let displayed = CGPoint(x: (normalizedCenter.x - 0.5) * displayedPixelSize.width,
                               y: (normalizedCenter.y - 0.5) * displayedPixelSize.height)
        return displayed.applying(
            contentRotation(quarterTurns: quarterTurns, mirroredHorizontally: mirroredHorizontally).inverted()
        )
    }

    /// Image space → view space, exactly as both renderers build it (Quartz
    /// concatenates it, Metal maps quad corners through it). One implementation so
    /// the two paths cannot drift, and so tests can assert the mapping itself.
    public func imageToViewTransform(sourcePixelSize: CGSize, viewSize: CGSize) -> CGAffineTransform {
        let displayed = ViewportState.displayedPixelSize(sourcePixelSize,
                                                        quarterTurns: normalizedQuarterTurns)
        let offset = ViewportState.imageSpaceOffset(
            normalizedCenter: normalizedCenter,
            displayedPixelSize: displayed,
            quarterTurns: normalizedQuarterTurns,
            mirroredHorizontally: mirroredHorizontally
        )
        var transform = CGAffineTransform.identity
        transform = transform.translatedBy(x: viewSize.width / 2, y: viewSize.height / 2)
        transform = transform.scaledBy(x: zoomScale, y: zoomScale)
        // Chained builder calls, not `concatenating`: the builder applies each step about
        // the view centre (which is what makes rotation feel like the image turning in
        // place), while `concatenating` puts the argument outside the centre translation
        // and rotates the whole frame about the origin instead.
        transform = transform.rotated(by: -CGFloat(normalizedQuarterTurns) * .pi / 2)
        if mirroredHorizontally { transform = transform.scaledBy(x: -1, y: 1) }
        transform = transform.translatedBy(x: -offset.x, y: -offset.y)
        return transform
    }

    /// The point of the *source*, in pixels relative to the image centre, that is
    /// currently under the centre of the view.
    public func imagePointUnderViewCenter(sourcePixelSize: CGSize) -> CGPoint {
        ViewportState.imageSpaceOffset(
            normalizedCenter: normalizedCenter,
            displayedPixelSize: ViewportState.displayedPixelSize(
                sourcePixelSize, quarterTurns: normalizedQuarterTurns),
            quarterTurns: normalizedQuarterTurns,
            mirroredHorizontally: mirroredHorizontally
        )
    }

    /// The normalized centre that keeps `imagePoint` under the view centre for the
    /// given rotation and mirror. Rotating or mirroring a zoomed-in view must not move
    /// the user somewhere else, and this is what makes that true: the image point under
    /// the centre is carried across the rotation rather than the normalized pair being
    /// reinterpreted in the new axes (which is the same numbers pointing at a
    /// different place).
    public static func normalizedCenter(keeping imagePoint: CGPoint,
                                        sourcePixelSize: CGSize,
                                        quarterTurns: Int,
                                        mirroredHorizontally: Bool) -> CGPoint {
        let displayedSize = displayedPixelSize(sourcePixelSize, quarterTurns: quarterTurns)
        guard displayedSize.width > 0, displayedSize.height > 0 else { return CGPoint(x: 0.5, y: 0.5) }
        let displayed = imagePoint.applying(
            contentRotation(quarterTurns: quarterTurns, mirroredHorizontally: mirroredHorizontally)
        )
        return CGPoint(x: displayed.x / displayedSize.width + 0.5,
                       y: displayed.y / displayedSize.height + 0.5)
    }

    // MARK: - Center clamping

    /// Keeps the visible rectangle inside the image when the image is larger
    /// than the view; centers the axis that is smaller than the view.
    public mutating func clampCenter(imagePixels: CGSize, viewPoints: CGSize, backingScale: CGFloat) {
        normalizedCenter = Self.clampCenter(
            normalizedCenter,
            imagePixels: imagePixels, viewPoints: viewPoints,
            zoomScale: zoomScale, quarterTurns: normalizedQuarterTurns
        )
    }

    public static func clampCenter(_ center: CGPoint, imagePixels: CGSize,
                                   viewPoints: CGSize, zoomScale: CGFloat,
                                   quarterTurns: Int) -> CGPoint {
        let displayed = displayedPixelSize(imagePixels, quarterTurns: quarterTurns)
        let scaled = CGSize(width: displayed.width * zoomScale, height: displayed.height * zoomScale)
        var result = center
        if scaled.width <= viewPoints.width { result.x = 0.5 }
        else {
            let halfVisible = (viewPoints.width / 2) / scaled.width
            result.x = min(max(center.x, halfVisible), 1 - halfVisible)
        }
        if scaled.height <= viewPoints.height { result.y = 0.5 }
        else {
            let halfVisible = (viewPoints.height / 2) / scaled.height
            result.y = min(max(center.y, halfVisible), 1 - halfVisible)
        }
        return result
    }

    /// Normalized rectangle currently visible in the image, consumed by the minimap.
    public func visibleNormalizedRect(imagePixels: CGSize, viewPoints: CGSize) -> CGRect {
        let displayed = Self.displayedPixelSize(imagePixels, quarterTurns: normalizedQuarterTurns)
        let scaled = CGSize(width: displayed.width * zoomScale, height: displayed.height * zoomScale)
        let width = min(1, viewPoints.width / max(scaled.width, 1))
        let height = min(1, viewPoints.height / max(scaled.height, 1))
        let originX = min(max(normalizedCenter.x - width / 2, 0), 1 - width)
        let originY = min(max(normalizedCenter.y - height / 2, 0), 1 - height)
        return CGRect(x: originX, y: originY, width: width, height: height)
    }

    // MARK: - Zoom / pan

    /// Pointer-centered zoom: the image point under the pointer stays put.
    public mutating func zoom(to newScale: CGFloat, around viewPoint: CGPoint,
                              viewPoints: CGSize, imagePixels: CGSize,
                              minScale: CGFloat, maxScale: CGFloat) {
        let clamped = min(max(newScale, minScale), maxScale)
        let displayed = Self.displayedPixelSize(imagePixels, quarterTurns: normalizedQuarterTurns)
        let oldWidth = displayed.width * zoomScale
        let oldHeight = displayed.height * zoomScale
        guard oldWidth > 0, oldHeight > 0 else { zoomScale = clamped; return }

        let dx = viewPoint.x - viewPoints.width / 2
        let dy = viewPoint.y - viewPoints.height / 2
        let anchorX = normalizedCenter.x + dx / oldWidth
        let anchorY = normalizedCenter.y + dy / oldHeight

        zoomScale = clamped
        let newWidth = displayed.width * clamped
        let newHeight = displayed.height * clamped
        normalizedCenter = CGPoint(
            x: anchorX - dx / newWidth,
            y: anchorY - dy / newHeight
        )
        clampCenter(imagePixels: imagePixels, viewPoints: viewPoints, backingScale: 1)
    }

    public mutating func pan(byViewDelta delta: CGSize, imagePixels: CGSize, viewPoints: CGSize) {
        let displayed = Self.displayedPixelSize(imagePixels, quarterTurns: normalizedQuarterTurns)
        let scaledWidth = displayed.width * zoomScale
        let scaledHeight = displayed.height * zoomScale
        guard scaledWidth > 0, scaledHeight > 0 else { return }
        normalizedCenter.x -= delta.width / scaledWidth
        normalizedCenter.y += delta.height / scaledHeight
        clampCenter(imagePixels: imagePixels, viewPoints: viewPoints, backingScale: 1)
    }

    public mutating func rotateClockwise() {
        viewRotationQuarterTurns = (normalizedQuarterTurns + 1) % 4
    }

    public mutating func rotateCounterClockwise() {
        viewRotationQuarterTurns = (normalizedQuarterTurns + 3) % 4
    }

    public mutating func toggleMirror() { mirroredHorizontally.toggle() }
}
