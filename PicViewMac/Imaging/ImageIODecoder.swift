import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// ImageIO-backed decoder. Every `CGImage` it returns is already EXIF-oriented;
/// the descriptor keeps the original orientation for metadata display.
public struct ImageIODecoder: ImageDecoding {
    public init() {}

    public func inspect(_ url: URL) async throws -> ImageDescriptor {
        try await Task.detached(priority: .userInitiated) {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
                throw ImageDecodeError.cannotCreateSource
            }
            return try Self.descriptor(for: source, url: url)
        }.value
    }

    public func decodeFirstDisplayableFrame(
        _ url: URL, target: DecodeTarget
    ) async throws -> DecodedImageHead {
        try await Task.detached(priority: .userInitiated) {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
                throw ImageDecodeError.cannotCreateSource
            }
            let descriptor = try Self.descriptor(for: source, url: url)
            let index = try Self.selectIndex(source: source, descriptor: descriptor, target: target)
            guard let decoded = Self.decodeLimited(source: source, index: index, target: target) else {
                throw ImageDecodeError.noDisplayableImage
            }
            let metadata = MetadataReader.read(source: source, url: url, index: index)
            return DecodedImageHead(image: decoded.image, descriptor: descriptor,
                                    metadata: metadata, level: decoded.level)
        }.value
    }

    /// Decodes a single additional frame or TIFF page on demand so callers never
    /// have to hold a whole animation in memory at once.
    public func decodeFrame(
        _ url: URL, index: Int, target: DecodeTarget = .fullResolution
    ) async throws -> DecodedFrame {
        try await Task.detached(priority: .userInitiated) {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
                throw ImageDecodeError.cannotCreateSource
            }
            let count = CGImageSourceGetCount(source)
            guard index >= 0, index < count else { throw ImageDecodeError.pageOutOfBounds }
            guard let decoded = Self.decodeLimited(source: source, index: index, target: target) else {
                throw ImageDecodeError.noDisplayableImage
            }
            let image = decoded.image
            let durations = Self.frameDurations(source: source)
            let duration = index < durations.count ? durations[index] : nil
            return DecodedFrame(image: image, index: index, duration: duration)
        }.value
    }

    /// Streams the frames of an animated image.
    ///
    /// Multi-page documents are deliberately excluded: their pages are not animation
    /// frames, and streaming them made the viewer display the last page of a TIFF on
    /// load while decoding every page up front. Pages are decoded on demand through
    /// `decodeFrame(_:index:)`.
    public func decodeRemainingFrames(
        _ url: URL, descriptor: ImageDescriptor
    ) -> AsyncThrowingStream<DecodedFrame, Error> {
        guard descriptor.animated else {
            return AsyncThrowingStream { $0.finish() }
        }
        let total = descriptor.frameCount
        return AsyncThrowingStream { continuation in
            let task = Task.detached(priority: .utility) {
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
                    continuation.finish(throwing: ImageDecodeError.cannotCreateSource)
                    return
                }
                let durations = Self.frameDurations(source: source)
                for index in 1..<max(total, 1) {
                    if Task.isCancelled { continuation.finish(); return }
                    guard let image = Self.decodeOriented(source: source, index: index) else { continue }
                    let duration = index < durations.count ? durations[index] : nil
                    continuation.yield(DecodedFrame(image: image, index: index, duration: duration))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Internals

    static func descriptor(for source: CGImageSource, url: URL) throws -> ImageDescriptor {
        let count = CGImageSourceGetCount(source)
        guard count > 0, let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
            as? [CFString: Any] else {
            throw ImageDecodeError.noDisplayableImage
        }
        let type = CGImageSourceGetType(source) as String?
        let utilType = type.flatMap { UTType($0) }
        let pixelWidth = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue ?? 0
        let pixelHeight = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue ?? 0
        let orientationRaw = (properties[kCGImagePropertyOrientation] as? NSNumber)?.uint32Value ?? 1
        let orientation = CGImagePropertyOrientation(rawValue: orientationRaw) ?? .up

        let isMultiPage = utilType?.conforms(to: .tiff) == true
        let durations = frameDurations(source: source)
        let animated = !isMultiPage && count > 1 && !durations.isEmpty

        // A multi-representation ICO reports its largest embedded size as the
        // image's dimensions; the per-request budget still picks the right one.
        var pixelSize = CGSize(width: pixelWidth, height: pixelHeight)
        if count > 1, !animated, !isMultiPage {
            var largest = 0
            for index in 0..<count {
                largest = max(largest, pixelMaximum(source: source, index: index))
            }
            if largest > 0 {
                pixelSize = CGSize(width: largest, height: largest)
            }
        }

        let descriptor = ImageDescriptor(
            sourceURL: url,
            pixelSize: pixelSize,
            frameCount: animated ? count : 1,
            pageCount: isMultiPage ? count : 1,
            orientation: orientation,
            animated: animated,
            loopCount: animated ? loopCount(source: source) : nil,
            frameDurations: durations,
            typeIdentifier: type,
            representationCount: count
        )
        return descriptor
    }

    static func frameDurations(source: CGImageSource) -> [TimeInterval] {
        let count = CGImageSourceGetCount(source)
        guard count > 1 else { return [] }
        var durations: [TimeInterval] = []
        durations.reserveCapacity(count)
        var sawDictionary = false
        for index in 0..<count {
            guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil)
                as? [CFString: Any] else { return [] }
            if let gif = properties[kCGImagePropertyGIFDictionary] as? [CFString: Any] {
                sawDictionary = true
                durations.append(delay(from: gif,
                                       unclamped: kCGImagePropertyGIFUnclampedDelayTime,
                                       clamped: kCGImagePropertyGIFDelayTime))
            } else if let webp = properties[kCGImagePropertyWebPDictionary] as? [CFString: Any] {
                sawDictionary = true
                durations.append(delay(from: webp,
                                       unclamped: kCGImagePropertyWebPUnclampedDelayTime,
                                       clamped: kCGImagePropertyWebPDelayTime))
            } else {
                durations.append(0)
            }
        }
        return sawDictionary ? durations : []
    }

    private static func delay(from dictionary: [CFString: Any],
                              unclamped: CFString, clamped: CFString) -> TimeInterval {
        if let unclampedValue = (dictionary[unclamped] as? NSNumber)?.doubleValue, unclampedValue > 0 {
            return unclampedValue
        }
        if let value = (dictionary[clamped] as? NSNumber)?.doubleValue, value > 0 {
            return value
        }
        return 0
    }

    /// Loop count is stored in the container-level properties for GIF and WebP;
    /// per-image properties carry it only for some writers, so both are checked.
    static func loopCount(source: CGImageSource) -> Int? {
        if let value = loopCount(in: CGImageSourceCopyProperties(source, nil) as? [CFString: Any]) {
            return value
        }
        return loopCount(in: CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
    }

    private static func loopCount(in properties: [CFString: Any]?) -> Int? {
        guard let properties else { return nil }
        if let gif = properties[kCGImagePropertyGIFDictionary] as? [CFString: Any],
           let value = gif[kCGImagePropertyGIFLoopCount] as? NSNumber {
            return value.intValue
        }
        if let webp = properties[kCGImagePropertyWebPDictionary] as? [CFString: Any],
           let value = webp[kCGImagePropertyWebPLoopCount] as? NSNumber {
            return value.intValue
        }
        return nil
    }

    /// ICO keeps several embedded sizes. With a pixel budget, pick the smallest
    /// representation that still covers it; without one, pick the largest for
    /// best quality. This is never surfaced as a "page" UI.
    static func selectIndex(source: CGImageSource, descriptor: ImageDescriptor,
                            target: DecodeTarget) throws -> Int {
        let count = CGImageSourceGetCount(source)
        if descriptor.pageCount > 1 {
            guard target.pageIndex >= 0, target.pageIndex < count else {
                throw ImageDecodeError.pageOutOfBounds
            }
            return target.pageIndex
        }
        guard count > 1 else { return 0 }
        let budget = target.maxPixelSize
        var best = 0
        var bestSize = 0
        var fallback = 0
        var fallbackSize = 0
        for index in 0..<count {
            let size = pixelMaximum(source: source, index: index)
            if size > fallbackSize { fallback = index; fallbackSize = size }
            if let budget, size <= budget && size > bestSize { best = index; bestSize = size }
        }
        if bestSize > 0 { return best }
        return fallbackSize > 0 ? fallback : 0
    }

    private static func pixelMaximum(source: CGImageSource, index: Int) -> Int {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil)
            as? [CFString: Any] else { return 0 }
        let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
        let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
        return max(width, height)
    }

    static func decodeOriented(source: CGImageSource, index: Int) -> CGImage? {
        guard let image = CGImageSourceCreateImageAtIndex(source, index, nil) else { return nil }
        let orientationRaw = (CGImageSourceCopyPropertiesAtIndex(source, index, nil)
            as? [CFString: Any])
            .flatMap { ($0[kCGImagePropertyOrientation] as? NSNumber)?.uint32Value } ?? 1
        guard let orientation = CGImagePropertyOrientation(rawValue: orientationRaw),
              orientation != .up else { return image }
        return apply(orientation: orientation, to: image) ?? image
    }

    /// Decodes one representation at the level the design allows, and reports which
    /// level that was so the caller can key its cache by what was produced.
    ///
    /// * at or below the 8192 ceiling: native pixels, orientation applied, then
    ///   explicitly materialized off-thread (A3). Delivery must never hand the
    ///   renderer a lazy image — measured, that puts the whole decode inside the
    ///   renderer's first draw (0.5 s for an 8192 PNG, 19 s for the investigation
    ///   image) plus a multi-GiB `Image IO` allocation.
    /// * above the ceiling: a bounded ImageIO thumbnail. `WithTransform` applies the
    ///   EXIF orientation during that decode, so the full-size orientation copy must
    ///   not run afterwards, and `ThumbnailMaxPixelSize` is the budget snapped up to
    ///   one of the stable buckets.
    ///
    /// Unknown dimensions (an unreadable header) deliberately take the bounded path:
    /// a needless bounded decode costs sharpness, a needless native one costs
    /// gigabytes. Oversized sources never fall back to native here.
    static func decodeLimited(source: CGImageSource, index: Int,
                              target: DecodeTarget) -> (image: CGImage, level: DecodeLevel)? {
        let longEdge = pixelMaximum(source: source, index: index)
        if longEdge > 0, longEdge <= DecodeBudget.maximumLongEdge {
            guard let image = decodeOriented(source: source, index: index) else { return nil }
            return (BitmapMaterializer.materialize(image), .native)
        }
        let requested = target.maxPixelSize ?? DecodeBudget.maximumLongEdge
        let bucket = DecodeBudget.bucket(atLeast: min(max(requested, 1), DecodeBudget.maximumLongEdge))
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: bucket,
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary) else {
            return nil
        }
        return (thumbnail, .bucket(bucket))
    }

    /// Orientation is applied to pixels on the fly; the file on disk is never rewritten.
    static func apply(orientation: CGImagePropertyOrientation, to image: CGImage) -> CGImage? {
        let width = image.width
        let height = image.height
        let swapsDimensions: Bool
        switch orientation {
        case .left, .leftMirrored, .right, .rightMirrored: swapsDimensions = true
        default: swapsDimensions = false
        }
        let outputWidth = swapsDimensions ? height : width
        let outputHeight = swapsDimensions ? width : height

        var transform = CGAffineTransform.identity
        switch orientation {
        case .up: transform = .identity
        case .upMirrored: transform = CGAffineTransform(translationX: CGFloat(width), y: 0).scaledBy(x: -1, y: 1)
        case .down: transform = CGAffineTransform(translationX: CGFloat(width), y: CGFloat(height)).rotated(by: .pi)
        case .downMirrored: transform = CGAffineTransform(translationX: 0, y: CGFloat(height)).scaledBy(x: 1, y: -1)
        case .left: transform = CGAffineTransform(translationX: CGFloat(height), y: 0).rotated(by: .pi / 2)
        case .leftMirrored: transform = CGAffineTransform(translationX: CGFloat(height), y: 0)
            .rotated(by: .pi / 2).scaledBy(x: -1, y: 1)
        case .right: transform = CGAffineTransform(translationX: 0, y: CGFloat(width)).rotated(by: -.pi / 2)
        case .rightMirrored: transform = CGAffineTransform(translationX: 0, y: CGFloat(width))
            .rotated(by: -.pi / 2).scaledBy(x: -1, y: 1)
        }

        guard let colorSpace = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil, width: outputWidth, height: outputHeight,
                bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }
        context.concatenate(transform)
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}
