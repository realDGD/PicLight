import XCTest
import AppKit
@testable import PicViewMac

/// Opening a folder is a request, and a request has a generation.
///
/// Measured before the fix: opening a folder of 3,000 files and then immediately a folder of one
/// file left the session saying the second folder was current while its list held 3,000 items from
/// the first — the slow scan landed after the fast one and published over it. The same shape existed
/// in the viewer's initial open and in a watcher rescan racing a folder change.
@MainActor
final class FolderSwitchRaceTests: XCTestCase {

    override func setUp() async throws {
        try await super.setUp()
        TestAppKit.ensureApplication()
    }

    private func makeViewer() -> (ViewerWindowController, ViewerViewController) {
        let controller = ViewerWindowController()
        TestAppKit.presentOffScreen(controller)
        controller.window?.setFrame(NSRect(x: 0, y: 0, width: 900, height: 700), display: false)
        controller.showWindow(nil)
        let viewer = controller.viewerViewController
        _ = viewer.view
        return (controller, viewer)
    }

    /// Runs the run loop until the session's item count has stopped changing for a second.
    @discardableResult
    private func settleItemCount(_ viewer: ViewerViewController, timeout: TimeInterval = 30) -> Int {
        var last = viewer.session.items.count
        var stable = 0
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            let now = viewer.session.items.count
            if now == last {
                stable += 1
                if stable >= 10 { break }
            } else {
                stable = 0
                last = now
            }
        }
        return viewer.session.items.count
    }

    /// The folder opened last owns the list, whatever order the scans finish in.
    func testASlowScanCannotPublishOverTheFolderOpenedAfterIt() throws {
        let base = try Fixtures.makeScratchDirectory("folder-race")
        defer { try? FileManager.default.removeItem(at: base) }
        let big = base.appendingPathComponent("A")
        let small = base.appendingPathComponent("B")
        try FileManager.default.createDirectory(at: big, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: small, withIntermediateDirectories: true)
        for index in 0..<3_000 {
            FileManager.default.createFile(atPath: big.appendingPathComponent("f\(index).png").path,
                                           contents: Data())
        }
        FileManager.default.createFile(atPath: small.appendingPathComponent("only.png").path,
                                       contents: Data())

        let (controller, viewer) = makeViewer()
        defer { TestAppKit.close(controller) }

        viewer.openFolder(big)
        viewer.openFolder(small)
        let count = settleItemCount(viewer)

        XCTAssertEqual(viewer.session.directory?.lastPathComponent, "B",
                       "precondition: the second folder is the session's folder")
        XCTAssertEqual(count, 1,
                       "the list is the folder that was opened last, not the one whose scan "
                       + "finished last (measured before: 3,000 items from A)")
        XCTAssertEqual(viewer.session.items.first?.displayName, "only.png")
    }

    /// The same guard on the initial-open path: opening two files quickly leaves the second one's
    /// folder as the list and the second file selected.
    func testOpeningASecondFileQuicklyLeavesTheSecondFolderCurrent() throws {
        let base = try Fixtures.makeScratchDirectory("open-race")
        defer { try? FileManager.default.removeItem(at: base) }
        let big = base.appendingPathComponent("A")
        let small = base.appendingPathComponent("B")
        try FileManager.default.createDirectory(at: big, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: small, withIntermediateDirectories: true)
        for index in 0..<3_000 {
            FileManager.default.createFile(atPath: big.appendingPathComponent("f\(index).png").path,
                                           contents: Data())
        }
        let target = small.appendingPathComponent("only.png")
        FileManager.default.createFile(atPath: target.path, contents: Data())

        let (controller, viewer) = makeViewer()
        defer { TestAppKit.close(controller) }
        viewer.open(url: big.appendingPathComponent("f0.png"))
        viewer.open(url: target)
        let count = settleItemCount(viewer)

        XCTAssertEqual(viewer.session.directory?.lastPathComponent, "B")
        XCTAssertEqual(count, 1, "the slow scan of A must publish nothing")
        XCTAssertEqual(viewer.session.currentItem?.displayName, "only.png",
                       "and the file that was opened last is the current one")
    }
}
