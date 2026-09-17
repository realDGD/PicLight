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

    func testViewerUsesTheStandardVisibleTitlebar() throws {
        let (controller, _) = try makeViewer()
        defer { controller.close() }
        guard let window = controller.window else { return XCTFail("no window") }

        XCTAssertTrue(window.styleMask.contains(.titled))
        XCTAssertFalse(window.styleMask.contains(.fullSizeContentView),
                       "content must start below the titlebar")
        XCTAssertEqual(window.titleVisibility, .visible)
        XCTAssertFalse(window.titlebarAppearsTransparent)
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            XCTAssertNotNil(window.standardWindowButton(button))
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
                       "there is no viewer-owned top bar any more")
        // The viewer's own chrome never reaches into the titlebar band: the content
        // view starts below it.
        guard let content = controller.window?.contentView else { return XCTFail("no content") }
        let titlebarHeight = controller.window!.frame.height - content.frame.height
        XCTAssertGreaterThan(titlebarHeight, 0, "the standard titlebar occupies real space")
    }

    // MARK: - Tool dock

    func testToolDockExposesTheViewerCommands() throws {
        let (controller, viewer) = try makeViewer()
        defer { controller.close() }
        let dock = try XCTUnwrap(viewer.chromeViewsForTesting["toolDock"] as? ViewerToolDockView)
        XCTAssertEqual(dock.commands,
                       [.rotateClockwise, .toggleMirror, .zoomToFit, .zoomActualPixels,
                        .moveToTrash, .showImageInfo])
    }

    /// Presence and enabled state are not enough: a button with no icon renders as
    /// an empty square, which is exactly how the dock shipped once.
    func testEveryDockButtonHasAVisibleSymbol() throws {
        let dock = ViewerToolDockView()
        dock.frame = NSRect(x: 0, y: 0, width: 300, height: 38)
        dock.layoutSubtreeIfNeeded()

        let buttons = dock.subviews.compactMap { $0 as? NSStackView }
            .flatMap { $0.arrangedSubviews.compactMap { $0 as? DockButton } }
        XCTAssertEqual(buttons.count, 7)

        for button in buttons where !button.isHidden {
            let image = try XCTUnwrap(button.symbolImage,
                                      "every visible dock button needs an icon")
            XCTAssertGreaterThan(image.size.width, 0,
                                 "the icon must have a real size, not just exist")
        }

        // The playback button only appears for animated content, and then it must
        // carry an icon too.
        dock.setAnimated(true, isPlaying: false)
        XCTAssertFalse(dock.subviews.compactMap { $0 as? NSStackView }
            .flatMap { $0.arrangedSubviews.compactMap { $0 as? DockButton } }
            .last!.isHidden)
        XCTAssertNotNil(dock.subviews.compactMap { $0 as? NSStackView }
            .flatMap { $0.arrangedSubviews.compactMap { $0 as? DockButton } }.last?.symbolImage)
    }

    func testToolDockIsFixedChromeCentredOnTheCanvas() throws {
        let (controller, viewer) = try makeViewer()
        defer { controller.close() }
        loadImage(viewer)
        let dock = try XCTUnwrap(viewer.chromeViewsForTesting["toolDock"] as? ViewerToolDockView)
        let canvas = try XCTUnwrap(viewer.chromeViewsForTesting["canvas"])

        XCTAssertFalse(dock.isHidden, "the dock is fixed chrome once an image is shown")
        settle()
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
        let buttons = dock.subviews.compactMap { $0 as? NSStackView }
            .flatMap { $0.arrangedSubviews.compactMap { $0 as? DockButton } }
        XCTAssertEqual(buttons.count, 7)

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
        XCTAssertEqual(buttons.count, 7, "six tools plus the playback button")

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

        viewer.toggleDrawerPinForTesting()
        settle(0.5)
        XCTAssertEqual(canvas.frame.width, rootWidth - drawerWidth, accuracy: 1,
                       "pinned: the canvas is the remaining area")
        XCTAssertEqual(canvas.frame.minX, drawerWidth, accuracy: 1)

        viewer.toggleDrawerPinForTesting()
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

        viewer.toggleDrawerPinForTesting()
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
        viewer.toggleDrawerPinForTesting()
        settle(0.6)
        checkAnchors("pinned")
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

        viewer.toggleDrawerPinForTesting()
        settle(0.5)
        XCTAssertEqual(viewer.viewerState.viewport.zoomScale, zoomBefore, accuracy: 0.0001,
                       "pinning must not silently reset a manual zoom")
        XCTAssertEqual(viewer.viewerState.viewport.normalizedCenter.x, 0.62, accuracy: 0.02,
                       "the focal point is preserved across the re-layout")
        XCTAssertEqual(viewer.viewerState.viewport.normalizedCenter.y, 0.5, accuracy: 0.02)

        viewer.toggleDrawerPinForTesting()
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

        viewer.toggleDrawerPinForTesting()
        settle(0.5)
        XCTAssertGreaterThan(window.minSize.width, ViewerWindow.defaultMinimumSize.width,
                             "pinned, the minimum width must still leave room for the image")
        XCTAssertGreaterThanOrEqual(window.minSize.width - viewer.currentDrawerWidth, 320,
                                    "at least 320 pt of canvas remains at the minimum size")

        viewer.toggleDrawerPinForTesting()
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

/// The dock's surface and icon treatment.
@MainActor
final class ToolDockAppearanceTests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        TestAppKit.ensureApplication()
    }

    private func dockButtons(_ dock: ViewerToolDockView) -> [DockButton] {
        dock.subviews.compactMap { $0 as? NSStackView }
            .flatMap { $0.arrangedSubviews.compactMap { $0 as? DockButton } }
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
        XCTAssertEqual(buttons.count, 7)

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
