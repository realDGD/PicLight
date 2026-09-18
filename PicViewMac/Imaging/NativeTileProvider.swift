import CoreGraphics
import Foundation
import PicPNGStream

public enum NativeTileProviderError: Error, LocalizedError {
    case unsupported(String)
    case openFailed(String)
    case decodeFailed(String)

    public var errorDescription: String? {
        switch self {
        case let .unsupported(reason): return "此格式暂不支持原生细节：\(reason)"
        case let .openFailed(reason): return "无法打开文件：\(reason)"
        case let .decodeFailed(reason): return "解码失败：\(reason)"
        }
    }
}

/// Produces native-detail tiles for a plan.
///
/// One pass covers the whole plan: the decoder inflates the stream once and we keep the
/// rows inside the plan's rectangle, so the visible viewport becomes native detail after a
/// single traversal instead of one traversal per tile. Rows outside the rectangle are
/// inflated and thrown away — that is the price of PNG's filter chain, where row *n*
/// cannot be reconstructed without rows 0…n-1 — and the saving is that nothing else is
/// ever allocated.
/// Whether the native-detail backend can serve a file at all.
///
/// Opening reads only the header chunks (the decoder refuses interlaced and 16-bit sources
/// by name), so this is a 30-byte question. The answer gates the *decision* to stand the
/// whole-image level path down: a source the tiles cannot serve must keep its level
/// upgrades, or the viewport would get neither tiles nor a sharper proxy.
public enum NativeTileCapability {
    public static func canServe(_ url: URL) -> Bool {
        var info = ps_info()
        var error = [CChar](repeating: 0, count: 256)
        guard let decoder = url.path.withCString({ ps_open($0, &info, &error, 256) }) else {
            return false
        }
        ps_close(decoder)
        return true
    }
}

public protocol NativeTileProviding: Sendable {
    func produce(plan: NativeTilePlan,
                 source: URL,
                 pageIndex: Int,
                 gutter: Int,
                 colorSpace: CGColorSpace?,
                 orientation: SourceOrientation,
                 shouldCancel: @Sendable () -> Bool,
                 onTile: @Sendable (NativeTile) -> Void) throws
}

private struct PendingTile {
    let key: NativeTileKey
    let coordinate: TileCoordinate
    /// In canonical oriented space: what the plan asked for and what the renderer places.
    let canonicalRect: CGRect
    /// In raw PNG space, clipped to the decoded region: what the buffer holds.
    let sourceRect: CGRect
}

/// The PNG implementation, over the streaming decoder.
public struct PNGNativeTileProvider: NativeTileProviding {
    public init() {}

    public func produce(plan: NativeTilePlan,
                        source: URL,
                        pageIndex: Int,
                        gutter: Int,
                        colorSpace: CGColorSpace?,
                        orientation: SourceOrientation,
                        shouldCancel: @Sendable () -> Bool,
                        onTile: @Sendable (NativeTile) -> Void) throws {
        var info = ps_info()
        var error = [CChar](repeating: 0, count: 256)
        guard let decoder = source.path.withCString({ ps_open($0, &info, &error, 256) }) else {
            let message = String(cString: error)
            throw message.contains("unsupported") || message.contains("interlaced")
                ? NativeTileProviderError.unsupported(message)
                : NativeTileProviderError.openFailed(message)
        }
        defer { ps_close(decoder) }

        // Two spaces are in play. The plan is expressed in *canonical oriented* source space —
        // the same space `RenderImage.sourcePixelSize` describes, and the space the proxy is
        // drawn in — while the decoder reads raw PNG rows. The conversion happens here and
        // nowhere else.
        let rawPixelSize = CGSize(width: CGFloat(info.width), height: CGFloat(info.height))
        let canonicalPixelSize = orientation.canonicalPixelSize(rawPixelSize: rawPixelSize)
        let imageBounds = CGRect(origin: .zero, size: canonicalPixelSize)
        // Grow by the gutter so even the outermost plan tiles have real neighbour pixels to
        // sample at their edges, and clip so we never ask for pixels that do not exist.
        let wantedCanonical = plan.decodeRect.insetBy(dx: -CGFloat(gutter), dy: -CGFloat(gutter))
            .intersection(imageBounds)
        let wanted = orientation.rawRect(forCanonicalRect: wantedCanonical, rawPixelSize: rawPixelSize)
        guard wanted.width >= 1, wanted.height >= 1 else {
            throw NativeTileProviderError.decodeFailed("empty plan")
        }
        let region = ps_rect(x: Int32(wanted.minX), y: Int32(wanted.minY),
                             width: Int32(wanted.width), height: Int32(wanted.height))
        guard ps_set_region(decoder, region) == 1 else {
            throw NativeTileProviderError.decodeFailed(
                "cannot hold a \(Int(wanted.width))×\(Int(wanted.height)) region")
        }

        let pending: [PendingTile] = plan.allCoordinates.map { coordinate in
            // The tile's canonical rectangle is what the plan and the renderer speak; the raw
            // rectangle is what the region buffer holds.
            let canonicalRect = NativeTilePlanner.sourceRect(for: coordinate, tileSize: plan.tileSize,
                                                             sourcePixelSize: canonicalPixelSize)
                .intersection(wantedCanonical)
            let rawRect = orientation.rawRect(forCanonicalRect: canonicalRect,
                                              rawPixelSize: rawPixelSize)
                .intersection(wanted)
            return PendingTile(key: NativeTileKey(sourcePath: source.path, pageIndex: pageIndex,
                                                  tileSize: plan.tileSize,
                                                  x: coordinate.x, y: coordinate.y),
                               coordinate: coordinate,
                               canonicalRect: canonicalRect,
                               sourceRect: rawRect)
        }

        var nextToDeliver = 0
        let regionStride = Int(wanted.width) * 4

        func deliverReadyTiles(decodedRows: Int) {
            while nextToDeliver < pending.count {
                let candidate = pending[nextToDeliver]
                // Rows arrive in raw order, so readiness is a raw-space question.
                guard decodedRows >= Int(candidate.sourceRect.maxY) else { return }
                nextToDeliver += 1
                if let tile = Self.slice(candidate: candidate, wanted: wanted,
                                         regionStride: regionStride, decoder: decoder,
                                         colorSpace: colorSpace, orientation: orientation,
                                         rawPixelSize: rawPixelSize) {
                    onTile(tile)
                }
            }
        }

        while true {
            if shouldCancel() { return }
            let status = ps_step(decoder, &error, 256)
            if status < 0 {
                throw NativeTileProviderError.decodeFailed(String(cString: error))
            }
            deliverReadyTiles(decodedRows: Int(ps_rows_done(decoder)))
            if status == 0 { break }
        }
        deliverReadyTiles(decodedRows: Int(info.height))
    }

    /// Copies one tile out of the region buffer into an image of its own.
    ///
    /// The image carries its own source rectangle, so the renderers draw the whole texture
    /// over it and never do texture-coordinate arithmetic. Tiles overlap by the gutter when
    /// they have one, which is harmless — the overlapping pixels are the same pixels.
    private static func slice(candidate: PendingTile,
                             wanted: CGRect,
                             regionStride: Int,
                             decoder: OpaquePointer,
                             colorSpace: CGColorSpace?,
                             orientation: SourceOrientation,
                             rawPixelSize: CGSize) -> NativeTile? {
        guard let base = ps_region_pixels(decoder) else { return nil }
        let rect = candidate.sourceRect
        guard rect.width >= 1, rect.height >= 1 else { return nil }

        let width = Int(rect.width)
        let height = Int(rect.height)
        let offsetX = Int(rect.minX - wanted.minX)
        let offsetY = Int(rect.minY - wanted.minY)
        let storedStride = width * 4

        var pixels = [UInt8](repeating: 0, count: storedStride * height)
        pixels.withUnsafeMutableBytes { destination in
            guard let target = destination.baseAddress else { return }
            for row in 0..<height {
                let source = base + (offsetY + row) * regionStride + offsetX * 4
                memcpy(target + row * storedStride, source, storedStride)
            }
        }

        // The pixels are the file's own bytes, so they must carry the file's colour space.
        // Tagging them sRGB made a profiled source render with shifted colour next to the
        // proxy, which ImageIO had colour-managed — visible on the investigation image as a
        // measurable difference from the source pixels. The proxy's space is the same
        // interpretation ImageIO arrived at, so taking it from there keeps the base layer
        // and the tiles consistent.
        let space = colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        // Raw order → canonical order. For an `.up` source this is a no-op, which is why the
        // whole orientation path stayed untested until a file with metadata met it.
        let canonical = orientation.canonicalPixels(fromRawBuffer: pixels, rawRect: rect,
                                                    rawPixelSize: rawPixelSize)
        guard let provider = CGDataProvider(data: Data(canonical.pixels) as CFData),
              let image = CGImage(
                width: Int(canonical.size.width), height: Int(canonical.size.height),
                bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: Int(canonical.size.width) * 4, space: space,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
              ) else { return nil }

        return NativeTile(key: candidate.key, sourceRect: candidate.canonicalRect, image: image)
    }
}
