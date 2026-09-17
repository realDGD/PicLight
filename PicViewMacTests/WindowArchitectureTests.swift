import XCTest
import AppKit
@testable import PicViewMac

/// Window-architecture invariants: one viewer equals exactly one standard
/// top-level `NSWindow`, and no hover UI ever creates another window.
///
/// Windows are classified by type rather than by counting `NSApp.windows`,
/// because menus, the Settings window and WindowServer leftovers are not
/// viewer windows.
@MainActor
final class WindowArchitectureTests: XCTestCase {
    private var controllers: [ViewerWindowController] = []

    override func setUp() async throws {
        try await super.setUp()
        TestAppKit.ensureApplication()
        controllers = []
    }

    override func tearDown() async throws {
        controllers.forEach { $0.close() }
        controllers = []
        try await super.tearDown()
    }

    // MARK: - Classification helpers

    private func makeViewer() -> ViewerWindowController {
        let controller = ViewerWindowController()
        controllers.append(controller)
        TestAppKit.presentOffScreen(controller)
        return controller
    }

    /// Viewer windows are `ViewerWindow` instances; everything else is "other".
    private func viewerWindows() -> [ViewerWindow] {
        NSApp.windows.compactMap { $0 as? ViewerWindow }
    }

    private func viewerWindows(visibleOnly: Bool) -> [ViewerWindow] {
        viewerWindows().filter { !visibleOnly || $0.isVisible }
    }

    private func overlayLikeWindows() -> [NSWindow] {
        NSApp.windows.filter { window in
            guard !(window is ViewerWindow) else { return false }
            // Panels are exactly what the spec forbids for hover chrome.
            if window is NSPanel { return true }
            // Untitled, borderless, always-on-top windows are overlay shaped.
            if window.styleMask == .borderless { return true }
            return window.level != .normal
        }
    }

    // MARK: - Viewer count

    func testOneTwoThreeViewersProduceExactlyThatManyTopLevelWindows() {
        for count in 1...3 {
            while controllers.count < count { _ = makeViewer() }
            let viewers = viewerWindows(visibleOnly: true)
            XCTAssertEqual(viewers.count, count, "expected \(count) viewer windows")
            // Each viewer owns exactly one window: no window controller owns a second.
            let owned = Set(controllers.compactMap { $0.window?.windowNumber })
            XCTAssertEqual(owned.count, controllers.count,
                           "each window controller must own exactly one distinct window")
        }
    }

    func testHoverChromeNeverCreatesViewerLikeOrOverlayWindows() {
        let controller = makeViewer()
        let viewer = controller.viewerViewController
        _ = viewer.view
        let before = viewerWindows(visibleOnly: false).count
        let overlaysBefore = overlayLikeWindows().count

        // Drive every chrome surface through the production paths.
        viewer.simulatePointer(atWindowPoint: NSPoint(x: 3, y: viewer.view.bounds.midY))
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        viewer.simulatePointer(atWindowPoint: NSPoint(x: viewer.view.bounds.midX,
                                                      y: viewer.view.bounds.height - 10))
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        viewer.perform(.toggleThumbnailDrawer)
        viewer.perform(.zoomToFit)
        viewer.perform(.zoomDoubleFit)
        viewer.simulateZoomActivity()
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        viewer.perform(.showImageInfo)
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        viewer.perform(.toggleImmersive)
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        viewer.perform(.toggleImmersive)

        XCTAssertEqual(viewerWindows(visibleOnly: false).count, before,
                       "hover chrome, minimap and immersive mode must not add viewer windows")
        XCTAssertEqual(overlayLikeWindows().count, overlaysBefore,
                       "no panel or overlay window may appear for hover UI")
        XCTAssertTrue((controller.window?.childWindows ?? []).isEmpty,
                      "hover UI must be subviews, never child windows")
    }

    func testDrawerAndMinimapAreSubviewsOfTheSingleViewerWindow() {
        let controller = makeViewer()
        let viewer = controller.viewerViewController
        _ = viewer.view
        let window = try? XCTUnwrap(controller.window)
        guard let window, let content = window.contentView else {
            return XCTFail("viewer window has no content view")
        }
        func contains(_ target: NSView) -> Bool {
            var node: NSView? = target
            while let current = node {
                if current === content { return true }
                node = current.superview
            }
            return false
        }
        XCTAssertTrue(contains(viewer.chromeSnapshot.canvasView))
        XCTAssertTrue(contains(viewer.chromeSnapshot.drawerView),
                      "the drawer must live inside the viewer window")
        XCTAssertTrue(contains(viewer.chromeSnapshot.minimapView),
                      "the minimap must live inside the viewer window")
    }

    // MARK: - Window class and style policy

    func testViewerWindowKeepsTheStandardStyleMaskAndIsNotAPanel() {
        let controller = makeViewer()
        guard let window = controller.window else { return XCTFail("no window") }

        XCTAssertFalse(window is NSPanel, "a viewer is a window, not a utility panel")
        XCTAssertTrue(type(of: window) == ViewerWindow.self)

        // Positive assertions on the real window, not on a zero-valued option.
        XCTAssertTrue(window.styleMask.contains(.titled))
        XCTAssertTrue(window.styleMask.contains(.closable))
        XCTAssertTrue(window.styleMask.contains(.miniaturizable))
        XCTAssertTrue(window.styleMask.contains(.resizable))
        XCTAssertFalse(window.styleMask.contains(.fullSizeContentView))
        XCTAssertNotEqual(window.styleMask, .borderless)
        XCTAssertTrue(window.isVisible)
        XCTAssertTrue(window.canBecomeKey)
        XCTAssertTrue(window.canBecomeMain)
    }

    func testRealTrafficLightButtonsExistAndAreUsed() {
        let controller = makeViewer()
        guard let window = controller.window else { return XCTFail("no window") }
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            XCTAssertNotNil(window.standardWindowButton(button),
                            "\(button) must be the real standard window button")
        }
        XCTAssertEqual(window.titleVisibility, .visible,
                       "the window management strip is the standard titlebar")
        XCTAssertFalse(window.titlebarAppearsTransparent,
                       "the titlebar is a normal, opaque AppKit bar")
        XCTAssertFalse(window.styleMask.contains(.fullSizeContentView),
                       "content starts below the titlebar instead of underneath it")
    }

    func testNativeTabbingIsDisabledOnTheWindowAndAppWide() {
        XCTAssertFalse(NSWindow.allowsAutomaticWindowTabbing,
                       "automatic window tabbing must be disabled app-wide")
        let controller = makeViewer()
        XCTAssertEqual(controller.window?.tabbingMode, .disallowed)
        XCTAssertTrue((controller.window?.tabbedWindows ?? []).isEmpty,
                      "a viewer must never join a tab group")
    }

    // MARK: - Immersive vs native Full Screen

    func testImmersiveModeChangesChromeOnlyAndKeepsWindowIdentity() {
        let controller = makeViewer()
        let viewer = controller.viewerViewController
        _ = viewer.view
        guard let window = controller.window else { return XCTFail("no window") }

        let frameBefore = window.frame
        let screenBefore = window.screen
        let numberBefore = window.windowNumber
        let maskBefore = window.styleMask

        // Reveal overlay chrome first, otherwise "immersive hides it" is not
        // observable. The left edge is the drawer's trigger now.
        viewer.simulatePointer(atWindowPoint: NSPoint(x: 5, y: viewer.view.bounds.midY))
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        XCTAssertTrue(viewer.chromeSnapshot.drawer,
                      "the drawer must be visible before immersive")

        viewer.perform(.toggleImmersive)
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        let chromeImmersive = viewer.chromeSnapshot

        XCTAssertEqual(window.frame, frameBefore, "immersive must not move or resize the window")
        XCTAssertEqual(window.screen, screenBefore, "immersive must not change the window's screen")
        XCTAssertEqual(window.windowNumber, numberBefore,
                       "immersive must not replace the top-level window")
        XCTAssertEqual(window.styleMask, maskBefore,
                       "immersive must not change the window style; it is chrome policy only")
        XCTAssertFalse(chromeImmersive.drawer, "immersive must actually hide the overlay chrome")

        viewer.perform(.toggleImmersive)
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        XCTAssertEqual(window.frame, frameBefore)
        XCTAssertEqual(window.windowNumber, numberBefore)
    }

    func testImmersiveStartsHiddenAndStillAllowsTemporaryHoverReveal() {
        let controller = makeViewer()
        let viewer = controller.viewerViewController
        _ = viewer.view
        viewer.simulatePointer(atWindowPoint: NSPoint(x: 5, y: viewer.view.bounds.midY))
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        XCTAssertTrue(viewer.chromeSnapshot.drawer, "the drawer is revealed by the left edge")

        viewer.simulateImmersive(true)
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        XCTAssertFalse(viewer.chromeSnapshot.drawer, "immersive starts with overlay chrome hidden")
        XCTAssertFalse(viewer.chromeSnapshot.minimap)

        // A stationary pointer must not bring chrome back on its own: the chrome
        // timer keeps ticking here without any new pointer event.
        for _ in 0..<6 { RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }
        XCTAssertFalse(viewer.chromeSnapshot.drawer,
                       "a parked pointer must not re-reveal chrome in immersive mode")

        // Moving into the left edge does reveal it temporarily.
        viewer.simulatePointer(atWindowPoint: NSPoint(x: 5, y: viewer.view.bounds.midY))
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        XCTAssertTrue(viewer.chromeSnapshot.drawer)

        viewer.simulateImmersive(false)
    }

    func testFullScreenUsesTheStandardCommandAndIsNotEmulatedByResizing() {
        let menu = MainMenuBuilder.build(appName: "PicViewMac", shortcutStore: ShortcutStore.shared)
        let windowMenu = menu.items.compactMap(\.submenu).first {
            $0.items.contains { $0.action == #selector(NSWindow.toggleFullScreen(_:)) }
        }
        let fullScreenItem = windowMenu?.items.first {
            $0.action == #selector(NSWindow.toggleFullScreen(_:))
        }
        XCTAssertNotNil(fullScreenItem, "native Full Screen must be the standard macOS command")
        XCTAssertNotEqual(fullScreenItem?.action, #selector(AppDelegate.performViewerCommand(_:)),
                          "full screen must not be routed through a custom viewer command")

        // The viewer is eligible for native full screen and never keeps its own
        // full-screen flag: `NSWindow` owns that state.
        let controller = makeViewer()
        XCTAssertTrue(controller.window?.collectionBehavior.contains(.fullScreenPrimary) == true)
        XCTAssertFalse(controller.viewerViewController.viewerState.isImmersive)
    }

    func testImmersiveAndFullScreenAreIndependentStates() {
        let controller = makeViewer()
        let viewer = controller.viewerViewController
        _ = viewer.view
        guard let window = controller.window else { return XCTFail("no window") }

        // Immersive must not put the window into native full screen.
        XCTAssertFalse(window.styleMask.contains(.fullScreen))
        viewer.perform(.toggleImmersive)
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        XCTAssertTrue(viewer.viewerState.isImmersive)
        XCTAssertFalse(window.styleMask.contains(.fullScreen),
                       "immersive is chrome policy, not native full screen")
        XCTAssertTrue(window.collectionBehavior.contains(.fullScreenPrimary),
                      "native full screen stays available while immersive mode is on")
        viewer.perform(.toggleImmersive)
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        XCTAssertFalse(viewer.viewerState.isImmersive)
    }
}

/// The drawer must be a pure overlay: opening and closing it may never move the
/// canvas or change zoom. This is the deterministic form of the acceptance
/// runner's equivalent check, which can only sample the live window afterwards.
@MainActor
final class DrawerOverlayInvarianceTests: XCTestCase {

    override func setUp() async throws {
        try await super.setUp()
        TestAppKit.ensureApplication()
    }
    /// Drains the main run loop so timers and main-actor jobs can run, which is
    /// how the chrome state machine is driven in a synchronous test.
    private func settle(_ seconds: TimeInterval = 0.25) {
        _ = RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    private func waitForImage(_ viewer: ViewerViewController) -> Bool {
        let deadline = Date().addingTimeInterval(10)
        while viewer.viewerState.currentImage == nil, Date() < deadline { settle(0.05) }
        settle(0.4)   // first layout pass and refit
        return viewer.viewerState.currentImage != nil
    }

    func testDrawerOpenAndCloseCyclesNeverChangeCanvasGeometry() throws {
        let directory = try Fixtures.makeScratchDirectory("drawer")
        defer { try? FileManager.default.removeItem(at: directory) }
        for name in ["a.png", "b.png", "c.png"] {
            try FileManager.default.copyItem(at: Fixtures.url("static.png"),
                                             to: directory.appendingPathComponent(name))
        }

        TestAppKit.ensureApplication()
        let controller = ViewerWindowController()
        defer { controller.close() }
        let viewer = controller.viewerViewController
        controller.showWindow(nil)
        _ = viewer.view
        viewer.open(url: directory.appendingPathComponent("b.png"))
        XCTAssertTrue(waitForImage(viewer), "the fixture image must load")

        let baseline = viewer.chromeSnapshot
        var sawDrawerOpen = false

        for _ in 0..<5 {
            // Pointer into the ~12 px left-edge hot zone.
            viewer.simulatePointer(atWindowPoint: NSPoint(x: 2, y: viewer.view.bounds.midY))
            settle(0.4)
            if viewer.chromeSnapshot.drawer { sawDrawerOpen = true }
            XCTAssertEqual(viewer.chromeSnapshot.canvasFrame, baseline.canvasFrame,
                           "opening the drawer must not move the canvas")
            XCTAssertEqual(viewer.chromeSnapshot.zoomScale, baseline.zoomScale, accuracy: 0.0001,
                           "opening the drawer must not change zoom")

            // Pointer away from the hot zone closes it again.
            viewer.simulatePointer(atWindowPoint: NSPoint(x: viewer.view.bounds.midX,
                                                         y: viewer.view.bounds.midY))
            settle(0.5)
            XCTAssertEqual(viewer.chromeSnapshot.canvasFrame, baseline.canvasFrame,
                           "closing the drawer must not move the canvas")
            XCTAssertEqual(viewer.chromeSnapshot.zoomScale, baseline.zoomScale, accuracy: 0.0001)
        }

        XCTAssertTrue(sawDrawerOpen,
                      "the check is only meaningful if the drawer actually opened")
        XCTAssertEqual(viewer.chromeSnapshot.drawerRows, viewer.session.items.count,
                       "the drawer still lists the whole folder afterwards")
    }

    func testMinimapVisibilityNeverChangesCanvasGeometry() throws {
        TestAppKit.ensureApplication()
        let controller = ViewerWindowController()
        defer { controller.close() }
        let viewer = controller.viewerViewController
        controller.showWindow(nil)
        _ = viewer.view
        viewer.open(url: Fixtures.url("static.png"))
        XCTAssertTrue(waitForImage(viewer), "the fixture image must load")

        let baseline = viewer.chromeSnapshot
        viewer.perform(.zoomDoubleFit)
        viewer.simulateZoomActivity()
        settle(0.3)
        XCTAssertTrue(viewer.chromeSnapshot.minimap, "zooming past Fit must reveal the minimap")
        XCTAssertEqual(viewer.chromeSnapshot.canvasFrame, baseline.canvasFrame,
                       "the minimap must not resize the canvas it describes")

        viewer.perform(.zoomToFit)
        settle(0.3)
        XCTAssertFalse(viewer.chromeSnapshot.minimap, "the minimap hides at Fit")
        XCTAssertEqual(viewer.chromeSnapshot.canvasFrame, baseline.canvasFrame)
    }
}
