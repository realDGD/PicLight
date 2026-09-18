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
        // Whole raw pixels: the row sink indexes rows and columns by integer offsets, and a
        // fractional origin turns into a one-pixel slice error (measured as two of three channels
        // differing across a whole tile). The previous region path quantized the same way through
        // `ps_rect(Int32(...))`, so this keeps the behaviour it replaced.
        let rawBounds = CGRect(origin: .zero, size: rawPixelSize)
        let requested = orientation.rawRect(forCanonicalRect: wantedCanonical, rawPixelSize: rawPixelSize)
        let wanted = CGRect(x: requested.minX.rounded(.down), y: requested.minY.rounded(.down),
                            width: requested.width.rounded(.down),
                            height: requested.height.rounded(.down))
            .intersection(rawBounds)
        guard wanted.width >= 1, wanted.height >= 1 else {
            throw NativeTileProviderError.decodeFailed("empty plan")
        }

        // One accumulator per tile. Rows are written straight into them as the stream passes, so
        // the decoder never holds a buffer as large as the plan: at 0.2 magnification a nine-grid
        // region is 3.4 GiB, while the tiles a viewport actually needs are a few hundred. This is
        // the difference between a warm area being affordable and being an OOM.
        var accumulators: [TileAccumulator] = plan.allCoordinates.map { coordinate in
            // Whole pixels here too: a fractional tile rect truncates differently for the column
            // offset and for the pixel count, which showed up as a one-column shift in the tile
            // (G, which depends only on y, survived; R and B did not).
            let planned = NativeTilePlanner.sourceRect(for: coordinate,
                                                       tileSize: plan.tileSize,
                                                       sourcePixelSize: canonicalPixelSize)
                .intersection(wantedCanonical)
            let canonicalRect = CGRect(x: planned.minX.rounded(.down), y: planned.minY.rounded(.down),
                                       width: planned.width.rounded(.down),
                                       height: planned.height.rounded(.down))
                .intersection(wantedCanonical)
            let rawRect = orientation.rawRect(forCanonicalRect: canonicalRect,
                                              rawPixelSize: rawPixelSize).intersection(wanted)
            return TileAccumulator(key: NativeTileKey(sourcePath: source.path, pageIndex: pageIndex,
                                                      tileSize: plan.tileSize,
                                                      x: coordinate.x, y: coordinate.y),
                                   canonicalRect: canonicalRect, rawRect: rawRect)
        }
        // Row ownership: which accumulators still need this row. Rows arrive in raw order.
        var pending = Array(accumulators.indices)
        var nextToDeliver = 0

        let context = RowContext(accumulators: accumulators)
        ps_set_row_callback(decoder, Unmanaged.passUnretained(context).toOpaque()) { rawContext, row, pixels, _ in
            guard let rawContext, let pixels else { return 0 }
            let context = Unmanaged<RowContext>.fromOpaque(rawContext).takeUnretainedValue()
            return context.write(row: Int(row), from: pixels) ? 1 : 0
        }

        func deliverReadyTiles(cancelled: Bool) {
            while nextToDeliver < accumulators.count {
                let accumulator = accumulators[nextToDeliver]
                guard accumulator.rowsWritten >= Int(accumulator.rawRect.height) else { return }
                nextToDeliver += 1
                guard !cancelled else { return }
                guard let tile = Self.makeTile(from: accumulator, orientation: orientation,
                                               rawPixelSize: rawPixelSize,
                                               colorSpace: colorSpace) else { continue }
                onTile(tile)
            }
        }
        _ = pending

        while true {
            if shouldCancel() {
                deliverReadyTiles(cancelled: true)
                return
            }
            let status = ps_step(decoder, &error, 256)
            if status < 0 {
                throw NativeTileProviderError.decodeFailed(String(cString: error))
            }
            deliverReadyTiles(cancelled: false)
            if status == 0 { break }
        }
        deliverReadyTiles(cancelled: false)
    }

    /// Copies one accumulator's pixels into canonical order and builds its image.
    private static func makeTile(from accumulator: TileAccumulator,
                                 orientation: SourceOrientation,
                                 rawPixelSize: CGSize,
                                 colorSpace: CGColorSpace?) -> NativeTile? {
        let rect = accumulator.rawRect
        guard rect.width >= 1, rect.height >= 1 else { return nil }
        let space = colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        let canonical = orientation.canonicalPixels(fromRawBuffer: accumulator.pixels,
                                                    rawRect: rect, rawPixelSize: rawPixelSize)
        guard canonical.size.width >= 1, canonical.size.height >= 1,
              let provider = CGDataProvider(data: Data(canonical.pixels) as CFData),
              let image = CGImage(
                width: Int(canonical.size.width), height: Int(canonical.size.height),
                bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: Int(canonical.size.width) * 4, space: space,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
              ) else { return nil }
        return NativeTile(key: accumulator.key, sourceRect: accumulator.canonicalRect, image: image)
    }
}

/// The row sink's state: for each incoming scanline, copy the column ranges that belong to the
/// tiles whose vertical span covers it. Kept out of the decoder on purpose — the C side only
/// knows about rows.
private final class RowContext {
    private let accumulators: [TileAccumulator]

    init(accumulators: [TileAccumulator]) {
        self.accumulators = accumulators
    }

    /// Returns false when every tile has all its rows, so the decode can stop early.
    func write(row: Int, from pixels: UnsafePointer<UInt8>) -> Bool {
        var stillNeeded = false
        for accumulator in accumulators {
            let rect = accumulator.rawRect
            guard rect.width >= 1, rect.height >= 1 else { continue }
            let rowIndex = row - Int(rect.minY)
            guard rowIndex >= 0, rowIndex < Int(rect.height) else {
                if accumulator.rowsWritten < Int(rect.height) { stillNeeded = true }
                continue
            }
            if rowIndex != accumulator.rowsWritten { continue }
            let width = Int(rect.width)
            // Absolute, not relative to the decoded region: the row handed to this sink is a whole
            // image scanline (the decoder expands from column 0), so subtracting the region origin
            // reads a tile's pixels from the wrong part of the row — visible as a tile whose
            // content is a different source column.
            let sourceOffset = Int(rect.minX) * 4
            let targetOffset = rowIndex * width * 4
            accumulator.pixels.withUnsafeMutableBytes { destination in
                guard let base = destination.baseAddress else { return }
                memcpy(base + targetOffset, pixels + sourceOffset, width * 4)
            }
            accumulator.rowsWritten += 1
            if accumulator.rowsWritten < Int(rect.height) { stillNeeded = true }
        }
        return stillNeeded
    }
}

/// Per-tile pixel storage with the bookkeeping the row sink needs.
private final class TileAccumulator: @unchecked Sendable {
    let key: NativeTileKey
    let canonicalRect: CGRect
    let rawRect: CGRect
    var pixels: [UInt8]
    var rowsWritten = 0

    init(key: NativeTileKey, canonicalRect: CGRect, rawRect: CGRect) {
        self.key = key
        self.canonicalRect = canonicalRect
        self.rawRect = rawRect
        self.pixels = [UInt8](repeating: 0, count: max(1, Int(rawRect.width) * Int(rawRect.height) * 4))
    }
}

