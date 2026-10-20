import CoreGraphics
import XCTest

@testable import PicViewMac

final class AnimatedFormatRegressionTests: XCTestCase {
    func testAPNGIsAnimationAndKeepsSourceDelaysAndPlayCount() async throws {
        let decoder = ImageIODecoder()
        let descriptor = try await decoder.inspect(Fixtures.url("animation/finite.apng"))
        XCTAssertTrue(descriptor.animated)
        XCTAssertEqual(descriptor.frameCount, 8)
        XCTAssertEqual(descriptor.loopCount, 2)
        assertDelays(descriptor.frameDurations, [0.02, 0.04, 0.08, 0.12, 0.2, 0.03, 0.07, 0.14])
    }

    func testIndependentPosterIsNeverAnimationFrameZero() async throws {
        let url = Fixtures.url("animation/poster-default.apng")
        let decoder = ImageIODecoder()
        let expected = try Data(contentsOf: Fixtures.url("animation/poster-default.apng.rgba"))
        let head = try await decoder.decodeFirstDisplayableFrame(url, target: .fullResolution)
        XCTAssertTrue(head.descriptor.animated)
        XCTAssertEqual(head.descriptor.frameCount, 3)
        assertDelays(head.descriptor.frameDurations, [0.04, 0.08, 0.12])
        XCTAssertEqual(try rgba(head.image), premultiplied(expected.prefix(96 * 64 * 4)))
        // Reopening / crossing a loop must still decode frame zero, never the poster.
        let frame = try await decoder.decodeFrame(url, index: 0)
        XCTAssertEqual(try rgba(frame.image), premultiplied(expected.prefix(96 * 64 * 4)))
    }

    func testAllCompositeFramesMatchIndependentOraclesIncludingRandomAccess() async throws {
        for name in ["composite.gif", "composite.apng", "composite.webp", "poster-default.apng"] {
            let expected = try Data(contentsOf: Fixtures.url("animation/\(name).rgba"))
            let stride = 96 * 64 * 4
            let count = expected.count / stride
            for index in ([count - 1, 0] + Array(0..<count)) {
                let frame = try await ImageIODecoder().decodeFrame(
                    Fixtures.url("animation/\(name)"), index: index)
                XCTAssertEqual(
                    try rgba(frame.image),
                    premultiplied(expected.subdata(in: index * stride..<(index + 1) * stride)),
                    "\(name) frame \(index)")
            }
        }
    }

    func testTenMillisecondDelaysAreNotClamped() async throws {
        for name in ["short-delay.gif", "short-delay.apng", "short-delay.webp"] {
            let descriptor = try await ImageIODecoder().inspect(Fixtures.url("animation/\(name)"))
            assertDelays(descriptor.frameDurations, [0.01, 0.02, 0.1])
        }
    }

    func testPosterFirstSubrectangleStartsOnTransparentCanvasForRGBPaletteAndSixteenBit() async throws {
        for kind in ["rgba", "rgb", "palette", "16bit"] {
            let url = Fixtures.url("animation/poster-offset-\(kind).apng")
            let head = try await ImageIODecoder().decodeFirstDisplayableFrame(url, target: .fullResolution)
            XCTAssertEqual(head.image.width, 32)
            XCTAssertEqual(head.image.height, 24)
            if kind == "16bit" {
                XCTAssertGreaterThan(head.image.bitsPerComponent, 8, "do not narrow to eight bits")
            }
            let actual = try rgba(head.image)
            for y in 0..<24 {
                for x in 0..<32 {
                    let i = (y * 32 + x) * 4
                    let inside = (5..<14).contains(x) && (3..<10).contains(y)
                    XCTAssertEqual(actual[i + 3], inside ? 255 : 0, "\(kind) at \(x),\(y)")
                    if inside {
                        XCTAssertGreaterThan(actual[i], 200)
                        XCTAssertLessThan(actual[i + 2], 40)
                    }
                }
            }
        }
    }

    func testTruncatedPosterFrameIsRejectedInsteadOfFallingBackToThePoster() async throws {
        let original = try Data(contentsOf: Fixtures.url("animation/poster-default.apng"))
        let directory = try Fixtures.makeScratchDirectory("poster-truncated")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("truncated.apng")
        // Keep a complete poster but truncate the first animation frame payload.
        let marker = try XCTUnwrap(original.range(of: Data("fdAT".utf8)))
        try original.prefix(marker.upperBound + 6).write(to: url)
        do {
            _ = try await ImageIODecoder().decodeFirstDisplayableFrame(url, target: .fullResolution)
            XCTFail("invalid animation must not silently show the independent poster")
        } catch {}
    }

    private func assertDelays(
        _ actual: [Double], _ expected: [Double], file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(actual.count, expected.count, file: file, line: line)
        for (a, e) in zip(actual, expected) {
            XCTAssertEqual(a, e, accuracy: 0.0000001, file: file, line: line)
        }
    }

    private func premultiplied(_ input: Data) -> Data {
        var data = input
        data.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
            for i in stride(from: 0, to: raw.count, by: 4) {
                for c in 0..<3 { raw[i + c] = UInt8((Int(raw[i + c]) * Int(raw[i + 3]) + 127) / 255) }
            }
        }
        return data
    }

    private func rgba(_ image: CGImage) throws -> Data {
        let context = try XCTUnwrap(
            CGContext(
                data: nil, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setBlendMode(.copy)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        var data = Data(bytes: context.data!, count: image.width * image.height * 4)
        // Compare premultiplied bytes; the stored independent decoder oracle is straight RGBA.
        data.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
            for i in stride(from: 0, to: raw.count, by: 4) where raw[i + 3] == 0 {
                raw[i] = 0
                raw[i + 1] = 0
                raw[i + 2] = 0
            }
        }
        return data
    }
}
