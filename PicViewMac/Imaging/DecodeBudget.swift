import CoreGraphics

/// Which decode a source should get.
///
/// `native` means the source's own pixels, which the design only allows up to the
/// hard ceiling. `bucket` means a bounded ImageIO thumbnail request of that long
/// edge. The level is part of decode identity, so it is `Hashable` and carried in
/// the cache key rather than recomputed at lookup time.
public enum DecodeLevel: Hashable, Sendable {
    case native
    case bucket(Int)

    /// Stable token for cache keys. Internal on purpose: `DecodeCache` is the only
    /// place allowed to turn identity into a string.
    var token: String {
        switch self {
        case .native: return "native"
        case let .bucket(edge): return "b\(edge)"
        }
    }
}

/// The decode-budget policy (spec §4.1 + §5.3, parameters frozen by the E1
/// benchmark): a source at or below `maximumLongEdge` is decoded natively so
/// ordinary photographs keep their resolution; anything larger is bounded to a
/// bucket derived from the canvas's physical requirement, with a fixed overscan.
///
/// The view-sized requirement can over-allocate by one bucket in short-wide
/// windows. That is accepted and documented in the spec: the extra density is the
/// zoom headroom available before a level change, and every level change is a full
/// stream decode.
public enum DecodeBudget {
    public static let maximumLongEdge = 8192
    public static let buckets = [1024, 2048, 4096, 8192]
    public static let overscan: CGFloat = 1.5

    public static var smallestBucket: Int { buckets[0] }

    /// The level for a source whose budget is already known.
    ///
    /// Used by `DecodeCoordinator` to *predict* the cache key before decoding, from a
    /// cheap header probe plus the caller's budget. It must agree with
    /// `level(sourceLongEdge:canvasPoints:backingScale:)` — a test asserts they do —
    /// because a lookup at a different level than the store can never hit.
    public static func level(sourceLongEdge: Int?, budget: Int?) -> DecodeLevel {
        guard let longEdge = sourceLongEdge, longEdge > 0 else { return .bucket(smallestBucket) }
        guard longEdge > maximumLongEdge else { return .native }
        let requested = budget ?? maximumLongEdge
        return .bucket(bucket(atLeast: min(max(requested, 1), maximumLongEdge)))
    }

    /// Longest edge the canvas can actually resolve, before bucket snapping.
    public static func requiredLongEdge(canvasPoints: CGSize, backingScale: CGFloat) -> Int {
        let scale = max(backingScale, 0.1)              // a bogus scale must not yield a zero budget
        let needed = max(canvasPoints.width, canvasPoints.height) * scale * overscan
        guard needed.isFinite, needed > 0 else { return 0 }
        return Int(needed.rounded(.up))
    }

    /// Smallest bucket that covers `longEdge`, clamped to the hard ceiling.
    public static func bucket(atLeast longEdge: Int) -> Int {
        for bucket in buckets where bucket >= longEdge { return bucket }
        return maximumLongEdge
    }

    /// The level to request for a source shown on a canvas of this size.
    ///
    /// Unknown dimensions (`sourceLongEdge <= 0`, e.g. an unreadable header) are
    /// treated as oversized deliberately: a wrong bounded decode costs sharpness,
    /// a wrong native decode can cost gigabytes.
    public static func level(sourceLongEdge: Int, canvasPoints: CGSize,
                             backingScale: CGFloat) -> DecodeLevel {
        guard sourceLongEdge > 0 else { return .bucket(smallestBucket) }
        guard sourceLongEdge > maximumLongEdge else { return .native }
        let required = requiredLongEdge(canvasPoints: canvasPoints, backingScale: backingScale)
        return .bucket(bucket(atLeast: required))
    }

    /// The pixel budget to hand to ImageIO, or nil when the source decodes natively.
    public static func pixelBudget(for level: DecodeLevel) -> Int? {
        switch level {
        case .native: return nil
        case let .bucket(edge): return edge
        }
    }
}
