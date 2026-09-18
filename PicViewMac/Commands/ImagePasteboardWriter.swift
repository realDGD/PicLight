import AppKit

/// What "复制图像" puts on the pasteboard, and what it costs.
///
/// Two representations, each under its own type, so a consumer gets the thing it asked for and
/// nothing is misrepresented:
///
/// - `public.file-url` — the original file, **by reference**. Zero decode, zero bytes copied, and
///   exact by construction: this is the original file, not a rendering of it. Written eagerly (it
///   is a string) so a paste into Finder or another app that wants a file always has it.
/// - `public.tiff` — a rendered bitmap, produced **lazily**: the data is only made when a consumer
///   actually asks for pixels, and only for the type it asks for. The bitmap is the one the viewer
///   is already displaying, captured by reference at copy time — no new decode, and no second copy
///   of the pixels. For a source inside the decode budget that bitmap is the source's own
///   resolution; for an oversized source it is the bounded proxy, which is exactly why the file URL
///   is offered alongside it rather than instead of it. Placing both is what makes the semantics
///   honest: an app that wants the original takes the URL, an app that wants pixels takes the
///   bitmap, and neither is told it got the other.
///
/// This is the audit the spec asks for. `NSPasteboardItem` + `NSPasteboardItemDataProvider` is the
/// mechanism: `writeObjects` registers the provider and the pasteboard calls back on the main
/// thread only when a paste reads that type. The alternative — `NSPasteboardWriting`, which
/// `writeObjects` asks for a property list of *immediately* — would encode a TIFF every time the
/// user pressed Copy whether or not anything ever pasted it. Promised data (`NSPasteboard`'s
/// promised types) is for a producer that does not have the bytes yet; we do have them, we just do
/// not want to spend them unless asked.
public final class BitmapPasteboardProvider: NSObject, NSPasteboardItemDataProvider {
    /// The bitmap to encode on demand, held by reference.
    private let image: CGImage

    public init(image: CGImage) {
        self.image = image
    }

    public func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem,
                           provideDataForType type: NSPasteboard.PasteboardType) {
        guard type == .tiff else { return }
        guard let data = Self.tiffData(from: image) else { return }
        item.setData(data, forType: .tiff)
    }

    /// TIFF, because it is the type every AppKit consumer understands and it is lossless — a
    /// re-encode to JPEG here would be a silent quality decision on the user's behalf.
    static func tiffData(from image: CGImage) -> Data? {
        let rep = NSBitmapImageRep(cgImage: image)
        return rep.representation(using: .tiff, properties: [:])
    }

    /// The pixel size of what will be pasted, so the caller can say so in the menu without
    /// decoding anything.
    var pixelSize: CGSize { CGSize(width: image.width, height: image.height) }

    /// The bitmap itself, so a test can prove the pasted pixels are the *same object* the viewer is
    /// showing rather than a re-decode that happens to have the same dimensions.
    var imageForTesting: CGImage { image }
}

/// One place that writes an image to the general pasteboard, for the context menu and anything
/// else that copies.
public enum ImagePasteboardWriter {
    /// Writes `url` as the original and `image` as the pixels. Returns false when the pasteboard
    /// refused the write, which is the only failure mode a caller can act on.
    @discardableResult
    public static func write(fileURL: URL, image: CGImage,
                             to pasteboard: NSPasteboard = .general) -> Bool {
        let item = NSPasteboardItem()
        // The original, by reference.
        item.setString(fileURL.absoluteString, forType: .fileURL)
        // The pixels, on demand.
        item.setDataProvider(BitmapPasteboardProvider(image: image), forTypes: [.tiff])

        pasteboard.clearContents()
        return pasteboard.writeObjects([item])
    }
}
