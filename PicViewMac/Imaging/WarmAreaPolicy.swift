import CoreGraphics
import Foundation

/// How much of the nine-grid around the viewport to keep warm.
///
/// The target from real use is "one viewport in every direction", so panning up to a screen in any
/// direction lands on tiles that are already decoded (and, within the GPU budget, already
/// uploaded). A *fixed* nine-grid cannot be the policy: measured on the investigation image
/// (`bench/warmbench`, results/warm-strategy-sweep.txt), the same nine-grid costs
///
///     physicalScale 0.2 → 3456 tiles → 3.38 GiB      1.0 → 150 tiles → 150 MiB
///     physicalScale 0.5 →  580 tiles →  580 MiB      2.0 →  48 tiles →  48 MiB
///
/// because at 0.2 the viewport itself covers 12000×8000 source pixels. So the warm area is a
/// *desire* that gets clamped against a byte budget, and the clamp runs the margin down in steps —
/// the stepped search the task asked for, with the step values fixed by the sweep rather than by
/// taste: 1.0 is the full nine-grid, 0.25 is one tile ring-ish, 0 is visible only.
public struct WarmAreaPlan: Equatable, Sendable {
    /// A plan the rest of the pipeline already understands: `visible` is what is on screen and
    /// `ring` is the warm area around it, in the order they should be asked for.
    public let plan: NativeTilePlan
    /// The margin actually used after clamping, in multiples of the viewport.
    public let margin: CGFloat
    /// True when the budget forced a smaller margin than requested.
    public let clampedByBudget: Bool
}

public enum WarmAreaPolicy {
    /// One viewport in each direction: the nine-grid.
    public static let requestedMargin: CGFloat = 1.0
    /// Margins tried in order. Measured tile bytes per step are in the sweep; the policy takes the
    /// first that fits, which is why the steps are coarse — a finer search would chase bytes the
    /// user cannot feel, at the cost of a bigger change in pan coverage.
    public static let marginSteps: [CGFloat] = [1.0, 0.75, 0.5, 0.25, 0.0]

    /// The warm plan for a viewport.
    ///
    /// Visible tiles are never dropped, whatever the budget: the tile that has to be sharp is the
    /// one on screen (§15 of the task). If even those exceed the budget, the margin is 0 and the
    /// caller still gets them — the alternative is a blurry viewport, which is worse than a full
    /// budget.
    public static func plan(visible: CGRect,
                            sourcePixelSize: CGSize,
                            tileSize: Int,
                            cpuBudgetBytes: Int,
                            margin: CGFloat = requestedMargin,
                            directionHint: CGVector = .zero) -> WarmAreaPlan? {
        guard visible.width >= 1, visible.height >= 1, tileSize > 0 else { return nil }
        let bounds = CGRect(origin: .zero, size: sourcePixelSize)
        let steps = ([margin] + marginSteps.filter { $0 < margin }).map { $0 }
        var fallback: WarmAreaPlan?

        for (index, candidate) in steps.enumerated() {
            let warm = visible.insetBy(dx: -visible.width * candidate,
                                       dy: -visible.height * candidate)
                .intersection(bounds)
            guard let plan = NativeTilePlanner.plan(sourceRect: warm, sourcePixelSize: sourcePixelSize,
                                                    tileSize: tileSize, ring: 0) else { continue }
            let visibleKeys = Set(plan.allCoordinates.filter {
                !NativeTilePlanner.sourceRect(for: $0, tileSize: tileSize,
                                              sourcePixelSize: sourcePixelSize)
                    .intersection(visible).isNull
            })
            let bytes = tileBytes(plan.allCoordinates, sourcePixelSize: sourcePixelSize,
                                  tileSize: tileSize)
            let ordered = order(plan: plan, visibleRect: visible, sourcePixelSize: sourcePixelSize,
                                tileSize: tileSize, directionHint: directionHint)
            let visibleTiles = ordered.filter { visibleKeys.contains($0) }
            let warmTiles = ordered.filter { !visibleKeys.contains($0) }
            let shaped = NativeTilePlan(tileSize: plan.tileSize, visible: visibleTiles,
                                        ring: warmTiles, decodeRect: plan.decodeRect)
            let result = WarmAreaPlan(plan: shaped, margin: candidate, clampedByBudget: index > 0)
            if fallback == nil { fallback = result }
            if bytes <= cpuBudgetBytes || candidate == 0 { return result }
        }
        return fallback
    }

    /// The hint is the movement of the *visible rectangle in source space*, which is what the
    /// viewer measures: the side the viewport is travelling toward is the side that will enter it.
    /// Normalised, so only the direction matters, and it changes ordering only — never the warm set.
    public static func directionHint(from previous: CGRect?, to current: CGRect) -> CGVector {
        guard let previous, previous.width > 0, previous.height > 0 else { return .zero }
        let dx = current.midX - previous.midX
        let dy = current.midY - previous.midY
        let length = hypot(dx, dy)
        // Below a few percent of a viewport this is re-layout noise, not travel.
        guard length > max(current.width, current.height) * 0.03 else { return .zero }
        return CGVector(dx: dx / length, dy: dy / length)
    }

    /// Tile bytes for a set of coordinates, following the same clipping the provider uses.
    public static func tileBytes(_ coordinates: [TileCoordinate], sourcePixelSize: CGSize,
                                 tileSize: Int) -> Int {
        var total = 0
        for coordinate in coordinates {
            let rect = NativeTilePlanner.sourceRect(for: coordinate, tileSize: tileSize,
                                                   sourcePixelSize: sourcePixelSize)
            total += Int(rect.width) * Int(rect.height) * 4
        }
        return total
    }

    /// Visible tiles first, then the rest outward from the viewport centre.
    ///
    /// `directionHint` biases the ordering toward where the user is moving: a tile in that
    /// direction is treated as closer than it is, so a pan in progress is covered before the area
    /// behind it. The bias is a fraction of a viewport, not a hard partition — a large intent
    /// should not starve the opposite side if the user turns around.
    public static func order(plan: NativeTilePlan, visibleRect: CGRect, sourcePixelSize: CGSize,
                             tileSize: Int, directionHint: CGVector = .zero) -> [TileCoordinate] {
        let centre = CGPoint(x: visibleRect.midX, y: visibleRect.midY)
        let scale = max(visibleRect.width, visibleRect.height)
        func score(_ coordinate: TileCoordinate) -> (Int, CGFloat) {
            let rect = NativeTilePlanner.sourceRect(for: coordinate, tileSize: tileSize,
                                                    sourcePixelSize: sourcePixelSize)
            let isVisible = !rect.intersection(visibleRect).isNull
            let dx = rect.midX - centre.x, dy = rect.midY - centre.y
            // A tile 0.5 viewports in the direction of travel scores as if it were at the centre.
            let biasedX = dx - directionHint.dx * scale * 0.5
            let biasedY = dy - directionHint.dy * scale * 0.5
            return (isVisible ? 0 : 1, hypot(biasedX, biasedY))
        }
        return plan.allCoordinates.sorted {
            let a = score($0), b = score($1)
            return a.0 != b.0 ? a.0 < b.0 : a.1 < b.1
        }
    }
}
