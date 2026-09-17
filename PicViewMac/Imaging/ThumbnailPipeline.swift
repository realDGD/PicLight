import Foundation
import CoreGraphics
import ImageIO

/// Downsampling thumbnails through ImageIO. An 8K source is never fully decoded
/// just to fill a ~150 px drawer cell, and the EXIF transform is applied here.
public actor ThumbnailPipeline {
    private let cache = NSCache<NSString, CGImageBox>()
    private var inFlight: [String: Task<CGImage?, Never>] = [:]

    public init(cacheLimit: Int = 600) {
        cache.countLimit = cacheLimit
        cache.totalCostLimit = 48 * 1024 * 1024
    }

    public func thumbnail(for url: URL, maxPixelSize: Int) async throws -> CGImage {
        let key = "\(url.path)|\(maxPixelSize)" as NSString
        if let cached = cache.object(forKey: key) { return cached.image }

        if let existing = inFlight[key as String] {
            if let image = await existing.value { return image }
        }

        let task = Task.detached(priority: .utility) { () -> CGImage? in
            Self.makeThumbnail(url: url, maxPixelSize: maxPixelSize)
        }
        inFlight[key as String] = task
        let image = await task.value
        inFlight[key as String] = nil
        guard let image else { throw ImageDecodeError.noDisplayableImage }
        cache.setObject(CGImageBox(image), forKey: key, cost: image.bytesPerRow * image.height)
        return image
    }

    /// Downsamples an already-decoded image for the navigator preview. This is a
    /// resample of pixels the viewer already holds, not a second decoder, and it
    /// runs off the main actor.
    public func preview(from image: CGImage, maxPixelSize: Int) async -> CGImage? {
        await Task.detached(priority: .utility) {
            let width = image.width
            let height = image.height
            guard width > 0, height > 0, maxPixelSize > 0 else { return nil }
            let scale = min(1, CGFloat(maxPixelSize) / CGFloat(max(width, height)))
            let targetWidth = max(1, Int((CGFloat(width) * scale).rounded()))
            let targetHeight = max(1, Int((CGFloat(height) * scale).rounded()))
            guard let context = CGContext(
                data: nil, width: targetWidth, height: targetHeight,
                bitsPerComponent: 8, bytesPerRow: 0,
                space: image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return nil }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
            return context.makeImage()
        }.value
    }

    public func cancelAll() {
        for task in inFlight.values { task.cancel() }
        inFlight.removeAll()
    }

    public func purge() {
        cache.removeAllObjects()
    }

    static func makeThumbnail(url: URL, maxPixelSize: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

/// `NSCache` needs class values; `CGImage` is immutable so boxing is safe.
final class CGImageBox: @unchecked Sendable {
    let image: CGImage
    init(_ image: CGImage) { self.image = image }
}
