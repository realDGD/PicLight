import Foundation
import CoreGraphics

/// A3 materialization: turn the lazy `CGImage` ImageIO returns into a bitmap whose
/// pixels are already resident, so the renderer's first draw cannot trigger a full
/// decode.
///
/// Measured on the investigation image: letting the lazy image reach the renderer
/// put 19 s of decoding inside that draw and peaked at 5.8 GiB, while delivering a
/// materialized bitmap made the draw 58 ms. The gate numbers live in
/// `docs/superpowers/specs/…-design.md` §17.5 and
/// `benchmarks/LargeImagePolicyBench/results/gates-A.txt`.
///
/// This is a **synchronous CPU operation**. `ImageIODecoder` already runs inside
/// `Task.detached`, so materializing must not spawn a second task — a nested task
/// only muddles priority, cancellation and test tracing.
public enum BitmapMaterializer {

    /// Number of materializations performed in this process. A counting seam for
    /// tests that prove the delivered bitmap is not re-materialized later; it is
    /// deliberately not a flag on the produced image, which would only assert
    /// itself.
    private(set) nonisolated(unsafe) static var materializations = 0

    /// Draws `image` into a fresh bitmap and returns it.
    ///
    /// Returns `image` unchanged only when no context can be created at all: a
    /// failure then degrades to today's behaviour instead of losing the frame.
    public static func materialize(_ image: CGImage) -> CGImage {
        guard image.width > 0, image.height > 0 else { return image }
        for plan in plans(for: image) {
            guard let context = CGContext(
                data: nil, width: image.width, height: image.height,
                bitsPerComponent: plan.bitsPerComponent, bytesPerRow: 0,
                space: plan.colorSpace, bitmapInfo: plan.bitmapInfo
            ) else { continue }
            context.interpolationQuality = .none          // 1:1 copy, no resampling
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            if let materialized = context.makeImage() {
                materializations += 1
                return materialized
            }
        }
        return image
    }

    struct Plan {
        let bitsPerComponent: Int
        let colorSpace: CGColorSpace
        let bitmapInfo: UInt32
    }

    /// Context plans in order of preference (spec §7: materialization must not
    /// reduce precision).
    ///
    /// Measured with the fixtures this policy was written against:
    /// * indexed PNG arrives as `bpp = 8` with **`colorSpace == nil`**, so a plan
    ///   must never dereference the source space — the palette is expanded into
    ///   sRGB instead, which is lossless for 8-bit palette entries;
    /// * 16-bit PNG/TIFF arrive as `bpc = 16` and ImageIO also returns 16-bit from
    ///   the bounded path, so the depth is preserved end to end rather than
    ///   flattened to 8-bit.
    static func plans(for image: CGImage) -> [Plan] {
        var plans: [Plan] = []
        let depth = image.bitsPerComponent
        let space = image.colorSpace

        if depth > 8, let space {
            let info = image.bitmapInfo.contains(.floatComponents)
                ? CGBitmapInfo.floatComponents.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
                : CGImageAlphaInfo.premultipliedLast.rawValue
            plans.append(Plan(bitsPerComponent: depth, colorSpace: space, bitmapInfo: info))
        }
        if let space {
            plans.append(Plan(bitsPerComponent: 8, colorSpace: space,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        }
        // Last resort, and the only plan for an indexed image: sRGB at 8 bits.
        // Deliberately not device RGB — the viewer never flattens to an unmanaged
        // device space.
        if let sRGB = CGColorSpace(name: CGColorSpace.sRGB) {
            plans.append(Plan(bitsPerComponent: 8, colorSpace: sRGB,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        }
        return plans
    }
}
