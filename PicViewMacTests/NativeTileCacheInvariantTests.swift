import XCTest
import AppKit
@testable import PicViewMac

/// The CPU tile cache now carries a second dimension — the source version — on top of
/// the byte budget, pinning and LRU. These are the invariants that must hold after
/// *every* operation, whichever combination of them ran.
@MainActor
final class NativeTileCacheInvariantTests: XCTestCase {

    override func setUp() async throws {
        try await super.setUp()
        TestAppKit.ensureApplication()
    }

    // MARK: - Fixtures

    private func tile(path: String = "/tmp/source.png", x: Int, size: Int = 64) -> NativeTile {
        let key = NativeTileKey(sourcePath: path, tileSize: size, x: x, y: 0)
        let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                                bytesPerRow: size * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        return NativeTile(key: key, sourceRect: CGRect(x: 0, y: 0, width: size, height: size),
                          image: context.makeImage()!)
    }

    private func key(x: Int, path: String = "/tmp/source.png", size: Int = 64) -> NativeTileKey {
        NativeTileKey(sourcePath: path, tileSize: size, x: x, y: 0)
    }

    /// The invariant that makes the byte budget meaningful: the running total is the sum of
    /// the resident tiles.
    ///
    /// Deliberately *not* asserted here: `pinnedKeys ⊆ keys`. Pins are placed when a request
    /// is made, before the tiles are decoded, so a pinned key that is not resident yet is
    /// normal. What must hold is that a pin never *outlives* its tile, which the individual
    /// tests below check where they remove one.
    private func assertInvariants(_ cache: NativeTileCache, _ label: String,
                                  file: StaticString = #filePath, line: UInt = #line) {
        let keys = cache.keysForTesting
        let total = keys.reduce(0) { sum, key in
            sum + (cache.tile(for: key)?.byteCost ?? 0)
        }
        XCTAssertEqual(cache.byteCount, total,
                       "\(label): storedBytes must equal the sum of the resident costs",
                       file: file, line: line)
        XCTAssertEqual(cache.count, keys.count, "\(label): count agrees with the key set",
                       file: file, line: line)
    }

    // MARK: - Invariants

    func testStoreKeepsTheByteTotalExact() {
        let cache = NativeTileCache(totalCostLimit: 8 * 1024 * 1024)
        assertInvariants(cache, "empty")
        for x in stride(from: 0, to: 640, by: 64) {
            cache.store(tile(x: x))
            assertInvariants(cache, "after storing x=\(x)")
        }
        XCTAssertEqual(cache.count, 10)
    }

    /// Re-decoding the same tile must replace its cost, not add a second copy of it.
    func testOverwritingATileDoesNotDoubleCountItsBytes() {
        let cache = NativeTileCache(totalCostLimit: 8 * 1024 * 1024)
        cache.store(tile(x: 0, size: 64))
        let single = cache.byteCount
        cache.store(tile(x: 0, size: 64))
        XCTAssertEqual(cache.count, 1)
        XCTAssertEqual(cache.byteCount, single, "the same key holds one tile's worth of bytes")
        assertInvariants(cache, "after an overwrite")
    }

    func testEvictionDropsTheLeastRecentlyUsedUnpinnedTile() {
        let oneTile = tile(x: 0).byteCost
        let cache = NativeTileCache(totalCostLimit: oneTile * 3)
        for x in [0, 64, 128] { cache.store(tile(x: x)) }
        _ = cache.tile(for: key(x: 64))            // 64 becomes the most recently used
        cache.store(tile(x: 192))                  // over budget → one eviction

        XCTAssertEqual(cache.evictionCount, 1)
        XCTAssertNil(cache.tile(for: key(x: 0)), "the oldest untouched tile goes first")
        XCTAssertNotNil(cache.tile(for: key(x: 64)))
        XCTAssertNotNil(cache.tile(for: key(x: 128)))
        XCTAssertNotNil(cache.tile(for: key(x: 192)))
        assertInvariants(cache, "after eviction")
    }

    /// The one thing an LRU must never do: evict what the viewport is showing. When the
    /// only unpinned tile is the newcomer, the newcomer is what goes.
    func testEvictionNeverTouchesAPinnedTile() {
        let oneTile = tile(x: 0).byteCost
        let cache = NativeTileCache(totalCostLimit: oneTile * 4)
        for x in [0, 64, 128, 192] { cache.store(tile(x: x)) }
        cache.pin([key(x: 0), key(x: 64), key(x: 128), key(x: 192)])   // everything is visible

        cache.store(tile(x: 256))                  // over budget with nothing else to drop

        XCTAssertEqual(cache.evictionCount, 1)
        for x in [0, 64, 128, 192] {
            XCTAssertNotNil(cache.tile(for: key(x: x)),
                            "a pinned tile must never be evicted (x=\(x))")
        }
        XCTAssertNil(cache.tile(for: key(x: 256)), "the unpinned newcomer is the one dropped")
        assertInvariants(cache, "after a pinned-only eviction")
    }

    func testPurgeKeepingRecomputesTheByteTotal() {
        let cache = NativeTileCache(totalCostLimit: 8 * 1024 * 1024)
        for x in [0, 64, 128] { cache.store(tile(x: x)) }
        cache.pin([key(x: 0), key(x: 64)])

        cache.purge(keeping: [key(x: 0)])

        XCTAssertEqual(cache.keysForTesting, [key(x: 0)])
        XCTAssertEqual(cache.byteCount, tile(x: 0).byteCost)
        XCTAssertEqual(cache.pinnedKeys, [key(x: 0)],
                       "a surviving tile keeps its pin, and its neighbour's pin goes with the tile")
        assertInvariants(cache, "after purge(keeping:)")
    }

    /// Purging another source is exact: everything from that path goes, nothing else.
    func testPurgeExceptSourceIsExact() {
        let cache = NativeTileCache(totalCostLimit: 8 * 1024 * 1024)
        cache.store(tile(path: "/tmp/a.png", x: 0))
        cache.store(tile(path: "/tmp/a.png", x: 64))
        cache.store(tile(path: "/tmp/b.png", x: 0))
        cache.pin([key(x: 0, path: "/tmp/a.png"), key(x: 0, path: "/tmp/b.png")])

        cache.purge(exceptSourcePath: "/tmp/b.png")

        XCTAssertEqual(cache.keysForTesting, [key(x: 0, path: "/tmp/b.png")],
                       "the other source is gone and this one is untouched")
        XCTAssertEqual(cache.purgedForSourceChange, 2)
        XCTAssertEqual(cache.pinnedKeys, [key(x: 0, path: "/tmp/b.png")])
        assertInvariants(cache, "after purge(exceptSourcePath:)")
    }

    func testRemoveAllLeavesNothingBehind() {
        let cache = NativeTileCache(totalCostLimit: 8 * 1024 * 1024)
        for x in [0, 64] { cache.store(tile(x: x)) }
        cache.pin([key(x: 0)])

        cache.removeAll()

        XCTAssertEqual(cache.count, 0)
        XCTAssertEqual(cache.byteCount, 0)
        XCTAssertEqual(cache.pinnedKeys, [])
        XCTAssertEqual(cache.sourceVersionCountForTesting, 0,
                       "the version records describe tiles; with no tiles they must go too")
        assertInvariants(cache, "after removeAll")
    }

    // MARK: - The source-version map is bounded

    /// The map is keyed by path and the viewer keeps browsing, so an entry that outlives its tiles
    /// would be one record per image ever opened — an unbounded leak sitting behind a bounded
    /// cache. A record may only survive while its tiles do, which bounds the map by the cache's own
    /// byte budget rather than by how many images the user looks at.
    func testVersionRecordsDoNotAccumulateForSourcesWhoseTilesAreGone() {
        // Three tiles of budget, browsed across two hundred files: every tile is evicted on
        // schedule, so anything left over is a record with nothing to describe.
        let oneTile = tile(x: 0).byteCost
        let cache = NativeTileCache(totalCostLimit: oneTile * 3)
        for index in 0..<200 {
            let path = "/tmp/browsed-\(index).png"
            cache.setSourceVersion("v1", for: path)
            cache.store(tile(path: path, x: 0))
            XCTAssertLessThanOrEqual(cache.sourceVersionCountForTesting, 4,
                                     "file \(index) left version records behind: "
                                     + "\(cache.sourceVersionCountForTesting)")
        }
        XCTAssertGreaterThan(cache.evictionCount, 100,
                             "the scenario must really be evicting, or it proves nothing")
        assertInvariants(cache, "after browsing")
    }

    /// …but a record whose tiles are still resident is what makes a re-request warm, so it stays.
    func testAVersionRecordSurvivesWhileItsTilesDo() {
        let cache = NativeTileCache(totalCostLimit: 8 * 1024 * 1024)
        cache.setSourceVersion("v1", for: "/tmp/kept.png")
        cache.store(tile(path: "/tmp/kept.png", x: 0))

        cache.setSourceVersion("v1", for: "/tmp/visiting.png")

        XCTAssertEqual(cache.sourceVersionCountForTesting, 2,
                       "the resident source keeps its record alongside the current one")
        XCTAssertEqual(cache.sourceVersion(for: "/tmp/kept.png"), "v1")
        XCTAssertEqual(cache.sourceVersion(for: "/tmp/visiting.png"), "v1")
    }

    /// Purging another source drops that source's records with its tiles.
    func testPurgingASourceDropsItsVersionRecord() {
        let cache = NativeTileCache(totalCostLimit: 8 * 1024 * 1024)
        cache.setSourceVersion("v1", for: "/tmp/gone.png")
        cache.setSourceVersion("v1", for: "/tmp/kept.png")
        cache.store(tile(path: "/tmp/gone.png", x: 0))
        cache.store(tile(path: "/tmp/kept.png", x: 0))

        cache.purge(exceptSourcePath: "/tmp/kept.png")

        XCTAssertNil(cache.sourceVersion(for: "/tmp/gone.png"),
                     "a source with no tiles has no identity to remember")
        XCTAssertEqual(cache.sourceVersion(for: "/tmp/kept.png"), "v1")
    }

    /// A version change is not a licence to leave the old record behind either.
    func testAVersionChangeKeepsOneRecordPerPath() {
        let cache = NativeTileCache(totalCostLimit: 8 * 1024 * 1024)
        cache.setSourceVersion("v1", for: "/tmp/photo.png")
        cache.store(tile(path: "/tmp/photo.png", x: 0))
        for version in ["v2", "v3", "v4"] { cache.setSourceVersion(version, for: "/tmp/photo.png") }
        XCTAssertEqual(cache.sourceVersionCountForTesting, 1, "one path, one record")
        XCTAssertEqual(cache.sourceVersion(for: "/tmp/photo.png"), "v4")
    }

    /// Stated where it can be checked: when a version change removes a tile, it removes the pin
    /// that was protecting it in the same breath.
    func testAVersionChangeTakesThePinWithTheTile() {
        let cache = NativeTileCache(totalCostLimit: 8 * 1024 * 1024)
        cache.setSourceVersion("v1", for: "/tmp/photo.png")
        cache.store(tile(path: "/tmp/photo.png", x: 0))
        cache.pin([key(x: 0, path: "/tmp/photo.png")])
        XCTAssertTrue(cache.pinnedKeys.isSubset(of: cache.keysForTesting))

        cache.setSourceVersion("v2", for: "/tmp/photo.png")

        XCTAssertEqual(cache.pinnedKeys, [], "a pin may not outlive the tile it protected")
        assertInvariants(cache, "after a version change with a pin")
    }

    /// The version check removes tiles too, so it has to keep the same books as the
    /// other removals.
    func testAVersionChangeKeepsTheByteTotalExact() {
        let cache = NativeTileCache(totalCostLimit: 8 * 1024 * 1024)
        cache.setSourceVersion("v1", for: "/tmp/a.png")
        cache.setSourceVersion("v1", for: "/tmp/b.png")
        cache.store(tile(path: "/tmp/a.png", x: 0))
        cache.store(tile(path: "/tmp/a.png", x: 64))
        cache.store(tile(path: "/tmp/b.png", x: 0))
        cache.pin([key(x: 0, path: "/tmp/a.png")])

        cache.setSourceVersion("v2", for: "/tmp/a.png")

        XCTAssertEqual(cache.keysForTesting, [key(x: 0, path: "/tmp/b.png")])
        XCTAssertEqual(cache.byteCount, tile(path: "/tmp/b.png", x: 0).byteCost)
        XCTAssertEqual(cache.pinnedKeys, [], "the replaced file's pin goes with it")
        XCTAssertEqual(cache.versionMismatches, 2)
        assertInvariants(cache, "after a version change")
    }

    /// A long mixed sequence, checked at every step: this is the shape the viewer
    /// actually produces (store while panning, pin the visible set, switch source).
    func testMixedSequenceKeepsEveryInvariant() {
        let cache = NativeTileCache(totalCostLimit: 6 * 64 * 64 * 4)
        cache.setSourceVersion("v1", for: "/tmp/a.png")
        cache.setSourceVersion("v1", for: "/tmp/b.png")
        for round in 0..<12 {
            let path = round < 8 ? "/tmp/a.png" : "/tmp/b.png"
            for x in stride(from: 0, to: 64 * 6, by: 64) {
                cache.store(tile(path: path, x: x + round * 8))
            }
            // Pin the newest three tiles of this round for this path: resident, so the pin is
            // protecting something real, which is the shape the viewer produces.
            cache.pin(Set([192, 256, 320].map { key(x: $0 + round * 8, path: path) }))
            XCTAssertTrue(cache.pinnedKeys.isSubset(of: cache.keysForTesting),
                          "round \(round): every pin here is on a resident tile")
            if round == 8 { cache.purge(exceptSourcePath: "/tmp/b.png") }
            if round == 10 { cache.setSourceVersion("v2", for: "/tmp/b.png") }
            assertInvariants(cache, "round \(round)")
            XCTAssertLessThanOrEqual(cache.byteCount, cache.totalCostLimit,
                                     "the budget bounds the unpinned working set")
        }
    }
}
