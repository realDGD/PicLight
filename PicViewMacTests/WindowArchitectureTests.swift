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
        XCTAssertTrue(window.styleMask.contains(.fullSizeContentView),
                      "auto-hide is the default, so the content reaches the top edge")
        XCTAssertNotEqual(window.styleMask, .borderless)
        XCTAssertTrue(window.isVisible)
        XCTAssertTrue(window.canBecomeKey)
        XCTAssertTrue(window.canBecomeMain)
    }

    /// The contract this file used to assert was "the standard titlebar is always visible". The
    /// redesign changes that — the bar auto-hides by default — but everything the old contract was
    /// protecting is still checked: the window is standard and titled, and the controls are AppKit's
    /// own `standardWindowButton`s rather than anything drawn.
    func testRealTrafficLightButtonsExistAndAreUsed() {
        let controller = makeViewer()
        guard let window = controller.window else { return XCTFail("no window") }
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            XCTAssertNotNil(window.standardWindowButton(button),
                            "\(button) must be the real standard window button")
        }
        XCTAssertTrue(window.styleMask.contains(.titled),
                      "the window management strip is still the standard titlebar")
        XCTAssertFalse(window is NSPanel)
        // Auto-hide's hidden state is a *transparent* titlebar, not a second hand-drawn one.
        XCTAssertTrue(window.titlebarAppearsTransparent)
        XCTAssertEqual(window.titleVisibility, .hidden)
        XCTAssertFalse(window.isMovableByWindowBackground,
                       "the window is dragged by its real titlebar, never by the image")
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

        // Open overlay chrome first, otherwise "immersive hides it" is not observable. The
        // drawer's own control is the explicit toggle — the pointer cannot open it.
        viewer.toggleDrawerForTesting()
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

    func testImmersiveStartsHiddenAndThePointerCannotBringChromeBack() {
        let controller = makeViewer()
        let viewer = controller.viewerViewController
        _ = viewer.view
        viewer.toggleDrawerForTesting()
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        XCTAssertTrue(viewer.chromeSnapshot.drawer, "the explicit control opens the drawer")

        viewer.simulateImmersive(true)
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        XCTAssertFalse(viewer.chromeSnapshot.drawer, "immersive starts with overlay chrome hidden")
        XCTAssertFalse(viewer.chromeSnapshot.minimap)

        // A stationary pointer must not bring chrome back on its own: the chrome timer keeps
        // ticking here without any new pointer event.
        for _ in 0..<6 { RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }
        XCTAssertFalse(viewer.chromeSnapshot.drawer,
                       "a parked pointer must not re-reveal chrome in immersive mode")

        // Nor does moving the pointer anywhere, the left edge included: the drawer's state is the
        // user's choice, so nothing the pointer does can undo immersive mode's suppression.
        for x in [0, 5, 23, 200] as [CGFloat] {
            viewer.simulatePointer(atWindowPoint: NSPoint(x: x, y: viewer.view.bounds.midY))
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
            XCTAssertFalse(viewer.chromeSnapshot.drawer,
                           "the pointer at x=\(x) must not reveal chrome in immersive mode")
        }

        // Leaving immersive mode restores the choice the user made.
        viewer.simulateImmersive(false)
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        XCTAssertTrue(viewer.chromeSnapshot.drawer,
                      "the drawer the user opened comes back when immersive mode ends")
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

/// The drawer reserves canvas width, and that reservation is reversible: closing it
/// puts the canvas back exactly where it was, and the user's view of the image — Fit
/// or a manual zoom — survives the cycle. The drawer used to be a hover-revealed
/// overlay that could not touch the canvas at all; it is now an explicitly opened pane,
/// which is what makes reserving width acceptable (spec §13 allows exactly this case).
/// This is the deterministic form of the acceptance runner's equivalent check, which can
/// only sample the live window afterwards.
@MainActor
final class DrawerReservationInvarianceTests: XCTestCase {

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

    /// The drawer is a reserving pane, not an overlay: opening it takes its width from the
    /// canvas, which is the one chrome-driven geometry change the spec allows (and requires an
    /// explicit user action to happen at all). What must hold is that the user's *view* of the
    /// image survives the cycle — Fit stays Fit, a manual zoom stays put — and that closing the
    /// drawer puts the canvas back exactly where it was, however many times it is done.
    func testDrawerOpenAndCloseCyclesReserveWidthAndRestoreTheCanvasExactly() throws {
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
        XCTAssertEqual(baseline.drawerReservedWidth, 0, "nothing is reserved while it is closed")
        var sawDrawerOpen = false

        for round in 0..<5 {
            viewer.toggleDrawerForTesting()
            settle(0.4)
            let open = viewer.chromeSnapshot
            if open.drawer { sawDrawerOpen = true }
            XCTAssertEqual(open.drawerReservedWidth, open.drawerWidth,
                           "round \(round): an open drawer reserves exactly its own width")
            XCTAssertLessThan(open.canvasFrame.width, baseline.canvasFrame.width,
                              "round \(round): and the canvas gives up that width")
            XCTAssertEqual(open.zoomScale, open.fitScale, accuracy: 0.0001,
                           "round \(round): Fit is still Fit, measured against the smaller canvas")

            viewer.toggleDrawerForTesting()
            settle(0.5)
            let closed = viewer.chromeSnapshot
            XCTAssertEqual(closed.canvasFrame, baseline.canvasFrame,
                           "round \(round): closing it returns the canvas to exactly where it was")
            XCTAssertEqual(closed.zoomScale, baseline.zoomScale, accuracy: 0.0001,
                           "round \(round): and to exactly the zoom it had")
            XCTAssertEqual(closed.drawerReservedWidth, 0)
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
