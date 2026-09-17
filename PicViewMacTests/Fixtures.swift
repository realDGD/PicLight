import XCTest
@testable import PicViewMac

/// Shared access to the generated fixture folder.
enum Fixtures {
    static var directory: URL {
        guard let url = Bundle.module.url(forResource: "Fixtures", withExtension: nil) else {
            fatalError("Fixtures resource is missing from the test bundle")
        }
        return url
    }

    static func url(_ name: String) -> URL {
        directory.appendingPathComponent(name)
    }

    /// Scratch directory so folder tests never touch the fixture folder itself.
    static func makeScratchDirectory(_ name: String = UUID().uuidString) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("picviewmac-tests", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
