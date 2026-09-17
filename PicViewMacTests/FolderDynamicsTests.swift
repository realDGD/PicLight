import XCTest
import AppKit
@testable import PicViewMac

/// Directory changes while a viewer is open: debounced rescans that preserve the
/// current file, plus file-descriptor lifecycle regressions.
@MainActor
final class FolderDynamicsTests: XCTestCase {

    override func setUp() async throws {
        try await super.setUp()
        TestAppKit.ensureApplication()
    }
    private func makeFolder() throws -> URL {
        try Fixtures.makeScratchDirectory("dynamics")
    }

    private func writeImage(_ name: String, in directory: URL) throws {
        try FileManager.default.copyItem(at: Fixtures.url("static.png"),
                                         to: directory.appendingPathComponent(name))
    }

    private func waitFor(_ condition: @escaping () -> Bool, timeout: TimeInterval = 5,
                         message: String) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(condition(), message)
    }

    func testWatcherRescansAfterAFileIsAdded() async throws {
        let directory = try makeFolder()
        defer { try? FileManager.default.removeItem(at: directory) }
        try writeImage("a.png", in: directory)

        let controller = ViewerViewController()
        _ = controller.view
        controller.open(url: directory.appendingPathComponent("a.png"))
        await waitFor({ controller.session.items.count == 1 }, message: "initial scan")

        try writeImage("b.png", in: directory)
        await waitFor({ controller.session.items.count == 2 },
                      message: "the watcher must pick up a new file")
        XCTAssertEqual(controller.session.items.map(\.displayName), ["a.png", "b.png"])
        XCTAssertEqual(controller.session.currentItem?.displayName, "a.png",
                       "adding a file must not move the user off the current image")
    }

    func testCurrentFileIdentitySurvivesAnExternallyAddedFileBeforeIt() async throws {
        let directory = try makeFolder()
        defer { try? FileManager.default.removeItem(at: directory) }
        try writeImage("b.png", in: directory)
        try writeImage("c.png", in: directory)

        let controller = ViewerViewController()
        _ = controller.view
        controller.open(url: directory.appendingPathComponent("c.png"))
        await waitFor({ controller.session.currentItem?.displayName == "c.png" },
                      message: "opened the requested file")

        try writeImage("a.png", in: directory)
        await waitFor({ controller.session.items.count == 3 }, message: "rescan after insert")
        XCTAssertEqual(controller.session.currentItem?.displayName, "c.png",
                       "identity is preserved even though the index changed")
        XCTAssertEqual(controller.session.positionDescription, "3 / 3")
    }

    func testExternallyRemovedCurrentFileSelectsNextThenPrevious() async throws {
        let directory = try makeFolder()
        defer { try? FileManager.default.removeItem(at: directory) }
        for name in ["a.png", "b.png", "c.png"] { try writeImage(name, in: directory) }

        let controller = ViewerViewController()
        _ = controller.view
        controller.open(url: directory.appendingPathComponent("b.png"))
        await waitFor({ controller.session.currentItem?.displayName == "b.png" },
                      message: "opened b.png")

        try FileManager.default.removeItem(at: directory.appendingPathComponent("b.png"))
        await waitFor({ controller.session.items.count == 2 }, message: "rescan after removal")
        XCTAssertEqual(controller.session.currentItem?.displayName, "c.png",
                       "a removed current file prefers the next image")

        try FileManager.default.removeItem(at: directory.appendingPathComponent("c.png"))
        await waitFor({ controller.session.items.count == 1 }, message: "rescan after second removal")
        XCTAssertEqual(controller.session.currentItem?.displayName, "a.png",
                       "with no next image the previous one is used")
    }

    func testRemovingTheLastFileLeavesAUsableEmptyState() async throws {
        let directory = try makeFolder()
        defer { try? FileManager.default.removeItem(at: directory) }
        try writeImage("only.png", in: directory)

        let controller = ViewerViewController()
        _ = controller.view
        controller.open(url: directory.appendingPathComponent("only.png"))
        await waitFor({ controller.session.items.count == 1 }, message: "initial scan")

        try FileManager.default.removeItem(at: directory.appendingPathComponent("only.png"))
        await waitFor({ controller.session.isEmpty }, message: "the folder becomes empty")
        XCTAssertNil(controller.session.currentItem)
        XCTAssertEqual(controller.session.positionDescription, "— / 0")
        // Navigation on an empty folder must be a safe no-op.
        controller.perform(.nextImage)
        controller.perform(.previousImage)
        XCTAssertNil(controller.session.currentItem)
    }

    func testRenamingTheCurrentFileKeepsItSelected() async throws {
        let directory = try makeFolder()
        defer { try? FileManager.default.removeItem(at: directory) }
        try writeImage("old.png", in: directory)
        try writeImage("other.png", in: directory)

        let controller = ViewerViewController()
        _ = controller.view
        controller.open(url: directory.appendingPathComponent("old.png"))
        await waitFor({ controller.session.currentItem?.displayName == "old.png" },
                      message: "opened old.png")

        try FileManager.default.moveItem(at: directory.appendingPathComponent("old.png"),
                                        to: directory.appendingPathComponent("renamed.png"))
        await waitFor({ controller.session.items.contains { $0.displayName == "renamed.png" } },
                      message: "rescan after rename")
        XCTAssertEqual(controller.session.items.count, 2)
        XCTAssertEqual(controller.session.currentItem?.displayName, "renamed.png",
                       "a rename inside the watched folder must follow the same file")
    }

    func testWatchingDoesNotRecurseIntoSubdirectories() async throws {
        let directory = try makeFolder()
        defer { try? FileManager.default.removeItem(at: directory) }
        try writeImage("a.png", in: directory)
        let nested = directory.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)

        let controller = ViewerViewController()
        _ = controller.view
        controller.open(url: directory.appendingPathComponent("a.png"))
        await waitFor({ controller.session.items.count == 1 }, message: "initial scan")

        try writeImage("deep.png", in: nested)
        try await Task.sleep(nanoseconds: 1_000_000_000)

        XCTAssertEqual(controller.session.items.count, 1,
                       "a change inside a subdirectory must not affect the current folder")
        XCTAssertFalse(controller.session.items.contains { $0.displayName == "deep.png" })
    }

    // MARK: - File descriptor lifecycle

    func testWatcherStartStopCyclesDoNotLeakFileDescriptors() async throws {
        let directory = try makeFolder()
        defer { try? FileManager.default.removeItem(at: directory) }
        try writeImage("a.png", in: directory)

        func openDescriptorCount() -> Int {
            (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count) ?? -1
        }

        let watcher = FolderWatcher()
        watcher.start(watching: directory)
        await Task.yield()
        let baseline = openDescriptorCount()
        XCTAssertGreaterThan(baseline, 0, "/dev/fd must be readable for this check")

        for _ in 0..<200 {
            watcher.start(watching: directory)
            watcher.stop()
        }
        // Let the cancel handlers run.
        try await Task.sleep(nanoseconds: 400_000_000)

        let after = openDescriptorCount()
        XCTAssertLessThanOrEqual(after, baseline + 3,
                                 "200 start/stop cycles must not accumulate descriptors "
                                 + "(baseline \(baseline), after \(after))")
    }

    func testWatcherStopIsIdempotentAndSilencesCallbacks() async throws {
        let directory = try makeFolder()
        defer { try? FileManager.default.removeItem(at: directory) }

        let watcher = FolderWatcher()
        let hits = Counter()
        watcher.onChange = { hits.increment() }
        watcher.start(watching: directory)
        watcher.stop()
        watcher.stop()
        watcher.stop()

        try writeImage("a.png", in: directory)
        try await Task.sleep(nanoseconds: 900_000_000)
        XCTAssertEqual(hits.value, 0,
                       "a stopped watcher must not deliver changes, even with a live descriptor")
    }

    func testWatcherDeliversDebouncedChangesExactlyOnce() async throws {
        let directory = try makeFolder()
        defer { try? FileManager.default.removeItem(at: directory) }

        let watcher = FolderWatcher()
        watcher.debounceInterval = 0.2
        let hits = Counter()
        watcher.onChange = { hits.increment() }
        watcher.start(watching: directory)

        // A burst of changes inside one debounce window collapses into one rescan.
        for index in 0..<5 {
            try writeImage("burst-\(index).png", in: directory)
        }
        try await Task.sleep(nanoseconds: 1_200_000_000)
        watcher.stop()

        XCTAssertGreaterThanOrEqual(hits.value, 1, "the watcher must report the burst")
        XCTAssertLessThanOrEqual(hits.value, 3,
                                 "debouncing must collapse a burst, got \(hits.value) notifications")
    }
}

/// Minimal thread-safe counter for watcher callbacks, which arrive off the main actor.
final class Counter: @unchecked Sendable {
    private let queue = DispatchQueue(label: "picviewmac.tests.counter")
    private var storage = 0

    func increment() { queue.sync { storage += 1 } }
    var value: Int { queue.sync { storage } }
}
