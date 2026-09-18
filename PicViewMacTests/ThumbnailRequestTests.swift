import XCTest
import AppKit
@testable import PicViewMac

/// The drawer's thumbnail request state machine and its delivery identity.
///
/// Two suspicions: a retry that clears the in-flight flag while the first request is still running
/// (two concurrent decodes for one URL), and a delivery that trusts the row number captured when
/// the request started (the wrong file gets the image after a reorder, insert or delete).
@MainActor
final class ThumbnailRequestTests: XCTestCase {

    override func setUp() async throws {
        try await super.setUp()
        TestAppKit.ensureApplication()
    }

    private func image(width: Int, height: Int, red: CGFloat) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                bytesPerRow: width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: red, green: 0.4, blue: 0.4, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    private func item(_ name: String) -> FolderItem {
        FolderItem(url: URL(fileURLWithPath: "/tmp/thumb-" + name))
    }

    /// A drawer with real cells: delivery only writes to a cell the table already has, so a drawer
    /// outside a window would silently drop everything and prove nothing.
    private func makeDrawer(rows: Int) -> (ThumbnailDrawerView, NSWindow) {
        let height = CGFloat(rows) * ThumbnailCellView.rowHeight + 8
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: height),
                              styleMask: [.titled], backing: .buffered, defer: false)
        // A window that releases itself on close leaves the table view dangling: closing it in the
        // test teardown then crashes in objc_release.
        window.isReleasedWhenClosed = false
        let drawer = ThumbnailDrawerView()
        drawer.frame = NSRect(x: 0, y: 0, width: 200, height: height)
        window.contentView = drawer
        window.makeKeyAndOrderFront(nil)
        drawer.layoutSubtreeIfNeeded()
        return (drawer, window)
    }

    // MARK: - C: delivery by row number

    /// The primitive is row-based, which is exactly why the caller must not use it with a row
    /// captured earlier: after a reorder that row belongs to another file. This documents the
    /// hazard the URL-based delivery exists to avoid.
    func testTheRowIndexPrimitiveDeliversToWhicheverItemNowOwnsThatRow() {
        let (drawer, window) = makeDrawer(rows: 3)
        defer { window.close() }
        let a = item("a.png")
        let b = item("b.png")
        let imageA = image(width: 100, height: 100, red: 0.9)
        let imageB = image(width: 200, height: 200, red: 0.1)
        drawer.rebuild(items: [a, b], currentIndex: 0)
        drawer.layoutSubtreeIfNeeded()

        // A request for row 1 (B) was started, and while it ran the row order changed.
        drawer.rebuild(items: [b, a], currentIndex: 0)
        drawer.layoutSubtreeIfNeeded()
        drawer.updateThumbnail(at: 0, image: imageB)      // stale index 0 now belongs to B — correct
        drawer.updateThumbnail(at: 1, image: imageA)      // stale index 1 now belongs to A — correct

        // The failure mode: the row captured for A is used after A moved.
        drawer.rebuild(items: [b, a], currentIndex: 0)
        drawer.layoutSubtreeIfNeeded()
        drawer.updateThumbnail(at: 0, image: imageA)      // index 0 is B now
        XCTAssertEqual(drawer.thumbnailImageForTesting(at: 0)?.width, imageA.width,
                       "index 0 is B, so A's image landed in B's row: the row number is not an "
                       + "identity")
    }

    /// Fixed path: delivery by URL reaches the item wherever it now is.
    func testDeliveryByURLFollowsTheItemAcrossAReorder() {
        let (drawer, window) = makeDrawer(rows: 3)
        defer { window.close() }
        let a = item("a.png")
        let b = item("b.png")
        let imageA = image(width: 100, height: 100, red: 0.9)
        drawer.rebuild(items: [a, b], currentIndex: 0)
        drawer.layoutSubtreeIfNeeded()
        XCTAssertTrue(drawer.updateThumbnail(for: a.url, image: imageA))
        drawer.rebuild(items: [b, a], currentIndex: 0)
        drawer.layoutSubtreeIfNeeded()
        XCTAssertTrue(drawer.updateThumbnail(for: a.url, image: imageA),
                      "the item is still present, so the delivery counts")
        XCTAssertEqual(drawer.thumbnailImageForTesting(at: 1)?.width, imageA.width,
                       "A's image belongs to A's row, wherever that row is")
        XCTAssertNotEqual(drawer.thumbnailImageForTesting(at: 0)?.width, imageA.width,
                          "and never to B's row")
    }

    /// A URL that is no longer in the list is reported so the caller can count the drop, and the
    /// image stays cached for whenever it comes back.
    func testDeliveryForAMissingURLIsIgnoredAndReported() {
        let (drawer, window) = makeDrawer(rows: 3)
        defer { window.close() }
        let a = item("a.png")
        let imageA = image(width: 100, height: 100, red: 0.9)
        drawer.rebuild(items: [a], currentIndex: 0)
        drawer.layoutSubtreeIfNeeded()
        drawer.rebuild(items: [], currentIndex: nil)
        XCTAssertFalse(drawer.updateThumbnail(for: a.url, image: imageA),
                       "an item that is gone cannot be delivered to")

        // The cache still has it: when the item returns, the provider serves it.
        drawer.thumbnailProvider = { item in item.url == a.url ? imageA : nil }
        drawer.rebuild(items: [a], currentIndex: 0)
        drawer.layoutSubtreeIfNeeded()
        XCTAssertEqual(drawer.thumbnailImageForTesting(at: 0)?.width, imageA.width,
                       "a cached thumbnail is still usable after a stale delivery was ignored")
    }

    /// Insert, delete and a rebuilt folder around a pending delivery.
    func testIndexDeliveriesAfterInsertAndDelete() {
        let (drawer, window) = makeDrawer(rows: 3)
        defer { window.close() }
        let a = item("a.png")
        let b = item("b.png")
        let c = item("c.png")
        let imageC = image(width: 140, height: 140, red: 0.5)
        drawer.rebuild(items: [a, b, c], currentIndex: 0)
        drawer.layoutSubtreeIfNeeded()
        // c is at 2. Deliver it by URL after an insert in front and a delete behind.
        drawer.rebuild(items: [b, a, c], currentIndex: 1)
        drawer.layoutSubtreeIfNeeded()
        XCTAssertTrue(drawer.updateThumbnail(for: c.url, image: imageC))
        XCTAssertEqual(drawer.thumbnailImageForTesting(at: 2)?.width, 140)
        drawer.rebuild(items: [c, a], currentIndex: 0)
        drawer.layoutSubtreeIfNeeded()
        XCTAssertTrue(drawer.updateThumbnail(for: c.url, image: imageC))
        XCTAssertEqual(drawer.thumbnailImageForTesting(at: 0)?.width, 140,
                       "after a delete, c is row 0 and the delivery follows it")
        XCTAssertNotEqual(drawer.thumbnailImageForTesting(at: 1)?.width, 140,
                          "a's row never receives c's image")
    }
}

/// The viewer's thumbnail request state machine: at most one request per URL, with the retry queued
/// behind a request that is already running instead of clearing its in-flight flag.
@MainActor
final class ThumbnailRequestStateTests: XCTestCase {

    private struct Probe: DimensionProbing {
        let longEdge: Int
        func longEdge(of url: URL) async -> Int? { longEdge }
    }

    override func setUp() async throws {
        try await super.setUp()
        TestAppKit.ensureApplication()
    }

    private func proxyBitmap(width: Int, height: Int) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                bytesPerRow: width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    private func pump(until condition: () -> Bool, timeout: TimeInterval = 20) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return condition()
    }

    private func makeViewer() throws -> (ViewerViewController, ViewerWindowController, FolderItem) {
        let name = "oversized-detail.png"
        guard FileManager.default.fileExists(atPath: Fixtures.url(name).path) else {
            throw XCTSkip("fixture missing")
        }
        let decoder = CountingDecoder(payload: proxyBitmap(width: 2048, height: 78),
                                      document: .still,
                                      pixelSize: CGSize(width: 8448, height: 320))
        let scheduler = NativeDetailScheduler(cache: NativeTileCache(totalCostLimit: 32 * 1024 * 1024),
                                              tileSize: 512)
        let viewer = ViewerViewController(decoder: decoder, thumbnails: ThumbnailPipeline(),
                                          probe: Probe(longEdge: 8448), nativeDetail: scheduler)
        let controller = ViewerWindowController(viewer: viewer)
        TestAppKit.presentOffScreen(controller)
        _ = viewer.view
        viewer.open(url: Fixtures.url(name))
        return (viewer, controller, FolderItem(url: Fixtures.url(name)))
    }

    /// The suspicion: the retry clears the in-flight flag and starts a second request while the
    /// first is still running.
    ///
    /// The app's own request (the drawer row, or the head event) is the first one; it is suspended
    /// before it can finish, and every later request is suspended too, so a duplicate would show up
    /// as a second suspended call.
    func testRetryWhileARequestIsRunningDoesNotStartASecondOne() throws {
        let (viewer, controller, item) = try makeViewer()
        defer { controller.close() }
        // The drawer requests thumbnails for every visible row (the fixture folder has many files),
        // so the invariant is per URL and the assertions are per URL too.
        let gate = PauseGate()
        viewer.thumbnailPauseHook = gate.hookAll
        XCTAssertTrue(pump(until: { viewer.thumbnailRequestsForTesting(item.url) == 1 }, timeout: 15),
                      "the current item's request must be running")
        let before = viewer.thumbnailRequestDiagnostics()

        // The bitmap is ready, so the retry path fires while that request is still in flight.
        viewer.retryCurrentItemThumbnail()
        viewer.retryCurrentItemThumbnail()      // and again: idempotent
        _ = pump(until: { false }, timeout: 0.2)
        let during = viewer.thumbnailRequestDiagnostics()
        XCTAssertEqual(viewer.thumbnailRequestsForTesting(item.url), 1,
                       "at most one request per URL while one is running")
        XCTAssertEqual(during.retryQueued >= 1, true, "the retry is queued, not started")
        XCTAssertLessThanOrEqual(during.maxConcurrentPerURL, 1,
                                 "two concurrent decodes for one URL is the bug")
        XCTAssertEqual(during.active, before.active,
                       "and no additional request is running for it")

        gate.releaseAll()
        XCTAssertTrue(pump(until: { viewer.thumbnailRequestDiagnostics().active == 0 }, timeout: 10))
        XCTAssertTrue(pump(until: { viewer.hasCachedThumbnailForTesting(item.url) }, timeout: 10),
                      "the request still delivers its result")
        XCTAssertEqual(viewer.thumbnailRequestDiagnostics().maxConcurrentPerURL, 1,
                       "one request per URL for the whole exchange")
        // Leave nothing suspended: a request that starts after the assertion would otherwise hold a
        // continuation past the end of the test.
        gate.releaseAll()
        _ = pump(until: { false }, timeout: 0.5)
        gate.releaseAll()
        viewer.thumbnailPauseHook = nil
    }

    /// A queued retry belongs to the item that was current when it was queued. If the user has moved
    /// on by the time the placeholder result comes back, starting it again decodes a placeholder for
    /// a row that is no longer waiting for anything.
    func testAQueuedRetryIsDroppedWhenTheUserMovesToAnotherItem() throws {
        let (viewer, controller, item) = try makeViewer()
        defer { controller.close() }
        // Catch the first request for the current item, which happens before its bitmap exists.
        let gate = PauseGate()
        viewer.thumbnailPauseHook = gate.hookAll
        XCTAssertTrue(pump(until: { viewer.thumbnailRequestsForTesting(item.url) == 1 }, timeout: 15),
                      "the first request must be running")
        viewer.retryCurrentItemThumbnail()          // queued behind the running request
        XCTAssertGreaterThanOrEqual(viewer.thumbnailRequestDiagnostics().retryQueued, 1)

        // The user moves to the next file and its bitmap arrives.
        viewer.perform(.nextImage)
        XCTAssertTrue(pump(until: { viewer.currentItemURLForTesting != item.url }, timeout: 15),
                      "the current item must change")
        XCTAssertTrue(pump(until: { viewer.viewerState.currentImage != nil }, timeout: 15),
                      "the new item's bitmap must exist before the old result comes back")
        let before = viewer.thumbnailRequestsForTesting(item.url)

        gate.releaseAll()
        XCTAssertTrue(pump(until: { viewer.thumbnailRequestDiagnostics().active == 0 }, timeout: 15))
        _ = pump(until: { false }, timeout: 0.3)
        XCTAssertEqual(viewer.thumbnailRequestsForTesting(item.url), before,
                       "the old item's queued retry must not start another request")
        XCTAssertGreaterThanOrEqual(viewer.thumbnailRequestDiagnostics().retryDroppedNotCurrent, 1,
                                    "and the drop is counted")
        viewer.thumbnailPauseHook = nil
    }

    /// Once the thumbnail is cached a retry is a no-op — the guard that keeps already-satisfied rows
    /// from starting work.
    func testRetryIsANoOpOnceTheThumbnailIsCached() throws {
        let (viewer, controller, item) = try makeViewer()
        defer { controller.close() }
        XCTAssertTrue(pump(until: { viewer.hasCachedThumbnailForTesting(item.url) }, timeout: 15),
                      "the current item thumbnail must arrive on its own")
        let before = viewer.thumbnailRequestDiagnostics()
        viewer.retryCurrentItemThumbnail()
        _ = pump(until: { false }, timeout: 0.3)
        let after = viewer.thumbnailRequestDiagnostics()
        XCTAssertEqual(after.requests, before.requests, "a cached URL is not requested again")
        XCTAssertEqual(after.active, 0)
        XCTAssertLessThanOrEqual(after.maxConcurrentPerURL, 1)
    }
}
