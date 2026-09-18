import XCTest
import AppKit
@testable import PicViewMac

/// Startup paths, exercised through the production API rather than by letting the
/// test show the window itself.
@MainActor
final class AppStartupTests: XCTestCase {
    private var environments: [AppEnvironment] = []

    override func setUp() async throws {
        try await super.setUp()
        TestAppKit.ensureApplication()
        environments = []
    }

    override func tearDown() async throws {
        environments.forEach { $0.viewerWindowControllers.forEach { $0.close() } }
        environments = []
        try await super.tearDown()
    }

    private func makeEnvironment() -> AppEnvironment {
        let environment = AppEnvironment()
        environments.append(environment)
        return environment
    }

    private func visibleViewerWindows() -> [ViewerWindow] {
        NSApp.windows.compactMap { $0 as? ViewerWindow }.filter { $0.isVisible }
    }

    /// The bug behind "Dock icon but no window": the controller was created and
    /// stored, but nothing ever ordered it front.
    func testPresentNewViewerWindowReallyShowsAWindow() {
        let environment = makeEnvironment()
        XCTAssertEqual(environments.count, 1)

        let controller = environment.presentNewViewerWindow()
        TestAppKit.moveOffScreen(controller.window)

        XCTAssertEqual(environment.viewerCount, 1)
        XCTAssertTrue(controller.window?.isVisible == true,
                      "a presented viewer must be visible without the caller showing it")
        // WindowServer focus (key/main) cannot be asserted from a session that is
        // not the active app, so this checks the ordered-front result instead:
        // visible, not miniaturised, and on screen.
        XCTAssertFalse(controller.window?.isMiniaturized == true)
        XCTAssertTrue(controller.window?.occlusionState.contains(.visible) == true
                      || controller.window?.isVisible == true)
        XCTAssertEqual(visibleViewerWindows().count, 1)
    }

    func testNewViewerWindowWithoutShowStaysOffscreenUntilPresented() {
        let environment = makeEnvironment()
        let controller = environment.newViewerWindow(show: false)
        XCTAssertEqual(controller.window?.isVisible, false,
                       "creating and showing are separate steps so a file open does not flash an empty window")
        controller.present()
        XCTAssertTrue(controller.window?.isVisible == true)
    }

    func testOpeningAFileCreatesExactlyOneWindowWithNoEmptyLeftover() async throws {
        let directory = try Fixtures.makeScratchDirectory("startup")
        defer { try? FileManager.default.removeItem(at: directory) }
        for name in ["a.png", "b.png"] {
            try FileManager.default.copyItem(at: Fixtures.url("static.png"),
                                             to: directory.appendingPathComponent(name))
        }

        let environment = makeEnvironment()
        environment.open(url: directory.appendingPathComponent("a.png"), behavior: .newWindow)
        try await Task.sleep(nanoseconds: 1_200_000_000)

        XCTAssertEqual(environment.viewerCount, 1,
                       "opening a file must not leave a stray empty viewer behind")
        XCTAssertEqual(visibleViewerWindows().count, 1)
        XCTAssertEqual(environment.currentFileNames, ["a.png"])
        XCTAssertTrue(environment.viewerWindowControllers.first?.window?.isVisible == true)
    }

    func testReopeningKeepsOneWindowAndDoesNotDuplicate() {
        let environment = makeEnvironment()
        _ = environment.presentNewViewerWindow()
        // A Dock reopen when a viewer is already visible must not add another.
        let hasVisible = environment.hasVisibleViewer
        XCTAssertTrue(hasVisible)
        if !hasVisible { _ = environment.presentNewViewerWindow() }
        XCTAssertEqual(environment.viewerCount, 1)
        XCTAssertEqual(visibleViewerWindows().count, 1)
    }

    func testEmptyStateShowsOnBareLaunchAndHidesWithAnImage() async throws {
        let directory = try Fixtures.makeScratchDirectory("startup-empty")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.copyItem(at: Fixtures.url("static.png"),
                                         to: directory.appendingPathComponent("a.png"))

        let environment = makeEnvironment()
        let controller = environment.presentNewViewerWindow()
        TestAppKit.moveOffScreen(controller.window)
        let viewer = controller.viewerViewController
        _ = viewer.view
        XCTAssertEqual(viewer.emptyStateReasonForTesting, .noImageOpened,
                       "a bare launch must explain how to open an image")
        XCTAssertFalse(viewer.chromeViewsForTesting["emptyState"]!.isHidden)

        viewer.open(url: directory.appendingPathComponent("a.png"))
        let deadline = Date().addingTimeInterval(10)
        while viewer.viewerState.currentImage == nil, Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertTrue(viewer.chromeViewsForTesting["emptyState"]!.isHidden,
                      "the welcome UI must get out of the way once an image loads")
        XCTAssertNil(viewer.emptyStateReasonForTesting)
    }

    func testEmptyFolderUsesTheEmptyStateWithItsOwnWording() async throws {
        let directory = try Fixtures.makeScratchDirectory("startup-emptyfolder")
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("%PDF-1.4".utf8).write(to: directory.appendingPathComponent("notes.pdf"))

        let environment = makeEnvironment()
        let controller = environment.presentNewViewerWindow()
        TestAppKit.moveOffScreen(controller.window)
        let viewer = controller.viewerViewController
        _ = viewer.view
        viewer.open(url: directory.appendingPathComponent("notes.pdf"))
        // Wait for the scan to finish: `directory` is set synchronously, so the
        // scan is observed through its effect on the empty-state wording.
        let deadline = Date().addingTimeInterval(8)
        while viewer.session.directory == nil, Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        var scans = 0
        let previousHandler = viewer.session.onItemsChanged
        viewer.session.onItemsChanged = {
            previousHandler?()
            scans += 1
        }
        while scans == 0, Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertGreaterThan(scans, 0, "the folder scan must complete")

        XCTAssertEqual(viewer.emptyStateReasonForTesting, .folderHasNoImages,
                       "an empty folder and a fresh launch read differently")
        XCTAssertNotEqual(EmptyStateView.Reason.folderHasNoImages.hint,
                          EmptyStateView.Reason.noImageOpened.hint)
    }
}

/// Pinning the drawer: it stays open, overlays the image, survives immersive mode
/// and never disturbs the canvas.
@MainActor
final class DrawerPinTests: XCTestCase {

    override func setUp() async throws {
        try await super.setUp()
        TestAppKit.ensureApplication()
    }
    func testAnOpenDrawerStaysOpenWithThePointerAnywhere() {
        var model = HoverVisibilityModel()
        model.setDrawerOpen(true, at: 0)
        _ = model.update(at: 0.2)
        XCTAssertTrue(model.drawerVisible)

        // The pointer leaves and stays away. Nothing the pointer does may close a drawer the user
        // opened, and no timer runs down behind them either.
        model.pointerMoved(at: 0.3)
        for step in 0..<30 { _ = model.update(at: 0.3 + Double(step) * 0.1) }
        XCTAssertTrue(model.drawerVisible, "an open drawer ignores the pointer entirely")
        XCTAssertTrue(model.drawerOpen)
    }

    func testClosingTheDrawerIsExplicitToo() {
        var model = HoverVisibilityModel()
        model.setDrawerOpen(true, at: 0)
        _ = model.update(at: 0.1)
        XCTAssertTrue(model.drawerVisible)

        model.toggleDrawer(at: 1.0)
        _ = model.update(at: 1.4)
        XCTAssertFalse(model.drawerVisible, "the toggle is what closes it")
    }

    func testAnOpenDrawerIsTemporarilyHiddenInImmersiveModeAndComesBack() {
        var model = HoverVisibilityModel()
        model.setDrawerOpen(true, at: 0)
        _ = model.update(at: 0.1)
        XCTAssertTrue(model.drawerVisible)

        model.setImmersive(true, at: 1)
        _ = model.update(at: 1.1)
        XCTAssertFalse(model.drawerVisible, "immersive hides chrome, including the drawer")
        XCTAssertTrue(model.drawerOpen, "the user's choice survives immersive mode")

        model.setImmersive(false, at: 2)
        _ = model.update(at: 2.1)
        XCTAssertTrue(model.drawerVisible, "leaving immersive mode restores the open drawer")
    }

    /// Waits for a condition instead of assuming the chrome timer ticked in time.
    /// A fixed drain is not enough on a loaded machine, where a 0.1 s timer can be
    /// delayed past the delay it is supposed to deliver.
    private func waitUntil(timeout: TimeInterval = 3,
                           _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return condition()
    }

    /// Pinning used to be chrome-only; it now reserves real layout space, so the
    /// canvas narrows and everything anchored to it follows.
    func testPinningReservesSpaceAndUnpinningRestoresIt() throws {
        TestAppKit.ensureApplication()
        let controller = ViewerWindowController()
        defer { controller.close() }
        let viewer = controller.viewerViewController
        TestAppKit.presentOffScreen(controller)
        _ = viewer.view
        viewer.open(url: Fixtures.url("static.png"))
        let deadline = Date().addingTimeInterval(10)
        while viewer.viewerState.currentImage == nil, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        let baseline = viewer.chromeSnapshot

        viewer.toggleDrawerForTesting()
        XCTAssertTrue(waitUntil { viewer.chromeSnapshot.drawer }, "pinning opens the drawer")
        let pinned = viewer.chromeSnapshot.canvasFrame
        XCTAssertLessThan(pinned.width, baseline.canvasFrame.width,
                          "a pinned drawer reserves leading space instead of overlaying")
        XCTAssertEqual(pinned.minX, baseline.canvasFrame.minX + ThumbnailDrawerView.minimumWidth,
                       accuracy: 1,
                       "the canvas starts where the drawer ends")

        viewer.toggleDrawerForTesting()
        XCTAssertTrue(waitUntil { !viewer.chromeSnapshot.drawer },
                      "unpinning closes the drawer after its hover delay")
        XCTAssertEqual(viewer.chromeSnapshot.canvasFrame, baseline.canvasFrame,
                       "unpinning gives the full width back to the canvas")
    }
}

/// Navigator layering and preview economy.
@MainActor
final class NavigatorLayeringTests: XCTestCase {

    override func setUp() async throws {
        try await super.setUp()
        TestAppKit.ensureApplication()
    }
    func testGlassSitsBehindPreviewAndViewportOverlay() {
        TestAppKit.ensureApplication()
        let navigator = NavigatorView()
        navigator.frame = NSRect(x: 0, y: 0, width: 168, height: 120)

        let background = navigator.backgroundSurface
        let preview = navigator.previewSurface
        XCTAssertTrue(background.superview === navigator)
        XCTAssertTrue(preview.superview === navigator)
        XCTAssertLessThan(navigator.subviews.firstIndex(of: background) ?? .max,
                          navigator.subviews.firstIndex(of: preview) ?? .min,
                          "the material must be behind the preview, never composited over it")
        let overlay = navigator.viewportOverlaySurface
        XCTAssertGreaterThan(navigator.subviews.firstIndex(of: overlay) ?? -1,
                             navigator.subviews.firstIndex(of: preview) ?? .max,
                             "the viewport outline view sits above the preview view")
        XCTAssertTrue(navigator.viewportOverlayLayer.superlayer === overlay.layer,
                      "the outline is drawn inside that overlay view's layer")
    }

    func testPreviewIsABoundedDownsampleNotTheSourceImage() async throws {
        let pipeline = ThumbnailPipeline()
        let decoder = ImageIODecoder()
        let head = try await decoder.decodeFirstDisplayableFrame(Fixtures.url("static.png"),
                                                                 target: .fullResolution)
        let previewImage = await pipeline.preview(from: head.image,
                                                  maxPixelSize: NavigatorView.previewPixelSize)
        let preview = try XCTUnwrap(previewImage)
        XCTAssertLessThanOrEqual(max(preview.width, preview.height), NavigatorView.previewPixelSize)
        XCTAssertEqual(NavigatorView.previewPixelSize, 336,
                       "the preview is the logical size at 2x for a crisp Retina result")
    }

    func testLargeSourceIsDownsampledForThePreview() async throws {
        let context = CGContext(data: nil, width: 4000, height: 3000, bitsPerComponent: 8,
                                bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 4000, height: 3000))
        let source = context.makeImage()!

        let pipeline = ThumbnailPipeline()
        let previewImage = await pipeline.preview(from: source,
                                                  maxPixelSize: NavigatorView.previewPixelSize)
        let preview = try XCTUnwrap(previewImage)
        XCTAssertLessThanOrEqual(max(preview.width, preview.height), 336)
        XCTAssertGreaterThan(preview.width, 100, "the preview keeps useful detail")
    }

    func testViewportMovementDoesNotRegenerateThePreview() throws {
        TestAppKit.ensureApplication()
        let controller = ViewerWindowController()
        defer { controller.close() }
        let viewer = controller.viewerViewController
        TestAppKit.presentOffScreen(controller)
        _ = viewer.view
        viewer.open(url: Fixtures.url("static.png"))
        let deadline = Date().addingTimeInterval(10)
        while viewer.viewerState.currentImage == nil, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))

        let navigator = viewer.chromeViewsForTesting["minimap"] as! NavigatorView
        let generationsAfterLoad = navigator.previewGenerationCount
        XCTAssertGreaterThan(generationsAfterLoad, 0, "loading an image builds one preview")
        XCTAssertTrue(navigator.hasPreviewImage)

        // Pan and zoom repeatedly: only the viewport rectangle may move.
        viewer.perform(.zoomDoubleFit)
        for _ in 0..<5 {
            viewer.perform(.zoomActualPixels)
            viewer.perform(.zoomToFit)
            viewer.perform(.zoomDoubleFit)
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        XCTAssertEqual(navigator.previewGenerationCount, generationsAfterLoad,
                       "pan and zoom must not rebuild the preview bitmap")
    }

    func testViewportOverlayIsAsingleCrispOutline() throws {
        TestAppKit.ensureApplication()
        let navigator = NavigatorView()
        navigator.frame = NSRect(x: 0, y: 0, width: 168, height: 120)
        navigator.setPreviewImage(Fixtures.thumbnail())  // main-actor helper
        navigator.visibleNormalizedRect = CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
        navigator.layoutSubtreeIfNeeded()

        XCTAssertNotNil(navigator.viewportOverlayLayer.path, "the outline must exist")
        XCTAssertEqual(navigator.viewportOverlayLayer.lineWidth, 1.5, accuracy: 0.001)
        XCTAssertEqual(navigator.viewportOverlayLayer.fillColor?.alpha ?? 1, 0.12, accuracy: 0.02)
        XCTAssertNil(navigator.viewportOverlayLayer.shadowOpacity > 0 ? "shadow" : nil,
                     "no shadow on the outline: it must read as one crisp frame")
        // A single shape layer cannot produce the multiple refracted frames that a
        // material composited over the outline did.
        XCTAssertEqual(navigator.viewportOverlaySurface.layer?.sublayers?
            .filter { $0 is CAShapeLayer }.count, 1)
    }
}

/// Delete follow-up: the two preferences must stop being aliases.
@MainActor
final class DeleteFollowUpTests: XCTestCase {

    override func setUp() async throws {
        try await super.setUp()
        TestAppKit.ensureApplication()
    }
    private func items(_ names: [String]) -> [FolderItem] {
        names.map { FolderItem(url: URL(fileURLWithPath: "/tmp/\($0)")) }
    }

    func testSmartPrefersTheNextImageThenThePrevious() {
        let session = FolderSession(items: items(["a.jpg", "b.jpg", "c.jpg"]))
        session.select(index: 1)
        session.removeCurrentWithSmartSelection(identity: session.currentItem?.id)
        XCTAssertEqual(session.currentItem?.displayName, "c.jpg", "smart follows the next image")

        let last = FolderSession(items: items(["a.jpg", "b.jpg"]))
        last.select(index: 1)
        last.removeCurrentWithSmartSelection(identity: last.currentItem?.id)
        XCTAssertEqual(last.currentItem?.displayName, "a.jpg", "smart falls back to the previous image")

        let only = FolderSession(items: items(["a.jpg"]))
        only.removeCurrentWithSmartSelection(identity: only.currentItem?.id)
        XCTAssertNil(only.currentItem, "removing the last file leaves an empty state")
    }

    func testStayInPlaceKeepsTheSlotRatherThanFollowingANeighbour() {
        // Deleting the *last* item must not walk backwards the way smart does when
        // the list is longer and the slot still exists.
        let session = FolderSession(items: items(["a.jpg", "b.jpg", "c.jpg", "d.jpg"]))
        session.select(index: 1)
        session.removeCurrentKeepingPosition(identity: session.currentItem?.id)
        XCTAssertEqual(session.currentIndex, 1, "the slot is held, not vacated")
        XCTAssertEqual(session.currentItem?.displayName, "c.jpg")

        // Removing the tail clamps to the new last slot.
        let tail = FolderSession(items: items(["a.jpg", "b.jpg"]))
        tail.select(index: 1)
        tail.removeCurrentKeepingPosition(identity: tail.currentItem?.id)
        XCTAssertEqual(tail.currentIndex, 0)
        XCTAssertEqual(tail.currentItem?.displayName, "a.jpg")

        let empty = FolderSession(items: items(["a.jpg"]))
        empty.removeCurrentKeepingPosition(identity: empty.currentItem?.id)
        XCTAssertTrue(empty.isEmpty)
        XCTAssertNil(empty.currentIndex)
    }

    /// The observable difference between the two preferences: what survives a
    /// folder change. `preferredIdentity` follows the file, `preferredIndex` holds
    /// the slot even when a re-sort puts a different file there.
    func testPreferencesDifferWhenTheFolderOrderChanges() {
        let session = FolderSession(items: items(["a.jpg", "b.jpg", "c.jpg"]))
        session.select(index: 1)
        let heldFile = session.currentItem?.displayName
        XCTAssertEqual(heldFile, "b.jpg")

        // A rescan that re-sorts the folder so that "b.jpg" moves to the end.
        let resorted = items(["a.jpg", "c.jpg", "b.jpg"])

        session.setItems(resorted, preferredIdentity: session.currentItem?.id)
        XCTAssertEqual(session.currentItem?.displayName, "b.jpg",
                       "the smart anchor follows the file the user was moved to")
        XCTAssertEqual(session.currentIndex, 2)

        session.setItems(resorted, preferredIndex: 1)
        XCTAssertEqual(session.currentIndex, 1,
                       "the stay-in-place anchor holds the slot after the re-sort")
        XCTAssertEqual(session.currentItem?.displayName, "c.jpg")
    }

    func testViewerRoutesDeleteThroughTheConfiguredPreference() async throws {
        let directory = try Fixtures.makeScratchDirectory("delete-policy")
        defer { try? FileManager.default.removeItem(at: directory) }
        for name in ["a.png", "b.png", "c.png"] {
            try FileManager.default.copyItem(at: Fixtures.url("static.png"),
                                             to: directory.appendingPathComponent(name))
        }
        let settings = AppSettings.shared
        let original = settings.deleteFollowUp
        defer { settings.deleteFollowUp = original }

        for policy in DeleteFollowUp.allCases {
            settings.deleteFollowUp = policy
            let viewer = ViewerViewController()
            _ = viewer.view
            viewer.open(url: directory.appendingPathComponent("b.png"))
            let deadline = Date().addingTimeInterval(10)
            while viewer.viewerState.currentImage == nil, Date() < deadline {
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            XCTAssertEqual(viewer.session.currentItem?.displayName, "b.png")

            viewer.perform(.moveToTrash)
            try? await Task.sleep(nanoseconds: 700_000_000)

            XCTAssertEqual(viewer.session.currentItem?.displayName, "c.png",
                           "\(policy): deleting the middle image lands on the next one")
            XCTAssertEqual(viewer.session.items.count, 2, "\(policy): the file is gone")

            // Restore the fixture for the next policy.
            try FileManager.default.copyItem(at: Fixtures.url("static.png"),
                                             to: directory.appendingPathComponent("b.png"))
        }
    }
}

extension Fixtures {
    /// A tiny in-memory image for tests that need a preview without touching disk.
    @MainActor
    static func thumbnail() -> CGImage {
        if let cached = FixtureCache.shared { return cached }
        let context = CGContext(data: nil, width: 64, height: 48, bitsPerComponent: 8,
                                bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.9, green: 0.3, blue: 0.2, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
        let image = context.makeImage()!
        FixtureCache.shared = image
        return image
    }
}

@MainActor
private enum FixtureCache {
    static var shared: CGImage?
}
