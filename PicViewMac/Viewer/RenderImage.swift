import Foundation
import CoreGraphics

/// What the canvas renders: a bitmap together with the geometry it represents.
///
/// The decoded bitmap may be a bounded proxy (see the large-image design), so
/// `bitmap.width/height` is *storage*, never source geometry. Every viewport
/// calculation — Fit, Fit Width, 100 %, pan clamping, the navigator rectangle —
/// derives from `ImageDescriptor.displayPixelSize`, which keeps a single
/// authority for source geometry instead of a second copy that could drift.
public struct RenderImage: Equatable {
    public let bitmap: CGImage
    public let descriptor: ImageDescriptor

    /// Logical source size in pixels, after EXIF orientation.
    public var sourcePixelSize: CGSize { descriptor.displayPixelSize }

    public init(bitmap: CGImage, descriptor: ImageDescriptor) {
        self.bitmap = bitmap
        self.descriptor = descriptor
    }

    /// Convenience for callers that only have pixels — synthetic canvases and
    /// tests. The bitmap *is* the source in that case, so geometry equals its own
    /// size; production callers must pass the real descriptor.
    public init(nativeBitmap bitmap: CGImage) {
        self.init(bitmap: bitmap, descriptor: ImageDescriptor(
            sourceURL: URL(fileURLWithPath: "/dev/null"),
            pixelSize: CGSize(width: bitmap.width, height: bitmap.height),
            orientation: .up
        ))
    }
}
