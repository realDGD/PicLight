import XCTest
import CoreGraphics
@testable import PicViewMac

final class ImageSortTests: XCTestCase {
    private func item(_ name: String, size: Int64? = nil, modified: Date? = nil,
                      created: Date? = nil, pixels: CGSize? = nil) -> FolderItem {
        FolderItem(url: URL(fileURLWithPath: "/tmp/\(name)"), byteSize: size,
                   creationDate: created, modificationDate: modified, pixelSize: pixels)
    }

    func testNaturalFilenameOrderPuts2Before10() {
        let items = [item("10.jpg"), item("2.jpg"), item("1.jpg"), item("a.jpg")]
        let sorted = ImageSort.sort(items, by: .filename)
        XCTAssertEqual(sorted.map(\.displayName), ["1.jpg", "2.jpg", "10.jpg", "a.jpg"])
    }

    func testNaturalOrderIsCaseInsensitiveLikeFinder() {
        let items = [item("b.JPG"), item("A.jpg"), item("c.jpg")]
        let sorted = ImageSort.sort(items, by: .filename)
        XCTAssertEqual(sorted.map(\.displayName), ["A.jpg", "b.JPG", "c.jpg"])
    }

    func testDescendingFilenameOrderReversesTheResult() {
        let items = [item("1.jpg"), item("2.jpg"), item("10.jpg")]
        let sorted = ImageSort.sort(items, by: .filename, direction: .descending)
        XCTAssertEqual(sorted.map(\.displayName), ["10.jpg", "2.jpg", "1.jpg"])
    }

    func testModificationAndCreationDateSorting() {
        let older = Date(timeIntervalSince1970: 1000)
        let newer = Date(timeIntervalSince1970: 2000)
        let items = [item("a.jpg", modified: newer, created: older),
                     item("b.jpg", modified: older, created: newer)]
        XCTAssertEqual(ImageSort.sort(items, by: .modificationDate).map(\.displayName), ["b.jpg", "a.jpg"])
        XCTAssertEqual(ImageSort.sort(items, by: .modificationDate, direction: .descending).map(\.displayName),
                       ["a.jpg", "b.jpg"])
        XCTAssertEqual(ImageSort.sort(items, by: .creationDate).map(\.displayName), ["a.jpg", "b.jpg"])
    }

    func testFileSizeSorting() {
        let items = [item("big.jpg", size: 900), item("small.jpg", size: 10), item("mid.jpg", size: 300)]
        XCTAssertEqual(ImageSort.sort(items, by: .fileSize).map(\.displayName),
                       ["small.jpg", "mid.jpg", "big.jpg"])
        XCTAssertEqual(ImageSort.sort(items, by: .fileSize, direction: .descending).map(\.displayName),
                       ["big.jpg", "mid.jpg", "small.jpg"])
    }

    func testDimensionSortingPlacesUnknownDimensionsFirst() {
        let items = [item("small.jpg", pixels: CGSize(width: 10, height: 10)),
                     item("unknown.jpg"),
                     item("large.jpg", pixels: CGSize(width: 400, height: 300))]
        XCTAssertEqual(ImageSort.sort(items, by: .dimensions).map(\.displayName),
                       ["unknown.jpg", "small.jpg", "large.jpg"])
    }

    func testEqualKeysFallBackToStableTieBreaker() {
        let items = [item("b.jpg", size: 100), item("a.jpg", size: 100)]
        XCTAssertEqual(ImageSort.sort(items, by: .fileSize).map(\.displayName), ["a.jpg", "b.jpg"])
    }
}
