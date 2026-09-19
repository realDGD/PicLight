import XCTest
import AppKit
@testable import PicViewMac

/// The folder browser as a mode: entering and leaving, what it shares with the image viewer, and
/// what it deliberately does not.
@MainActor
final class FolderBrowserModeTests: XCTestCase {

    override func setUp() async throws {
        try await super.setUp()
        TestAppKit.ensureApplication()
    }

    private func makeFolder(_ count: Int,
                            subfolders: Int = 0) throws -> (directory: URL,
                                                            controller: ViewerWindowController,
                                                            viewer: ViewerViewController) {
        let directory = try Fixtures.makeScratchDirectory("folder-browser")
        for index in 0..<count {
            try FileManager.default.copyItem(at: Fixtures.url("static.png"),
                                             to: directory.appendingPathComponent("img\(index).png"))
        }
        for index in 0..<subfolders {
            try FileManager.default.createDirectory(
                at: directory.appendingPathComponent("sub\(index)"),
                withIntermediateDirectories: true)
        }
        let controller = ViewerWindowController()
        TestAppKit.presentOffScreen(controller)
        let viewer = controller.viewerViewController
        controller.showWindow(nil)
        _ = viewer.view
        viewer.open(url: directory.appendingPathComponent("img0.png"))
        waitForImage(viewer)
        return (directory, controller, viewer)
    }

    @discardableResult
    private func waitForImage(_ viewer: ViewerViewController, timeout: TimeInterval = 10) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while viewer.viewerState.currentImage == nil, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        return viewer.viewerState.currentImage != nil
    }

    private func settle(_ seconds: TimeInterval = 0.3) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    private func cleanup(_ directory: URL, _ controller: ViewerWindowController) {
        controller.close()
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Entering and leaving

    /// The command the dock's grid button and the context menu both carry enters the mode.
    func testTheBrowseFolderCommandEntersTheMode() throws {
        let (directory, controller, viewer) = try makeFolder(3)
        defer { cleanup(directory, controller) }
        XCTAssertEqual(viewer.viewerMode, .image)

        viewer.perform(.browseFolder)

        XCTAssertEqual(viewer.viewerMode, .folderBrowser)
        XCTAssertFalse(viewer.folderBrowserContainerForTesting.isHidden)
        XCTAssertNotNil(viewer.folderBrowserForTesting, "the browser is built on demand")
    }

    /// It is a real mode, not an overlay: the image mode's views are off screen while it is up.
    func testItIsAModeNotAnOverlay() throws {
        let (directory, controller, viewer) = try makeFolder(3)
        defer { cleanup(directory, controller) }
        viewer.perform(.browseFolder)
        settle()

        XCTAssertTrue(viewer.isImageModeHidden)
        for name in ["canvas", "toolDock", "bottomBar", "drawer", "floatingNavigation"] {
            let chrome = try XCTUnwrap(viewer.chromeViewsForTesting[name])
            XCTAssertTrue(chrome.isHidden, "\(name) belongs to image mode and must be away")
        }
        // And the gallery is not the drawer: it is a different view, in a different container.
        let browser = try XCTUnwrap(viewer.folderBrowserForTesting)
        XCTAssertFalse(browser.view.isDescendant(of: viewer.chromeViewsForTesting["drawer"]!),
                       "the browser must not be the drawer wearing a bigger hat")
    }

    /// The chrome timer keeps running while the browser is up; it must not bring the dock or the
    /// HUD back over the gallery.
    func testTheChromeTimerDoesNotRepaintImageChromeOverTheGallery() throws {
        let (directory, controller, viewer) = try makeFolder(3)
        defer { cleanup(directory, controller) }
        viewer.perform(.browseFolder)
        settle(0.3)
        // Several timer ticks: the tick interval is 0.1 s.
        settle(0.6)

        for name in ["toolDock", "bottomBar", "canvas"] {
            XCTAssertTrue(try XCTUnwrap(viewer.chromeViewsForTesting[name]).isHidden, name)
        }
    }

    /// Back returns to image mode and comes back to the *same* image, without re-decoding it.
    func testBackReturnsToTheSameImageWithoutReDecodingIt() throws {
        let (directory, controller, viewer) = try makeFolder(3)
        defer { cleanup(directory, controller) }
        viewer.perform(.nextImage)
        waitForImage(viewer)
        let item = try XCTUnwrap(viewer.session.currentItem)
        let bitmap = try XCTUnwrap(viewer.viewerState.currentImage)
        let viewport = viewer.canvasViewportForTesting

        viewer.perform(.browseFolder)
        settle()
        let browser = try XCTUnwrap(viewer.folderBrowserForTesting)
        browser.view.backControl.sendAction(browser.view.backControl.action!,
                                            to: browser.view.backControl.target)
        settle()

        XCTAssertEqual(viewer.viewerMode, .image)
        XCTAssertEqual(viewer.session.currentItem?.url, item.url, "the selection is preserved")
        XCTAssertTrue(viewer.viewerState.currentImage === bitmap,
                      "leaving the browser must not re-decode the image it never stopped showing")
        XCTAssertEqual(viewer.canvasViewportForTesting.normalizedCenter.x,
                       viewport.normalizedCenter.x, accuracy: 1e-9,
                       "and the viewport comes back where it was")
        XCTAssertFalse(viewer.isImageModeHidden)
    }

    /// The mode is a separate presentation hierarchy: the browser cannot see the image mode's
    /// views. Checked by structure rather than by reading the source.
    func testTheTwoModesDoNotShareAViewHierarchy() throws {
        let (directory, controller, viewer) = try makeFolder(3)
        defer { cleanup(directory, controller) }
        viewer.perform(.browseFolder)
        settle()
        let browser = try XCTUnwrap(viewer.folderBrowserForTesting)
        let imageModeViews = viewer.chromeViewsForTesting.values.filter {
            $0 !== viewer.folderBrowserContainerForTesting
        }
        for chrome in imageModeViews {
            for candidate in [browser.view, browser.view.gallery, browser.view.treeSidebar] {
                XCTAssertFalse(candidate.isDescendant(of: chrome),
                               "the browser must not be inside image mode's views")
                XCTAssertFalse(chrome.isDescendant(of: candidate))
            }
        }
    }

    // MARK: - Shared state

    /// The session's index is the one both modes use, so a selection made in the gallery is what
    /// the image mode comes back to.
    func testSelectionIsSharedWithTheSession() throws {
        let (directory, controller, viewer) = try makeFolder(4)
        defer { cleanup(directory, controller) }
        viewer.perform(.browseFolder)
        settle()
        let browser = try XCTUnwrap(viewer.folderBrowserForTesting)

        browser.select(2)
        XCTAssertEqual(viewer.session.currentIndex, 2, "one index, shared")
        // Captured by URL rather than by name: the folder is watched, and a rescan may re-sort the
        // list under a slow run. What the test is about is that the *file* survives the trip.
        let selected = try XCTUnwrap(viewer.session.currentItem).url

        browser.view.backControl.sendAction(browser.view.backControl.action!,
                                            to: browser.view.backControl.target)
        waitForImage(viewer)
        XCTAssertEqual(viewer.session.currentItem?.url, selected,
                       "and the image mode shows the selection")
    }

    /// Double-click opens the item and returns to the image: the same path Return takes.
    func testOpeningAGalleryItemReturnsToImageMode() throws {
        let (directory, controller, viewer) = try makeFolder(4)
        defer { cleanup(directory, controller) }
        viewer.perform(.browseFolder)
        settle()
        let browser = try XCTUnwrap(viewer.folderBrowserForTesting)

        browser.view.gallery.onItemOpened?(3)
        waitForImage(viewer)

        XCTAssertEqual(viewer.viewerMode, .image, "opening an item leaves the browser")
        XCTAssertEqual(viewer.session.currentIndex, 3)
    }

    /// Entering the browser pins the titlebar visible: the browser's toolbar is the mode's top bar,
    /// flush under a bar that never hides on top of it, and the drawer button stays in that bar.
    func testTheTitlebarStaysVisibleWhileBrowsing() throws {
        let (directory, controller, viewer) = try makeFolder(4)
        defer { cleanup(directory, controller) }
        let window = try XCTUnwrap(viewer.view.window as? ViewerWindow)
        XCTAssertEqual(window.titlebarMode, .autoHide, "precondition: the default is auto-hide")

        viewer.perform(.browseFolder)
        settle()

        XCTAssertEqual(viewer.viewerMode, .folderBrowser)
        XCTAssertEqual(window.titlebarMode, .alwaysVisible,
                       "browsing pins the titlebar to always-visible")
        XCTAssertEqual(window.titlebarState, .full)
        XCTAssertFalse(window.styleMask.contains(.fullSizeContentView),
                       "content stops reaching under the bar, so the browser's toolbar sits "
                       + "flush below the titlebar instead of under it")

        // Pointer away and idle: the pinned bar must not auto-hide.
        viewer.simulatePointer(atWindowPoint: viewer.view.convert(
            CGPoint(x: viewer.view.bounds.midX, y: viewer.view.bounds.midY), to: nil))
        settle(TitlebarVisibilityModel.Timing().hideDelay + 0.5)
        XCTAssertEqual(window.titlebarState, .full,
                       "the titlebar does not auto-hide while the browser is up")

        // The drawer button is part of that visible bar, not floating over the browser.
        for accessory in window.titlebarAccessoryViewControllers {
            XCTAssertFalse(accessory.isHidden,
                           "with the pinned bar the accessory is in the titlebar")
        }

        // Leaving restores the user's mode; the browser's flush layout goes away with it.
        let escape = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
                                                    modifierFlags: [], timestamp: 0,
                                                    windowNumber: 0, context: nil,
                                                    characters: "\u{1b}",
                                                    charactersIgnoringModifiers: "\u{1b}",
                                                    isARepeat: false, keyCode: 53))
        viewer.keyDown(with: escape)
        settle(0.5)
        XCTAssertEqual(viewer.viewerMode, .image)
        XCTAssertEqual(window.titlebarMode, .autoHide,
                       "leaving the browser hands the titlebar back to the user's setting")
    }

    func testEscapeLeavesTheBrowserAndKeepsTheSelection() throws {
        let (directory, controller, viewer) = try makeFolder(4)
        defer { cleanup(directory, controller) }
        viewer.perform(.browseFolder)
        settle()
        let browser = try XCTUnwrap(viewer.folderBrowserForTesting)
        browser.select(1)

        let escape = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
                                                    modifierFlags: [], timestamp: 0,
                                                    windowNumber: 0, context: nil,
                                                    characters: "\\u{1b}", charactersIgnoringModifiers: "\\u{1b}",
                                                    isARepeat: false, keyCode: 53))
        viewer.keyDown(with: escape)
        settle()

        XCTAssertEqual(viewer.viewerMode, .image)
        XCTAssertEqual(viewer.session.currentIndex, 1, "Escape keeps the current selection")
    }

    /// Sorting is one shared order: changing it in the gallery changes the order the image mode
    /// navigates in, with no second sort state anywhere.
    func testTheGalleryAndTheImageViewerShareOneSortOrder() throws {
try SharedSettingsScope.preservingSort {

            let (directory, controller, viewer) = try makeFolder(5)
            defer { cleanup(directory, controller) }
            let original = AppSettings.shared.sortKey
            defer { AppSettings.shared.sortKey = original }

            viewer.perform(.browseFolder)
            settle()
            let browser = try XCTUnwrap(viewer.folderBrowserForTesting)
            browser.view.onSortKeyChanged?(.fileSize)
            settle()

            XCTAssertEqual(AppSettings.shared.sortKey, .fileSize)
            // The image mode's own navigation now follows that order, because it reads the same list.
            let names = viewer.session.items.map(\.displayName)
            XCTAssertEqual(names, ImageSort.sort(viewer.session.items, by: .fileSize,
                                                 direction: AppSettings.shared.sortDirection)
                .map(\.displayName))
    
}
}

    // MARK: - The folder tree

    /// The tree shows the current folder inside its parent's context, and the current folder is
    /// highlighted.
    func testTheTreeShowsTheCurrentFolderInContext() throws {
        let (directory, controller, viewer) = try makeFolder(3, subfolders: 2)
        defer { cleanup(directory, controller) }
        viewer.perform(.browseFolder)
        settle()
        let browser = try XCTUnwrap(viewer.folderBrowserForTesting)
        let sidebar = browser.view.treeSidebar

        XCTAssertGreaterThan(sidebar.visibleRowCount, 0, "the tree has rows")
        XCTAssertEqual(sidebar.selectedPath, directory.resolvingSymlinksInPath().path,
                       "the current folder is the highlighted row")
        let names = (0..<sidebar.visibleRowCount).compactMap { sidebar.renderedName(at: $0) }
        XCTAssertTrue(names.contains(directory.lastPathComponent), "and it is in the list")
        XCTAssertTrue(names.contains(directory.deletingLastPathComponent().lastPathComponent),
                      "with its parent above it")
    }

    /// Clicking a folder moves the gallery and the image viewer to it, and the browser stays open.
    func testClickingAFolderMovesTheGalleryAndKeepsTheBrowserOpen() throws {
        let (directory, controller, viewer) = try makeFolder(3, subfolders: 1)
        defer { cleanup(directory, controller) }
        let subfolder = directory.appendingPathComponent("sub0")
        try FileManager.default.copyItem(at: Fixtures.url("static.png"),
                                         to: subfolder.appendingPathComponent("only.png"))

        viewer.perform(.browseFolder)
        settle()
        let browser = try XCTUnwrap(viewer.folderBrowserForTesting)
        browser.view.onFolderChosen?(subfolder)
        settle(0.6)

        XCTAssertEqual(viewer.viewerMode, .folderBrowser, "the browser stays open")
        XCTAssertEqual(viewer.session.items.map(\.displayName), ["only.png"],
                       "the gallery moved to the chosen folder")
        XCTAssertEqual(viewer.session.directory?.standardizedFileURL.path,
                       subfolder.standardizedFileURL.path)
    }

    /// A viewer that never opens the browser never builds one.
    func testTheBrowserIsBuiltOnDemand() throws {
        let (directory, controller, viewer) = try makeFolder(2)
        defer { cleanup(directory, controller) }
        XCTAssertNil(viewer.folderBrowserForTesting)
        XCTAssertEqual(viewer.folderBrowserContainerForTesting.subviews.count, 0)
    }
}
