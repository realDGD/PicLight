import XCTest
import AppKit
@testable import PicViewMac

@MainActor
final class AFeatureBehaviorTests: XCTestCase {
    func testLoopNavigationAvailabilityAndRandomNeverRepeats() {
        let items = ["a.png", "b.jpg", "c.gif"].map { FolderItem(url: URL(fileURLWithPath: "/tmp/\($0)")) }
        let session = FolderSession(items: items)
        XCTAssertFalse(session.canGoPrevious)
        session.loopBrowsing = true
        XCTAssertTrue(session.canGoPrevious)
        session.goPrevious()
        XCTAssertEqual(session.currentIndex, 2)
        XCTAssertTrue(session.canGoNext)
        session.goNext()
        XCTAssertEqual(session.currentIndex, 0)
        for _ in 0..<20 {
            let previous = session.currentIndex
            session.goRandom()
            XCTAssertNotEqual(previous, session.currentIndex)
        }
        session.setItems([items[0]])
        XCTAssertFalse(session.canGoNext)
        XCTAssertFalse(session.canGoPrevious)
        session.goRandom()
        XCTAssertEqual(session.currentIndex, 0)
        session.setItems([])
        XCTAssertNil(session.goRandom())
    }

    func testExclusionScanAndDirectOpenException() async throws {
        let directory = try Fixtures.makeScratchDirectory("a-exclusions")
        defer { try? FileManager.default.removeItem(at: directory) }
        for name in ["static.png", "static.jpg", "static.gif"] {
            try FileManager.default.copyItem(at: Fixtures.url(name), to: directory.appendingPathComponent(name))
        }
        let scanner = FolderScanner()
        let filtered = try await scanner.scan(directory: directory, excludingExtensions: ["png", "gif"])
        XCTAssertEqual(filtered.map(\.displayName), ["static.jpg"])
        let explicit = try await scanner.scan(directory: directory, excludingExtensions: ["png", "gif"],
                                              includingURL: directory.appendingPathComponent("static.gif"))
        XCTAssertEqual(Set(explicit.map(\.displayName)), ["static.jpg", "static.gif"])
    }

    func testDisplayPoliciesRespectEmptyImmersiveAndUnavailableEdges() {
        var dock = ToolDockVisibilityModel()
        dock.displayPolicy = .alwaysVisible
        dock.update(at: 10)
        XCTAssertFalse(dock.visible)
        dock.setHasImage(true, at: 10)
        dock.update(at: 100)
        XCTAssertTrue(dock.visible)
        dock.displayPolicy = .alwaysHidden
        dock.setPointer(inZone: true, at: 101)
        dock.update(at: 102)
        XCTAssertFalse(dock.visible)
        dock.displayPolicy = .alwaysVisible
        dock.setImmersive(true, at: 103)
        dock.update(at: 104)
        XCTAssertFalse(dock.visible)

        var nav = FloatingNavigationVisibilityModel()
        nav.setDisplayPolicy(.alwaysVisible, at: 0)
        nav.setAvailable(previous: false, next: true)
        nav.setHasImage(true, at: 0)
        nav.update(at: 100)
        XCTAssertFalse(nav.previous.visible)
        XCTAssertTrue(nav.next.visible)
        nav.setDisplayPolicy(.alwaysHidden, at: 101)
        nav.setPointer(previousSide: true, nextSide: true, at: 102)
        nav.update(at: 103)
        XCTAssertFalse(nav.previous.visible)
        XCTAssertFalse(nav.next.visible)
        nav.setDisplayPolicy(.alwaysVisible, at: 104)
        nav.setImmersive(true, at: 104)
        nav.update(at: 105)
        XCTAssertFalse(nav.next.visible)

        var chrome = ViewerChromeModel()
        chrome.setZoomedIn(true, at: 0)
        chrome.hideMinimap = true
        chrome.update(at: 0)
        XCTAssertFalse(chrome.minimapVisible)
        var titlebar = TitlebarVisibilityModel()
        titlebar.setAlwaysHidden(true, at: 0)
        titlebar.setPointer(inTrafficLightsZone: true, inTitlebarZone: true, at: 1)
        titlebar.reveal()
        titlebar.update(at: 1)
        XCTAssertEqual(titlebar.state, .hidden)
    }

    func testLiveFilteringRefreshesTheViewerAndDirectOpeningStillWorks() async throws {
        TestAppKit.ensureApplication()
        let settings = AppSettings.shared
        let previous = settings.excludedExtensions
        let previousFollowUp = settings.deleteFollowUp
        defer { settings.excludedExtensions = previous; settings.deleteFollowUp = previousFollowUp }
        settings.excludedExtensions = []
        let directory = try Fixtures.makeScratchDirectory("a-live-filter")
        defer { try? FileManager.default.removeItem(at: directory) }
        for name in ["static.png", "static.jpg", "static.gif"] {
            try FileManager.default.copyItem(at: Fixtures.url(name), to: directory.appendingPathComponent(name))
        }
        let viewer = ViewerViewController(thumbnails: ThumbnailPipeline())
        viewer.loadViewIfNeeded()
        viewer.openFolder(directory)
        try await waitUntil { viewer.session.items.count == 3 }
        settings.excludedExtensions = ["gif", "png"]
        try await waitUntil { viewer.session.items.count == 1 }
        XCTAssertEqual(viewer.session.currentItem?.displayName, "static.jpg")
        settings.deleteFollowUp = .stayInPlace
        viewer.open(url: directory.appendingPathComponent("static.gif"))
        settings.excludedExtensions = ["png"]
        try await waitUntil { viewer.session.currentItem?.displayName == "static.gif" }
        XCTAssertEqual(Set(viewer.session.items.map(\.displayName)), ["static.jpg", "static.gif"])
        viewer.stopChromeTimer()
    }

    func testDeleteConfirmationCancellationPreservesSelectionAndFile() async throws {
        TestAppKit.ensureApplication()
        let settings = AppSettings.shared
        let previous = settings.confirmBeforeTrash
        defer { settings.confirmBeforeTrash = previous }
        settings.confirmBeforeTrash = true
        let directory = try Fixtures.makeScratchDirectory("a-delete-cancel")
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("photo.png")
        try FileManager.default.copyItem(at: Fixtures.url("static.png"), to: file)
        let controller = ViewerWindowController(viewer: ViewerViewController(thumbnails: ThumbnailPipeline()))
        TestAppKit.presentOffScreen(controller)
        defer { controller.close() }
        let viewer = controller.viewerViewController
        viewer.session.setItems([FolderItem(url: file)])
        viewer.perform(.moveToTrash)
        let sheet = try XCTUnwrap(controller.window?.attachedSheet)
        controller.window?.endSheet(sheet, returnCode: .alertSecondButtonReturn)
        try await waitUntil { controller.window?.attachedSheet == nil }
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(viewer.session.currentItem?.url, file)
    }

    func testReplacedFileIsNotDeletedByAnOlderConfirmation() async throws {
        TestAppKit.ensureApplication()
        let settings = AppSettings.shared
        let previous = settings.confirmBeforeTrash
        defer { settings.confirmBeforeTrash = previous }
        settings.confirmBeforeTrash = true
        let directory = try Fixtures.makeScratchDirectory("a-delete-replacement")
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("photo.png")
        try FileManager.default.copyItem(at: Fixtures.url("static.png"), to: file)
        let controller = ViewerWindowController(viewer: ViewerViewController(thumbnails: ThumbnailPipeline()))
        TestAppKit.presentOffScreen(controller)
        defer { controller.close() }
        let viewer = controller.viewerViewController
        viewer.session.setItems([FolderItem(url: file)])
        viewer.perform(.moveToTrash)
        let sheet = try XCTUnwrap(controller.window?.attachedSheet)
        let replacement = Data("new file contents".utf8)
        try replacement.write(to: file, options: .atomic)
        controller.window?.endSheet(sheet, returnCode: .alertFirstButtonReturn)
        try await waitUntil { viewer.viewerState.errorMessage?.contains("文件已发生变化") == true }
        XCTAssertEqual(try Data(contentsOf: file), replacement)
        XCTAssertEqual(viewer.session.currentItem?.url, file)
    }

    func testClearingGalleryDropsPendingAndAllowsFreshRequests() {
        TestAppKit.ensureApplication()
        let host = GalleryAuditHost(items: (0..<3).map {
            FolderItem(url: URL(fileURLWithPath: "/tmp/a-gallery/img-\($0).png"), pixelSize: CGSize(width: 2, height: 2))
        })
        let browser = FolderBrowserViewController(host: host)
        let window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 900, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        TestAppKit.prepareForOffScreen(window)
        window.contentView = browser.view
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        browser.reload()
        browser.view.layoutSubtreeIfNeeded()
        let before = host.requests.count
        XCTAssertGreaterThan(before, 0)
        browser.clearCachedThumbnails(reloadVisible: true)
        XCTAssertGreaterThan(host.requests.count, before,
                             "cancelled requests must not stay in the browser's pending dictionary")
        browser.clearCachedThumbnails(reloadVisible: false)
        XCTAssertEqual(browser.view.gallery.loadingThumbnailCount, 0)
        XCTAssertEqual(browser.view.gallery.deliveredImageCountForTesting, 0)
    }

    func testPinningAutomaticToolbarDoesNotChangeOtherWindowsOrSettings() {
        TestAppKit.ensureApplication()
        let settings = AppSettings.shared
        let previous = settings.dockDisplayPolicy
        defer { settings.dockDisplayPolicy = previous }
        settings.dockDisplayPolicy = .automatic
        let first = ViewerViewController(thumbnails: ThumbnailPipeline())
        let second = ViewerViewController(thumbnails: ThumbnailPipeline())
        first.loadViewIfNeeded(); second.loadViewIfNeeded()
        first.setToolDockPinned(true)
        XCTAssertEqual(settings.dockDisplayPolicy, .automatic)
        XCTAssertTrue(first.isToolDockPinned)
        XCTAssertFalse(second.isToolDockPinned)
        first.applySettings()
        XCTAssertTrue(first.isToolDockPinned, "unrelated settings refresh must retain a local pin")
    }

    private func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !predicate(), Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(predicate(), "expected live state transition before deadline")
    }
}
