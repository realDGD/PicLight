import XCTest
import AppKit
import CoreGraphics
@testable import PicViewMac

/// Spec §12: while a bounded decode runs (≈16 s on an oversized PNG) the viewer says
/// it is decoding. Before this, the placeholder claimed "this folder has no supported
/// images" for the whole decode, which is a different and alarming statement — the
/// folder clearly does contain one.
@MainActor
final class LoadingStateTests: XCTestCase {

    override func setUp() async throws {
        try await super.setUp()
        TestAppKit.ensureApplication()
    }

    private struct Probe: DimensionProbing {
        let longEdge: Int
        func longEdge(of url: URL) async -> Int? { longEdge }
    }

    private func makeViewer(decoder: CountingDecoder, probeEdge: Int) -> ViewerWindowController {
        let viewer = ViewerViewController(decoder: decoder, thumbnails: ThumbnailPipeline(),
                                          probe: Probe(longEdge: probeEdge))
        let controller = ViewerWindowController(viewer: viewer)
        TestAppKit.presentOffScreen(controller)
        _ = viewer.view
        return controller
    }

    private func pump(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    @discardableResult
    private func pump(until condition: () -> Bool, timeout: TimeInterval = 6) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return condition()
    }

    func testAnOversizedImageSaysItIsDecodingInsteadOfBlamingTheFolder() throws {
        let directory = try Fixtures.makeScratchDirectory("loading-state")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("giant.png")
        try Data([0x89, 0x50]).write(to: url)

        // The delay stands in for the ~16 s the investigation image needs.
        let decoder = CountingDecoder(delay: 1.0, document: .still,
                                      pixelSize: CGSize(width: 48000, height: 32000))
        let controller = makeViewer(decoder: decoder, probeEdge: 48000)
        defer { controller.close() }
        let viewer = controller.viewerViewController

        viewer.open(url: url)
        pump(0.3)
        let reason: EmptyStateView.Reason? = viewer.emptyStateReasonForTesting
        XCTAssertEqual(reason, EmptyStateView.Reason.loading,
                       "a decode in flight is not an empty folder")
        XCTAssertNil(viewer.viewerState.currentImage)

        XCTAssertTrue(pump(until: { viewer.viewerState.currentImage != nil }))
        pump(0.2)
        XCTAssertNil(viewer.emptyStateReasonForTesting,
                     "once the bitmap is published the placeholder steps aside")
    }

    func testAFolderWithNoSupportedImagesStillSaysSo() throws {
        let directory = try Fixtures.makeScratchDirectory("loading-state-empty")
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("not an image".utf8).write(to: directory.appendingPathComponent("notes.txt"))

        let decoder = CountingDecoder(document: .still)
        let controller = makeViewer(decoder: decoder, probeEdge: 100)
        defer { controller.close() }
        let viewer = controller.viewerViewController

        viewer.open(url: directory.appendingPathComponent("notes.txt"))
        // Wait for the scan to finish: the list is the signal, not a duration.
        _ = pump(until: { viewer.session.directory != nil }, timeout: 5)
        pump(0.3)
        let reason: EmptyStateView.Reason? = viewer.emptyStateReasonForTesting
        XCTAssertEqual(reason, EmptyStateView.Reason.folderHasNoImages,
                       "an empty folder keeps its own wording")
    }

    func testNothingOpenedYetKeepsTheWelcomeState() throws {
        let decoder = CountingDecoder(document: .still)
        let controller = makeViewer(decoder: decoder, probeEdge: 100)
        defer { controller.close() }
        pump(0.2)
        let reason: EmptyStateView.Reason? = controller.viewerViewController.emptyStateReasonForTesting
        XCTAssertEqual(reason, EmptyStateView.Reason.noImageOpened)
    }
}
