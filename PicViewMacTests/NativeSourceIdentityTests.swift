import XCTest
import AppKit
@testable import PicViewMac

/// A tile key is a path, so the cache has to know *which file* the path held when the
/// tile was decoded. Without that, overwriting `photo.png` from another app left the
/// previous file's pixels on screen: the path matched, the key matched, the picture
/// was simply the wrong one.
@MainActor
final class NativeSourceIdentityTests: XCTestCase {

    private let fixtureName = "oversized-detail.png"

    override func setUp() async throws {
        try await super.setUp()
        TestAppKit.ensureApplication()
    }

    // MARK: - Helpers

    private func tile(path: String, x: Int, size: Int = 64) -> NativeTile {
        let key = NativeTileKey(sourcePath: path, tileSize: size, x: x, y: 0)
        let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                                bytesPerRow: size * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.3, green: 0.3, blue: 0.3, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        return NativeTile(key: key, sourceRect: CGRect(x: 0, y: 0, width: size, height: size),
                          image: context.makeImage()!)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("piclight-source-identity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    // MARK: - The version stamp

    /// The version must change when a file is replaced at the same path, even when the
    /// new file has the same length.
    func testTheVersionFollowsAReplacementAtTheSamePath() throws {
        let directory = try makeTemporaryDirectory()
        let file = directory.appendingPathComponent("photo.png")
        try Data(repeating: 0x11, count: 4_096).write(to: file)
        let first = NativeDetailScheduler.sourceVersion(of: file)

        // Same length, different bytes, later modification date: size alone cannot see
        // this, which is why the version carries both.
        try Data(repeating: 0x22, count: 4_096).write(to: file)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(10)], ofItemAtPath: file.path)
        let second = NativeDetailScheduler.sourceVersion(of: file)

        XCTAssertNotEqual(first, second,
                          "a replaced file must not keep its identity")
    }

    func testTheVersionIsStableForAnUnchangedFile() throws {
        let file = Fixtures.url(fixtureName)
        XCTAssertEqual(NativeDetailScheduler.sourceVersion(of: file),
                       NativeDetailScheduler.sourceVersion(of: file))
    }

    // MARK: - The cache drops what the version no longer matches

    func testChangingTheVersionDropsOnlyThatPathsTiles() {
        let cache = NativeTileCache(totalCostLimit: 8 * 1024 * 1024)
        let other = "/tmp/another-source.png"
        cache.setSourceVersion("v1", for: "/tmp/photo.png")
        cache.setSourceVersion("v1", for: other)
        cache.store(tile(path: "/tmp/photo.png", x: 0))
        cache.store(tile(path: "/tmp/photo.png", x: 64))
        cache.store(tile(path: other, x: 0))
        XCTAssertEqual(cache.count, 3)

        cache.setSourceVersion("v2", for: "/tmp/photo.png")

        XCTAssertEqual(cache.count, 1, "only the replaced file's tiles go")
        XCTAssertNotNil(cache.tile(for: NativeTileKey(sourcePath: other, tileSize: 64, x: 0, y: 0)))
        XCTAssertEqual(cache.versionMismatches, 2, "both stale tiles are accounted for")
        XCTAssertEqual(cache.byteCount, tile(path: other, x: 0).byteCost,
                       "and the byte total follows them out")
    }

    func testAnUnchangedVersionKeepsTheTiles() {
        let cache = NativeTileCache(totalCostLimit: 8 * 1024 * 1024)
        cache.setSourceVersion("v1", for: "/tmp/photo.png")
        cache.store(tile(path: "/tmp/photo.png", x: 0))

        cache.setSourceVersion("v1", for: "/tmp/photo.png")

        XCTAssertEqual(cache.count, 1, "a re-request for the same file stays warm")
        XCTAssertEqual(cache.versionMismatches, 0)
    }

    /// A tile decoded before any version was known is stamped with the empty version, so
    /// the first real version always replaces it rather than trusting it.
    func testATileStoredBeforeAnyVersionIsNotTrusted() {
        let cache = NativeTileCache(totalCostLimit: 8 * 1024 * 1024)
        cache.store(tile(path: "/tmp/photo.png", x: 0))
        cache.setSourceVersion("v1", for: "/tmp/photo.png")
        XCTAssertEqual(cache.count, 0, "an unstamped tile cannot be assumed current")
        XCTAssertEqual(cache.versionMismatches, 1)
    }

    // MARK: - End to end through a request

    /// The whole point: the pass for the *new* file must not serve the old file's tile.
    func testARequestForAReplacedFileCannotServeTheOldTile() async throws {
        let directory = try makeTemporaryDirectory()
        let file = directory.appendingPathComponent("replaced.png")
        try Data(repeating: 0x33, count: 2_048).write(to: file)
        let oldVersion = NativeDetailScheduler.sourceVersion(of: file)

        let cache = NativeTileCache(totalCostLimit: 8 * 1024 * 1024)
        cache.setSourceVersion(oldVersion, for: file.path)
        cache.store(tile(path: file.path, x: 0))
        XCTAssertEqual(cache.count, 1, "the old file's tile is resident")

        // The user saves over the file while it is on screen.
        try Data(repeating: 0x44, count: 4_096).write(to: file)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(30)], ofItemAtPath: file.path)

        let scheduler = NativeDetailScheduler(cache: cache, tileSize: 64)
        let plan = try XCTUnwrap(NativeTilePlanner.plan(sourceRect: CGRect(x: 0, y: 0, width: 64,
                                                                          height: 64),
                                                        sourcePixelSize: CGSize(width: 512, height: 512),
                                                        tileSize: 64, ring: 0))
        await scheduler.request(plan: plan, source: file, epoch: 1)

        XCTAssertNil(cache.tile(for: NativeTileKey(sourcePath: file.path, tileSize: 64, x: 0, y: 0)),
                     "the replaced file's tiles must be gone before the new pass runs")
        XCTAssertEqual(cache.versionMismatches, 1)
    }
}
