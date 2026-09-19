import XCTest
import AppKit
@testable import PicViewMac

/// The viewer layout refactor: a standard titlebar, a fixed bottom tool dock, and
/// a drawer that reserves real space instead of overlaying when pinned.
@MainActor
final class ViewerLayoutTests: XCTestCase {

    override func setUp() async throws {
        try await super.setUp()
        TestAppKit.ensureApplication()
    }
    private func makeViewer() throws -> (controller: ViewerWindowController, viewer: ViewerViewController) {
        TestAppKit.ensureApplication()
        let controller = ViewerWindowController()
        TestAppKit.presentOffScreen(controller)
        let viewer = controller.viewerViewController
        _ = viewer.view
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        viewer.view.layoutSubtreeIfNeeded()
        return (controller, viewer)
    }

    private func settle(_ seconds: TimeInterval = 0.3) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    private func loadImage(_ viewer: ViewerViewController) {
        viewer.open(url: Fixtures.url("static.png"))
        let deadline = Date().addingTimeInterval(10)
        while viewer.viewerState.currentImage == nil, Date() < deadline { settle(0.05) }
        settle(0.4)
    }

    // MARK: - Titlebar

    /// The default is the auto-hiding titlebar: still a standard titled window with the real
    /// controls, with the content reaching the top edge and the bar itself away.
    func testViewerUsesTheStandardTitlebarInItsDefaultAutoHideMode() throws {
        let (controller, _) = try makeViewer()
        defer { controller.close() }
        guard let window = controller.window as? ViewerWindow else { return XCTFail("no window") }

        XCTAssertTrue(window.styleMask.contains(.titled))
        XCTAssertTrue(window.styleMask.contains(.fullSizeContentView),
                      "auto-hide lets the content reach the top edge")
        XCTAssertEqual(window.titlebarMode, .autoHide)
        XCTAssertEqual(window.titleVisibility, .hidden)
        XCTAssertTrue(window.titlebarAppearsTransparent)
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            XCTAssertNotNil(window.standardWindowButton(button),
                            "the real controls, not a drawn replacement")
        }
        XCTAssertEqual(window.title, "PicLight", "no image: the app name is the title")
    }

    func testTitleFollowsTheCurrentImage() throws {
        let (controller, viewer) = try makeViewer()
        defer { controller.close() }
        loadImage(viewer)
        XCTAssertEqual(controller.window?.title, "static.png",
                       "the standard titlebar shows the current file")
    }

    func testTitlebarAndTrafficLightsAreNotPartOfViewerChrome() throws {
        let (controller, viewer) = try makeViewer()
        defer { controller.close() }
        XCTAssertFalse(viewer.chromeViewsForTesting.keys.contains("topBar"),
                       "there is no viewer-owned top bar")
        // In auto-hide mode the content reaches the top of the window, so there is no titlebar band
        // for the viewer's chrome to stay out of — and no fake titlebar view among the chrome.
        guard let content = controller.window?.contentView else { return XCTFail("no content") }
        let titlebarHeight = controller.window!.frame.height - content.frame.height
        XCTAssertEqual(titlebarHeight, 0, accuracy: 0.5,
                       "the content view spans the whole window in auto-hide mode")
        XCTAssertFalse(viewer.chromeViewsForTesting.values.contains { $0 is NSTitlebarAccessoryViewController },
                       "no viewer-owned titlebar accessory")
    }

    // MARK: - Tool dock

    func testToolDockExposesTheViewerCommands() throws {
        let (controller, viewer) = try makeViewer()
        defer { controller.close() }
        let dock = try XCTUnwrap(viewer.chromeViewsForTesting["toolDock"] as? ViewerToolDockView)
        XCTAssertEqual(dock.commands,
                       [.zoomOut, .zoomIn, .zoomToFit, .zoomToFitWidth, .zoomActualPixels,
                        .previousImage, .nextImage,
                        .rotateClockwise, .toggleMirror, .moveToTrash,
                        .toggleThumbnailDrawer, .showImageInfo])
    }

    /// Adjustments first, then moving through the folder, then the zoom and file
    /// actions - with the navigation pair sitting in the middle of the dock.
    func testDockUsesTheRequestedZoomSymbols() {
        XCTAssertEqual(ViewerToolDockView.fitSymbol,
                       "arrow.down.left.and.arrow.up.right.rectangle")
        XCTAssertEqual(ViewerToolDockView.fitWidthSymbol, "arrow.left.and.right.square")
        // Every symbol the dock declares must actually resolve on this system.
        for item in ViewerToolDockView.layout {
            guard case let .command(symbol, _, _) = item else { continue }
            XCTAssertNotNil(NSImage(systemSymbolName: symbol, accessibilityDescription: nil), symbol)
        }
    }

    func testNavigationSitsInTheMiddleOfTheDock() throws {
        let dock = ViewerToolDockView()
        dock.frame = NSRect(x: 0, y: 0, width: 400, height: 38)
        dock.layoutSubtreeIfNeeded()
        let commands = dock.commands
        let previousIndex = try XCTUnwrap(commands.firstIndex(of: .previousImage))
        let nextIndex = try XCTUnwrap(commands.firstIndex(of: .nextImage))
        XCTAssertEqual(nextIndex, previousIndex + 1, "the navigation pair is adjacent")

        // The pair sits inside the navigation group, with the zoom group before it and the image
        // actions after. The dock used to be one flat strip with the pair in the middle; the
        // redesign gives it four groups, so the contract is the group's position, not the centre.
        let zoomGroup = try XCTUnwrap(commands.firstIndex(of: .zoomToFit))
        let firstImageAction = try XCTUnwrap(commands.firstIndex(of: .rotateClockwise))
        XCTAssertLessThan(zoomGroup, previousIndex, "zoom leads")
        XCTAssertLessThan(nextIndex, firstImageAction, "navigation precedes the image actions")
        XCTAssertEqual(nextIndex, previousIndex + 1, "and the pair is adjacent")

        // Group separators, drawn as arranged subviews that are not buttons.
        let separators = dock.subviews.compactMap { $0 as? NSStackView }
            .flatMap { $0.arrangedSubviews.filter { $0 is NSBox } }
        XCTAssertEqual(separators.count, 4,
                       "one between each pair of groups, plus the pin's own")
    }

    /// Presence and enabled state are not enough: a button with no icon renders as
    /// an empty square, which is exactly how the dock shipped once.
    func testEveryDockButtonHasAVisibleSymbol() throws {
        let dock = ViewerToolDockView()
        dock.frame = NSRect(x: 0, y: 0, width: 300, height: 38)
        dock.layoutSubtreeIfNeeded()

        let buttons = dockButtonsForTesting(dock)
        XCTAssertEqual(buttons.count, dock.commands.count + 2,
                       "the tool buttons, the playback button and the pin")

        for button in buttons where !button.isHidden {
            let image = try XCTUnwrap(button.symbolImage,
                                      "every visible dock button needs an icon")
            XCTAssertGreaterThan(image.size.width, 0,
                                 "the icon must have a real size, not just exist")
        }

        // The playback button only appears for animated content, and then it must
        // carry an icon too. It sits after the tool buttons and before the pin.
        dock.setAnimated(true, isPlaying: false)
        let playback = dockButtonsForTesting(dock)[dock.commands.count]
        XCTAssertEqual(playback.isHidden, false)
        XCTAssertNotNil(playback.symbolImage)
    }

    /// Fit width binds the image to the view's width and lets the height overflow.
    func testFitWidthMatchesTheViewWidthAndKeepsTheHorizontalCentre() throws {
        let (controller, viewer) = try makeViewer()
        defer { controller.close() }
        controller.window?.setContentSize(NSSize(width: 400, height: 600))
        loadImage(viewer)
        let canvas = try XCTUnwrap(viewer.chromeViewsForTesting["canvas"] as? ImageCanvasView)

        viewer.perform(.zoomToFitWidth)
        settle()
        let viewport = viewer.viewerState.viewport
        XCTAssertEqual(viewport.zoomScale,
                       canvas.bounds.width / canvas.imagePixelSize.width, accuracy: 0.001,
                       "fit width uses the canvas width")
        XCTAssertEqual(viewport.normalizedCenter.x, 0.5, accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(viewport.zoomScale, viewport.fitScale - 0.001,
                                    "fitting the width of a tall image zooms in further than Fit")

        // The image now fills the width, so that axis cannot pan.
        let visible = viewport.visibleNormalizedRect(imagePixels: canvas.imagePixelSize,
                                                    viewPoints: canvas.bounds.size)
        XCTAssertEqual(visible.width, 1, accuracy: 0.01)
    }

    func testToolDockIsCentredOnTheCanvasWhenRevealed() throws {
        let (controller, viewer) = try makeViewer()
        defer { controller.close() }
        loadImage(viewer)
        let dock = try XCTUnwrap(viewer.chromeViewsForTesting["toolDock"] as? ViewerToolDockView)
        let canvas = try XCTUnwrap(viewer.chromeViewsForTesting["canvas"])

        // The dock auto-hides, so it is brought back the way the user brings it
        // back: by moving the pointer into the strip above the bottom edge.
        revealToolDock(viewer, dock)
        XCTAssertFalse(dock.isHidden, "the dock is on screen over its reveal strip")

        let dockCenter = dock.superview!.convert(CGPoint(x: dock.frame.midX, y: dock.frame.midY),
                                                to: viewer.view)
        let canvasCenterX = canvas.frame.midX
        XCTAssertEqual(dockCenter.x, canvasCenterX, accuracy: 2,
                       "the dock is centred on the canvas, not on the window")
        XCTAssertLessThan(dockCenter.y, canvas.frame.minY + 60,
                          "the dock sits near the bottom of the image area")
    }

    /// The dock must not move when the pointer enters it. The first version moved
    /// the layer's anchor point at hover time, which shifted every icon.
    func testHoveringTheDockDoesNotMoveAnyButton() throws {
        let dock = ViewerToolDockView()
        dock.frame = NSRect(x: 0, y: 0, width: 300, height: 38)
        dock.layoutSubtreeIfNeeded()
        let buttons = dockButtonsForTesting(dock)
        XCTAssertEqual(buttons.count, dock.commands.count + 2)
        let framesBefore = buttons.map(\.frame)
        let positionsBefore = buttons.map { $0.layer?.position }
        let anchorsBefore = buttons.map { $0.layer?.anchorPoint }

        buttons[2].onHoverChanged?(true)
        let zoomed = try XCTUnwrap(buttons[2].currentScale)
        XCTAssertEqual(zoomed, ViewerToolDockView.hoveredScale, accuracy: 0.001)

        XCTAssertEqual(buttons.map(\.frame), framesBefore,
                       "hovering must not change any button's frame")
        XCTAssertEqual(buttons.map { $0.layer?.position }, positionsBefore,
                       "hovering must not relocate any button's layer")
        XCTAssertEqual(buttons.map { $0.layer?.anchorPoint }, anchorsBefore,
                       "the anchor point must never be touched after layout")

        // The enlargement is centred on the button, not applied from a corner.
        let transform = try XCTUnwrap(buttons[2].layerTransform)
        let bounds = try XCTUnwrap(buttons[2].layer?.bounds)
        let centre = CGPoint(x: bounds.midX, y: bounds.midY)
        let mapped = CGPoint(x: centre.x * transform.m11 + transform.m41,
                             y: centre.y * transform.m22 + transform.m42)
        XCTAssertEqual(mapped.x, centre.x, accuracy: 0.01,
                       "scaling must keep the button's centre in place")
        XCTAssertEqual(mapped.y, centre.y, accuracy: 0.01)

        buttons[2].onHoverChanged?(false)
        XCTAssertEqual(buttons[2].currentScale, 1, accuracy: 0.001)
    }

    func testDockHoverScalesButtonsAndReturnsToBaseline() throws {
        let (controller, viewer) = try makeViewer()
        defer { controller.close() }
        let dock = try XCTUnwrap(viewer.chromeViewsForTesting["toolDock"] as? ViewerToolDockView)
        let buttons = dock.subviews.compactMap { $0 as? NSStackView }
            .flatMap { $0.arrangedSubviews.compactMap { $0 as? DockButton } }
        XCTAssertEqual(buttons.count, dockButtonsForTesting(dock).count)

        XCTAssertEqual(buttons[0].currentScale, 1, accuracy: 0.001)
        buttons[1].onHoverChanged?(true)
        XCTAssertEqual(buttons[1].currentScale, ViewerToolDockView.hoveredScale, accuracy: 0.001)
        XCTAssertEqual(buttons[0].currentScale, ViewerToolDockView.neighbourScale, accuracy: 0.001,
                       "the immediate neighbour lifts slightly, like a Dock")
        XCTAssertEqual(buttons[3].currentScale, 1, accuracy: 0.001,
                       "buttons further away are unaffected")

        buttons[1].onHoverChanged?(false)
        XCTAssertEqual(buttons[1].currentScale, 1, accuracy: 0.001)
        XCTAssertEqual(buttons[0].currentScale, 1, accuracy: 0.001)
    }

    /// The dock is a viewer subview, never a window of its own.
    func testDockAndInfoCardAddNoTopLevelWindows() throws {
        let before = NSApp.windows.count
        let (controller, viewer) = try makeViewer()
        defer { controller.close() }
        loadImage(viewer)
        viewer.setInfoCardVisible(true)
        settle()
        XCTAssertEqual(NSApp.windows.count, before + 1,
                       "only the viewer window itself is added")
        XCTAssertTrue(viewer.chromeViewsForTesting["toolDock"]!.isDescendant(of: viewer.view))
        XCTAssertTrue(viewer.chromeViewsForTesting["infoCard"]!.isDescendant(of: viewer.view))
    }

    // MARK: - Drawer pin layout

    func testPinnedDrawerReservesCanvasWidth() throws {
        let (controller, viewer) = try makeViewer()
        defer { controller.close() }
        loadImage(viewer)
        let canvas = try XCTUnwrap(viewer.chromeViewsForTesting["canvas"])
        let rootWidth = viewer.view.bounds.width
        let drawerWidth = viewer.currentDrawerWidth

        XCTAssertEqual(canvas.frame.width, rootWidth, accuracy: 1,
                       "unpinned: the canvas owns the whole content area")

        viewer.toggleDrawerForTesting()
        settle(0.5)
        XCTAssertEqual(canvas.frame.width, rootWidth - drawerWidth, accuracy: 1,
                       "pinned: the canvas is the remaining area")
        XCTAssertEqual(canvas.frame.minX, drawerWidth, accuracy: 1)

        viewer.toggleDrawerForTesting()
        settle(0.5)
        XCTAssertEqual(canvas.frame.width, rootWidth, accuracy: 1,
                       "unpinning restores the full width")
    }

    func testDrawerWidthStaysInTheDocumentedRange() throws {
        let (controller, viewer) = try makeViewer()
        defer { controller.close() }
        XCTAssertGreaterThanOrEqual(viewer.currentDrawerWidth, ThumbnailDrawerView.minimumWidth)
        XCTAssertLessThanOrEqual(viewer.currentDrawerWidth, ThumbnailDrawerView.maximumWidth)
    }

    // MARK: - Fit follows the canvas

    /// The whole point of moving to real constraints: fit is measured against
    /// canvas bounds, so nothing has to subtract the sidebar by hand.
    func testFitIsMeasuredAgainstTheCanvasNotTheWindow() throws {
        let (controller, viewer) = try makeViewer()
        defer { controller.close() }
        // A tall, narrow window, so the canvas *width* is what limits the fit and
        // the assertion below is meaningful. The remembered window size from other
        // tests would otherwise make the height the binding constraint.
        controller.window?.setContentSize(NSSize(width: 400, height: 600))
        loadImage(viewer)
        let canvas = try XCTUnwrap(viewer.chromeViewsForTesting["canvas"] as? ImageCanvasView)

        viewer.perform(.zoomToFit)
        settle()
        let unpinnedFit = viewer.viewerState.viewport.fitScale
        XCTAssertEqual(unpinnedFit,
                       ViewportState.fitScale(imagePixels: canvas.imagePixelSize,
                                              viewPoints: canvas.bounds.size),
                       accuracy: 0.0001)
        XCTAssertEqual(unpinnedFit, canvas.bounds.width / canvas.imagePixelSize.width,
                       accuracy: 0.01, "width binds in this geometry")

        viewer.toggleDrawerForTesting()
        settle(0.5)
        let pinnedFit = viewer.viewerState.viewport.fitScale
        XCTAssertEqual(canvas.bounds.width, 400 - viewer.currentDrawerWidth, accuracy: 1)
        XCTAssertEqual(pinnedFit,
                       ViewportState.fitScale(imagePixels: canvas.imagePixelSize,
                                              viewPoints: canvas.bounds.size),
                       accuracy: 0.0001,
                       "fit is re-measured against the narrower canvas")
        XCTAssertEqual(pinnedFit, canvas.bounds.width / canvas.imagePixelSize.width,
                       accuracy: 0.01,
                       "fit uses the canvas width, not the window width minus a hand-written inset")
        XCTAssertLessThan(pinnedFit, unpinnedFit,
                          "the narrower canvas fits the image smaller")
        XCTAssertTrue(viewer.viewerState.viewport.isAtFit,
                      "a viewer sitting at Fit stays at Fit after pinning")
    }

    // MARK: - Panels follow the canvas

    func testDockNavigatorAndInfoFollowTheCanvasWhenPinned() throws {
        let (controller, viewer) = try makeViewer()
        defer { controller.close() }
        // An explicit size, so the assertions do not depend on the window size
        // remembered from earlier runs.
        controller.window?.setContentSize(NSSize(width: 900, height: 600))
        loadImage(viewer)
        let canvas = try XCTUnwrap(viewer.chromeViewsForTesting["canvas"])
        let minimap = try XCTUnwrap(viewer.chromeViewsForTesting["minimap"])
        let infoCard = try XCTUnwrap(viewer.chromeViewsForTesting["infoCard"])
        let dock = try XCTUnwrap(viewer.chromeViewsForTesting["toolDock"])
        let bottomBar = try XCTUnwrap(viewer.chromeViewsForTesting["bottomBar"])

        func checkAnchors(_ label: String) {
            let canvasFrame = canvas.frame
            for (name, view) in [("minimap", minimap), ("infoCard", infoCard),
                                 ("toolDock", dock), ("bottomBar", bottomBar)] {
                XCTAssertGreaterThanOrEqual(view.frame.minX, canvasFrame.minX - 1,
                                            "\(label): \(name) must sit inside the canvas area")
            }
            XCTAssertEqual(minimap.frame.maxX, canvasFrame.maxX - 14, accuracy: 2,
                           "\(label): the minimap hugs the canvas trailing edge")
            XCTAssertEqual(dock.frame.midX, canvasFrame.midX, accuracy: 2,
                           "\(label): the dock stays centred on the canvas")
            XCTAssertEqual(infoCard.frame.minX, canvasFrame.minX + 14, accuracy: 2,
                           "\(label): the info card hugs the canvas leading edge")
        }

        settle()
        checkAnchors("unpinned")
        viewer.toggleDrawerForTesting()
        settle(0.6)
        checkAnchors("pinned")
    }

    /// The dock is wider than a narrow canvas if the window minimum does not account
    /// for it, and then it draws across the sidebar.
    func testToolDockFitsInsideTheCanvasAtTheMinimumWindowSize() throws {
        let (controller, viewer) = try makeViewer()
        defer { controller.close() }
        loadImage(viewer)
        viewer.toggleDrawerForTesting()
        settle(0.6)

        guard let window = controller.window else { return XCTFail("no window") }
        window.setContentSize(window.minSize)
        settle(0.5)

        let dock = try XCTUnwrap(viewer.chromeViewsForTesting["toolDock"])
        let canvas = try XCTUnwrap(viewer.chromeViewsForTesting["canvas"])
        XCTAssertGreaterThanOrEqual(canvas.frame.width, dock.frame.width,
                                    "the canvas must be at least as wide as the dock "
                                      + "(canvas \(canvas.frame.width), dock \(dock.frame.width))")
        XCTAssertGreaterThanOrEqual(dock.frame.minX, canvas.frame.minX - 1,
                                    "the dock must not hang over the sidebar")
        XCTAssertLessThanOrEqual(dock.frame.maxX, canvas.frame.maxX + 1)
    }

    // MARK: - Zoom survives a pin toggle

    func testPinningPreservesAManualZoomAndItsFocalPoint() throws {
        let (controller, viewer) = try makeViewer()
        defer { controller.close() }
        controller.window?.setContentSize(NSSize(width: 400, height: 600))
        loadImage(viewer)
        let canvas = try XCTUnwrap(viewer.chromeViewsForTesting["canvas"] as? ImageCanvasView)

        viewer.perform(.zoomToFit)
        viewer.perform(.zoomDoubleFit)          // a manual zoom, not Fit any more
        var viewport = viewer.viewerState.viewport
        // A focal point that stays inside the clampable range both before and
        // after pinning, so any movement would be a real defect.
        viewport.normalizedCenter = CGPoint(x: 0.62, y: 0.5)
        viewer.canvasViewportForTesting = viewport
        settle()
        let zoomBefore = viewer.viewerState.viewport.zoomScale
        XCTAssertFalse(viewer.viewerState.viewport.isAtFit)
        // The zoomed image must still be wider than the pinned canvas, otherwise
        // the axis legitimately re-centres and the check would be vacuous.
        XCTAssertGreaterThan(canvas.imagePixelSize.width * zoomBefore,
                             canvas.bounds.width - viewer.currentDrawerWidth)

        viewer.toggleDrawerForTesting()
        settle(0.5)
        XCTAssertEqual(viewer.viewerState.viewport.zoomScale, zoomBefore, accuracy: 0.0001,
                       "pinning must not silently reset a manual zoom")
        XCTAssertEqual(viewer.viewerState.viewport.normalizedCenter.x, 0.62, accuracy: 0.02,
                       "the focal point is preserved across the re-layout")
        XCTAssertEqual(viewer.viewerState.viewport.normalizedCenter.y, 0.5, accuracy: 0.02)

        viewer.toggleDrawerForTesting()
        settle(0.5)
        XCTAssertEqual(viewer.viewerState.viewport.zoomScale, zoomBefore, accuracy: 0.0001,
                       "unpinning also keeps the manual zoom")
        XCTAssertEqual(viewer.viewerState.viewport.normalizedCenter.x, 0.62, accuracy: 0.02)
        let visible = viewer.viewerState.viewport.visibleNormalizedRect(
            imagePixels: canvas.imagePixelSize, viewPoints: canvas.bounds.size)
        XCTAssertLessThanOrEqual(visible.maxX, 1.0001, "the viewport stays inside the image")
        XCTAssertGreaterThanOrEqual(visible.minX, -0.0001)
    }

    func testMinimumSizeGrowsSoThePinnedCanvasStaysUsable() throws {
        let (controller, viewer) = try makeViewer()
        defer { controller.close() }
        guard let window = controller.window else { return XCTFail("no window") }
        XCTAssertEqual(window.minSize.width, ViewerWindow.defaultMinimumSize.width, accuracy: 1)

        viewer.toggleDrawerForTesting()
        settle(0.5)
        XCTAssertGreaterThan(window.minSize.width, ViewerWindow.defaultMinimumSize.width,
                             "pinned, the minimum width must still leave room for the image")
        XCTAssertGreaterThanOrEqual(window.minSize.width - viewer.currentDrawerWidth, 320,
                                    "at least 320 pt of canvas remains at the minimum size")

        viewer.toggleDrawerForTesting()
        settle(0.5)
        XCTAssertEqual(window.minSize.width, ViewerWindow.defaultMinimumSize.width, accuracy: 1)
    }
}

/// The in-viewer information card.
@MainActor
final class ImageInfoCardTests: XCTestCase {

    override func setUp() async throws {
        try await super.setUp()
        TestAppKit.ensureApplication()
    }
    private func makeViewer() throws -> (controller: ViewerWindowController, viewer: ViewerViewController) {
        TestAppKit.ensureApplication()
        let controller = ViewerWindowController()
        TestAppKit.presentOffScreen(controller)
        let viewer = controller.viewerViewController
        _ = viewer.view
        viewer.open(url: Fixtures.url("static.png"))
        let deadline = Date().addingTimeInterval(10)
        while viewer.viewerState.currentImage == nil, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        return (controller, viewer)
    }

    func testInfoCardTogglesInTheViewerWithoutCreatingAWindow() throws {
        let (controller, viewer) = try makeViewer()
        defer { controller.close() }
        let card = try XCTUnwrap(viewer.chromeViewsForTesting["infoCard"] as? ImageInfoCardView)
        let windowsBefore = NSApp.windows.count

        viewer.perform(.showImageInfo)
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        XCTAssertFalse(card.isHidden, "the card appears inside the viewer")
        XCTAssertTrue(card.isDescendant(of: viewer.view))
        XCTAssertEqual(NSApp.windows.count, windowsBefore,
                       "showing image info must not open a window")

        viewer.perform(.showImageInfo)
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        XCTAssertTrue(card.isHidden, "clicking the info command again hides the card")
    }

    func testInfoCardSitsAtTheCanvasLowerLeftAndRefreshesWithTheImage() throws {
        let (controller, viewer) = try makeViewer()
        defer { controller.close() }
        let card = try XCTUnwrap(viewer.chromeViewsForTesting["infoCard"] as? ImageInfoCardView)
        let canvas = try XCTUnwrap(viewer.chromeViewsForTesting["canvas"])
        viewer.perform(.showImageInfo)
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))

        XCTAssertEqual(card.frame.minX, canvas.frame.minX + 14, accuracy: 2)
        // Bottom-anchored inside the image area and capped in height, rather than
        // "centred low": on a short canvas the cap legitimately makes it tall.
        XCTAssertGreaterThanOrEqual(card.frame.minY, canvas.frame.minY - 1,
                                    "the card stays inside the image area")
        XCTAssertLessThan(card.frame.minY, canvas.frame.midY,
                          "the card is anchored towards the bottom, not the top")
        XCTAssertLessThanOrEqual(card.frame.maxY, canvas.frame.maxY + 1)
        XCTAssertLessThanOrEqual(card.frame.height,
                                 canvas.frame.height * ImageInfoCardView.maximumHeightFraction + 2,
                                 "the card never takes over the whole image area")
        XCTAssertLessThanOrEqual(card.frame.width, ImageInfoCardView.maximumWidth + 1)
        XCTAssertGreaterThan(card.rowCount, 1)
        XCTAssertEqual(card.shownFile, "static.png")

        // Switching images refreshes the card rather than leaving stale metadata.
        viewer.session.select(url: Fixtures.url("static.bmp"))
        let deadline = Date().addingTimeInterval(10)
        while viewer.viewerState.currentImage == nil, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        XCTAssertEqual(card.shownFile, "static.bmp", "the card follows the current image")
    }

    func testInfoRowsComeFromTheReaderNotFromTheCard() {
        let metadata = ImageMetadata(fileName: "x.jpg", fileSize: 2048,
                                     colorSpace: "Display P3", bitDepth: 8,
                                     fields: ["像素尺寸": "100 × 50", "方向": "6"])
        let descriptor = ImageDescriptor(sourceURL: URL(fileURLWithPath: "/tmp/x.jpg"),
                                         pixelSize: CGSize(width: 100, height: 50))
        let rows = ImageInfoCardView.rows(metadata: metadata, descriptor: descriptor)
        XCTAssertEqual(rows.first?.0, "文件")
        XCTAssertEqual(rows.first?.1, "x.jpg")
        XCTAssertTrue(rows.contains { $0.0 == "EXIF 方向" && $0.1 == "6" },
                      "the stored orientation is reported as stored")
        XCTAssertTrue(rows.contains { $0.0 == "显示尺寸" && $0.1 == "100 × 50" })
    }
}

/// Every button in a dock, in layout order.
@MainActor
func dockButtonsForTesting(_ dock: ViewerToolDockView) -> [DockButton] {
    dock.subviews.compactMap { $0 as? NSStackView }
        .flatMap { $0.arrangedSubviews.compactMap { $0 as? DockButton } }
}

/// Brings the auto-hidden dock back the way the user does: the pointer moves into
/// the invisible strip over the pill, and the show delay is allowed to elapse
/// before visibility is re-evaluated.
@MainActor
func revealToolDock(_ viewer: ViewerViewController, _ dock: ViewerToolDockView) {
    func movePointer(onto point: CGPoint) {
        viewer.simulatePointer(atWindowPoint: viewer.view.convert(point, to: nil))
    }
    let inside = CGPoint(x: dock.frame.midX, y: dock.frame.midY)
    movePointer(onto: inside)
    RunLoop.current.run(until: Date().addingTimeInterval(0.12))
    // A second event, one show delay later, is what flips the model to visible —
    // exactly what a moving pointer does in the app.
    movePointer(onto: CGPoint(x: inside.x + 1, y: inside.y))
    RunLoop.current.run(until: Date().addingTimeInterval(0.25))
}

/// Moves the pointer far away from the dock and waits out the hide delay.
@MainActor
func idleAwayFromToolDock(_ viewer: ViewerViewController) {
    let canvasPoint = CGPoint(x: viewer.view.bounds.midX,
                              y: viewer.view.bounds.midY + 120)
    viewer.simulatePointer(atWindowPoint: viewer.view.convert(canvasPoint, to: nil))
    RunLoop.current.run(until: Date().addingTimeInterval(0.95))
    viewer.simulatePointer(atWindowPoint: viewer.view.convert(
        CGPoint(x: canvasPoint.x + 1, y: canvasPoint.y), to: nil))
    RunLoop.current.run(until: Date().addingTimeInterval(0.25))
}

/// The dock's surface and icon treatment.
@MainActor
final class ToolDockAppearanceTests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        TestAppKit.ensureApplication()
    }

    private func dockButtons(_ dock: ViewerToolDockView) -> [DockButton] {
        dockButtonsForTesting(dock)
    }

    /// The dock is a glass pill on macOS 26+, and a plain system material before
    /// that. Either way it is a system surface, never a hand-drawn blur.
    func testDockUsesNativeGlassWhereTheSystemProvidesIt() {
        let dock = ViewerToolDockView()
        let glassAvailable = ProcessInfo.processInfo.isOperatingSystemAtLeast(
            OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0))
        XCTAssertEqual(dock.usesNativeGlass, glassAvailable,
                       "glass is chosen by an availability guard, matching the running OS")
        XCTAssertTrue(dock.usesNativeGlass || dock.usesSystemMaterial,
                      "the dock must still have a system surface on older systems")
    }

    /// Over a translucent surface the icons must not be baked to one shade: they
    /// are template images carrying a dynamic tint, so they stay legible as the
    /// background and the appearance change.
    func testDockIconsAreTemplateImagesWithADynamicTint() {
        let dock = ViewerToolDockView()
        let buttons = dockButtons(dock)
        XCTAssertEqual(buttons.count, dock.commands.count + 2)

        for button in buttons where !button.isHidden {
            XCTAssertNotNil(button.symbolImage, "every visible dock button has an icon")
            XCTAssertEqual(button.symbolImage?.isTemplate, true,
                           "a non-template icon cannot follow the surface behind it")
            XCTAssertNotNil(button.iconTint, "the icon needs an explicit tint")
        }
    }

    func testIconTintResolvesDifferentlyInLightAndDark() throws {
        let dock = ViewerToolDockView()
        let button = try XCTUnwrap(dockButtons(dock).first)
        let tint = try XCTUnwrap(button.iconTint)

        var dark: NSColor?
        NSAppearance(named: .darkAqua)?.performAsCurrentDrawingAppearance {
            dark = tint.usingColorSpace(.sRGB)
        }
        var light: NSColor?
        NSAppearance(named: .aqua)?.performAsCurrentDrawingAppearance {
            light = tint.usingColorSpace(.sRGB)
        }
        let darkColor = try XCTUnwrap(dark)
        let lightColor = try XCTUnwrap(light)
        XCTAssertNotEqual(darkColor, lightColor,
                          "a dynamic tint must resolve differently per appearance")
        XCTAssertGreaterThan(darkColor.brightnessComponent, lightColor.brightnessComponent,
                             "the icon is light on a dark surface and dark on a light one")
    }

    func testIconTintIsReappliedWhenTheAppearanceChanges() {
        let dock = ViewerToolDockView()
        let button = dockButtons(dock)[0]
        button.contentTintColor = .systemRed      // simulate a stale tint
        button.viewDidChangeEffectiveAppearance()
        XCTAssertEqual(button.iconTint, .labelColor,
                       "an appearance change re-applies the adaptive tint")
    }
}

/// The navigator takes the shape of the image it describes.
@MainActor
final class NavigatorSizingTests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        TestAppKit.ensureApplication()
    }

    private let maximum = NSSize(width: 168, height: 120)

    func testSizeFollowsTheImageAspectInsideTheMaximumBox() {
        let landscape = NavigatorView.size(forImagePixels: CGSize(width: 400, height: 300),
                                           maximum: maximum)
        XCTAssertEqual(landscape.width / landscape.height, 4.0 / 3.0, accuracy: 0.02)
        XCTAssertLessThanOrEqual(landscape.width, maximum.width + 0.001)
        XCTAssertLessThanOrEqual(landscape.height, maximum.height + 0.001)

        let portrait = NavigatorView.size(forImagePixels: CGSize(width: 300, height: 400),
                                          maximum: maximum)
        XCTAssertEqual(portrait.height / portrait.width, 4.0 / 3.0, accuracy: 0.02,
                       "a portrait image gives a portrait navigator")
        // The box is height-limited, so the portrait case shows up as a narrower
        // navigator at the same height.
        XCTAssertLessThan(portrait.width, landscape.width)
        XCTAssertEqual(portrait.height, landscape.height, accuracy: 0.5)
    }

    func testSquareImageGetsTheTallestBoxThatFits() {
        let square = NavigatorView.size(forImagePixels: CGSize(width: 500, height: 500),
                                        maximum: maximum)
        XCTAssertEqual(square.width, square.height, accuracy: 0.01)
        XCTAssertEqual(square.height, maximum.height, accuracy: 0.01,
                       "a square fills the box's height")
    }

    /// A panorama or a very tall image would otherwise collapse the navigator into a
    /// sliver, so the aspect is clamped and the image letterboxes inside.
    func testExtremeAspectsAreClamped() {
        let panorama = NavigatorView.size(forImagePixels: CGSize(width: 8000, height: 500),
                                          maximum: maximum)
        XCTAssertEqual(panorama.width / panorama.height,
                       NavigatorView.maximumAspect, accuracy: 0.02)
        XCTAssertGreaterThanOrEqual(panorama.height, NavigatorView.preferredMinimumShortSide - 0.001,
                                    "a 2:1 clamp still leaves a comfortable short side")

        let skyscraper = NavigatorView.size(forImagePixels: CGSize(width: 400, height: 8000),
                                            maximum: maximum)
        XCTAssertEqual(skyscraper.height / skyscraper.width,
                       1 / NavigatorView.minimumAspect, accuracy: 0.02)
        // The maximum box wins over the preferred short side at this extreme: the
        // navigator gets narrow rather than exceeding its box.
        XCTAssertLessThanOrEqual(skyscraper.height, maximum.height + 0.001)
        XCTAssertLessThanOrEqual(skyscraper.width, maximum.width + 0.001)
        XCTAssertGreaterThan(skyscraper.width, 40, "still wide enough to aim at")
    }

    func testUnknownImageKeepsTheDefaultBox() {
        XCTAssertEqual(NavigatorView.size(forImagePixels: .zero, maximum: maximum), maximum)
    }

    func testNavigatorResizesWithTheImageAndKeepsItsBottomRightCorner() throws {
        let controller = ViewerWindowController()
        defer { controller.close() }
        TestAppKit.presentOffScreen(controller)
        let viewer = controller.viewerViewController
        _ = viewer.view
        controller.window?.setContentSize(NSSize(width: 900, height: 600))

        func load(_ name: String) {
            viewer.open(url: Fixtures.url(name))
            let deadline = Date().addingTimeInterval(10)
            while viewer.viewerState.currentImage == nil, Date() < deadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }

        load("static.png")           // 64x48, landscape
        let navigator = try XCTUnwrap(viewer.chromeViewsForTesting["minimap"] as? NavigatorView)
        let canvas = try XCTUnwrap(viewer.chromeViewsForTesting["canvas"])
        let landscapeFrame = navigator.frame
        XCTAssertEqual(landscapeFrame.width / landscapeFrame.height, 4.0 / 3.0, accuracy: 0.05,
                       "the navigator matches the image aspect")
        XCTAssertEqual(navigator.frame.maxX, canvas.frame.maxX - 14, accuracy: 2,
                       "the trailing edge stays anchored")
        XCTAssertEqual(navigator.frame.minY, canvas.frame.minY + 34, accuracy: 2,
                       "the bottom edge stays anchored")

        // A multi-page document opens on its first page (40x30), and the navigator
        // follows whatever is actually displayed.
        load("oriented-6.jpg")       // 40x20 stored, displayed 20x40 after EXIF
        let portraitFrame = navigator.frame
        XCTAssertLessThan(portraitFrame.width, landscapeFrame.width,
                          "a portrait image gives a narrower navigator")
        XCTAssertEqual(portraitFrame.width / portraitFrame.height, 0.5, accuracy: 0.05,
                       "and its shape matches the displayed image")
        XCTAssertEqual(navigator.frame.maxX, canvas.frame.maxX - 14, accuracy: 2)
        XCTAssertEqual(navigator.frame.minY, canvas.frame.minY + 34, accuracy: 2)
    }
}


/// The drawer is opened and closed from the titlebar, beside the traffic lights.
@MainActor
final class DrawerTitlebarButtonTests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        TestAppKit.ensureApplication()
    }

    private func makeViewer() throws -> (controller: ViewerWindowController, viewer: ViewerViewController) {
        TestAppKit.ensureApplication()
        let controller = ViewerWindowController()
        TestAppKit.presentOffScreen(controller)
        let viewer = controller.viewerViewController
        _ = viewer.view
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        return (controller, viewer)
    }

    /// The first version put the button inside a container view with no intrinsic
    /// size: the titlebar laid that container out zero-width and clipped the button
    /// away, so it existed but could not be seen.
    ///
    /// It now also leaves with the titlebar — a hidden bar must not leave a lone control
    /// floating over the image, so the accessory is taken out of the titlebar entirely —
    /// so the size check is made with the bar revealed, which is the state in which the
    /// button is meant to be clickable.
    func testTitlebarDrawerButtonHasARealOnScreenSize() throws {
        let (controller, viewer) = try makeViewer()
        defer { controller.close() }
        controller.window?.layoutIfNeeded()
        let button = try XCTUnwrap(controller.drawerTitlebarButton)
        XCTAssertTrue(controller.window?.titlebarAccessoryViewControllers.isEmpty ?? false,
                      "with the bar away the accessory is not in the titlebar at all")

        // Reveal the bar, which is where the button is meant to be used.
        let zones = viewer.titlebarRevealZones
        viewer.simulatePointer(atWindowPoint: viewer.view.convert(
            CGPoint(x: zones.b.midX, y: zones.b.midY), to: nil))
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        controller.window?.layoutIfNeeded()

        let accessory = try XCTUnwrap(controller.window?.titlebarAccessoryViewControllers.first,
                                      "the revealed bar carries the drawer accessory")
        let accessoryView = accessory.view
        XCTAssertGreaterThan(accessoryView.frame.width, 0,
                             "a zero-width accessory is invisible in the titlebar")
        XCTAssertGreaterThan(accessoryView.frame.height, 0)
        XCTAssertFalse(accessoryView.isHidden)
        XCTAssertFalse(accessory.isHidden)
        // Everything the user needs to click is inside that frame.
        let buttonInWindow = button.convert(button.bounds, to: nil)
        let accessoryInWindow = accessoryView.convert(accessoryView.bounds, to: nil)
        XCTAssertGreaterThan(buttonInWindow.width, 0)
        XCTAssertTrue(buttonInWindow.width <= accessoryInWindow.width + 1
                      && buttonInWindow.height <= accessoryInWindow.height + 1,
                      "the button must fit inside the accessory's on-screen frame "
                        + "(button \(buttonInWindow.size), accessory \(accessoryInWindow.size))")
        _ = viewer
    }

    func testTitlebarCarriesADrawerButton() throws {
        let (controller, viewer) = try makeViewer()
        defer { controller.close() }
        let button = try XCTUnwrap(controller.drawerTitlebarButton,
                                   "the titlebar needs the drawer control")
        // Reveal the bar: that is when the accessory is in the titlebar (it is taken out while
        // the bar is away, so nothing can float over the content).
        let zones = viewer.titlebarRevealZones
        viewer.simulatePointer(atWindowPoint: viewer.view.convert(
            CGPoint(x: zones.b.midX, y: zones.b.midY), to: nil))
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))

        XCTAssertFalse(button.isDescendant(of: controller.window!.contentView!),
                       "the button lives in a titlebar accessory, not in the content area")
        XCTAssertEqual(controller.window?.titlebarAccessoryViewControllers.count, 1)
        XCTAssertEqual(controller.window?.titlebarAccessoryViewControllers.first?.layoutAttribute,
                       .leading, "it sits next to the traffic lights")
        XCTAssertNotNil(button.image)
        XCTAssertEqual(button.toolTip, "打开左栏")
        _ = viewer
    }

    func testTitlebarButtonOpensAndClosesTheDrawer() throws {
        let (controller, viewer) = try makeViewer()
        defer { controller.close() }
        let button = try XCTUnwrap(controller.drawerTitlebarButton)

        XCTAssertFalse(viewer.chromeSnapshot.drawer, "the drawer starts closed")
        button.performClick(nil)
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        XCTAssertTrue(viewer.isDrawerOpen, "clicking opens the drawer and holds it")
        XCTAssertTrue(viewer.chromeSnapshot.drawer)
        XCTAssertEqual(button.toolTip, "关闭左栏")
        XCTAssertEqual(button.contentTintColor, .controlAccentColor)

        button.performClick(nil)
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        XCTAssertFalse(viewer.isDrawerOpen, "clicking again closes it")
        XCTAssertEqual(button.toolTip, "打开左栏")
    }

    /// The drawer no longer carries a pin control of its own.
    func testDrawerHasNoPinControlOfItsOwn() throws {
        let drawer = ThumbnailDrawerView(style: .drawer)
        drawer.frame = NSRect(x: 0, y: 0, width: 200, height: 400)
        func buttons(in view: NSView) -> [NSButton] {
            var found = view.subviews.compactMap { $0 as? NSButton }
            for subview in view.subviews { found.append(contentsOf: buttons(in: subview)) }
            return found
        }
        XCTAssertTrue(buttons(in: drawer).isEmpty,
                      "the open/close control moved to the titlebar")
    }

    func testCommandAndTitlebarButtonAgree() throws {
        let (controller, viewer) = try makeViewer()
        defer { controller.close() }
        viewer.perform(.toggleThumbnailDrawer)
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        XCTAssertTrue(viewer.isDrawerOpen)
        XCTAssertEqual(controller.drawerTitlebarButton?.toolTip, "关闭左栏")
        viewer.perform(.toggleThumbnailDrawer)
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        XCTAssertFalse(viewer.isDrawerOpen)
    }
}

/// While zoomed, one swipe at the edge arms the switch and the next performs it.
final class ArmedSwitchTests: XCTestCase {
    func testOneSwipeAtTheEdgeOnlyArmsWhileZoomed() {
        var router = GestureRouter(swipeMode: .smart, switchThreshold: 0.1)
        router.beginGesture()
        var results: [GestureIntent] = []
        for _ in 0..<20 { results.append(router.routeSwipe(deltaX: -40, deltaY: 0, viewWidth: 900,
                                                          isZoomedIn: true, canPanInDirection: false)) }
        XCTAssertFalse(results.contains(.nextImage), "the first swipe must not switch")
        XCTAssertTrue(router.zoomedSwitchArmed, "it arms instead")

        // A second gesture carries it out.
        router.beginGesture()
        XCTAssertEqual(router.routeSwipe(deltaX: -40, deltaY: 0, viewWidth: 900,
                                         isZoomedIn: true, canPanInDirection: false),
                       .nextImage)
        XCTAssertFalse(router.zoomedSwitchArmed, "the arming is used up")
    }

    func testArmingSurvivesBetweenGesturesButNotPanningAway() {
        var router = GestureRouter(swipeMode: .smart, switchThreshold: 0.1)
        router.beginGesture()
        for _ in 0..<20 { _ = router.routeSwipe(deltaX: -40, deltaY: 0, viewWidth: 900,
                                                isZoomedIn: true, canPanInDirection: false) }
        XCTAssertTrue(router.zoomedSwitchArmed)
        router.endGesture()
        XCTAssertTrue(router.zoomedSwitchArmed, "the second swipe is a separate gesture")

        // Panning away from the edge means the user is looking around again.
        _ = router.routeSwipe(deltaX: 40, deltaY: 0, viewWidth: 900,
                              isZoomedIn: true, canPanInDirection: true)
        XCTAssertFalse(router.zoomedSwitchArmed)
    }

    func testAtFitASingleSwipeStillSwitches() {
        var router = GestureRouter(swipeMode: .smart, switchThreshold: 0.1)
        router.beginGesture()
        var result: GestureIntent = .none
        for _ in 0..<20 where result == .none {
            result = router.routeSwipe(deltaX: -40, deltaY: 0, viewWidth: 900,
                                       isZoomedIn: false, canPanInDirection: false)
        }
        XCTAssertEqual(result, .nextImage, "the two-step rule applies only while zoomed")
    }

    func testArmingCanBeCleared() {
        var router = GestureRouter(swipeMode: .smart, switchThreshold: 0.1)
        router.beginGesture()
        for _ in 0..<20 { _ = router.routeSwipe(deltaX: -40, deltaY: 0, viewWidth: 900,
                                                isZoomedIn: true, canPanInDirection: false) }
        XCTAssertTrue(router.zoomedSwitchArmed)
        router.disarmZoomedSwitch()
        XCTAssertFalse(router.zoomedSwitchArmed)

        // The same swipe still cannot switch after a disarm.
        router.beginGesture()
        for _ in 0..<3 { _ = router.routeSwipe(deltaX: -40, deltaY: 0, viewWidth: 900,
                                               isZoomedIn: true, canPanInDirection: false) }
        XCTAssertTrue(router.zoomedSwitchArmed, "it arms again rather than switching")
    }

    /// Continuing the *same* swipe must not redeem the arming, however far it goes.
    func testOneLongSwipeArmsButDoesNotSwitch() {
        var router = GestureRouter(swipeMode: .smart, switchThreshold: 0.1)
        router.beginGesture()
        for _ in 0..<80 {
            XCTAssertEqual(router.routeSwipe(deltaX: -60, deltaY: 0, viewWidth: 900,
                                             isZoomedIn: true, canPanInDirection: false),
                           .none,
                           "one swipe only arms, no matter how far it travels")
        }
        XCTAssertTrue(router.zoomedSwitchArmed)
    }
}
