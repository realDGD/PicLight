import XCTest
import CoreGraphics
@testable import PicViewMac

/// Spec §9.5: a window resize may buy a new bounded decode only when it has
/// settled, only when nobody is dragging, and only when the bitmap on screen is
/// actually undersampled. These tests pin the decision; the 300 ms scheduler that
/// calls it lives in the viewer and is exercised by the manual resize check.
final class ResizeUpgradeTests: XCTestCase {

    /// 48000×32000, the investigation image.
    private let giant = CGSize(width: 48000, height: 32000)

    private func level(current: DecodeLevel,
                       source: CGSize? = nil,
                       canvas: CGSize,
                       backingScale: CGFloat = 2,
                       zoomScale: CGFloat = 0.01,
                       quarterTurns: Int = 0,
                       isInteracting: Bool = false) -> DecodeLevel? {
        ResizeUpgradePolicy.level(current: current,
                                  sourcePixelSize: source ?? giant,
                                  canvasPoints: canvas,
                                  backingScale: backingScale,
                                  zoomScale: zoomScale,
                                  quarterTurns: quarterTurns,
                                  isInteracting: isInteracting)
    }

    func testAGrowingCanvasAskForTheCoarserBucket() {
        // 1000 pt × 2 backing × 1.5 overscan = 3000 → 4096, coarser than 2048.
        XCTAssertEqual(level(current: .bucket(2048), canvas: CGSize(width: 1000, height: 700)),
                       .bucket(4096))
    }

    func testAShrinkingCanvasKeepsTheBitmapOnScreen() {
        XCTAssertNil(level(current: .bucket(8192), canvas: CGSize(width: 200, height: 150)))
        XCTAssertNil(level(current: .bucket(4096), canvas: CGSize(width: 300, height: 200)))
    }

    func testTheSameRequirementIsNotANewDecode() {
        // 1000 pt × 2 × 1.5 = 3000 → 4096, already displayed: no work.
        XCTAssertNil(level(current: .bucket(4096), canvas: CGSize(width: 1000, height: 700)))
    }

    func testDraggingSuppressesTheUpgradeEntirely() {
        XCTAssertNil(level(current: .bucket(1024), canvas: CGSize(width: 1000, height: 700),
                           isInteracting: true))
    }

    func testOrdinarySourcesNeverUpgrade() {
        // A 4000-px source is native at any window size: nothing to buy.
        XCTAssertNil(level(current: .native, source: CGSize(width: 4000, height: 3000),
                           canvas: CGSize(width: 3000, height: 2000)))
    }

    func testANativeBitmapIsNeverReplacedByABucket() {
        // Unreachable for an oversized source (policy never decodes it natively), and
        // if it ever happened, native detail already exceeds every bucket: a resize
        // must not trade it for less.
        XCTAssertNil(level(current: .native, canvas: CGSize(width: 300, height: 200)))
        XCTAssertNil(level(current: .native, canvas: CGSize(width: 4000, height: 3000)))
    }

    func testZoomedInMagnificationRaisesTheRequirement() {
        // Canvas alone (300 pt × 1 × 1.5 = 450) would ask for 1024, but at this zoom
        // the image is displayed 6400 backing pixels wide: the bitmap is undersampled.
        XCTAssertEqual(level(current: .bucket(1024), canvas: CGSize(width: 300, height: 200),
                             backingScale: 1, zoomScale: 6400.0 / 48000.0),
                       .bucket(8192))
    }

    func testFitZoomDoesNotRaiseTheRequirement() {
        // At Fit the whole image is on screen, so the canvas term already covers it.
        XCTAssertNil(level(current: .bucket(4096), canvas: CGSize(width: 1000, height: 700),
                           backingScale: 2, zoomScale: 1000.0 / 48000.0))
    }

    func testRotationUsesTheDisplayedExtent() {
        // A quarter turn swaps the displayed extent, which lowers the requirement for
        // a wide source: 32000·zoom is smaller than 48000·zoom.
        let landscape = level(current: .bucket(1024), canvas: CGSize(width: 300, height: 200),
                              backingScale: 1, zoomScale: 6400.0 / 48000.0, quarterTurns: 1)
        XCTAssertEqual(landscape, .bucket(8192))
        let turned = ResizeUpgradePolicy.level(current: .bucket(8192), sourcePixelSize: giant,
                                               canvasPoints: CGSize(width: 300, height: 200),
                                               backingScale: 1, zoomScale: 6400.0 / 48000.0,
                                               quarterTurns: 1, isInteracting: false)
        XCTAssertNil(turned, "the same zoom through a quarter turn needs less than 8192")
    }

    func testZeroCanvasGeometryDoesNotStartADecode() {
        XCTAssertNil(level(current: .bucket(8192), canvas: .zero))
    }

    func testTheDebounceMatchesTheDocumentedValue() {
        XCTAssertEqual(ResizeUpgradePolicy.debounce, 0.3, accuracy: 0.0001)
    }

    func testLevelOrderingTreatsNativeAsFinest() {
        XCTAssertTrue(ResizeUpgradePolicy.isCoarser(.bucket(2048), than: .bucket(1024)))
        XCTAssertFalse(ResizeUpgradePolicy.isCoarser(.bucket(1024), than: .bucket(2048)))
        XCTAssertFalse(ResizeUpgradePolicy.isCoarser(.bucket(8192), than: .native))
        XCTAssertTrue(ResizeUpgradePolicy.isCoarser(.native, than: .bucket(8192)))
        XCTAssertFalse(ResizeUpgradePolicy.isCoarser(.native, than: .native))
    }
}
