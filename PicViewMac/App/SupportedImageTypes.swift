import Foundation
import UniformTypeIdentifiers

/// Fast eligibility filter for the v0.1 format set. Decoder inspection stays
/// authoritative; this only decides whether a file is worth listing.
public enum SupportedImageTypes {
    /// v0.1 hard-required formats. HEIC/HEIF are deliberately not advertised.
    public static let requiredExtensions: Set<String> = [
        "bmp", "gif", "ico", "png", "jpg", "jpeg", "tif", "tiff", "webp"
    ]

    public static var requiredContentTypes: [UTType] {
        [.bmp, .gif, .ico, .png, .jpeg, .tiff, .webP]
    }

    public static func isCandidate(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return requiredExtensions.contains(ext)
    }

    public static func isCandidate(pathExtension ext: String) -> Bool {
        requiredExtensions.contains(ext.lowercased())
    }

    /// Extensions declared to Finder so double-click and Open With route here.
    public static let declaredDocumentExtensions = requiredExtensions.sorted()
}
