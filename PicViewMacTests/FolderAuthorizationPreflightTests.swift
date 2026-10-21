import Foundation
import XCTest
@testable import PicViewMac

@MainActor
final class FolderAuthorizationPreflightTests: XCTestCase {
    func testDownloadsConsentTargetsTheUserFolderWithoutReadingTheDirectory() throws {
        let suite = "PicLight.authorization-preflight.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = FolderAccessStore(defaults: defaults, sandboxed: false)
        defer { store.shutdown() }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let downloads = home.appendingPathComponent("Downloads", isDirectory: true)
        for requested in [downloads, downloads.appendingPathComponent("not-read/nested", isDirectory: true)] {
            XCTAssertEqual(store.directoryRequiringSelection(beforeReading: requested)?.path, home.path,
                           "Downloads triggers consent; the user folder is the authorization target")
        }
        XCTAssertNil(store.directoryRequiringSelection(beforeReading: home))
        XCTAssertNil(store.directoryRequiringSelection(beforeReading:
            home.appendingPathComponent("Downloads-other", isDirectory: true)),
            "the folder boundary must not match similarly named siblings")
        XCTAssertTrue(store.records.isEmpty, "preflight alone must not add authorization records")
    }
}
