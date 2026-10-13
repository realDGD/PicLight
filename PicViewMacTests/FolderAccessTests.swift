import XCTest
import AppKit
@testable import PicViewMac

private final class BookmarkProbeGate: @unchecked Sendable {
    let entered = DispatchSemaphore(value: 0)
    let resume = DispatchSemaphore(value: 0)
    func waitForEntry() -> Bool { entered.wait(timeout: .now() + 3) == .success }
}

private final class TestFolderBookmarks: FolderBookmarkProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var mappings: [String: ResolvedFolderBookmark] = [:]
    private var denied: Set<String> = []
    private var gate: BookmarkProbeGate?
    private var starts = 0
    private var stops = 0
    var counts: (Int, Int) { lock.withLock { (starts, stops) } }
    func map(_ old: URL, to new: URL) {
        lock.withLock { mappings[old.path] = .init(url: new, stale: true) }
    }
    func deny(_ url: URL) { _ = lock.withLock { denied.insert(url.path) } }
    func blockNextProbe(_ gate: BookmarkProbeGate) { lock.withLock { self.gate = gate } }
    func create(for url: URL, securityScoped: Bool) throws -> Data { Data(url.path.utf8) }
    func resolve(_ data: Data, securityScoped: Bool) throws -> ResolvedFolderBookmark {
        guard let path = String(data: data, encoding: .utf8) else { throw CocoaError(.fileReadCorruptFile) }
        return lock.withLock { mappings[path] ?? .init(url: URL(fileURLWithPath: path), stale: false) }
    }
    func startAccess(_ url: URL) -> Bool { lock.withLock { starts += 1 }; return true }
    func stopAccess(_ url: URL) { lock.withLock { stops += 1 } }
    func checkReadable(_ url: URL) throws {
        let pending = lock.withLock { () -> BookmarkProbeGate? in
            defer { gate = nil }
            return gate
        }
        if let pending { pending.entered.signal(); pending.resume.wait() }
        if lock.withLock({ denied.contains(url.path) }) { throw CocoaError(.fileReadNoPermission) }
    }
}

@MainActor
final class FolderAccessStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!
    override func setUp() async throws {
        suite = "PicLight.folder-access-tests.\(UUID())"
        defaults = UserDefaults(suiteName: suite)!
    }
    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
        defaults = nil
    }

    func testAddDeduplicateRestoreAndRemoveWithoutDeletingDirectory() async throws {
        let folder = try Fixtures.makeScratchDirectory("folder-record")
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = FolderAccessStore(defaults: defaults, sandboxed: false)
        let first = try await store.add(folder)
        let again = try await store.add(folder.appendingPathComponent("."))
        XCTAssertEqual(first.id, again.id)
        XCTAssertEqual(store.records.count, 1)
        store.shutdown()
        let restored = FolderAccessStore(defaults: defaults, sandboxed: false)
        await restored.refresh()
        XCTAssertEqual(restored.records.first?.status, .available)
        XCTAssertEqual(restored.records.first?.id, first.id)
        let restoredScope = await restored.prepareAccess(to: folder)
        XCTAssertNotNil(restoredScope)
        restored.remove(first.id)
        XCTAssertTrue(restored.records.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path))
        let next = FolderAccessStore(defaults: defaults, sandboxed: false)
        XCTAssertTrue(next.records.isEmpty)
        restored.shutdown()
    }

    func testStaleBookmarkUpdatesResolvedPathAndPersistsNewBookmark() async throws {
        let backend = TestFolderBookmarks()
        let old = URL(fileURLWithPath: "/tmp/old-folder")
        let moved = URL(fileURLWithPath: "/tmp/moved-folder")
        let store = FolderAccessStore(defaults: defaults, backend: backend, sandboxed: false)
        let record = try await store.add(old)
        store.shutdown()
        backend.map(old, to: moved)
        let restored = FolderAccessStore(defaults: defaults, backend: backend, sandboxed: false)
        await restored.refresh()
        XCTAssertEqual(restored.records.first?.id, record.id)
        XCTAssertEqual(restored.records.first?.path, FolderAccessStore.canonicalPath(moved))
        XCTAssertEqual(restored.records.first?.bookmark, Data(moved.path.utf8))
        XCTAssertEqual(restored.records.first?.status, .available)
        let next = FolderAccessStore(defaults: defaults, backend: backend, sandboxed: false)
        XCTAssertEqual(next.records.first?.path, FolderAccessStore.canonicalPath(moved))
        restored.shutdown()
    }

    func testRealBookmarkFollowsRenamedDirectoryAndMissingDirectoryIsNotEmpty() async throws {
        let base = try Fixtures.makeScratchDirectory("folder-bookmark-move")
        defer { try? FileManager.default.removeItem(at: base) }
        let old = base.appendingPathComponent("old", isDirectory: true)
        let moved = base.appendingPathComponent("moved", isDirectory: true)
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        let store = FolderAccessStore(defaults: defaults, sandboxed: false)
        _ = try await store.add(old)
        store.shutdown()
        try FileManager.default.moveItem(at: old, to: moved)
        let restored = FolderAccessStore(defaults: defaults, sandboxed: false)
        await restored.refresh()
        XCTAssertEqual(restored.records.first?.path, FolderAccessStore.canonicalPath(moved))
        XCTAssertEqual(restored.records.first?.status, .available)
        try FileManager.default.removeItem(at: moved)
        await restored.refresh()
        XCTAssertEqual(restored.records.count, 1)
        XCTAssertNotEqual(restored.records.first?.status, .available)
        XCTAssertFalse(restored.records.first?.detail.isEmpty ?? true)
        restored.shutdown()
    }

    func testDeniedAdditionDoesNotPersistAndCorruptStorageSurvivesRefresh() async throws {
        let backend = TestFolderBookmarks()
        let folder = URL(fileURLWithPath: "/tmp/denied-folder")
        backend.deny(folder)
        let store = FolderAccessStore(defaults: defaults, backend: backend, sandboxed: false)
        do { _ = try await store.add(folder); XCTFail("denied folder must not be added") }
        catch { XCTAssertTrue(store.records.isEmpty) }
        XCTAssertNil(defaults.data(forKey: "folderAccessRecords.v1"))
        let corrupt = Data("corrupt-records".utf8)
        defaults.set(corrupt, forKey: "folderAccessRecords.v1")
        let broken = FolderAccessStore(defaults: defaults, backend: backend, sandboxed: false)
        await broken.refresh()
        XCTAssertNotNil(broken.storageError)
        XCTAssertEqual(defaults.data(forKey: "folderAccessRecords.v1"), corrupt)
    }

    func testRemovedRecordCannotReturnFromPendingRestoreAndScopeEndsOnce() async throws {
        let backend = TestFolderBookmarks()
        let folder = URL(fileURLWithPath: "/tmp/scoped-folder")
        let store = FolderAccessStore(defaults: defaults, backend: backend, sandboxed: true)
        let record = try await store.add(folder)
        XCTAssertEqual(backend.counts.0, 1)
        let gate = BookmarkProbeGate()
        backend.blockNextProbe(gate)
        let refresh = Task { await store.refresh() }
        let entered = await Task.detached { gate.waitForEntry() }.value
        XCTAssertTrue(entered)
        store.remove(record.id)
        gate.resume.signal()
        await refresh.value
        XCTAssertTrue(store.records.isEmpty)
        XCTAssertEqual(backend.counts.0, backend.counts.1)
    }

    func testOperationRetainsScopeAfterRecordRemovalUntilFinished() async throws {
        let backend = TestFolderBookmarks()
        let folder = URL(fileURLWithPath: "/tmp/scoped-parent")
        let store = FolderAccessStore(defaults: defaults, backend: backend, sandboxed: true)
        let record = try await store.add(folder)
        var lease = await store.prepareAccess(to: folder.appendingPathComponent("child"))
        XCTAssertNotNil(lease)
        store.remove(record.id)
        XCTAssertEqual(backend.counts.1, 0)
        withExtendedLifetime(lease) {}
        lease = nil
        XCTAssertEqual(backend.counts.0, 1)
        XCTAssertEqual(backend.counts.1, 1)
        store.shutdown()
        XCTAssertEqual(backend.counts.1, 1)
    }

    func testReselectRemovedRecordDoesNotRecreateIt() async throws {
        let backend = TestFolderBookmarks()
        let folder = URL(fileURLWithPath: "/tmp/reselection")
        let store = FolderAccessStore(defaults: defaults, backend: backend, sandboxed: false)
        let record = try await store.add(folder)
        let gate = BookmarkProbeGate()
        backend.blockNextProbe(gate)
        let addition = Task { try await store.add(folder, replacing: record.id) }
        let entered = await Task.detached { gate.waitForEntry() }.value
        XCTAssertTrue(entered)
        store.remove(record.id)
        gate.resume.signal()
        do { _ = try await addition.value; XCTFail("removed record must not reappear") }
        catch is CancellationError {} catch { XCTFail("unexpected error: \(error)") }
        XCTAssertTrue(store.records.isEmpty)
    }

    func testCoverageUsesDirectoryBoundaryAndNormalModeDoesNotStartSecurityScope() async throws {
        XCTAssertTrue(FolderAccessStore.covers(URL(fileURLWithPath: "/tmp/a"), URL(fileURLWithPath: "/tmp/a/b")))
        XCTAssertFalse(FolderAccessStore.covers(URL(fileURLWithPath: "/tmp/a"), URL(fileURLWithPath: "/tmp/ab")))
        let backend = TestFolderBookmarks()
        let store = FolderAccessStore(defaults: defaults, backend: backend, sandboxed: false)
        _ = try await store.add(URL(fileURLWithPath: "/tmp/normal"))
        store.shutdown()
        XCTAssertEqual(backend.counts.0, 0)
        XCTAssertEqual(backend.counts.1, 0)
    }

}

private actor TestFolderScanner: FolderDirectoryScanning {
    var denied = true
    var delayedDirectory: URL?
    var delayedFinished = false
    func allow() { denied = false }
    func delayFailure(for directory: URL) { delayedDirectory = directory }
    func finished() -> Bool { delayedFinished }
    func scan(directory: URL, excludingExtensions: Set<String>, includingURL: URL?) async throws -> [FolderItem] {
        if directory == delayedDirectory {
            try await Task.sleep(for: .milliseconds(200))
            delayedFinished = true
            throw CocoaError(.fileReadNoPermission)
        }
        if denied { throw CocoaError(.fileReadNoPermission) }
        return try await FolderScanner().scan(directory: directory, excludingExtensions: excludingExtensions,
                                              includingURL: includingURL)
    }
}

@MainActor
final class FolderAccessViewerTests: XCTestCase {
    private var suite: String!
    private var defaults: UserDefaults!
    private var prompt = true
    override func setUp() async throws {
        TestAppKit.ensureApplication()
        suite = "PicLight.folder-viewer-tests.\(UUID())"
        defaults = UserDefaults(suiteName: suite)!
        prompt = AppSettings.shared.promptForFolderAccess
        AppSettings.shared.promptForFolderAccess = false
    }
    override func tearDown() async throws {
        AppSettings.shared.promptForFolderAccess = prompt
        defaults.removePersistentDomain(forName: suite)
    }
    private func makeViewer(_ scanner: TestFolderScanner) -> (ViewerViewController, FolderAccessStore) {
        let store = FolderAccessStore(defaults: defaults, sandboxed: false)
        let viewer = ViewerViewController(thumbnails: ThumbnailPipeline())
        viewer.folderAccessStore = store
        viewer.folderScanner = scanner
        viewer.loadViewIfNeeded()
        return (viewer, store)
    }
    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(4)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition(), "expected state did not arrive")
    }
    private func views(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(views) }

    func testDeniedParentKeepsExplicitImageAndGrantRetriesSameTarget() async throws {
        let directory = try Fixtures.makeScratchDirectory("folder-parent-denied")
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("z-target.png")
        try FileManager.default.copyItem(at: Fixtures.url("static.png"), to: target)
        try FileManager.default.copyItem(at: Fixtures.url("static.jpg"), to: directory.appendingPathComponent("a-other.jpg"))
        let scanner = TestFolderScanner()
        let (viewer, store) = makeViewer(scanner)
        defer { viewer.cancelFolderRequest(); store.shutdown() }
        viewer.open(url: target)
        try await waitUntil { viewer.folderReadFailure != nil && viewer.viewerState.currentImage != nil }
        XCTAssertEqual(viewer.session.items.count, 1)
        XCTAssertEqual(viewer.session.currentItem?.url.lastPathComponent, target.lastPathComponent)
        XCTAssertTrue(viewer.folderReadFailure?.isPermission == true)
        let banner = try XCTUnwrap(views(viewer.view).compactMap { $0 as? FolderAccessBannerView }.first)
        XCTAssertFalse(banner.isHidden, "disabled automatic prompting retains manual recovery")
        viewer.enterFolderBrowser()
        XCTAssertFalse(banner.isHidden, "the same failure remains visible in grid mode")
        await scanner.allow()
        _ = try await store.add(directory)
        try await waitUntil { viewer.folderReadFailure == nil && viewer.session.items.count == 2 }
        XCTAssertEqual(viewer.session.currentItem?.url.lastPathComponent, target.lastPathComponent)
        XCTAssertTrue(banner.isHidden)
    }

    func testSelectingAncestorRestoresFailedChildStatusAndBrowsing() async throws {
        let base = try Fixtures.makeScratchDirectory("folder-ancestor-grant")
        defer { try? FileManager.default.removeItem(at: base) }
        let child = base.appendingPathComponent("child")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: Fixtures.url("static.png"), to: child.appendingPathComponent("image.png"))
        let scanner = TestFolderScanner()
        let (viewer, store) = makeViewer(scanner)
        defer { viewer.cancelFolderRequest(); store.shutdown() }
        let record = try await store.add(child)
        viewer.openFolder(child)
        try await waitUntil { viewer.folderReadFailure != nil }
        XCTAssertEqual(store.records.first { $0.id == record.id }?.status, .needsSelection)
        await scanner.allow()
        _ = try await store.add(base)
        try await waitUntil { viewer.folderReadFailure == nil && viewer.session.items.count == 1 }
        XCTAssertEqual(store.records.first { $0.id == record.id }?.status, .available)
        XCTAssertEqual(viewer.session.directory, child.resolvingSymlinksInPath())
    }

    func testEmptyFolderIsDifferentFromPermissionFailureAndManualRetryWorks() async throws {
        let directory = try Fixtures.makeScratchDirectory("folder-empty-retry")
        defer { try? FileManager.default.removeItem(at: directory) }
        let scanner = TestFolderScanner()
        let (viewer, store) = makeViewer(scanner)
        defer { viewer.cancelFolderRequest(); store.shutdown() }
        viewer.openFolder(directory)
        try await waitUntil { viewer.folderReadFailure != nil }
        await scanner.allow()
        viewer.retryFolderAccess()
        try await waitUntil { viewer.folderReadFailure == nil }
        XCTAssertTrue(viewer.session.items.isEmpty)
        XCTAssertEqual(viewer.session.directory, directory.resolvingSymlinksInPath())
    }

    func testOldPermissionFailureAndGrantCannotReplaceNewerFolder() async throws {
        let base = try Fixtures.makeScratchDirectory("folder-old-failure")
        defer { try? FileManager.default.removeItem(at: base) }
        let old = base.appendingPathComponent("old")
        let new = base.appendingPathComponent("new")
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: new, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: Fixtures.url("static.png"), to: new.appendingPathComponent("current.png"))
        let scanner = TestFolderScanner()
        await scanner.allow()
        await scanner.delayFailure(for: old.resolvingSymlinksInPath())
        let (viewer, store) = makeViewer(scanner)
        defer { viewer.cancelFolderRequest(); store.shutdown() }
        viewer.openFolder(old)
        try await Task.sleep(for: .milliseconds(20))
        viewer.openFolder(new)
        try await waitUntil { viewer.session.currentItem?.displayName == "current.png" }
        let deadline = Date().addingTimeInterval(3)
        while !(await scanner.finished()), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        let finished = await scanner.finished()
        XCTAssertTrue(finished)
        _ = try await store.add(old)
        XCTAssertNil(viewer.folderReadFailure)
        XCTAssertEqual(viewer.session.directory, new.resolvingSymlinksInPath())
        XCTAssertEqual(viewer.session.currentItem?.displayName, "current.png")
    }

    func testReselectMovedRecordRetriesOriginalFileAtNewLocation() async throws {
        let base = try Fixtures.makeScratchDirectory("folder-reselect-moved")
        defer { try? FileManager.default.removeItem(at: base) }
        let old = base.appendingPathComponent("old")
        let moved = base.appendingPathComponent("moved")
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: moved, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: Fixtures.url("static.png"), to: moved.appendingPathComponent("target.png"))
        let scanner = TestFolderScanner()
        let (viewer, store) = makeViewer(scanner)
        defer { viewer.cancelFolderRequest(); store.shutdown() }
        let record = try await store.add(old)
        viewer.open(url: old.appendingPathComponent("target.png"))
        try await waitUntil { viewer.folderReadFailure != nil }
        await scanner.allow()
        _ = try await store.add(moved, replacing: record.id)
        try await waitUntil { viewer.folderReadFailure == nil && viewer.session.currentItem?.displayName == "target.png" }
        XCTAssertEqual(viewer.session.directory, moved.resolvingSymlinksInPath())
    }

    func testClosingViewerRejectsPendingFailureAndLaterGrant() async throws {
        let directory = try Fixtures.makeScratchDirectory("folder-closed-request")
        defer { try? FileManager.default.removeItem(at: directory) }
        let scanner = TestFolderScanner()
        await scanner.delayFailure(for: directory.resolvingSymlinksInPath())
        let (viewer, store) = makeViewer(scanner)
        viewer.openFolder(directory)
        try await Task.sleep(for: .milliseconds(20))
        viewer.cancelFolderRequest()
        try await Task.sleep(for: .milliseconds(250))
        _ = try await store.add(directory)
        XCTAssertNil(viewer.folderReadFailure)
        XCTAssertTrue(viewer.session.items.isEmpty)
        store.shutdown()
    }

    func testManagerMinimumSizeFitsControlsAndRemovalDoesNotSelectDifferentRecord() async throws {
        let store = FolderAccessStore(defaults: defaults, backend: TestFolderBookmarks(), sandboxed: false)
        let first = try await store.add(URL(fileURLWithPath: "/tmp/first"))
        _ = try await store.add(URL(fileURLWithPath: "/tmp/second"))
        let controller = FolderAccessWindowController(store: store)
        defer { controller.close(); store.shutdown() }
        let window = try XCTUnwrap(controller.window)
        let manager = try XCTUnwrap(window.contentViewController as? FolderAccessViewController)
        manager.loadViewIfNeeded()
        XCTAssertEqual(window.contentView?.bounds.width ?? 0, 680, accuracy: 1)
        XCTAssertEqual(window.contentView?.bounds.height ?? 0, 520, accuracy: 1)
        window.setContentSize(window.contentMinSize)
        manager.view.layoutSubtreeIfNeeded()
        for button in views(manager.view).compactMap({ $0 as? NSButton }) {
            XCTAssertTrue(manager.view.bounds.contains(manager.view.convert(button.bounds, from: button)), button.title)
        }
        manager.table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        store.remove(first.id)
        XCTAssertEqual(manager.table.selectedRow, -1)
        XCTAssertFalse(manager.removeButton.isEnabled)
        XCTAssertFalse(manager.openButton.isEnabled)
    }
}
