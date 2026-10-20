import CoreGraphics
import Foundation
import ImageIO

/// Confined to one serial decoding worker. ImageIO retains composition dependencies;
/// requesting a later index does not discard delta-frame disposal/blend operations.
final class AnimationImageSource {
    let source: CGImageSource
    let descriptor: ImageDescriptor
    private let firstFrame: APNGFirstFrame?

    init(
        url: URL, source existingSource: CGImageSource? = nil,
        descriptor existingDescriptor: ImageDescriptor? = nil
    ) throws {
        guard
            let source = existingSource
                ?? CGImageSourceCreateWithURL(
                    url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
        else {
            throw ImageDecodeError.cannotCreateSource
        }
        self.source = source
        descriptor = try existingDescriptor ?? ImageIODecoder.descriptor(for: source, url: url)
        firstFrame =
            CGImageSourceGetType(source) as String? == "public.png" ? try APNGFirstFrame.read(from: url) : nil
    }

    func frame(at index: Int, maxPixelSize: Int) throws -> CGImage {
        guard index >= 0, index < CGImageSourceGetCount(source) else {
            throw ImageDecodeError.pageOutOfBounds
        }
        let image: CGImage?
        if index == 0, let firstFrame {
            image = firstFrame.decode(maxPixelSize: maxPixelSize)
        } else if max(descriptor.pixelSize.width, descriptor.pixelSize.height) > Double(maxPixelSize) {
            image = CGImageSourceCreateThumbnailAtIndex(
                source, index,
                [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceShouldCache: false,
                    kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
                ] as CFDictionary)
            guard let image else { throw ImageDecodeError.noDisplayableImage }
            return image  // thumbnail already oriented
        } else {
            image = CGImageSourceCreateImageAtIndex(
                source, index,
                [
                    kCGImageSourceShouldCache: false, kCGImageSourceShouldCacheImmediately: false,
                ] as CFDictionary)
        }
        guard let image else { throw ImageDecodeError.noDisplayableImage }
        if descriptor.orientation != .up {
            guard let oriented = ImageIODecoder.apply(orientation: descriptor.orientation, to: image) else {
                throw ImageDecodeError.noDisplayableImage
            }
            return oriented
        }
        return image
    }

    func releaseDecodedFrame(at index: Int) { CGImageSourceRemoveCacheAtIndex(source, index) }

    /// Materialize lazy ImageIO pixels off-thread and detach from the decoder's cache.
    static func detached(_ image: CGImage) throws -> CGImage {
        guard let data = image.dataProvider?.data, let provider = CGDataProvider(data: data),
            let colorSpace = image.colorSpace,
            let result = CGImage(
                width: image.width, height: image.height,
                bitsPerComponent: image.bitsPerComponent, bitsPerPixel: image.bitsPerPixel,
                bytesPerRow: image.bytesPerRow, space: colorSpace, bitmapInfo: image.bitmapInfo,
                provider: provider, decode: image.decode, shouldInterpolate: image.shouldInterpolate,
                intent: image.renderingIntent)
        else { throw ImageDecodeError.noDisplayableImage }
        return result
    }
}

enum AnimationResourcePolicy {
    static let budgetBytes = 80 * 1024 * 1024
    static let smallCacheBytes = 8 * 1024 * 1024

    /// Allow three full mip chains, one staging frame and one decoded working frame.
    /// 16-bit / Quartz uses a conservative eight bytes per pixel and four bitmaps.
    static func maximumEdge(size: CGSize, budget: Int = budgetBytes, highDepth: Bool = false) -> Int {
        let w = max(1, size.width)
        let h = max(1, size.height)
        let bytesPerPixel = highDepth ? 32.0 : 24.0
        let scale = min(1, sqrt(Double(max(1, budget)) / (Double(w * h) * bytesPerPixel)))
        return max(1, min(8192, Int(floor(max(w, h) * scale))))
    }
}
