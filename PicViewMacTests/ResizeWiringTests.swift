import XCTest
import AppKit
import CoreGraphics
@testable import PicViewMac

/// End-to-end half of the resize policy: the pure decision is pinned in
/// `ResizeUpgradeTests`, and these tests prove the viewer acts on it — the load asks
/// for the §5.3 bucket of its canvas, a settled larger window buys a coarser one, and
/// shrinking or an ordinary source buys nothing.
///
/// Windows come from the production `ViewerWindowController` with an injected viewer,
/// and the run loop is pumped rather than awaited: that is the pattern the other
/// window-touching suites use.
@MainActor
final class ResizeWiringTests: XCTestCase {

    override func setUp() async throws {
        try await super.setUp()
        TestAppKit.ensureApplication()
    }

    private struct Probe: DimensionProbing {
        let longEdge: Int
        func longEdge(of url: URL) async -> Int? { longEdge }
    }

    @MainActor
    private struct Harness {
        let controller: ViewerWindowController
        let decoder: CountingDecoder
        var viewer: ViewerViewController { controller.viewerViewController }
        var window: NSWindow { controller.window! }
    }

    private func makeHarness(pixelSize: CGSize, probeEdge: Int) -> Harness {
        let decoder = CountingDecoder(document: .still, pixelSize: pixelSize)
        let viewer = ViewerViewController(decoder: decoder, thumbnails: ThumbnailPipeline(),
                                          probe: Probe(longEdge: probeEdge))
        let controller = ViewerWindowController(viewer: viewer)
        TestAppKit.presentOffScreen(controller)
        _ = viewer.view
        return Harness(controller: controller, decoder: decoder)
    }

    /// Note on scope: with a source the native-detail backend can serve, a zoom or resize no
    /// longer buys a coarser whole-image level — the tiles answer that requirement directly
    /// and at higher quality (see `NativeDetailWiringTests`). These two tests therefore use a
    /// source the tile backend refuses (16-bit PNG), which is exactly the case where the
    /// whole-image level path still has to do the work.

    private func scratchImage(_ name: String) throws -> (URL, URL) {
        let directory = try Fixtures.makeScratchDirectory("resize-wiring")
        let url = directory.appendingPathComponent(name)
        try Data([0x89, 0x50]).write(to: url)
        return (directory, url)
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

    /// What the frozen §5.3/E1 formula says this geometry should ask for. The canvas
    /// is the authority, so expectations are derived from the geometry actually laid
    /// out, including the display's backing scale.
    private func expectedBudget(_ harness: Harness) -> Int {
        DecodeBudget.bucket(atLeast: DecodeBudget.requiredLongEdge(
            canvasPoints: harness.viewer.view.bounds.size,
            backingScale: harness.window.backingScaleFactor))
    }

    func testTheLoadDecodesAtTheBucketItsCanvasRequires() throws {
        let (directory, url) = try scratchImage("giant.png")
        defer { try? FileManager.default.removeItem(at: directory) }

        let harness = makeHarness(pixelSize: CGSize(width: 48000, height: 32000), probeEdge: 48000)
        defer { harness.controller.close() }
        harness.window.setContentSize(NSSize(width: 420, height: 320))
        pump(0.2)
        // The load target is computed synchronously inside `open`, from this canvas.
        let expected = expectedBudget(harness)

        harness.viewer.open(url: url)
        XCTAssertTrue(pump(until: { harness.decoder.requestedBudgets.count == 1 }),
                      "the load must decode")
        XCTAssertEqual(harness.decoder.requestedBudgets.first ?? nil, expected,
                       "load budget was \(String(describing: harness.decoder.requestedBudgets)) for canvas "
                       + "\(harness.viewer.view.bounds.size) @\(harness.window.backingScaleFactor)x")
        XCTAssertLessThanOrEqual(expected, DecodeBudget.maximumLongEdge)
    }

    func testAGrownWindowNeverLeavesTheBitmapUndersampled() throws {
        // The file itself is a 16-bit PNG: the tile backend refuses it ("unsupported PNG:
        // bit depth 16"), so the level path must still upgrade.
        let url = Fixtures.url("depth16.png")
        guard FileManager.default.fileExists(atPath: url.path) else { throw XCTSkip("fixture missing") }

        let harness = makeHarness(pixelSize: CGSize(width: 48000, height: 32000), probeEdge: 48000)
        defer { harness.controller.close() }
        harness.window.setContentSize(NSSize(width: 420, height: 320))
        pump(0.2)
        harness.viewer.open(url: url)
        XCTAssertTrue(pump(until: { harness.decoder.requestedBudgets.count >= 1 }))
        harness.decoder.reset()
        pump(0.6)                                  // let the image-sized frame settle

        // Grow well past a bucket step. Nothing may decode inside the layout pass.
        harness.window.setContentSize(NSSize(width: 1700, height: 1100))
        pump(0.1)
        XCTAssertEqual(harness.decoder.requestedBudgets.count, 0,
                       "a resize must not decode synchronously in the layout pass")

        XCTAssertTrue(pump(until: {
            guard let last = harness.decoder.requestedBudgets.last ?? nil else { return false }
            return last >= self.expectedBudget(harness)
        }), "a settled, larger canvas must be served by a bitmap that covers it, got "
             + "\(String(describing: harness.decoder.requestedBudgets)) for canvas "
             + "\(harness.viewer.view.bounds.size)")
        let last = try XCTUnwrap(harness.decoder.requestedBudgets.last ?? nil)
        XCTAssertLessThanOrEqual(last, DecodeBudget.maximumLongEdge)
    }

    func testShrinkingTheWindowDoesNotReDecode() throws {
        let (directory, url) = try scratchImage("giant.png")
        defer { try? FileManager.default.removeItem(at: directory) }

        let harness = makeHarness(pixelSize: CGSize(width: 48000, height: 32000), probeEdge: 48000)
        defer { harness.controller.close() }
        harness.window.setContentSize(NSSize(width: 1700, height: 1100))
        pump(0.2)
        harness.viewer.open(url: url)
        XCTAssertTrue(pump(until: { harness.decoder.requestedBudgets.count >= 1 }))
        // Everything settles first: the load, the image-sized frame, any upgrade.
        pump(1.2)
        let settled = harness.decoder.requestedBudgets.count

        harness.window.setContentSize(NSSize(width: 300, height: 220))
        pump(1.2)                                   // four debounce windows
        XCTAssertEqual(harness.decoder.requestedBudgets.count, settled,
                       "a smaller canvas is already satisfied by the bitmap on screen")
    }

    func testAnOrdinaryImageNeverReDecodesOnResize() throws {
        let (directory, url) = try scratchImage("photo.png")
        defer { try? FileManager.default.removeItem(at: directory) }

        // 4000 px: native at any window size, so there is no level to upgrade.
        let harness = makeHarness(pixelSize: CGSize(width: 4000, height: 3000), probeEdge: 4000)
        defer { harness.controller.close() }
        pump(0.2)
        harness.viewer.open(url: url)
        XCTAssertTrue(pump(until: { harness.decoder.requestedBudgets.count >= 1 }))
        pump(1.2)
        let settled = harness.decoder.requestedBudgets.count

        harness.window.setContentSize(NSSize(width: 1700, height: 1100))
        pump(1.2)
        XCTAssertEqual(harness.decoder.requestedBudgets.count, settled,
                       "ordinary photographs must not pay a decode for a resize")
    }

    func testSwitchingImagesCancelsAPendingUpgrade() throws {
        let (directory, first) = try scratchImage("a-giant.png")
        defer { try? FileManager.default.removeItem(at: directory) }
        let second = directory.appendingPathComponent("b-photo.png")
        try Data([0x89, 0x50]).write(to: second)

        let harness = makeHarness(pixelSize: CGSize(width: 48000, height: 32000), probeEdge: 48000)
        defer { harness.controller.close() }
        harness.window.setContentSize(NSSize(width: 420, height: 320))
        pump(0.2)
        harness.viewer.open(url: first)
        XCTAssertTrue(pump(until: { harness.decoder.requestedBudgets.count >= 1 }))

        // Resize, then switch before the debounce fires: the pending upgrade belongs
        // to the image being replaced and must not decode it again.
        harness.window.setContentSize(NSSize(width: 1700, height: 1100))
        harness.viewer.open(url: second)
        pump(1.2)
        XCTAssertEqual(harness.decoder.requestedNames.filter { $0 == "a-giant.png" }.count, 1,
                       "the replaced image must not be decoded again by a stale upgrade")
    }
}

/// The other half of the user-visible promise: zooming in sharpens the bitmap.
/// The level check is the same debounced one as for a resize, with the policy's zoom
/// term supplying the requirement, so the assertions live beside the resize ones.
extension ResizeWiringTests {

    func testZoomingInBuysTheCoarserLevelAfterTheDebounce() throws {
        // 16-bit source: not servable by the tile backend, so the level path answers.
        let url = Fixtures.url("depth16.png")
        guard FileManager.default.fileExists(atPath: url.path) else { throw XCTSkip("fixture missing") }

        let harness = makeHarness(pixelSize: CGSize(width: 48000, height: 32000), probeEdge: 48000)
        defer { harness.controller.close() }
        harness.window.setContentSize(NSSize(width: 420, height: 320))
        pump(0.2)
        harness.viewer.open(url: url)
        XCTAssertTrue(pump(until: { harness.decoder.requestedBudgets.count >= 1 }))
        let loadBudget = harness.decoder.requestedBudgets.first ?? nil
        harness.decoder.reset()
        pump(0.6)

        // 100 %: one image pixel per backing pixel. On a 2× display that is a 0.5
        // zoom factor, i.e. the 48000-pixel source shown across 24000 points — far
        // past the load budget, so the bitmap is undersampled and must be replaced.
        harness.viewer.perform(.zoomActualPixels)
        pump(0.1)
        XCTAssertEqual(harness.decoder.requestedBudgets.count, 0,
                       "a zoom gesture must not decode synchronously")

        XCTAssertTrue(pump(until: {
            guard let last = harness.decoder.requestedBudgets.last ?? nil else { return false }
            return last > (loadBudget ?? 0)
        }), "zooming past the headroom must buy a sharper level, got "
             + "\(String(describing: harness.decoder.requestedBudgets)) after load \(String(describing: loadBudget))")
        XCTAssertEqual(harness.decoder.requestedBudgets.last ?? nil, DecodeBudget.maximumLongEdge,
                       "the sharpest level available is the 8192 proxy")
    }

    func testZoomingOutDoesNotBuyAnything() throws {
        let (directory, url) = try scratchImage("giant.png")
        defer { try? FileManager.default.removeItem(at: directory) }

        let harness = makeHarness(pixelSize: CGSize(width: 48000, height: 32000), probeEdge: 48000)
        defer { harness.controller.close() }
        harness.window.setContentSize(NSSize(width: 420, height: 320))
        pump(0.2)
        harness.viewer.open(url: url)
        XCTAssertTrue(pump(until: { harness.decoder.requestedBudgets.count >= 1 }))
        harness.viewer.perform(.zoomActualPixels)
        XCTAssertTrue(pump(until: { harness.decoder.requestedBudgets.count >= 1 }))
        pump(0.6)
        harness.decoder.reset()

        harness.viewer.perform(.zoomToFit)
        pump(1.2)
        XCTAssertEqual(harness.decoder.requestedBudgets.count, 0,
                       "fitting the image is already covered by the bitmap on screen")
    }
}
