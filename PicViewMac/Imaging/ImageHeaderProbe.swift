import Foundation
import ImageIO
import CoreGraphics

/// Reads an image header — no pixel decode — to learn a file's pixel size.
///
/// This lives in the imaging layer because two callers need exactly the same answer
/// and must not be able to disagree: folder sorting fills `FolderItem.pixelSize`
/// with it, and `DimensionProbe` (C2) uses it to decide whether a file is too large
/// for a native decode before any decode is started.
public enum ImageHeaderProbe {
    /// Pixel size as stored in the file, before EXIF orientation. `nil` when the
    /// header cannot be read at all — callers must treat that as unknown, not as
    /// small (see `OversizedPolicy`).
    public static func pixelSize(of url: URL) -> CGSize? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any] else { return nil }
        let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue ?? 0
        let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue ?? 0
        guard width > 0, height > 0 else { return nil }
        return CGSize(width: width, height: height)
    }
}
