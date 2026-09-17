import XCTest
import CoreGraphics
@testable import PicViewMac

/// Cache identity: url + page + level. The B-series gate measured that a preload
/// at one level can never satisfy a request at another, and the E3 gate measured
/// that `NSCache` will happily evict the entry that is on screen when the working
/// set is over budget — so these tests pin both the aliasing rules and the purge
/// bookkeeping that protects the visible bitmap.
final class CacheIdentityTests: XCTestCase {

    private func syntheticHead(width: Int = 32, height: Int = 24,
                               url: URL = URL(fileURLWithPath: "/tmp/identity.png")) -> DecodedImageHead {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let descriptor = ImageDescriptor(sourceURL: url,
                                         pixelSize: CGSize(width: 48000, height: 32000))
        return DecodedImageHead(image: context.makeImage()!, descriptor: descriptor,
                                metadata: ImageMetadata())
    }

    func testLevelsDoNotAlias() {
        let cache = DecodeCache()
        let url = URL(fileURLWithPath: "/tmp/identity.png")
        let bounded = DecodeCacheKey(url: url, level: .bucket(4096))
        cache.store(head: syntheticHead(), for: bounded)

        XCTAssertNotNil(cache.head(for: bounded))
        XCTAssertNil(cache.head(for: DecodeCacheKey(url: url, level: .bucket(8192))),
                     "a 4096 entry must not satisfy an 8192 request")
        XCTAssertNil(cache.head(for: DecodeCacheKey(url: url, level: .native)))
    }

    func testPagesDoNotAlias() {
        let cache = DecodeCache()
        let url = URL(fileURLWithPath: "/tmp/identity.png")
        let page0 = DecodeCacheKey(url: url, pageIndex: 0, level: .native)
        let page1 = DecodeCacheKey(url: url, pageIndex: 1, level: .native)
        cache.store(head: syntheticHead(), for: page0)

        XCTAssertNotNil(cache.head(for: page0))
        XCTAssertNil(cache.head(for: page1))
    }

    func testFramesCarryLevelAndPageIdentity() {
        let cache = DecodeCache()
        let url = URL(fileURLWithPath: "/tmp/identity.gif")
        let key = DecodeCacheKey(url: url, level: .native)
        let frame = syntheticHead()
        cache.store(frame: DecodedFrame(image: frame.image, index: 2, duration: 0.1), for: key)

        XCTAssertNotNil(cache.frame(for: key, index: 2))
        XCTAssertNil(cache.frame(for: DecodeCacheKey(url: url, level: .bucket(4096)), index: 2),
                     "frame identity includes the level")
        XCTAssertNil(cache.frame(for: DecodeCacheKey(url: url, pageIndex: 1, level: .native), index: 2),
                     "and the page")
    }

    /// The bug this test exists for: with `currentURL`-only bookkeeping the purge
    /// cannot tell which level is on screen, so it keeps the wrong bitmap.
    func testPurgeKeepsTheCurrentPageAndLevel() {
        let cache = DecodeCache()
        let url = URL(fileURLWithPath: "/tmp/identity.png")
        let onScreen = DecodeCacheKey(url: url, pageIndex: 0, level: .bucket(8192))
        let otherLevel = DecodeCacheKey(url: url, pageIndex: 0, level: .bucket(4096))
        let otherPage = DecodeCacheKey(url: url, pageIndex: 1, level: .bucket(8192))
        let otherFile = DecodeCacheKey(url: URL(fileURLWithPath: "/tmp/other.png"), level: .native)
        for key in [onScreen, otherLevel, otherPage, otherFile] {
            cache.store(head: syntheticHead(), for: key)
        }

        cache.setCurrent(onScreen)
        NotificationCenter.default.post(name: .decodeCacheMemoryPressure, object: nil)

        XCTAssertNotNil(cache.head(for: onScreen), "the on-screen bitmap survives")
        XCTAssertNil(cache.head(for: otherLevel), "another level of the same file does not")
        XCTAssertNil(cache.head(for: otherPage), "another page of the same file does not")
        XCTAssertNil(cache.head(for: otherFile), "another file does not")
    }

    func testPurgeKeepingNothingEmptiesTheCache() {
        let cache = DecodeCache()
        let key = DecodeCacheKey(url: URL(fileURLWithPath: "/tmp/identity.png"), level: .native)
        cache.store(head: syntheticHead(), for: key)
        cache.purge(keeping: nil)
        XCTAssertNil(cache.head(for: key))
    }

    /// Pins the B-series decision (768 MiB bitmap budget) so a future edit cannot
    /// quietly restore the pre-benchmark value.
    func testBudgetIsTheBenchmarkedValue() {
        XCTAssertEqual(DecodeCache().budgetBytes, 768 * 1024 * 1024)
        XCTAssertEqual(DecodeCache(totalCostLimit: 1_000).budgetBytes, 1_000)
    }

    /// E3 measured that an entry whose cost exceeds the whole budget does not
    /// survive, and that `NSCache` decides this silently. No caller may assume such
    /// an entry stays cached — but it must not poison the cache for entries that do
    /// fit. (The pre-benchmark code would have hit exactly this with a 5.7 GiB entry
    /// against a 384 MiB budget.)
    func testOversizedEntryDoesNotPoisonTheCache() {
        let cache = DecodeCache(totalCostLimit: 64 * 1024)      // 64 KiB
        let big = DecodeCacheKey(url: URL(fileURLWithPath: "/tmp/big.png"), level: .native)
        let small = DecodeCacheKey(url: URL(fileURLWithPath: "/tmp/small.png"), level: .native)
        cache.store(head: syntheticHead(width: 512, height: 512), for: big)     // 1 MiB, way over budget
        cache.store(head: syntheticHead(), for: small)                          // ~3 KiB, fits
        XCTAssertNotNil(cache.head(for: small),
                        "an entry that fits must still be retained after an oversized store")
    }
}
