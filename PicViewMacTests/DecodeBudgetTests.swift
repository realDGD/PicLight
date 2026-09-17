import XCTest
import CoreGraphics
@testable import PicViewMac

/// The decode-budget policy. The bucket column of the E1 gate matrix is pinned
/// here so the formula cannot drift away from the measured decision, and the
/// "≤8192 stays native" rule is pinned because it is what keeps ordinary
/// photographs from being permanently softened (spec §5.1).
final class DecodeBudgetTests: XCTestCase {

    private let giant = 48000, giantHeight = 32000

    // MARK: - Level selection

    func testOrdinarySourcesBelowTheCeilingStayNative() {
        // The E1 matrix computed buckets for these too, but the accepted policy is
        // native resolution for anything at or below the ceiling.
        for source in [4032, 6000, 8192, 1024, 200] {
            for canvas in [CGSize(width: 960, height: 596), CGSize(width: 2496, height: 1404),
                           CGSize(width: 600, height: 1200), CGSize(width: 2000, height: 500)] {
                XCTAssertEqual(DecodeBudget.level(sourceLongEdge: source, canvasPoints: canvas,
                                                  backingScale: 2),
                               .native,
                               "\(source)px on a \(Int(canvas.width))x\(Int(canvas.height)) canvas")
            }
        }
    }

    func testOversizedSourcesUseTheE1BucketMatrix() {
        // Canvas geometries from the E1 gate run, backing scale 2 (this machine).
        let cases: [(String, CGSize, DecodeLevel)] = [
            ("default window", CGSize(width: 960, height: 596), .bucket(4096)),
            ("full screen", CGSize(width: 2496, height: 1404), .bucket(8192)),
            ("narrow tall", CGSize(width: 600, height: 1200), .bucket(4096)),
            ("short wide", CGSize(width: 2000, height: 500), .bucket(8192)),
            ("half screen", CGSize(width: 1248, height: 1404), .bucket(8192)),
        ]
        for (name, canvas, expected) in cases {
            XCTAssertEqual(DecodeBudget.level(sourceLongEdge: giant, canvasPoints: canvas, backingScale: 2),
                           expected, "\(name): 48000px source")
            // Aspect does not matter to the requirement — only the long edge does.
            XCTAssertEqual(DecodeBudget.level(sourceLongEdge: 32000, canvasPoints: canvas, backingScale: 2),
                           expected, "\(name): 32000px source")
            XCTAssertEqual(DecodeBudget.level(sourceLongEdge: 20000, canvasPoints: canvas, backingScale: 2),
                           expected, "\(name): 20000px source")
        }
    }

    func testJustAboveTheCeilingIsBounded() {
        XCTAssertEqual(DecodeBudget.level(sourceLongEdge: 8192, canvasPoints: CGSize(width: 960, height: 596),
                                          backingScale: 2), .native)
        XCTAssertEqual(DecodeBudget.level(sourceLongEdge: 8193, canvasPoints: CGSize(width: 960, height: 596),
                                          backingScale: 2), .bucket(4096))
    }

    func testUnknownDimensionsFailSafe() {
        // A header that cannot be read must not authorise a native decode.
        for unknown in [0, -1] {
            XCTAssertEqual(DecodeBudget.level(sourceLongEdge: unknown, canvasPoints: CGSize(width: 960, height: 596),
                                              backingScale: 2), .bucket(DecodeBudget.smallestBucket))
        }
    }

    func testDegenerateCanvasOrScaleStillProducesAUsableBucket() {
        XCTAssertEqual(DecodeBudget.level(sourceLongEdge: giant, canvasPoints: .zero, backingScale: 2),
                       .bucket(DecodeBudget.smallestBucket))
        XCTAssertEqual(DecodeBudget.level(sourceLongEdge: giant, canvasPoints: CGSize(width: 960, height: 596),
                                          backingScale: 0), .bucket(DecodeBudget.smallestBucket))
        // An empty canvas legitimately has no requirement; what must never happen is
        // the requirement being computed from a zero scale, which would collapse the
        // bucket to nothing for a real canvas.
        XCTAssertEqual(DecodeBudget.requiredLongEdge(canvasPoints: .zero, backingScale: 2), 0)
        XCTAssertGreaterThan(DecodeBudget.requiredLongEdge(canvasPoints: CGSize(width: 960, height: 596),
                                                           backingScale: 0), 0,
                             "a bogus scale is clamped, not multiplied through")
    }

    func testBackingScaleIsHonoured() {
        // The same window on a 1x display needs half the pixels.
        XCTAssertEqual(DecodeBudget.level(sourceLongEdge: giant, canvasPoints: CGSize(width: 960, height: 596),
                                          backingScale: 1), .bucket(2048))
        XCTAssertEqual(DecodeBudget.level(sourceLongEdge: giant, canvasPoints: CGSize(width: 960, height: 596),
                                          backingScale: 2), .bucket(4096))
    }

    // MARK: - Bucket helper

    func testBucketSnappingAndClamping() {
        XCTAssertEqual(DecodeBudget.bucket(atLeast: 0), 1024)
        XCTAssertEqual(DecodeBudget.bucket(atLeast: 1), 1024)
        XCTAssertEqual(DecodeBudget.bucket(atLeast: 1024), 1024)
        XCTAssertEqual(DecodeBudget.bucket(atLeast: 1025), 2048)
        XCTAssertEqual(DecodeBudget.bucket(atLeast: 4096), 4096)
        XCTAssertEqual(DecodeBudget.bucket(atLeast: 4097), 8192)
        XCTAssertEqual(DecodeBudget.bucket(atLeast: 8192), 8192)
        XCTAssertEqual(DecodeBudget.bucket(atLeast: 8193), 8192, "the hard ceiling clamps")
        XCTAssertEqual(DecodeBudget.bucket(atLeast: 100_000), DecodeBudget.maximumLongEdge)
    }

    func testOverscanIsTheFrozenValue() {
        XCTAssertEqual(DecodeBudget.overscan, 1.5)
        // 1365 * 2 * 1.5 = 4095 -> clamped up within the same bucket
        XCTAssertEqual(DecodeBudget.requiredLongEdge(canvasPoints: CGSize(width: 1365, height: 100),
                                                     backingScale: 2), 4095)
    }

    func testPixelBudgetMapping() {
        XCTAssertNil(DecodeBudget.pixelBudget(for: .native))
        XCTAssertEqual(DecodeBudget.pixelBudget(for: .bucket(4096)), 4096)
        XCTAssertEqual(DecodeBudget.pixelBudget(for: .bucket(8192)), 8192)
    }

    // MARK: - Oversized predicate

    func testOversizedPredicateBoundary() {
        XCTAssertFalse(OversizedPolicy.isOversized(sourceLongEdge: 8192))
        XCTAssertTrue(OversizedPolicy.isOversized(sourceLongEdge: 8193))
        XCTAssertTrue(OversizedPolicy.isOversized(sourceLongEdge: nil),
                      "an unreadable header must fail safe: no native decode, no preload")
        XCTAssertTrue(OversizedPolicy.isOversized(sourceLongEdge: 0))
        XCTAssertFalse(OversizedPolicy.isOversized(sourceLongEdge: 1))
    }

    func testPredicateAndBudgetAgreeAboutTheCeiling() {
        XCTAssertEqual(OversizedPolicy.isOversized(sourceLongEdge: DecodeBudget.maximumLongEdge + 1),
                       !(DecodeBudget.level(sourceLongEdge: DecodeBudget.maximumLongEdge + 1,
                                            canvasPoints: CGSize(width: 100, height: 100),
                                            backingScale: 2) == .native))
    }
}

/// C2 dimension probing: on-demand, cached, header-only.
final class DimensionProbeTests: XCTestCase {

    func testProbeReadsHeaderDimensionsOnly() async throws {
        let probe = DimensionProbe()
        let longEdge = await probe.longEdge(of: Fixtures.url("static.png"))
        let cached = await probe.cachedCount()
        XCTAssertEqual(longEdge, 64, "static.png is 64x48; the probe reports the longest edge")
        XCTAssertEqual(cached, 1, "the answer is remembered")
    }

    func testProbeIsCachedAcrossCalls() async throws {
        let probe = DimensionProbe()
        _ = await probe.longEdge(of: Fixtures.url("static.png"))
        _ = await probe.longEdge(of: Fixtures.url("static.png"))
        let afterOneFile = await probe.cachedCount()
        XCTAssertEqual(afterOneFile, 1, "one entry per file, not one per call")
        _ = await probe.longEdge(of: Fixtures.url("static.bmp"))
        let afterTwoFiles = await probe.cachedCount()
        XCTAssertEqual(afterTwoFiles, 2)
    }

    func testUnreadableFileIsNotCachedAndCountsAsOversized() async throws {
        let probe = DimensionProbe()
        let missing = URL(fileURLWithPath: "/tmp/does-not-exist-\(UUID().uuidString).png")
        let longEdge = await probe.longEdge(of: missing)
        let cached = await probe.cachedCount()
        let oversized = await probe.isOversized(missing)
        XCTAssertNil(longEdge)
        XCTAssertEqual(cached, 0, "a failure is not remembered as a dimension")
        XCTAssertTrue(oversized, "an unreadable file must not be treated as small")
    }

    func testForgetDropsTheRememberedDimension() async throws {
        let probe = DimensionProbe()
        let url = Fixtures.url("static.png")
        _ = await probe.longEdge(of: url)
        await probe.forget(url)
        let cached = await probe.cachedCount()
        XCTAssertEqual(cached, 0)
    }

    func testFixtureClassificationMatchesItsRealPixels() async throws {
        let probe = DimensionProbe()
        let staticIsOversized = await probe.isOversized(Fixtures.url("static.png"))
        let orientedIsOversized = await probe.isOversized(Fixtures.url("oriented-6.jpg"))
        XCTAssertFalse(staticIsOversized)
        XCTAssertFalse(orientedIsOversized)
    }
}
