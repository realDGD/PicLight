import XCTest
import CoreGraphics
@testable import PicViewMac

/// The warm-area policy, pinned against the measurements it was chosen from
/// (`benchmarks/LargeImagePolicyBench/results/warm-strategy-sweep.txt`).
final class WarmAreaPolicyTests: XCTestCase {

    private let source = CGSize(width: 48000, height: 32000)
    private let tileSize = 512

    private func visible(width: Double, height: Double) -> CGRect {
        CGRect(x: (source.width - width) / 2, y: (source.height - height) / 2,
               width: width, height: height)
    }

    /// One viewport in each direction, when the budget allows it: the nine-grid the user asked for.
    func testAFullNineGridIsChosenWhenItFitsTheBudget() throws {
        // 100 %: measured at 150 tiles / 150 MiB, so a 256 MiB budget takes the whole thing.
        let plan = try XCTUnwrap(WarmAreaPolicy.plan(visible: visible(width: 2400, height: 1600),
                                                     sourcePixelSize: source, tileSize: tileSize,
                                                     cpuBudgetBytes: 256 * 1024 * 1024))
        XCTAssertEqual(plan.margin, 1.0, accuracy: 0.001)
        XCTAssertFalse(plan.clampedByBudget)
        // The decode rect covers the three-viewport rectangle, rounded out to whole tiles: it is
        // the union of the tiles that intersect it, not the rectangle itself.
        XCTAssertGreaterThanOrEqual(plan.plan.decodeRect.width, 2400 * 3 - 1)
        XCTAssertLessThanOrEqual(plan.plan.decodeRect.width, 2400 * 3 + Double(tileSize) * 2)
    }

    /// The dangerous case: at 0.2 the same nine-grid measured 3.38 GiB, so the margin has to come
    /// down instead of the process doing it.
    func testTheMarginStepsDownWhenTheNineGridWouldBeHuge() throws {
        let plan = try XCTUnwrap(WarmAreaPolicy.plan(visible: visible(width: 12000, height: 8000),
                                                     sourcePixelSize: source, tileSize: tileSize,
                                                     cpuBudgetBytes: 256 * 1024 * 1024))
        // At 0.2 the viewport itself is 408 MiB (measured), so no margin fits a 256 MiB budget and
        // the policy's answer is the honest one: visible only, and it says it was clamped.
        XCTAssertTrue(plan.clampedByBudget, "0.2 must not take a 3.4 GiB warm area")
        XCTAssertEqual(plan.margin, 0, accuracy: 0.001)
        XCTAssertEqual(plan.plan.allCoordinates.count, plan.plan.visible.count)
        let bytes = WarmAreaPolicy.tileBytes(plan.plan.allCoordinates, sourcePixelSize: source,
                                              tileSize: tileSize)
        XCTAssertGreaterThan(bytes, 0)
        XCTAssertLessThan(bytes, 512 * 1024 * 1024, "and it stays a viewport's worth, not 3.4 GiB")
    }

    /// Visible tiles are never dropped, whatever the budget: a blurry viewport is worse than a full
    /// budget, and the task makes visible the top priority.
    func testVisibleTilesSurviveABudgetTooSmallForThem() throws {
        // A source that is oversized with a viewport large enough to exceed the budget on its own.
        let plan = try XCTUnwrap(WarmAreaPolicy.plan(visible: visible(width: 12000, height: 8000),
                                                     sourcePixelSize: source, tileSize: tileSize,
                                                     cpuBudgetBytes: 8 * 1024 * 1024))
        XCTAssertEqual(plan.margin, 0, accuracy: 0.001)
        XCTAssertTrue(plan.clampedByBudget)
        XCTAssertFalse(plan.plan.visible.isEmpty, "the viewport's tiles are always included")
        XCTAssertGreaterThan(plan.plan.visible.count, 100)
    }

    /// Panning one viewport in any direction must land inside the warm area — the whole point.
    func testOneViewportOfPanStaysInsideTheWarmArea() throws {
        let rect = visible(width: 2400, height: 1600)
        let plan = try XCTUnwrap(WarmAreaPolicy.plan(visible: rect, sourcePixelSize: source,
                                                     tileSize: tileSize,
                                                     cpuBudgetBytes: 256 * 1024 * 1024))
        for offset in [CGPoint(x: -2400, y: 0), CGPoint(x: 2400, y: 0),
                       CGPoint(x: 0, y: -1600), CGPoint(x: 0, y: 1600)] {
            let panned = rect.offsetBy(dx: offset.x, dy: offset.y)
            XCTAssertTrue(plan.plan.decodeRect.contains(panned),
                          "a one-viewport pan to \(offset) must stay warm")
        }
    }

    /// Visible first, then nearest; a direction hint pulls that side forward without starving the
    /// other.
    func testOrderingIsVisibleFirstAndBiasedInTheDirectionOfTravel() throws {
        let rect = visible(width: 2400, height: 1600)
        let plan = try XCTUnwrap(WarmAreaPolicy.plan(visible: rect, sourcePixelSize: source,
                                                     tileSize: tileSize,
                                                     cpuBudgetBytes: 256 * 1024 * 1024))
        let visibleKeys = Set(plan.plan.visible)
        XCTAssertEqual(plan.plan.allCoordinates.prefix(visibleKeys.count).filter {
            visibleKeys.contains($0)
        }.count, visibleKeys.count, "visible tiles come first")

        let right = WarmAreaPolicy.order(plan: plan.plan, visibleRect: rect, sourcePixelSize: source,
                                         tileSize: tileSize, directionHint: CGVector(dx: 1, dy: 0))
        let left = WarmAreaPolicy.order(plan: plan.plan, visibleRect: rect, sourcePixelSize: source,
                                        tileSize: tileSize, directionHint: CGVector(dx: -1, dy: 0))
        XCTAssertNotEqual(right, left, "the hint changes the order")
        // Same tiles, different order — a hint must never change *what* is warm.
        XCTAssertEqual(Set(right), Set(left))
    }

    /// The step-down is visible in the middle range: at 0.5 the full nine-grid measured 580 MiB,
    /// so a 256 MiB budget takes a smaller margin, and a 1 GiB budget takes the whole nine-grid.
    func testTheMiddleRangeClampsToASmallerMargin() throws {
        let rect = visible(width: 4800, height: 3200)
        let tight = try XCTUnwrap(WarmAreaPolicy.plan(visible: rect, sourcePixelSize: source,
                                                     tileSize: tileSize,
                                                     cpuBudgetBytes: 256 * 1024 * 1024))
        XCTAssertTrue(tight.clampedByBudget)
        XCTAssertGreaterThan(tight.margin, 0, "0.5 is affordable at some margin")
        XCTAssertLessThan(tight.margin, 1.0)
        let tightBytes = WarmAreaPolicy.tileBytes(tight.plan.allCoordinates,
                                                   sourcePixelSize: source, tileSize: tileSize)
        XCTAssertLessThanOrEqual(tightBytes, 256 * 1024 * 1024)

        let generous = try XCTUnwrap(WarmAreaPolicy.plan(visible: rect, sourcePixelSize: source,
                                                        tileSize: tileSize,
                                                        cpuBudgetBytes: 1024 * 1024 * 1024))
        XCTAssertEqual(generous.margin, 1.0, accuracy: 0.001)
        XCTAssertFalse(generous.clampedByBudget)
    }

    func testNoMarginForAViewportLargerThanTheSource() throws {
        let plan = try XCTUnwrap(WarmAreaPolicy.plan(visible: CGRect(origin: .zero, size: source),
                                                     sourcePixelSize: source, tileSize: tileSize,
                                                     cpuBudgetBytes: 256 * 1024 * 1024))
        XCTAssertEqual(plan.margin, 0, accuracy: 0.001)
        XCTAssertEqual(plan.plan.decodeRect, CGRect(origin: .zero, size: source))
    }
}
