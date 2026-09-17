import CoreGraphics
import Foundation

/// Whether a window resize should buy a new bounded decode (spec §9.5).
///
/// Only oversized sources have decode levels, so this is a no-op for ordinary
/// images. For an oversized source the answer is "keep what is on screen" unless
/// the geometry has settled, the user has stopped dragging, and the bitmap is
/// genuinely undersampled for the new canvas — every level change is a full
/// stream decode (measured: ~16 s on the 1.9 GiB investigation image), which is
/// exactly the cost the bounded design exists to avoid paying casually.
///
/// The decision is pure so the rules can be tested without a window.
public enum ResizeUpgradePolicy {
    /// §9.5 asks for "~300 ms after the resize settles".
    public static let debounce: TimeInterval = 0.3

    /// The level to decode for, or `nil` to keep the bitmap on screen.
    ///
    /// `current` is the level of the bitmap being displayed. `zoomScale` is in
    /// points per source pixel, matching `ViewportState`, so the zoom term asks for
    /// what the current magnification can actually resolve rather than what the
    /// whole canvas could.
    public static func level(current: DecodeLevel,
                             sourcePixelSize: CGSize,
                             canvasPoints: CGSize,
                             backingScale: CGFloat,
                             zoomScale: CGFloat,
                             quarterTurns: Int,
                             isInteracting: Bool) -> DecodeLevel? {
        // A drag is never a moment to start a 16 s decode.
        guard !isInteracting else { return nil }
        let sourceLongEdge = Int(max(sourcePixelSize.width, sourcePixelSize.height).rounded())
        guard sourceLongEdge > DecodeBudget.maximumLongEdge else { return nil }

        let displayed = ViewportState.displayedPixelSize(sourcePixelSize, quarterTurns: quarterTurns)
        let magnified = CGSize(width: displayed.width * max(zoomScale, 0),
                               height: displayed.height * max(zoomScale, 0))
        let zoomRequirement = Int((max(magnified.width, magnified.height) * max(backingScale, 0.1))
            .rounded(.up))
        let canvasRequirement = DecodeBudget.requiredLongEdge(canvasPoints: canvasPoints,
                                                              backingScale: backingScale)
        let candidate = DecodeLevel.bucket(
            DecodeBudget.bucket(atLeast: max(canvasRequirement, zoomRequirement))
        )
        return isCoarser(candidate, than: current) ? candidate : nil
    }

    /// `.native` is the finest level there is; buckets order by long edge, so a
    /// smaller bucket is already covered by a larger one and never escalates.
    static func isCoarser(_ candidate: DecodeLevel, than current: DecodeLevel) -> Bool {
        switch (candidate, current) {
        case let (.bucket(candidateEdge), .bucket(currentEdge)): return candidateEdge > currentEdge
        case (.bucket, .native): return false
        case (.native, .bucket): return true
        case (.native, .native): return false
        }
    }
}
