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
