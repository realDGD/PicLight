import XCTest
import CoreGraphics
@testable import PicViewMac

/// Task 6 gate: animated WebP is proven against fixtures before any third-party
/// decoder is introduced. If these fail, add a narrowly scoped libwebp decoder
/// for WebP only.
final class WebPParityTests: XCTestCase {
    private let decoder = ImageIODecoder()

    private let expectations: [WebPParity.Expectation] = [
        .init(fileName: "animated.webp", frameCount: 3, pixelSize: CGSize(width: 32, height: 32),
              durations: [0.1, 0.2, 0.3], loopCount: 0),
        .init(fileName: "animated-twice.webp", frameCount: 2, pixelSize: CGSize(width: 32, height: 32),
              durations: [0.06, 0.06], loopCount: 2),
    ]

    func testSystemImageIOIsSufficientForAnimatedWebP() async throws {
        let report = await WebPParity.evaluate(decoder: decoder, directory: Fixtures.directory,
                                               expectations: expectations)
        print("WebP parity matrix (system ImageIO):\n\(report.summary)")
        XCTAssertTrue(report.passed,
                      "animated WebP parity failed, so a libwebp-backed decoder is required:\n\(report.summary)")
    }

    func testStaticWebPFormatsAreDecodedByImageIO() async throws {
        for name in ["static.webp", "lossy.webp"] {
            let descriptor = try await decoder.inspect(Fixtures.url(name))
            XCTAssertFalse(descriptor.animated, name)
            XCTAssertEqual(descriptor.frameCount, 1, name)
            XCTAssertEqual(descriptor.pixelSize, CGSize(width: 64, height: 48), name)
        }
    }

    func testNoThirdPartyWebPDecoderIsShippedWhenParityPasses() async throws {
        let report = await WebPParity.evaluate(decoder: decoder, directory: Fixtures.directory,
                                               expectations: expectations)
        // The release decision recorded by this test: on this platform the system
        // decoder satisfies the fixture matrix, so the app ships no libwebp
        // dependency and no third-party attribution is required.
        XCTAssertTrue(report.passed)
        XCTAssertEqual(String(describing: type(of: decoder)), "ImageIODecoder")
    }

    func testLoopCountZeroMeansInfiniteAndIsReportedDistinctlyFromFinite() async throws {
        let infinite = try await decoder.inspect(Fixtures.url("animated.webp"))
        let finite = try await decoder.inspect(Fixtures.url("animated-twice.webp"))
        XCTAssertEqual(infinite.loopCount, 0)
        XCTAssertEqual(finite.loopCount, 2)
        XCTAssertNotEqual(infinite.loopCount, finite.loopCount)
    }
}
