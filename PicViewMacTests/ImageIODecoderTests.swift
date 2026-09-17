import XCTest
import CoreGraphics
import ImageIO
@testable import PicViewMac

final class ImageIODecoderTests: XCTestCase {
    private let decoder = ImageIODecoder()

    func testInspectsEveryRequiredFormat() async throws {
        let expectations: [(String, CGSize)] = [
            ("static.png", CGSize(width: 64, height: 48)),
            ("static.bmp", CGSize(width: 40, height: 20)),
            ("static.gif", CGSize(width: 24, height: 24)),
            ("static.jpg", CGSize(width: 96, height: 64)),
            ("multi.ico", CGSize(width: 32, height: 32)),
            ("multipage.tiff", CGSize(width: 40, height: 30)),
            ("single.tiff", CGSize(width: 36, height: 24)),
            ("static.webp", CGSize(width: 64, height: 48)),
            ("lossy.webp", CGSize(width: 64, height: 48)),
        ]
        for (name, size) in expectations {
            let descriptor = try await decoder.inspect(Fixtures.url(name))
            XCTAssertEqual(descriptor.pixelSize, size, name)
            XCTAssertNotNil(descriptor.typeIdentifier, name)
        }
    }

    func testDecodesFirstDisplayableFrameForEveryRequiredFormat() async throws {
        for name in ["static.png", "static.bmp", "static.gif", "static.jpg",
                     "multi.ico", "multipage.tiff", "single.tiff", "static.webp"] {
            let head = try await decoder.decodeFirstDisplayableFrame(Fixtures.url(name), target: .fullResolution)
            XCTAssertGreaterThan(head.image.width, 0, name)
            XCTAssertGreaterThan(head.image.height, 0, name)
            XCTAssertFalse(head.metadata.fileName.isEmpty, name)
        }
    }

    // MARK: - Orientation

    func testOrientedJPEGReportsCorrectDisplayOrientationWithoutRewritingSource() async throws {
        let url = Fixtures.url("oriented-6.jpg")
        let originalBytes = try Data(contentsOf: url)

        let descriptor = try await decoder.inspect(url)
        XCTAssertEqual(descriptor.orientation, .right, "orientation 6 must be reported as .right")
        XCTAssertEqual(descriptor.pixelSize, CGSize(width: 40, height: 20))
        XCTAssertEqual(descriptor.displayPixelSize, CGSize(width: 20, height: 40),
                       "a 90° rotation swaps the displayed dimensions")

        let head = try await decoder.decodeFirstDisplayableFrame(url, target: .fullResolution)
        XCTAssertEqual(CGSize(width: head.image.width, height: head.image.height),
                       descriptor.displayPixelSize,
                       "decoded pixels must already be oriented, so the canvas never rotates twice")
        XCTAssertEqual(try Data(contentsOf: url), originalBytes,
                       "view-only behavior must never rewrite the source file")
    }

    func testUnorientedImageKeepsIdentityOrientation() async throws {
        let descriptor = try await decoder.inspect(Fixtures.url("static.png"))
        XCTAssertEqual(descriptor.orientation, .up)
        XCTAssertEqual(descriptor.displayPixelSize, descriptor.pixelSize)
    }

    func testColorSpaceSurvivesDecode() async throws {
        let head = try await decoder.decodeFirstDisplayableFrame(Fixtures.url("display-p3.png"),
                                                                target: .fullResolution)
        let colorSpace = try XCTUnwrap(head.image.colorSpace)
        XCTAssertEqual(colorSpace.name, CGColorSpace.displayP3,
                       "decoding must not flatten Display P3 into a device RGB space")
        XCTAssertNotNil(head.metadata.colorSpace)
    }

    // MARK: - Animation

    func testAnimatedGIFDescriptorReportsFramesAndLoopCount() async throws {
        let descriptor = try await decoder.inspect(Fixtures.url("animated-infinite.gif"))
        XCTAssertTrue(descriptor.animated)
        XCTAssertEqual(descriptor.frameCount, 3)
        XCTAssertEqual(descriptor.loopCount, 0, "loop count 0 means infinite")
        XCTAssertEqual(descriptor.frameDurations.count, 3)
        XCTAssertEqual(descriptor.frameDurations[1], 0.2, accuracy: 0.05)
    }

    func testFiniteAnimatedGIFReportsItsLoopCount() async throws {
        let descriptor = try await decoder.inspect(Fixtures.url("animated-twice.gif"))
        XCTAssertEqual(descriptor.loopCount, 2)
    }

    func testStaticFileIsNotReportedAsAnimated() async throws {
        let descriptor = try await decoder.inspect(Fixtures.url("static.gif"))
        XCTAssertFalse(descriptor.animated)
        XCTAssertEqual(descriptor.frameCount, 1)
    }

    func testRemainingFramesStreamDecodesLaterFrames() async throws {
        let url = Fixtures.url("animated-infinite.gif")
        let descriptor = try await decoder.inspect(url)
        var frames: [Int] = []
        for try await frame in decoder.decodeRemainingFrames(url, descriptor: descriptor) {
            XCTAssertGreaterThan(frame.image.width, 0)
            frames.append(frame.index)
        }
        XCTAssertEqual(frames, [1, 2], "the head is frame 0, the stream carries the rest")
    }

    func testDecodeFramePublishesRequestedFrameOnly() async throws {
        let frame = try await decoder.decodeFrame(Fixtures.url("animated-infinite.gif"), index: 2)
        XCTAssertEqual(frame.index, 2)
        XCTAssertEqual(CGSize(width: frame.image.width, height: frame.image.height),
                       CGSize(width: 32, height: 32))
    }

    // MARK: - Multi-page TIFF and ICO

    func testSinglePageTIFFReportsOnePageAndDecodes() async throws {
        let descriptor = try await decoder.inspect(Fixtures.url("single.tiff"))
        XCTAssertEqual(descriptor.pageCount, 1)
        XCTAssertFalse(descriptor.animated)
        XCTAssertEqual(descriptor.pixelSize, CGSize(width: 36, height: 24))
        let head = try await decoder.decodeFirstDisplayableFrame(Fixtures.url("single.tiff"),
                                                                 target: .fullResolution)
        XCTAssertEqual(CGSize(width: head.image.width, height: head.image.height),
                       CGSize(width: 36, height: 24))
    }

    func testTruncatedJPEGDoesNotCrashAndKeepsNavigationUsable() async throws {
        let url = Fixtures.url("truncated.jpg")
        // A truncated file may decode partially or fail outright; both are
        // acceptable. What is not acceptable is crashing or wedging the viewer.
        let descriptor = try? await decoder.inspect(url)
        XCTAssertEqual(descriptor?.sourceURL, url)

        let head = try? await decoder.decodeFirstDisplayableFrame(url, target: .fullResolution)
        if let head {
            XCTAssertGreaterThan(head.image.width, 0, "a partial decode must still be a usable image")
        }

        // The next fixture in the folder still decodes, so navigation survives.
        let following = try await decoder.decodeFirstDisplayableFrame(Fixtures.url("static.png"),
                                                                      target: .fullResolution)
        XCTAssertEqual(CGSize(width: following.image.width, height: following.image.height),
                       CGSize(width: 64, height: 48))
    }

    func testMultiPageTIFFReportsPagesNotAnimation() async throws {
        let descriptor = try await decoder.inspect(Fixtures.url("multipage.tiff"))
        XCTAssertEqual(descriptor.pageCount, 3)
        XCTAssertFalse(descriptor.animated, "TIFF pages are pages, not animation frames")
        let second = try await decoder.decodeFrame(Fixtures.url("multipage.tiff"), index: 1,
                                                   target: DecodeTarget(pageIndex: 1))
        XCTAssertEqual(CGSize(width: second.image.width, height: second.image.height),
                       CGSize(width: 30, height: 40))
    }

    func testPageIndexBeyondRangeThrowsInsteadOfCrashing() async throws {
        do {
            _ = try await decoder.decodeFrame(Fixtures.url("multipage.tiff"), index: 99)
            XCTFail("expected a bounds error")
        } catch {
            XCTAssertTrue(error is ImageDecodeError)
        }
    }

    func testICOKeepsRepresentationsAndSelectsByTargetSize() async throws {
        let url = Fixtures.url("multi.ico")
        let descriptor = try await decoder.inspect(url)
        XCTAssertGreaterThan(descriptor.representationCount, 1, "ICO fixture keeps multiple sizes")

        let small = try await decoder.decodeFirstDisplayableFrame(
            url, target: DecodeTarget(maxPixelSize: 16))
        let large = try await decoder.decodeFirstDisplayableFrame(
            url, target: DecodeTarget(maxPixelSize: 64))
        XCTAssertLessThanOrEqual(small.image.width, 16, "a 16 px budget must pick the small representation")
        XCTAssertGreaterThan(large.image.width, small.image.width,
                             "a larger budget must pick a bigger representation")
        // ICO is never exposed as pages.
        XCTAssertEqual(descriptor.pageCount, 1)
    }

    // MARK: - Errors

    func testCorruptFileThrowsInsteadOfCrashing() async throws {
        do {
            _ = try await decoder.decodeFirstDisplayableFrame(Fixtures.url("corrupt.png"),
                                                              target: .fullResolution)
            XCTFail("expected a decode error")
        } catch {
            XCTAssertTrue(error is ImageDecodeError)
        }
    }

    func testUnsupportedFileThrowsInsteadOfCrashing() async throws {
        do {
            _ = try await decoder.inspect(Fixtures.url("not-an-image.pdf"))
            XCTFail("expected a decode error")
        } catch {
            XCTAssertTrue(error is ImageDecodeError)
        }
    }

    func testMissingFileThrowsInsteadOfCrashing() async throws {
        do {
            _ = try await decoder.inspect(URL(fileURLWithPath: "/tmp/definitely-missing.png"))
            XCTFail("expected a decode error")
        } catch {
            XCTAssertTrue(error is ImageDecodeError)
        }
    }
}

/// Pages and frames are different things, and the difference is visible in the UI.
final class MultiPageDocumentTests: XCTestCase {
    @MainActor
    func testOpeningAMultiPageTIFFShowsTheFirstPage() async throws {
        let viewer = ViewerViewController()
        _ = viewer.view
        viewer.open(url: Fixtures.url("multipage.tiff"))
        let deadline = Date().addingTimeInterval(10)
        while viewer.viewerState.currentImage == nil, Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        try? await Task.sleep(nanoseconds: 1_000_000_000)   // give any stream a chance

        let image = try XCTUnwrap(viewer.viewerState.currentImage)
        XCTAssertEqual(CGSize(width: image.width, height: image.height),
                       CGSize(width: 40, height: 30),
                       "a multi-page document opens on page 1, not on its last page")
        XCTAssertEqual(viewer.viewerState.pageIndex, 0)
        XCTAssertEqual(viewer.viewerState.pageDescription, "1 / 3")
    }

    @MainActor
    func testOpeningAMultiPageTIFFDoesNotDecodeEveryPage() async throws {
        // A multi-page document: several pages, not animated, so the decoder must
        // not stream them as frames.
        let decoder = CountingDecoder(document: .multiPage(pageCount: 3))
        let viewer = ViewerViewController(decoder: decoder)
        _ = viewer.view
        viewer.open(url: Fixtures.url("multipage.tiff"))
        let deadline = Date().addingTimeInterval(10)
        while viewer.viewerState.currentImage == nil, Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        try? await Task.sleep(nanoseconds: 800_000_000)

        XCTAssertEqual(decoder.frameRequestCount, 0,
                       "pages must be decoded on demand, not streamed as animation frames")
    }

    @MainActor
    func testPagesStillAdvanceOnRequest() async throws {
        let viewer = ViewerViewController()
        _ = viewer.view
        viewer.open(url: Fixtures.url("multipage.tiff"))
        let deadline = Date().addingTimeInterval(10)
        while viewer.viewerState.currentImage == nil, Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        viewer.perform(.nextPage)
        // The index advances immediately; the pixels arrive when the page decodes.
        let advance = Date().addingTimeInterval(5)
        while viewer.viewerState.currentImage?.width != 30, Date() < advance {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(viewer.viewerState.pageIndex, 1)
        XCTAssertEqual(CGSize(width: viewer.viewerState.currentImage?.width ?? 0,
                             height: viewer.viewerState.currentImage?.height ?? 0),
                       CGSize(width: 30, height: 40),
                       "page 2 is the portrait page")
    }
}
