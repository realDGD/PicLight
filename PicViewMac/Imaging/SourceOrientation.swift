import CoreGraphics
import Foundation
import ImageIO

/// How the file's pixels relate to the *canonical* source space the viewer works in.
///
/// The proxy arrives from ImageIO already oriented, and `RenderImage.sourcePixelSize` /
/// `ImageDescriptor.displayPixelSize` describe that oriented image. The tile backend reads raw
/// PNG rows, so it has to cross this boundary itself: a canonical rectangle has to become a raw
/// rectangle to decode, and raw pixels have to be written back in canonical order. Skipping
/// either half either puts tiles in the right place with the wrong content or the right content
/// in the wrong place — and only for sources whose orientation is not `.up`, which is exactly
/// what no automated test exercised until the tile backend made it visible.
///
/// All eight orientations are affine and axis aligned, so there is exactly one table here, and
/// `ImageIODecoder.apply` uses the same one. The values were measured against ImageIO's own
/// oriented decode (`kCGImageSourceCreateThumbnailWithTransform`) rather than derived by hand:
/// three of the four axis-swapping cases were the wrong way round in the first version, and a
/// square test image cannot tell a correct translation from a clipped one.
public struct SourceOrientation: Equatable, Sendable {
    public let raw: CGImagePropertyOrientation

    public init(_ raw: CGImagePropertyOrientation) {
        self.raw = raw
    }

    public static let up = SourceOrientation(.up)

    /// Whether the orientation exchanges width and height.
    public var swapsDimensions: Bool {
        switch raw {
        case .left, .leftMirrored, .right, .rightMirrored: return true
        default: return false
        }
    }

    public func canonicalPixelSize(rawPixelSize: CGSize) -> CGSize {
        swapsDimensions ? CGSize(width: rawPixelSize.height, height: rawPixelSize.width)
                        : rawPixelSize
    }

    /// Raw pixel coordinates → canonical pixel coordinates.
    ///
    /// `CGPoint.applying` uses Core Graphics' row-vector convention, so these numbers read as
    /// `(a·x + c·y + tx, b·x + d·y + ty)`.
    public func rawToCanonicalTransform(rawPixelSize: CGSize) -> CGAffineTransform {
        let width = rawPixelSize.width, height = rawPixelSize.height
        let canonicalWidth = swapsDimensions ? height : width
        let canonicalHeight = swapsDimensions ? width : height
        switch raw {
        case .up:
            return CGAffineTransform(a: 1, b: 0, c: 0, d: 1, tx: 0, ty: 0)
        case .upMirrored:
            return CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: width - 1, ty: 0)
        case .down:
            return CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: width - 1, ty: height - 1)
        case .downMirrored:
            return CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: height - 1)
        // Careful: Core Graphics' names do *not* match the EXIF numbers they stand for —
        // `.left` is 8 and `.leftMirrored` is 5, the reverse of the reading the numbers suggest.
        // These four entries are labelled by the CG case, with the geometry measured per EXIF
        // value from ImageIO's own oriented decode:
        //   EXIF 5 (.leftMirrored) → (y, x)            EXIF 6 (.right)         → (W'-1-y, x)
        //   EXIF 7 (.rightMirrored) → (W'-1-y, H'-1-x) EXIF 8 (.left)          → (y, H'-1-x)
        case .leftMirrored:
            return CGAffineTransform(a: 0, b: 1, c: 1, d: 0, tx: 0, ty: 0)
        case .right:
            return CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: canonicalWidth - 1, ty: 0)
        case .rightMirrored:
            return CGAffineTransform(a: 0, b: -1, c: -1, d: 0,
                                     tx: canonicalWidth - 1, ty: canonicalHeight - 1)
        case .left:
            return CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: canonicalHeight - 1)
        @unknown default:
            return .identity
        }
    }

    /// Canonical pixel coordinates → raw pixel coordinates: the inverse of the above.
    public func canonicalToRawTransform(rawPixelSize: CGSize) -> CGAffineTransform {
        rawToCanonicalTransform(rawPixelSize: rawPixelSize).inverted()
    }

    /// The file's pixel rectangle that holds a canonical rectangle.
    public func rawRect(forCanonicalRect rect: CGRect, rawPixelSize: CGSize) -> CGRect {
        rectBounds(rect, transform: canonicalToRawTransform(rawPixelSize: rawPixelSize),
                   clippingTo: CGRect(origin: .zero, size: rawPixelSize))
    }

    /// The canonical rectangle a raw rectangle corresponds to.
    public func canonicalRect(forRawRect rect: CGRect, rawPixelSize: CGSize) -> CGRect {
        let canonical = canonicalPixelSize(rawPixelSize: rawPixelSize)
        return rectBounds(rect, transform: rawToCanonicalTransform(rawPixelSize: rawPixelSize),
                          clippingTo: CGRect(origin: .zero, size: canonical))
    }

    /// Bounding box of a rectangle under an axis-aligned transform.
    ///
    /// The transform is defined on pixel *indices*, so a rect's exclusive far edge must not be
    /// mapped as if it were an index: mapping `maxX` (= `minX + width`, one past the last
    /// column) through a mirror gives `minX - 1`, and the rect loses a column. The mapped rect is
    /// therefore built from the two extreme *indices* with the far edge re-excluded.
    private func rectBounds(_ rect: CGRect, transform: CGAffineTransform,
                            clippingTo bounds: CGRect) -> CGRect {
        let farX = max(rect.minX, rect.maxX - 1)
        let farY = max(rect.minY, rect.maxY - 1)
        let corners = [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: farX, y: rect.minY),
                       CGPoint(x: rect.minX, y: farY), CGPoint(x: farX, y: farY)]
            .map { $0.applying(transform) }
        let minX = corners.map(\.x).min() ?? 0, maxX = corners.map(\.x).max() ?? 0
        let minY = corners.map(\.y).min() ?? 0, maxY = corners.map(\.y).max() ?? 0
        return CGRect(x: minX, y: minY, width: (maxX - minX) + 1, height: (maxY - minY) + 1)
            .intersection(bounds)
    }

    /// Reorders a raw RGBA8 buffer (top-left origin) into canonical order.
    ///
    /// `rawRect` is the buffer's rectangle in raw pixel space. Pixels are premultiplied, so this
    /// is a pure move: no channel arithmetic is involved.
    public func canonicalPixels(fromRawBuffer raw: [UInt8],
                                rawRect: CGRect,
                                rawPixelSize: CGSize) -> (pixels: [UInt8], size: CGSize) {
        let width = Int(rawRect.width), height = Int(rawRect.height)
        guard width > 0, height > 0, raw.count >= width * height * 4 else {
            return (raw, CGSize(width: width, height: height))
        }
        let transform = rawToCanonicalTransform(rawPixelSize: rawPixelSize)
        let canonicalRect = self.canonicalRect(forRawRect: rawRect, rawPixelSize: rawPixelSize)
        let outWidth = Int(canonicalRect.width), outHeight = Int(canonicalRect.height)
        guard outWidth > 0, outHeight > 0 else { return (raw, CGSize(width: width, height: height)) }
        var output = [UInt8](repeating: 0, count: outWidth * outHeight * 4)
        let originX = canonicalRect.minX, originY = canonicalRect.minY

        raw.withUnsafeBufferPointer { input in
            output.withUnsafeMutableBufferPointer { destination in
                for y in 0..<height {
                    for x in 0..<width {
                        let projected = CGPoint(x: rawRect.minX + CGFloat(x),
                                                y: rawRect.minY + CGFloat(y))
                            .applying(transform)
                        let cx = Int(projected.x - originX), cy = Int(projected.y - originY)
                        guard cx >= 0, cy >= 0, cx < outWidth, cy < outHeight else { continue }
                        let source = (y * width + x) * 4
                        let target = (cy * outWidth + cx) * 4
                        destination[target] = input[source]
                        destination[target + 1] = input[source + 1]
                        destination[target + 2] = input[source + 2]
                        destination[target + 3] = input[source + 3]
                    }
                }
            }
        }
        return (output, CGSize(width: outWidth, height: outHeight))
    }
}
