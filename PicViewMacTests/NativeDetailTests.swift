import XCTest
import CoreGraphics
import AppKit
@testable import PicViewMac
import PicPNGStream

/// Collects tiles from a `@Sendable` callback, which cannot capture mutable state.
final class TileCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [NativeTile] = []
    var tiles: [NativeTile] { lock.lock(); defer { lock.unlock() }; return storage }
    var count: Int { lock.lock(); defer { lock.unlock() }; return storage.count }
    func append(_ tile: NativeTile) { lock.lock(); storage.append(tile); lock.unlock() }
}

/// The native-detail path, tested without a window where possible: planning is pure, the
/// cache is a byte budget with pinning, and the provider is exercised against the real
/// decoder on a fixture. The end-to-end test at the bottom drives a real viewer.
final class NativeDetailTests: XCTestCase {

    // MARK: - Planning

    func testVisibleSourceRectFollowsTheViewportAndSurvivesRotation() {
        let source = CGSize(width: 4000, height: 2000)
        let view = CGSize(width: 800, height: 600)

        // Fitted: the whole image is visible, so the rect is the image.
        var state = ViewportState(fitScale: 0.2, zoomScale: 0.2)
        let fitted = NativeTilePlanner.visibleSourceRect(viewport: state, sourcePixelSize: source,
                                                         viewSize: view)
        XCTAssertEqual(fitted.width, 4000, accuracy: 1)
        XCTAssertEqual(fitted.height, 2000, accuracy: 1)

        // 100 %: a 800×600 pt view shows 800×600 source pixels.
        state.zoomScale = 1
        let actual = NativeTilePlanner.visibleSourceRect(viewport: state, sourcePixelSize: source,
                                                         viewSize: view)
        XCTAssertEqual(actual.width, 800, accuracy: 1)
        XCTAssertEqual(actual.height, 600, accuracy: 1)
        XCTAssertEqual(actual.midX, 2000, accuracy: 1)
        XCTAssertEqual(actual.midY, 1000, accuracy: 1)

        // Zoomed in and panned: the rect is a sub-rectangle, still inside the image.
        state.zoomScale = 8
        state.normalizedCenter = CGPoint(x: 0.25, y: 0.75)
        let zoomed = NativeTilePlanner.visibleSourceRect(viewport: state, sourcePixelSize: source,
                                                        viewSize: view)
        XCTAssertEqual(zoomed.width, 100, accuracy: 1)
        XCTAssertEqual(zoomed.height, 75, accuracy: 1)
        XCTAssertEqual(zoomed.midX, 1000, accuracy: 1)
        // Displayed y grows upward, source y grows downward.
        XCTAssertEqual(zoomed.midY, 500, accuracy: 1)

        // A quarter turn swaps the visible extent, and the same normalized pair now names a
        // different part of the source: displayed "up" is the source's *left* after a
        // clockwise turn, so 75 % up the displayed height is source y 1500 here. (The
        // viewer's own rotate path carries the image point across instead — that is
        // `ViewRotationGeometryTests`' job; this test sets the viewport directly, so it
        // sees the raw reinterpretation.)
        var turned = state
        turned.viewRotationQuarterTurns = 1
        let rotated = NativeTilePlanner.visibleSourceRect(viewport: turned, sourcePixelSize: source,
                                                         viewSize: view)
        XCTAssertEqual(rotated.width, 75, accuracy: 1.5)
        XCTAssertEqual(rotated.height, 100, accuracy: 1.5)
        XCTAssertEqual(rotated.midX, 1000, accuracy: 2)
        XCTAssertEqual(rotated.midY, 1500, accuracy: 2)
        XCTAssertTrue(CGRect(origin: .zero, size: source).contains(rotated),
                      "the visible rect stays inside the source for every rotation")
    }

    func testNeedsNativeDetailOnlyWhenTheProxyIsOutResolved() {
        // A 48000-pixel source with an 8192 proxy: the proxy covers 1/5.86 of native.
        XCTAssertFalse(NativeTilePlanner.needsNativeDetail(sourceLongEdge: 48000, proxyLongEdge: 8192,
                                                           physicalScale: 0.027), "Fit does not need tiles")
        XCTAssertFalse(NativeTilePlanner.needsNativeDetail(sourceLongEdge: 48000, proxyLongEdge: 8192,
                                                           physicalScale: 0.16), "below the proxy ratio")
        XCTAssertTrue(NativeTilePlanner.needsNativeDetail(sourceLongEdge: 48000, proxyLongEdge: 8192,
                                                          physicalScale: 0.5), "zoomed in: tiles")
        XCTAssertTrue(NativeTilePlanner.needsNativeDetail(sourceLongEdge: 48000, proxyLongEdge: 8192,
                                                          physicalScale: 1), "100 %: tiles")
        // Ordinary photographs are never in this path: the source is its own best bitmap.
        XCTAssertFalse(NativeTilePlanner.needsNativeDetail(sourceLongEdge: 6000, proxyLongEdge: 6000,
                                                           physicalScale: 1))
        XCTAssertFalse(NativeTilePlanner.needsNativeDetail(sourceLongEdge: 6000, proxyLongEdge: 6000,
                                                           physicalScale: 4), "magnifying cannot add detail")
    }

    func testPlanCoversTheViewportAndOneRingNearestFirst() {
        let source = CGSize(width: 48000, height: 32000)
        let rect = CGRect(x: 10000, y: 8000, width: 2400, height: 1600)
        guard let plan = NativeTilePlanner.plan(sourceRect: rect, sourcePixelSize: source,
                                                tileSize: 512) else {
            return XCTFail("plan must exist")
        }
        // Visible: ceil(2400/512)+1 = 5 columns or 6 depending on alignment; a bounding check
        // is what matters — every tile that intersects the rect must be in the set.
        func covered(_ coordinate: TileCoordinate) -> CGRect {
            NativeTilePlanner.sourceRect(for: coordinate, tileSize: 512, sourcePixelSize: source)
        }
        let visibleUnion = plan.visible.reduce(CGRect.null) { $0.union(covered($1)) }
        XCTAssertTrue(visibleUnion.contains(rect), "visible tiles must cover the viewport")
        XCTAssertFalse(plan.visible.isEmpty)

        // The ring surrounds the visible set without duplicating it.
        let visibleKeys = Set(plan.visible)
        XCTAssertFalse(plan.ring.isEmpty)
        XCTAssertTrue(plan.ring.allSatisfy { !visibleKeys.contains($0) })
        let xRange = plan.visible.map(\.x).min()!...plan.visible.map(\.x).max()!
        let yRange = plan.visible.map(\.y).min()!...plan.visible.map(\.y).max()!
        XCTAssertTrue(plan.ring.contains { $0.x == xRange.lowerBound - 1 })
        XCTAssertTrue(plan.ring.contains { $0.y == yRange.upperBound + 1 })

        // Nearest to the viewport centre first, which is the order tiles should arrive in.
        let centre = CGPoint(x: rect.midX, y: rect.midY)
        let distances = plan.visible.map { coordinate -> CGFloat in
            let tile = covered(coordinate)
            return hypot(tile.midX - centre.x, tile.midY - centre.y)
        }
        XCTAssertEqual(distances, distances.sorted(), "visible tiles are ordered by distance")

        // The decode rectangle contains every planned tile but stays bounded.
        for coordinate in plan.allCoordinates {
            XCTAssertTrue(plan.decodeRect.contains(covered(coordinate)),
                          "tile \(coordinate) outside the decode rect")
        }
        XCTAssertLessThan(plan.decodeRect.width, CGFloat(source.width))
    }

    // MARK: - Cache

    func testCacheEvictsByBytesAndNeverWhatIsOnScreen() {
        let cache = NativeTileCache(totalCostLimit: 4096)
        func tile(_ x: Int) -> NativeTile {
            NativeTile(key: NativeTileKey(sourcePath: "/a.png", x: x, y: 0),
                       sourceRect: CGRect(x: x * 16, y: 0, width: 16, height: 16),
                       image: makeImage(width: 16, height: 16))
        }
        for x in 0..<8 {
            cache.store(tile(x))
        }
        XCTAssertLessThanOrEqual(cache.byteCount, 4096, "the budget is enforced in bytes")
        XCTAssertGreaterThan(cache.evictionCount, 0, "something had to go")
        let survivors = (0..<8).filter { cache.tile(for: NativeTileKey(sourcePath: "/a.png", x: $0, y: 0)) != nil }
        XCTAssertEqual(survivors, [4, 5, 6, 7], "1 KiB tiles in a 4 KiB budget: the four oldest went")

        // Pinning the viewport protects it from the same pressure.
        cache.removeAll()
        let pinned = NativeTileKey(sourcePath: "/a.png", x: 0, y: 0)
        cache.store(tile(0))
        cache.pin([pinned])
        for x in 1..<8 {
            cache.store(tile(x))
        }
        XCTAssertNotNil(cache.tile(for: pinned), "the tile on screen must survive eviction")
    }

    // MARK: - Provider, against the real decoder

    private func makeImage(width: Int, height: Int) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    func testOnePassFillsEveryTileInThePlan() throws {
        // The point of the design: one traversal of the stream fills the whole viewport, not
        // one traversal per tile. The fixture cycles filter types and is 8192 wide, so this
        // also covers the clipped-tile and edge cases.
        let url = Fixtures.url("wide-gradient.png")
        guard FileManager.default.fileExists(atPath: url.path) else { throw XCTSkip("fixture missing") }
        let source = CGSize(width: 8192, height: 256)
        let rect = CGRect(x: 3000, y: 40, width: 900, height: 180)
        let plan = try XCTUnwrap(NativeTilePlanner.plan(sourceRect: rect, sourcePixelSize: source,
                                                        tileSize: 256))
        let collector = TileCollector()
        let provider = PNGNativeTileProvider()
        try provider.produce(plan: plan, source: url, pageIndex: 0, gutter: 1,
                             shouldCancel: { false },
                             onTile: { collector.append($0) })
        let delivered = collector.tiles

        XCTAssertEqual(delivered.count, plan.allCoordinates.count,
                       "every planned tile must arrive from a single pass")
        XCTAssertEqual(Set(delivered.map(\.key)), Set(plan.allCoordinates.map {
            NativeTileKey(sourcePath: url.path, x: $0.x, y: $0.y)
        }))
        for tile in delivered {
            XCTAssertGreaterThanOrEqual(tile.image.width, 1)
            XCTAssertGreaterThanOrEqual(tile.image.height, 1)
            XCTAssertTrue(tile.sourceRect.width <= CGFloat(plan.tileSize + 2))
        }
        // Determinism: the same plan twice produces the same tiles in the same order.
        let second = TileCollector()
        try provider.produce(plan: plan, source: url, pageIndex: 0, gutter: 1,
                             shouldCancel: { false }, onTile: { second.append($0) })
        XCTAssertEqual(delivered.map(\.key), second.tiles.map(\.key))
    }

    func testCancellingAPassStopsItPromptly() throws {
        let url = Fixtures.url("wide-gradient.png")
        guard FileManager.default.fileExists(atPath: url.path) else { throw XCTSkip("fixture missing") }
        let source = CGSize(width: 8192, height: 256)
        // 64-pixel tiles so deliveries happen while the pass is still running; with
        // 256-pixel tiles every tile in this fixture completes on the same row and there is
        // nothing left to cancel.
        let plan = try XCTUnwrap(NativeTilePlanner.plan(
            sourceRect: CGRect(x: 0, y: 0, width: 4096, height: 256),
            sourcePixelSize: source, tileSize: 64))
        let counter = TileCounter()
        let provider = PNGNativeTileProvider()
        try provider.produce(plan: plan, source: url, pageIndex: 0, gutter: 1,
                             shouldCancel: { counter.value > 0 },
                             onTile: { _ in counter.increment() })
        let delivered = counter.value
        XCTAssertGreaterThan(delivered, 0)
        XCTAssertLessThan(delivered, plan.allCoordinates.count,
                          "cancellation must stop the pass before it finishes")
    }

    func testAnUnsupportedSourceIsRefusedByName() throws {
        let url = Fixtures.url("depth16.png")
        guard FileManager.default.fileExists(atPath: url.path) else { throw XCTSkip("fixture missing") }
        let plan = try XCTUnwrap(NativeTilePlanner.plan(sourceRect: CGRect(x: 0, y: 0, width: 32, height: 32),
                                                        sourcePixelSize: CGSize(width: 96, height: 64),
                                                        tileSize: 64))
        let provider = PNGNativeTileProvider()
        XCTAssertThrowsError(try provider.produce(plan: plan, source: url, pageIndex: 0, gutter: 1,
                                                  shouldCancel: { false }, onTile: { _ in })) { error in
            let message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            XCTAssertTrue(message.contains("16"), "the refusal must say why: \(message)")
        }
    }

    // MARK: - Scheduler

    func testSchedulerDeduplicatesIdenticalRequestsAndRunsOnePass() async throws {
        let url = Fixtures.url("wide-gradient.png")
        guard FileManager.default.fileExists(atPath: url.path) else { throw XCTSkip("fixture missing") }
        let cache = NativeTileCache(totalCostLimit: 8 * 1024 * 1024)
        let scheduler = NativeDetailScheduler(cache: cache, tileSize: 256)
        let plan = try XCTUnwrap(NativeTilePlanner.plan(sourceRect: CGRect(x: 0, y: 0, width: 1024, height: 256),
                                                        sourcePixelSize: CGSize(width: 8192, height: 256),
                                                        tileSize: 256))
        let done = expectation(description: "pass finished")
        await scheduler.setOnTile { _ in }
        await scheduler.request(plan: plan, source: url)
        // The same request again while the pass runs must not start a second pass.
        await scheduler.request(plan: plan, source: url)
        await scheduler.request(plan: plan, source: url)
        let deadline = Date().addingTimeInterval(10)
        var stats = await scheduler.statistics()
        while stats.passes < 1, Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
            stats = await scheduler.statistics()
        }
        done.fulfill()
        await fulfillment(of: [done], timeout: 0.1)
        stats = await scheduler.statistics()
        XCTAssertEqual(stats.passes, 1, "three identical requests, one pass")
        XCTAssertEqual(stats.tilesDelivered, plan.allCoordinates.count)
        XCTAssertGreaterThan(cache.count, 0)
    }

    func testSchedulerPurgesWhenTheViewportNoLongerWantsDetail() async throws {
        let url = Fixtures.url("wide-gradient.png")
        guard FileManager.default.fileExists(atPath: url.path) else { throw XCTSkip("fixture missing") }
        let cache = NativeTileCache(totalCostLimit: 8 * 1024 * 1024)
        let scheduler = NativeDetailScheduler(cache: cache, tileSize: 256)
        let plan = try XCTUnwrap(NativeTilePlanner.plan(sourceRect: CGRect(x: 0, y: 0, width: 512, height: 256),
                                                        sourcePixelSize: CGSize(width: 8192, height: 256),
                                                        tileSize: 256))
        await scheduler.request(plan: plan, source: url)
        let deadline = Date().addingTimeInterval(10)
        while await scheduler.statistics().tilesDelivered == 0, Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertGreaterThan(cache.count, 0)
        await scheduler.stopAndPurge()
        let bytes = cache.byteCount
        XCTAssertEqual(bytes, 0, "zooming out must give the memory back")
    }
}
