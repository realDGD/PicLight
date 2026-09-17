import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Decoded result for the first displayable frame. Image pixels are already
/// EXIF-oriented; `descriptor.orientation` keeps the original orientation.
public struct DecodedImageHead: Sendable {
    public let image: CGImage
    public let descriptor: ImageDescriptor
    public let metadata: ImageMetadata
    /// The level this bitmap was actually decoded at. Cache identity is what was
    /// produced, not what was requested: an oversized source that fell back to a
    /// bounded decode must never be stored under `.native`.
    public let level: DecodeLevel

    public init(image: CGImage, descriptor: ImageDescriptor, metadata: ImageMetadata,
                level: DecodeLevel = .native) {
        self.image = image
        self.descriptor = descriptor
        self.metadata = metadata
        self.level = level
    }
}

public struct DecodedFrame: Sendable {
    public let image: CGImage
    public let index: Int
    public let duration: TimeInterval?

    public init(image: CGImage, index: Int, duration: TimeInterval?) {
        self.image = image
        self.index = index
        self.duration = duration
    }
}

/// Bounds a decode request.
///
/// `maxPixelSize` is a real output budget: a source at or below the 8192 ceiling is
/// still decoded natively (so ordinary photographs keep their resolution), and a
/// larger source is bounded to the smallest bucket that covers this budget — the
/// caller derives it from the canvas with `DecodeBudget`.
///
/// `pageIndex` selects a TIFF page; animation frames are enumerated separately and
/// are deliberately not budgeted in this iteration.
public struct DecodeTarget: Sendable {
    public var maxPixelSize: Int?
    public var pageIndex: Int

    public init(maxPixelSize: Int? = nil, pageIndex: Int = 0) {
        self.maxPixelSize = maxPixelSize
        self.pageIndex = pageIndex
    }

    public static let fullResolution = DecodeTarget()
}

public protocol ImageDecoding: Sendable {
    func inspect(_ url: URL) async throws -> ImageDescriptor
    func decodeFirstDisplayableFrame(
        _ url: URL, target: DecodeTarget
    ) async throws -> DecodedImageHead
    func decodeRemainingFrames(
        _ url: URL, descriptor: ImageDescriptor
    ) -> AsyncThrowingStream<DecodedFrame, Error>
}

public enum ImageDecodeError: Error, LocalizedError {
    case cannotCreateSource
    case noDisplayableImage
    case pageOutOfBounds

    public var errorDescription: String? {
        switch self {
        case .cannotCreateSource: return "无法读取该图像文件"
        case .noDisplayableImage: return "该文件不包含可显示的图像"
        case .pageOutOfBounds: return "页码超出范围"
        }
    }
}
