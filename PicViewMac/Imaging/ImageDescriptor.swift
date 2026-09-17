import Foundation
import CoreGraphics
import ImageIO

public struct ImageDescriptor: Sendable {
    public let sourceURL: URL
    public let pixelSize: CGSize
    public let frameCount: Int
    public let pageCount: Int
    public let orientation: CGImagePropertyOrientation
    public let animated: Bool
    /// Normalized total plays: nil means once, zero means infinite.
    public let loopCount: Int?
    public let frameDurations: [TimeInterval]
    public let typeIdentifier: String?
    public let representationCount: Int

    public var displayPixelSize: CGSize {
        switch orientation {
        case .left, .leftMirrored, .right, .rightMirrored:
            return CGSize(width: pixelSize.height, height: pixelSize.width)
        default: return pixelSize
        }
    }

    public init(sourceURL: URL, pixelSize: CGSize, frameCount: Int = 1,
                pageCount: Int = 1, orientation: CGImagePropertyOrientation = .up,
                animated: Bool = false, loopCount: Int? = nil,
                frameDurations: [TimeInterval] = [], typeIdentifier: String? = nil,
                representationCount: Int = 1) {
        self.sourceURL = sourceURL
        self.pixelSize = pixelSize
        self.frameCount = frameCount
        self.pageCount = pageCount
        self.orientation = orientation
        self.animated = animated
        self.loopCount = loopCount
        self.frameDurations = frameDurations
        self.typeIdentifier = typeIdentifier
        self.representationCount = representationCount
    }
}
