import Foundation

/// The single predicate for "this source is too large for a native decode".
///
/// Neighbour preload and the thumbnail drawer both ask this question, and the
/// answer must be identical in both places: preloading an oversized neighbour
/// cannot be cancelled once started (ImageIO ignores task cancellation), and a
/// drawer full of oversized items must not launch a stream decode per cell.
public enum OversizedPolicy {
    /// Unknown dimensions count as oversized on purpose — the same asymmetry as
    /// `DecodeBudget`: a needless bounded decode costs sharpness, a needless
    /// native decode can cost gigabytes.
    public static func isOversized(sourceLongEdge: Int?) -> Bool {
        guard let longEdge = sourceLongEdge, longEdge > 0 else { return true }
        return longEdge > DecodeBudget.maximumLongEdge
    }
}
