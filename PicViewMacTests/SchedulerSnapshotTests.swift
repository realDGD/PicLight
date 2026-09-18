import XCTest
import AppKit
@testable import PicViewMac

/// Three scheduler-level correctness questions: which metadata a pass decodes with, whether a
/// cancelled pass can still write to the CPU cache, and what happens to the previous source's tiles
/// when the pass moves to another file. Plus the drawer geometry for a very long filename.
@MainActor
final class SchedulerSnapshotTests: XCTestCase {

    private let fixtureName = "oversized-detail.png"

    override func setUp() async throws {
        try await super.setUp()
        TestAppKit.ensureApplication()
    }

    private func plan(x: CGFloat) throws -> NativeTilePlan {
        try XCTUnwrap(NativeTilePlanner.plan(sourceRect: CGRect(x: x, y: 0, width: 2048, height: 512),
                                             sourcePixelSize: CGSize(width: 8448, height: 320),
                                             tileSize: 512, ring: 0))
    }

    private func thumbnail(width: Int, height: Int) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                bytesPerRow: width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.4, green: 0.5, blue: 0.6, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    /// A. Each pass records the metadata of *its own* request. The pass used to read the actor's
    /// current values when the detached task started, so a pass for source A could decode with
    /// source B's orientation and colour space.
    func testEachPassCapturesItsOwnRequestMetadata() async throws {
        let scheduler = NativeDetailScheduler(cache: NativeTileCache(totalCostLimit: 8 * 1024 * 1024),
                                              tileSize: 512)
        let sourceA = Fixtures.url(fixtureName)
        let sourceB = URL(fileURLWithPath: "/tmp/other-source.png")
        let spaceA = CGColorSpace(name: CGColorSpace.sRGB)
        let spaceB = CGColorSpace(name: CGColorSpace.displayP3)

        await scheduler.request(plan: try plan(x: 0), source: sourceA, colorSpace: spaceA,
                                orientation: .up, epoch: 1)
        let first = await scheduler.runningMetadataForTesting
        XCTAssertEqual(first?.orientation, .up, "the first pass keeps its own orientation")
        XCTAssertEqual(first?.colorSpace?.name, spaceA?.name)

        await scheduler.request(plan: try plan(x: 2048), source: sourceB, colorSpace: spaceB,
                                orientation: SourceOrientation(.right), epoch: 2)
        let second = await scheduler.runningMetadataForTesting
        XCTAssertEqual(second?.orientation, SourceOrientation(.right))
        XCTAssertEqual(second?.colorSpace?.name, spaceB?.name)
        // The first pass must never have been described with the second request's metadata: the
        // snapshot is recorded before the task exists, so it cannot change under it.
        XCTAssertNotEqual(first?.orientation, second?.orientation)
    }

    /// B. A tile from a cancelled pass is dropped *before* it reaches the cache: validation, then
    /// store, then publish.
    func testAStaleDecodedTileNeverEntersTheCache() async throws {
        let cache = NativeTileCache(totalCostLimit: 8 * 1024 * 1024)
        let scheduler = NativeDetailScheduler(cache: cache, tileSize: 512)
        let source = Fixtures.url("oversized-detail.png")
        await scheduler.request(plan: try plan(x: 0), source: source, epoch: 1)
        let liveToken = await scheduler.passTokenForTesting

        // A tile from the live pass is accepted…
        let key = NativeTileKey(sourcePath: source.path, tileSize: 512, x: 0, y: 0)
        let tile = NativeTile(key: key, sourceRect: CGRect(x: 0, y: 0, width: 512, height: 320),
                              image: thumbnail(width: 512, height: 320))
        await scheduler.acceptDecodedTileForTesting(tile, token: liveToken)
        XCTAssertEqual(cache.count, 1, "a live tile is stored")

        // …and one from a pass that is no longer current is not.
        let stale = NativeTileKey(sourcePath: source.path, tileSize: 512, x: 512, y: 0)
        let staleTile = NativeTile(key: stale,
                                   sourceRect: CGRect(x: 512, y: 0, width: 512, height: 320),
                                   image: thumbnail(width: 512, height: 320))
        await scheduler.acceptDecodedTileForTesting(staleTile, token: liveToken - 1)
        XCTAssertEqual(cache.count, 1, "the stale tile must not enter the cache")
        XCTAssertNil(cache.tile(for: stale))
        let discarded = await scheduler.staleDecodedTilesDiscarded
        XCTAssertEqual(discarded, 1, "and it is counted")
    }

    /// C. Moving to another source drops that source's tiles instead of keeping them out of budget.
    func testMovingToAnotherSourcePurgesThePreviousSourcesTiles() async throws {
        let cache = NativeTileCache(totalCostLimit: 8 * 1024 * 1024)
        let scheduler = NativeDetailScheduler(cache: cache, tileSize: 512)
        let sourceA = Fixtures.url(fixtureName)
        let sourceB = URL(fileURLWithPath: "/tmp/other-source.png")

        await scheduler.request(plan: try plan(x: 0), source: sourceA, epoch: 1)
        let keyA = NativeTileKey(sourcePath: sourceA.path, tileSize: 512, x: 0, y: 0)
        await scheduler.acceptDecodedTileForTesting(
            NativeTile(key: keyA, sourceRect: CGRect(x: 0, y: 0, width: 512, height: 320),
                       image: thumbnail(width: 512, height: 320)),
            token: await scheduler.passTokenForTesting)
        XCTAssertEqual(cache.count, 1)

        await scheduler.request(plan: try plan(x: 0), source: sourceB, epoch: 2)
        XCTAssertNil(cache.tile(for: keyA), "the previous source's tiles go")
        XCTAssertEqual(cache.purgedForSourceChange, 1)

        // Same source again: the tiles that are still there are kept, so a disable → re-enable stays
        // warm rather than re-decoding.
        let keyB = NativeTileKey(sourcePath: sourceB.path, tileSize: 512, x: 0, y: 0)
        await scheduler.acceptDecodedTileForTesting(
            NativeTile(key: keyB, sourceRect: CGRect(x: 0, y: 0, width: 512, height: 320),
                       image: thumbnail(width: 512, height: 320)),
            token: await scheduler.passTokenForTesting)
        await scheduler.request(plan: try plan(x: 2048), source: sourceB, epoch: 3)
        XCTAssertNotNil(cache.tile(for: keyB), "a same-source request keeps its warm tiles")
    }
    /// A pass is not finished while tiles it already emitted are still queued for acceptance.
    /// Otherwise a pending plan would start first, bump the generation, and the tail tiles would be
    /// classified as stale even though the provider decoded them successfully.
    func testAPassWaitsForItsTailTilesBeforeFinishing() async throws {
        let cache = NativeTileCache(totalCostLimit: 8 * 1024 * 1024)
        let scheduler = NativeDetailScheduler(cache: cache, tileSize: 512)
        let source = Fixtures.url("oversized-detail.png")
        await scheduler.request(plan: try plan(x: 0), source: source, epoch: 1)
        let token = await scheduler.passTokenForTesting
        let passesAtStart = await scheduler.statistics().passes
        XCTAssertEqual(passesAtStart, 0)

        // The provider emits three tiles and stops, with two of them still queued for acceptance.
        for _ in 0..<3 { await scheduler.noteEmittedTileForTesting() }
        await scheduler.noteProducerFinishedForTesting(token: token, produced: 3)
        let passesAfterProducer = await scheduler.statistics().passes
        XCTAssertEqual(passesAfterProducer, 0,
                       "the pass may not finish while emitted tiles are still queued")

        func tile(_ x: Int) throws -> NativeTile {
            let key = NativeTileKey(sourcePath: source.path, tileSize: 512, x: x, y: 0)
            return NativeTile(key: key, sourceRect: CGRect(x: x, y: 0, width: 512, height: 320),
                              image: try XCTUnwrap(self.thumbnail(width: 512, height: 320)))
        }
        await scheduler.acceptDecodedTileForTesting(try tile(0), token: token)
        await scheduler.acceptDecodedTileForTesting(try tile(512), token: token)
        let passesMidDrain = await scheduler.statistics().passes
        let staleMidDrain = await scheduler.staleDecodedTilesDiscarded
        XCTAssertEqual(passesMidDrain, 0, "still one acceptance outstanding")
        XCTAssertEqual(staleMidDrain, 0,
                       "nothing here is stale: these are tiles the pass really decoded")

        await scheduler.acceptDecodedTileForTesting(try tile(1024), token: token)
        let passesAfterDrain = await scheduler.statistics().passes
        let produced = await scheduler.lastPassProduced
        let accepted = await scheduler.lastPassAcceptedForTesting
        let staleAfterDrain = await scheduler.staleDecodedTilesDiscarded
        XCTAssertEqual(passesAfterDrain, 1,
                       "the pass finishes once its acceptance work is drained")
        XCTAssertEqual(produced, 3, "produced counts what the provider emitted")
        XCTAssertEqual(accepted, 3, "accepted counts what reached the cache")
        XCTAssertEqual(staleAfterDrain, 0, "and no live tile was mislabelled stale")
        XCTAssertEqual(cache.count, 3, "all three are in the cache")
    }

    /// The pending-plan variant: the queued plan starts only after the old pass's tail is accepted,
    /// and those tiles keep the old token, so they are stored rather than discarded.
    func testAPendingPlanStartsOnlyAfterTheTailIsAccepted() async throws {
        let cache = NativeTileCache(totalCostLimit: 8 * 1024 * 1024)
        let scheduler = NativeDetailScheduler(cache: cache, tileSize: 512)
        let source = Fixtures.url("oversized-detail.png")
        await scheduler.request(plan: try plan(x: 0), source: source, epoch: 1)
        let firstToken = await scheduler.passTokenForTesting

        // A small move within the same source: the running pass covers the viewport, so the second
        // request becomes a pending plan instead of starting a new pass.
        await scheduler.request(plan: try plan(x: 512), source: source, epoch: 2)
        let tokenAfterSecondRequest = await scheduler.passTokenForTesting
        XCTAssertEqual(tokenAfterSecondRequest, firstToken,
                       "the second request must not start a new pass yet")

        await scheduler.noteEmittedTileForTesting()
        await scheduler.noteProducerFinishedForTesting(token: firstToken, produced: 1)
        let stillPending = await scheduler.pendingPlanForTesting
        XCTAssertNotNil(stillPending,
                        "the pending plan is still queued until the tail is accepted")

        let key = NativeTileKey(sourcePath: source.path, tileSize: 512, x: 0, y: 0)
        let tile = NativeTile(key: key, sourceRect: CGRect(x: 0, y: 0, width: 512, height: 320),
                              image: try XCTUnwrap(thumbnail(width: 512, height: 320)))
        await scheduler.acceptDecodedTileForTesting(tile, token: firstToken)
        XCTAssertNotNil(cache.tile(for: key),
                        "the tail tile was decoded by a live pass, so it is stored")
        let staleAfterTail = await scheduler.staleDecodedTilesDiscarded
        XCTAssertEqual(staleAfterTail, 0, "it must not be counted as stale")
    }

    /// A pass that really is superseded still drops its late tiles before they reach the cache.
    func testATrulySupersededPassStillDropsItsLateTiles() async throws {
        let cache = NativeTileCache(totalCostLimit: 8 * 1024 * 1024)
        let scheduler = NativeDetailScheduler(cache: cache, tileSize: 512)
        let source = Fixtures.url("oversized-detail.png")
        await scheduler.request(plan: try plan(x: 0), source: source, epoch: 1)
        let oldToken = await scheduler.passTokenForTesting
        await scheduler.noteEmittedTileForTesting()

        // A purge invalidates the pass outright.
        await scheduler.stopAndPurge(epoch: 2)
        let key = NativeTileKey(sourcePath: source.path, tileSize: 512, x: 0, y: 0)
        let tile = NativeTile(key: key, sourceRect: CGRect(x: 0, y: 0, width: 512, height: 320),
                              image: try XCTUnwrap(thumbnail(width: 512, height: 320)))
        await scheduler.acceptDecodedTileForTesting(tile, token: oldToken)
        XCTAssertNil(cache.tile(for: key), "a superseded pass's tile never reaches the cache")
        let staleCount = await scheduler.staleDecodedTilesDiscarded
        XCTAssertEqual(staleCount, 1, "and it is counted as stale, which is what it is")
    }
    /// C. A queued plan keeps the page it was requested for. The pending start used to pass page 0
    /// unconditionally, so a pan on page 2 restarted the pass on page 0 — the wrong page's pixels.
    func testAPendingPlanKeepsItsPageIndex() async throws {
        let cache = NativeTileCache(totalCostLimit: 8 * 1024 * 1024)
        let scheduler = NativeDetailScheduler(cache: cache, tileSize: 512)
        let source = Fixtures.url("oversized-detail.png")
        let first = try plan(x: 0)
        let second = try plan(x: 512)

        await scheduler.request(plan: first, source: source, pageIndex: 2, epoch: 1)
        let runningPage = await scheduler.runningPageIndexForTesting
        XCTAssertEqual(runningPage, 2, "the pass decodes the requested page")

        // A small move inside the same page becomes a queued plan.
        await scheduler.request(plan: second, source: source, pageIndex: 2, epoch: 2)
        let queued = await scheduler.pendingPlanForTesting
        XCTAssertNotNil(queued, "the small move is queued, not started")

        // Finish the running pass so the queued one starts.
        await scheduler.noteEmittedTileForTesting()
        await scheduler.noteProducerFinishedForTesting(token: await scheduler.passTokenForTesting,
                                                       produced: 1)
        let pageAfterQueue = await scheduler.runningPageIndexForTesting
        XCTAssertEqual(pageAfterQueue, 2, "the queued plan starts on its own page, not page 0")
    }

}

/// D. A very long filename must not stretch the selection card past the row.
@MainActor
final class ThumbnailLongFilenameTests: XCTestCase {

    override func setUp() async throws {
        try await super.setUp()
        TestAppKit.ensureApplication()
    }

    private func cell(width: CGFloat = 200, height: CGFloat = 168) -> ThumbnailCellView {
        let cell = ThumbnailCellView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        cell.translatesAutoresizingMaskIntoConstraints = false
        cell.widthAnchor.constraint(equalToConstant: width).isActive = true
        cell.heightAnchor.constraint(equalToConstant: height).isActive = true
        return cell
    }

    private func picture(width: Int, height: Int) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                bytesPerRow: width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.3, green: 0.5, blue: 0.7, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    func testLongFilenamesCannotPushTheCardOutOfTheRow() {
        let names = [
            String(repeating: "a", count: 100),
            String(repeating: "b", count: 200),
            String(repeating: "中文文件名", count: 30),
            String(repeating: "🙂", count: 60),
            String(repeating: "very-long-name-without-spaces", count: 8),
        ]
        let shapes = [(300, 200), (200, 300), (100, 400), (40, 400)]
        for name in names {
            for (width, height) in shapes {
                let subject = cell()
                subject.configure(item: FolderItem(url: URL(fileURLWithPath: "/tmp/" + name + ".png")),
                                  image: nil, isCurrent: true)
                subject.layoutSubtreeIfNeeded()
                subject.setThumbnail(picture(width: width, height: height))
                subject.layoutSubtreeIfNeeded()

                let card = subject.selectionBackgroundView.frame
                let label = subject.nameLabelView.frame
                XCTAssertGreaterThanOrEqual(card.minX, -0.5,
                                            "card escapes on the left (\(width)x\(height), "
                                            + "\(name.prefix(12))…)")
                XCTAssertLessThanOrEqual(card.maxX, subject.bounds.width + 0.5,
                                         "card escapes on the right (\(width)x\(height))")
                XCTAssertLessThanOrEqual(label.maxX, card.maxX + 0.5,
                                         "label escapes the card (\(width)x\(height))")
                XCTAssertGreaterThanOrEqual(label.minX, card.minX - 0.5)
            }
        }
    }
}
