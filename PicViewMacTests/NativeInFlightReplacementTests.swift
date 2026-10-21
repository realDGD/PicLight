import XCTest
import AppKit
@testable import PicViewMac

/// The hard half of same-path replacement: the file changes while a pass for the *old* file
/// is still running.
///
/// `NativeSourceIdentityTests` covers the cache side of the story — a version change drops the
/// previous file's tiles. That is necessary but not sufficient. If the request for the new file
/// is for the viewport the old pass already covers, the scheduler used to return through the
/// "running plan already covers this viewport" fast path: the pass kept its generation token,
/// kept emitting v1 tiles, and every one of them was accepted, stored under the *new* version
/// and published. The cache looked consistent the whole time, because the tiles were stamped
/// with whatever version the map held when they were stored.
@MainActor
final class NativeInFlightReplacementTests: XCTestCase {

    override func setUp() async throws {
        try await super.setUp()
        TestAppKit.ensureApplication()
    }

    // MARK: - A provider that can be held open

    /// A provider that can be held open, and that emits its tile *regardless of cancellation*.
    ///
    /// That is not cheating, it is the race the guard exists for: a real decoder samples the
    /// cancel flag per tile, so a tile the inflate had already produced when the cancel landed is
    /// still handed over. The scheduler — not the provider — has to be the thing that rejects it.
    ///
    /// Each pass paints a different colour, because the two passes for one replaced file produce
    /// tiles with *identical keys*: the key is the path, and the path did not change. Only the
    /// pixels can tell the old file's tile from the new one's.
    private final class GatedProvider: NativeTileProviding, @unchecked Sendable {
        private let lock = NSLock()
        private var starts: [String] = []
        private var emitted = 0
        /// Set false for passes after the first, which should run to completion normally.
        var blockFirstPass = true
        private let gate = DispatchSemaphore(value: 0)

        var startedPaths: [String] {
            lock.lock(); defer { lock.unlock() }
            return starts
        }

        var emittedCount: Int {
            lock.lock(); defer { lock.unlock() }
            return emitted
        }

        /// Lets a blocked call proceed.
        func release() {
            for _ in 0..<8 { gate.signal() }
        }

        func produce(plan: NativeTilePlan, source: URL, pageIndex: Int, gutter: Int,
                     colorSpace: CGColorSpace?, orientation: SourceOrientation,
                     shouldCancel: @Sendable () -> Bool,
                     onTile: @Sendable (NativeTile) -> Void) throws {
            lock.lock()
            let passIndex = starts.count
            starts.append(source.path)
            lock.unlock()

            if passIndex == 0 && blockFirstPass {
                // Bounded, so a failing assertion cannot strand a cooperative thread.
                _ = gate.wait(timeout: .now() + 3)
            }
            guard let coordinate = plan.visible.first else { return }
            let rect = NativeTilePlanner.sourceRect(for: coordinate, tileSize: plan.tileSize,
                                                    sourcePixelSize: CGSize(width: 2048, height: 512))
            guard let tile = Self.tile(key: NativeTileKey(sourcePath: source.path,
                                                          pageIndex: pageIndex,
                                                          tileSize: plan.tileSize,
                                                          x: coordinate.x, y: coordinate.y),
                                       rect: rect, size: plan.tileSize,
                                       color: Self.color(forPass: passIndex)) else { return }
            lock.lock()
            emitted += 1
            lock.unlock()
            onTile(tile)
        }

        /// Pass 0 (the file before the replacement) paints red; every later pass paints green.
        static func color(forPass index: Int) -> CGColor {
            index == 0
                ? CGColor(red: 0.9, green: 0.05, blue: 0.05, alpha: 1)
                : CGColor(red: 0.05, green: 0.9, blue: 0.05, alpha: 1)
        }

        static func tile(key: NativeTileKey, rect: CGRect, size: Int, color: CGColor) -> NativeTile? {
            let side = max(1, min(size, 64))
            guard let context = CGContext(data: nil, width: side, height: side,
                                          bitsPerComponent: 8, bytesPerRow: side * 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return nil }
            context.setFillColor(color)
            context.fill(CGRect(x: 0, y: 0, width: side, height: side))
            guard let image = context.makeImage() else { return nil }
            return NativeTile(key: key, sourceRect: rect, image: image)
        }
    }

    /// The top-left pixel of a tile, straight out of its buffer: the tiles are premultiplied RGBA8,
    /// so no redraw is needed and none is done (a 1×1 redraw would resample and blur the answer).
    private func topLeftPixel(of tile: NativeTile) -> [UInt8] {
        guard let data = tile.image.dataProvider?.data as Data? else { return [] }
        return Array(data.prefix(4))
    }

    /// Red = the file that was replaced; green = the replacement. Classified by channel dominance
    /// rather than by exact bytes, because the fill's colour space is not this test's subject.
    private func describe(_ pixel: [UInt8]) -> String {
        guard pixel.count == 4 else { return "no pixels" }
        if pixel[0] > 128, pixel[1] < 128 { return "the replaced file's pixels (red)" }
        if pixel[1] > 128, pixel[0] < 128 { return "the replacement's pixels (green)" }
        return "neither colour: \(pixel)"
    }

    // MARK: - Fixtures

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("piclight-in-flight-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    /// A file whose *bytes* differ visibly from `other`, so a test failure reads as "the wrong
    /// picture" rather than "an equal-looking buffer".
    private func writeImage(_ byte: UInt8, to url: URL, length: Int = 4_096) throws {
        try Data(repeating: byte, count: length).write(to: url)
    }

    private func plan() throws -> NativeTilePlan {
        try XCTUnwrap(NativeTilePlanner.plan(sourceRect: CGRect(x: 0, y: 0, width: 512, height: 512),
                                             sourcePixelSize: CGSize(width: 2048, height: 512),
                                             tileSize: 512, ring: 0))
    }

    /// Waits for the blocked pass to reach the provider. The condition is the evidence; a sleep
    /// would only be evidence that time passed.
    private func waitForStarts(_ provider: GatedProvider, count: Int,
                               timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while provider.startedPaths.count < count, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        return provider.startedPaths.count >= count
    }

    /// Publication is observed from the pass's own thread, so the record of it is a lock-protected
    /// box rather than a captured array. Tiles, not keys: the two passes for one replaced file
    /// produce *identical* keys, so only the pixels can say which pass a publication came from.
    private final class PublishedTiles: @unchecked Sendable {
        private let lock = NSLock()
        private var tiles: [NativeTile] = []
        func append(_ tile: NativeTile) { lock.lock(); tiles.append(tile); lock.unlock() }
        var all: [NativeTile] { lock.lock(); defer { lock.unlock() }; return tiles }
    }

    private func waitFor(_ condition: @escaping () -> Bool, timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        return condition()
    }

    /// The async counterpart: the scheduler is an actor, so its counters are only readable with
    /// `await`. Polling rather than sleeping keeps the assertion the evidence.
    private func waitForAsync(_ condition: @escaping () async -> Bool,
                              timeout: TimeInterval = 5) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return await condition()
    }

    /// Tiles the scheduler refused at the store boundary, by either guard.
    private func discardedTileCount(_ scheduler: NativeDetailScheduler) async -> Int {
        await scheduler.staleDecodedTilesDiscarded + scheduler.replacedSourceTilesDiscarded
    }

    // MARK: - The reproduction

    /// The scenario from the spec, step by step:
    ///
    /// 1. `X.png` holds v1
    /// 2. a native pass A is requested and blocks in the provider
    /// 3. `X.png` is overwritten in place with visibly different v2
    /// 4. a request for v2 arrives
    /// 5. pass A is released and emits a v1 tile
    ///
    /// The v1 tile must never be stored, published, or stamped with v2's identity.
    func testALateTileFromTheReplacedFileIsRejectedAndTheNewFileGetsItsOwnPass() async throws {
        let directory = try makeTemporaryDirectory()
        let file = directory.appendingPathComponent("X.png")
        try writeImage(0x11, to: file)

        let provider = GatedProvider()
        defer { provider.release() }
        let cache = NativeTileCache(totalCostLimit: 8 * 1024 * 1024)
        let scheduler = NativeDetailScheduler(provider: provider, cache: cache, tileSize: 512)

        let published = PublishedTiles()
        await scheduler.setOnTile { tile in published.append(tile) }

        await scheduler.request(plan: try plan(), source: file, pageIndex: 0, epoch: 1)
        XCTAssertTrue(waitForStarts(provider, count: 1), "pass A must be running")
        let tokenBeforeReplacement = await scheduler.passTokenForTesting

        // The user saves over the file from another application: same path, different bytes.
        try writeImage(0x22, to: file, length: 8_192)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: file.path)

        // The new request is for the *same* viewport, which is exactly the case the fast path
        // used to swallow.
        await scheduler.request(plan: try plan(), source: file, pageIndex: 0, epoch: 2)

        let tokenAfterReplacement = await scheduler.passTokenForTesting
        XCTAssertNotEqual(tokenAfterReplacement, tokenBeforeReplacement,
                          "a replaced file is a new source generation, so the old pass is invalidated")
        XCTAssertTrue(waitForStarts(provider, count: 2),
                      "a pass for the new file must start; the old pass cannot cover it")

        // The old pass is released and emits its v1 tile. Asserting the tile was really produced
        // matters: without it the discard check below would pass vacuously if the provider had
        // simply given up.
        let emittedBeforeRelease = provider.emittedCount
        provider.release()
        XCTAssertTrue(waitFor { provider.emittedCount > emittedBeforeRelease },
                      "the released pass must actually hand over its tile")
        _ = await waitForAsync { await self.discardedTileCount(scheduler) > 0 }

        let discarded = await discardedTileCount(scheduler)
        XCTAssertGreaterThanOrEqual(discarded, 1,
                                    "the v1 tile is discarded before it can be stored")

        // Nothing from the old pass may be resident or published. Both passes key their tiles by
        // path, so the assertion has to be about pixels: the picture on screen must be the
        // replacement's, never the file it replaced.
        let path = file.path
        let staleKey = NativeTileKey(sourcePath: path, tileSize: 512, x: 0, y: 0)
        let resident = try XCTUnwrap(cache.tile(for: staleKey),
                                     "the new file's pass must have populated the cache")
        XCTAssertEqual(describe(topLeftPixel(of: resident)), "the replacement's pixels (green)",
                       "the resident tile is the old file's pixels wearing the new file's identity")

        XCTAssertFalse(published.all.isEmpty, "the new pass must publish")
        for tile in published.all {
            XCTAssertEqual(describe(topLeftPixel(of: tile)), "the replacement's pixels (green)",
                           "a tile from the replaced file was published")
        }
    }

    /// The identity guard on its own, with the pass token still valid.
    ///
    /// The token guard answers "is this the current pass?". It cannot answer "is the file this
    /// pass is decoding still the file at that path?" — and that is the question that decides
    /// whether a tile may be *stored*, because the cache stamps whatever version it currently
    /// holds. This drives the store boundary directly with a live token and a replaced version.
    func testATileFromAReplacedFileIsRefusedAtTheStoreBoundary() async throws {
        let directory = try makeTemporaryDirectory()
        let file = directory.appendingPathComponent("boundary.png")
        try writeImage(0x66, to: file)

        let cache = NativeTileCache(totalCostLimit: 8 * 1024 * 1024)
        let scheduler = NativeDetailScheduler(provider: GatedProvider(), cache: cache, tileSize: 512)
        await scheduler.request(plan: try plan(), source: file, pageIndex: 0, epoch: 1)
        let liveToken = await scheduler.passTokenForTesting
        let passVersion = await scheduler.runningVersionTokenForTesting
        XCTAssertNotNil(passVersion, "the pass records the identity it is decoding")

        // The file is replaced and the replacement's version becomes the recorded one. No new
        // request is made, so the pass token is untouched: only the identity guard can see this.
        try writeImage(0x77, to: file, length: 8_192)
        let replacementVersion = SourceFileIdentity.read(at: file).versionToken
        XCTAssertNotEqual(replacementVersion, passVersion)
        cache.setSourceVersion(replacementVersion, for: file.path)

        let key = NativeTileKey(sourcePath: file.path, tileSize: 512, x: 0, y: 0)
        let tile = try XCTUnwrap(GatedProvider.tile(key: key,
                                                    rect: CGRect(x: 0, y: 0, width: 512, height: 512),
                                                    size: 512,
                                                    color: GatedProvider.color(forPass: 0)))
        await scheduler.acceptDecodedTileForTesting(tile, token: liveToken)

        XCTAssertNil(cache.tile(for: key),
                     "a tile decoded from the replaced file cannot enter the cache under the new version")
        let replaced = await scheduler.replacedSourceTilesDiscarded
        let stale = await scheduler.staleDecodedTilesDiscarded
        XCTAssertEqual(replaced, 1, "the identity guard is what refused it")
        XCTAssertEqual(stale, 0, "the pass token was still valid, so this is not a stale pass")
    }

    /// The other half of the same contract: a request for a file that did *not* change must keep
    /// taking the fast path. Otherwise every viewport update would restart the pass and the
    /// disable → re-enable warmth the cache work paid for would be gone.
    func testAnUnchangedFileKeepsTheRunningPass() async throws {
        let directory = try makeTemporaryDirectory()
        let file = directory.appendingPathComponent("stable.png")
        try writeImage(0x33, to: file)

        let provider = GatedProvider()
        defer { provider.release() }
        let scheduler = NativeDetailScheduler(provider: provider,
                                              cache: NativeTileCache(totalCostLimit: 8 * 1024 * 1024),
                                              tileSize: 512)

        await scheduler.request(plan: try plan(), source: file, pageIndex: 0, epoch: 1)
        XCTAssertTrue(waitForStarts(provider, count: 1))
        let token = await scheduler.passTokenForTesting

        // Same viewport, unchanged file: the running pass already covers it.
        await scheduler.request(plan: try plan(), source: file, pageIndex: 0, epoch: 2)

        let tokenAfter = await scheduler.passTokenForTesting
        let invalidations = await scheduler.replacedSourceInvalidations
        XCTAssertEqual(tokenAfter, token,
                       "an unchanged file keeps its pass and its warmed tiles")
        XCTAssertEqual(provider.startedPaths.count, 1, "and no second pass is started")
        XCTAssertEqual(invalidations, 0,
                       "a stable file is never mistaken for a replacement")
    }

}
