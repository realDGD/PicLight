import XCTest
import CoreGraphics
@testable import PicViewMac

final class FolderScannerTests: XCTestCase {
    func testScanDoesNotRecurseIntoSubdirectories() throws {
        let directory = try Fixtures.makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data().write(to: directory.appendingPathComponent("top.png"))
        let nested = directory.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data().write(to: nested.appendingPathComponent("deep.png"))

        let items = try FolderScanner.scanSynchronously(directory: directory)
        XCTAssertEqual(items.map(\.displayName), ["top.png"])
    }

    func testScanSkipsUnsupportedFilesAndDirectoriesThatLookLikeImages() throws {
        let directory = try Fixtures.makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data().write(to: directory.appendingPathComponent("image.png"))
        try Data().write(to: directory.appendingPathComponent("notes.txt"))
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("folder.png"),
                                                withIntermediateDirectories: true)

        let items = try FolderScanner.scanSynchronously(directory: directory)
        XCTAssertEqual(items.map(\.displayName), ["image.png"])
    }

    func testScannedItemsCarrySortableMetadata() throws {
        let items = try FolderScanner.scanSynchronously(directory: Fixtures.directory)
        let png = try XCTUnwrap(items.first { $0.displayName == "static.png" })
        XCTAssertNotNil(png.byteSize)
        XCTAssertNotNil(png.creationDate)
        XCTAssertNotNil(png.modificationDate)
        XCTAssertNil(png.pixelSize, "dimension lookup must stay lazy")
        XCTAssertTrue(items.contains { $0.displayName == "static.webp" })
        XCTAssertFalse(items.contains { $0.displayName == "not-an-image.pdf" })
    }

    func testLazyDimensionLookupFillsPixelSizesOnlyWhenRequested() async throws {
        let scanner = FolderScanner()
        let items = try await scanner.scan(directory: Fixtures.directory)
        let filled = await FolderScanner.fillDimensions(items)
        let png = try XCTUnwrap(filled.first { $0.displayName == "static.png" })
        XCTAssertEqual(png.pixelSize, CGSize(width: 64, height: 48))
    }

    func testScanningReadsNoImageBodiesForLargeFolders() throws {
        let directory = try Fixtures.makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        // 10,000 candidate names with no decodable bodies at all: a scan must not
        // attempt to decode anything, otherwise it would fail or stall here.
        for index in 0..<10_000 {
            try Data([0x00]).write(to: directory.appendingPathComponent("photo-\(index).jpg"))
        }
        let started = Date()
        let items = try FolderScanner.scanSynchronously(directory: directory)
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertEqual(items.count, 10_000)
        XCTAssertTrue(items.allSatisfy { $0.pixelSize == nil })
        XCTAssertLessThan(elapsed, 20, "scanning 10k filenames must not inspect image bodies")
    }
}
