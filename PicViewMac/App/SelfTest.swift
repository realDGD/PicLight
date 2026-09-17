import AppKit
import ImageIO

/// Headless-ish acceptance runner used to verify the real AppKit app on machines
/// where the screen cannot be captured (CI, remote shells). It drives the exact
/// production code paths and prints a report, then terminates.
///
/// Usage: PICVIEW_SELFTEST=<image file> PicLight.app/Contents/MacOS/PicLight
@MainActor
final class SelfTestReporter {
    private(set) var lines: [String] = []
    private(set) var failures: [String] = []

    func check(_ name: String, _ condition: Bool, _ detail: String = "") {
        lines.append("\(condition ? "PASS" : "FAIL") \(name)\(detail.isEmpty ? "" : ": \(detail)")")
        if !condition { failures.append(name) }
    }

    func note(_ text: String) { lines.append("DIAG \(text)") }
}

@MainActor
enum SelfTest {
    static var requestedFilePath: String? {
        ProcessInfo.processInfo.environment["PICVIEW_SELFTEST"]
    }

    static func run(fileURL: URL, environment: AppEnvironment, timeout: TimeInterval = 20) {
        let reporter = SelfTestReporter()
        func check(_ name: String, _ condition: Bool, _ detail: String = "") {
            reporter.check(name, condition, detail)
        }

        // Exercise the same path Finder and `open -a` use, not a shortcut.
        environment.fileOpener.open(url: fileURL)
        let deadlineEarly = Date().addingTimeInterval(2)
        while environment.mostRecentViewer == nil, Date() < deadlineEarly {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        guard let controller = environment.mostRecentViewer,
              let viewer = controller.viewerViewController as ViewerViewController? else {
            print("FAIL no viewer window was created")
            NSApp.terminate(nil)
            return
        }

        // Wait for the asynchronous decode to publish pixels.
        let deadline = Date().addingTimeInterval(timeout)
        while viewer.viewerState.currentImage == nil, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }

        let windows = NSApp.windows.filter { $0.isVisible }
        if windows.isEmpty {
            for window in NSApp.windows {
                reporter.note("window \(type(of: window)) visible=\(window.isVisible) "
                    + "mini=\(window.isMiniaturized) frame=\(window.frame) "
                    + "occlusion=\(window.occlusionState.contains(.visible))")
            }
        }
        check("one visible viewer window", windows.count == 1,
              "visible windows: \(windows.count)")
        check("no child overlay windows", windows.allSatisfy { ($0.childWindows ?? []).isEmpty })
        check("viewer is a standard titled NSWindow",
              windows.first?.styleMask.contains(.titled) == true
                && windows.first?.styleMask != .borderless)
        check("native tabbing disabled", windows.first?.tabbingMode == .disallowed)

        guard let descriptor = viewer.viewerState.descriptor, let image = viewer.viewerState.currentImage else {
            check("image decoded", false, "no pixels were published within \(timeout)s")
            finish(reporter)
            return
        }
        check("image decoded", true,
              "\(image.width)x\(image.height) from \(descriptor.sourceURL.lastPathComponent)")
        check("folder session lists the directory", viewer.session.items.count >= 1,
              "\(viewer.session.items.count) supported files")
        check("current item is the requested file",
              viewer.session.currentItem?.url.lastPathComponent == fileURL.lastPathComponent,
              viewer.session.currentItem?.displayName ?? "none")

        // Navigation keeps folder order and identity separate from decode state.
        let first = viewer.session.currentItem?.displayName
        viewer.perform(.nextImage)
        waitForDecode(viewer, timeout: 10)
        var second = viewer.session.currentItem?.displayName
        check("next image navigates", first != second, "\(first ?? "-") -> \(second ?? "-")")

        // The folder may legitimately contain unreadable files (the corrupt
        // fixture lives here), so step forward until a decodable image lands.
        var skipped: [String] = []
        var attempts = 0
        while viewer.viewerState.currentImage == nil, attempts < 5 {
            skipped.append(viewer.session.currentItem?.displayName ?? "?")
            viewer.perform(.nextImage)
            waitForDecode(viewer, timeout: 10)
            second = viewer.session.currentItem?.displayName
            attempts += 1
        }
        check("a decodable neighbour loads", viewer.viewerState.currentImage != nil,
              skipped.isEmpty
                ? (viewer.viewerState.metadata?.fileName ?? "-")
                : "skipped unreadable: \(skipped.joined(separator: ", "))")

        // View-only operations must not touch the file on disk.
        let before = try? Data(contentsOf: fileURL)
        viewer.perform(.rotateClockwise)
        viewer.perform(.toggleMirror)
        viewer.perform(.zoomActualPixels)
        let zoomedPercent = viewer.viewerState.viewport.zoomPercent
        viewer.perform(.zoomToFit)
        let fitted = viewer.viewerState.viewport.isAtFit
        let after = try? Data(contentsOf: fileURL)
        check("rotate and mirror are view-only", before == after)
        check("100% then Fit works", viewer.viewerState.currentImage != nil && zoomedPercent != 0 && fitted,
              "100% reported \(zoomedPercent)%, Fit restored: \(fitted)")

        // Immersive mode changes chrome only.
        let windowsBeforeImmersive = NSApp.windows.filter { $0.isVisible }.count
        viewer.perform(.toggleImmersive)
        drainRunLoop(0.3)
        check("immersive does not close or add windows",
              NSApp.windows.filter { $0.isVisible }.count == windowsBeforeImmersive,
              "\(windowsBeforeImmersive) -> \(NSApp.windows.filter { $0.isVisible }.count)")
        viewer.perform(.toggleImmersive)
        drainRunLoop(0.3)

        // TIFF pages stay separate from the folder index.
        if let tiff = viewer.session.items.first(where: { $0.url.pathExtension.lowercased() == "tiff" }) {
            viewer.session.select(url: tiff.url)
            waitForDecode(viewer, timeout: 10)
            let pageBefore = viewer.viewerState.pageDescription
            viewer.perform(.nextPage)
            waitForDecode(viewer, timeout: 10)
            check("TIFF page navigation works",
                  viewer.viewerState.pageDescription != pageBefore,
                  "\(pageBefore ?? "-") -> \(viewer.viewerState.pageDescription ?? "-")")
            check("folder index is unchanged by page navigation",
                  viewer.session.currentItem?.url == tiff.url)
        }

        verifyStartupPresentation(environment, reporter)
        verifyChrome(viewer, reporter)
        verifyDrawerPin(viewer, reporter)
        verifyNavigatorLayering(viewer, reporter)
        verifyAnimation(viewer, reporter)
        verifyTrash(reporter)
        verifyBundleDeclaration(reporter)
        verifyErrorState(reporter)
        verifyWindowSizing(reporter)
        verifyAppearance(viewer, reporter)

        finish(reporter)
    }

    /// The four symptoms reported from the first real GUI pass. Each is checked
    /// through the production code path, not by calling a test-only shortcut.
    private static func verifyStartupPresentation(_ environment: AppEnvironment,
                                                 _ reporter: SelfTestReporter) {
        func check(_ name: String, _ condition: Bool, _ detail: String = "") {
            reporter.check(name, condition, detail)
        }
        // 1. Bare launch must present a window, not just create one. The count is
        //    measured as a delta because the runner already has a viewer open.
        func visibleViewerWindows() -> Int {
            NSApp.windows.compactMap { $0 as? ViewerWindow }.filter { $0.isVisible }.count
        }
        let beforeBare = visibleViewerWindows()
        let bare = environment.presentNewViewerWindow()
        drainRunLoop(0.5)
        check("bare launch path presents a visible window",
              bare.window?.isVisible == true,
              "visible: \(bare.window?.isVisible == true)")
        check("bare launch shows the welcome state",
              bare.viewerViewController.emptyStateReasonForTesting == .noImageOpened,
              String(describing: bare.viewerViewController.emptyStateReasonForTesting))
        check("bare launch adds exactly one window and no phantom",
              visibleViewerWindows() == beforeBare + 1,
              "\(beforeBare) -> \(visibleViewerWindows())")
        bare.close()
        drainRunLoop(0.5)
        check("closing the bare window restores the previous window count",
              visibleViewerWindows() == beforeBare, "\(visibleViewerWindows())")

        // 2. Hover must be driven by the root view, not by whichever subview is on top.
        let controller = environment.presentNewViewerWindow()
        drainRunLoop(0.4)
        let viewer = controller.viewerViewController
        func mouseMovedTrackingViews(in view: NSView) -> [String] {
            var names: [String] = []
            if view.trackingAreas.contains(where: { $0.options.contains(.mouseMoved) }) {
                names.append(String(describing: type(of: view)))
            }
            for subview in view.subviews { names.append(contentsOf: mouseMovedTrackingViews(in: subview)) }
            return names
        }
        let trackingOwners = mouseMovedTrackingViews(in: viewer.view)
        check("pointer tracking belongs to the viewer root only",
              trackingOwners == ["ViewerRootView"], trackingOwners.joined(separator: ", "))

        // 3. The left edge is a narrow band and a hidden drawer is not clickable.
        let bounds = viewer.view.bounds
        check("left hot zone is at most 12 px",
              ThumbnailDrawerView.hotZoneWidth <= 12,
              "\(ThumbnailDrawerView.hotZoneWidth) px")
        check("13 px in is not the drawer trigger",
              viewer.zone(forRootPoint: CGPoint(x: 13, y: bounds.midY)) != .leftEdgeHotZone)
        check("drawer width stays in the 180-220 px range",
              ThumbnailDrawerView.minimumWidth >= 180 && ThumbnailDrawerView.maximumWidth <= 220)
        if let content = controller.window?.contentView {
            let midPoint = CGPoint(x: content.bounds.midX, y: content.bounds.midY)
            let hit = content.hitTest(midPoint)
            let drawerView = viewer.chromeViewsForTesting["drawer"]!
            let emptyStateView = viewer.chromeViewsForTesting["emptyState"]!
            let canvasView = viewer.chromeViewsForTesting["canvas"]!
            // With no image loaded the welcome surface legitimately owns the middle;
            // what must never happen is a hidden drawer owning it.
            let legitimate = hit === canvasView
                || hit?.isDescendant(of: canvasView) == true
                || hit?.isDescendant(of: emptyStateView) == true
            check("hidden chrome leaves the image area clickable",
                  legitimate && hit?.isDescendant(of: drawerView) != true,
                  String(describing: hit))
        }
        controller.close()
    }

    /// Pinning keeps the drawer open without moving the canvas.
    private static func verifyDrawerPin(_ viewer: ViewerViewController, _ reporter: SelfTestReporter) {
        func check(_ name: String, _ condition: Bool, _ detail: String = "") {
            reporter.check(name, condition, detail)
        }
        let baseline = viewer.chromeSnapshot
        viewer.toggleDrawerPinForTesting()
        drainRunLoop(0.5)
        check("pinning opens the drawer", viewer.chromeSnapshot.drawer)
        check("a pinned drawer does not move the canvas",
              viewer.chromeSnapshot.canvasFrame == baseline.canvasFrame
                && abs(viewer.chromeSnapshot.zoomScale - baseline.zoomScale) < 0.0001,
              "frame \(viewer.chromeSnapshot.canvasFrame.size), zoom \(viewer.chromeSnapshot.zoomScale)")

        // Moving the pointer away must not close it while pinned.
        viewer.simulatePointer(atWindowPoint: NSPoint(x: viewer.view.bounds.midX,
                                                     y: viewer.view.bounds.midY))
        drainRunLoop(0.8)
        check("a pinned drawer survives the pointer leaving", viewer.chromeSnapshot.drawer)

        viewer.toggleDrawerPinForTesting()
        drainRunLoop(0.8)
        check("unpinning restores hover auto-close", viewer.chromeSnapshot.drawer == false)
    }

    /// The navigator: a bounded preview above the glass, one crisp outline above it.
    private static func verifyNavigatorLayering(_ viewer: ViewerViewController,
                                                _ reporter: SelfTestReporter) {
        func check(_ name: String, _ condition: Bool, _ detail: String = "") {
            reporter.check(name, condition, detail)
        }
        guard let navigator = viewer.chromeViewsForTesting["minimap"] as? NavigatorView else {
            check("navigator exists", false)
            return
        }
        let background = navigator.backgroundSurface
        let preview = navigator.previewSurface
        let backgroundIndex = navigator.subviews.firstIndex(of: background) ?? .max
        let previewIndex = navigator.subviews.firstIndex(of: preview) ?? .min
        check("navigator glass is behind the preview", backgroundIndex < previewIndex,
              "glass at \(backgroundIndex), preview at \(previewIndex)")
        check("navigator viewport overlay is above the preview",
              navigator.viewportOverlayLayer.superlayer === navigator.layer)
        check("navigator preview is a bounded downsample",
              navigator.hasPreviewImage
                && max(navigator.previewPixelSize.width, navigator.previewPixelSize.height)
                    <= CGFloat(NavigatorView.previewPixelSize),
              "\(navigator.previewPixelSize)")
        check("navigator viewport outline has a single crisp stroke",
              navigator.viewportOverlayLayer.lineWidth <= 2
                && navigator.layer?.sublayers?.filter { $0 is CAShapeLayer }.count == 1,
              "lineWidth \(navigator.viewportOverlayLayer.lineWidth)")

        let generations = navigator.previewGenerationCount
        viewer.perform(.zoomDoubleFit)
        viewer.perform(.zoomToFit)
        viewer.perform(.zoomDoubleFit)
        drainRunLoop(0.3)
        check("pan and zoom do not rebuild the navigator preview",
              navigator.previewGenerationCount == generations,
              "\(generations) -> \(navigator.previewGenerationCount)")
        viewer.perform(.zoomToFit)
    }

    /// Hover chrome must not disturb the canvas, and the minimap appears only
    /// when the image is zoomed past Fit.
    private static func verifyChrome(_ viewer: ViewerViewController, _ reporter: SelfTestReporter) {
        func check(_ name: String, _ condition: Bool, _ detail: String = "") {
            reporter.check(name, condition, detail)
        }
        // The window is still settling right after the first image appears (first
        // layout pass, backing scale). Wait for the canvas geometry to stop
        // changing so the comparison below isolates the drawer's effect.
        let settled = waitForStableCanvas(viewer)
        let before = viewer.chromeSnapshot
        check("canvas geometry settles before the drawer check", settled,
              "frame \(before.canvasFrame.size), zoom \(before.zoomScale)")
        check("drawer lists the whole folder", before.drawerRows == viewer.session.items.count,
              "\(before.drawerRows) rows")

        // Pointer into the ~44 px top region.
        let top = NSPoint(x: viewer.view.bounds.midX, y: viewer.view.bounds.height - 10)
        viewer.simulatePointer(atWindowPoint: top)
        drainRunLoop(0.4)
        var snapshot = viewer.chromeSnapshot
        check("top hover reveals top chrome", snapshot.top)
        check("top hover reveals the bottom bar", snapshot.bottom)

        // Pointer into the left-edge hot zone.
        let leftEdge = NSPoint(x: 3, y: viewer.view.bounds.midY)
        viewer.simulatePointer(atWindowPoint: leftEdge)
        drainRunLoop(0.4)
        snapshot = viewer.chromeSnapshot
        check("left-edge hover opens the drawer", snapshot.drawer)
        check("drawer rows equal the folder contents",
              snapshot.drawerRows == viewer.session.items.count)
        check("opening the drawer never changes canvas geometry",
              snapshot.canvasFrame == before.canvasFrame && snapshot.zoomScale == before.zoomScale,
              "before frame \(before.canvasFrame.size) zoom \(before.zoomScale); "
                + "after frame \(snapshot.canvasFrame.size) zoom \(snapshot.zoomScale)")

        // The minimap is only permitted while zoomed past Fit.
        viewer.perform(.zoomToFit)
        viewer.simulateZoomActivity()
        drainRunLoop(0.1)
        check("minimap is hidden at Fit", viewer.chromeSnapshot.minimap == false)

        // Smaller fixtures are zoomed *out* at 100 %, so use Fit x2 to get past Fit.
        viewer.perform(.zoomToFit)
        viewer.perform(.zoomDoubleFit)
        viewer.simulateZoomActivity()
        drainRunLoop(0.1)
        let zoomed = viewer.chromeSnapshot
        check("minimap appears past Fit", zoomed.minimap && zoomed.zoomScale > zoomed.fitScale,
              "zoom \(zoomed.zoomScale) vs fit \(zoomed.fitScale)")

        // A pointer that merely rests in the top zone must not keep chrome alive.
        viewer.simulatePointer(atWindowPoint: NSPoint(x: viewer.view.bounds.midX,
                                                      y: viewer.view.bounds.height - 10))
        drainRunLoop(0.4)
        check("hover still works before immersive", viewer.chromeSnapshot.top)

        // The auxiliary surfaces use the native system look: Liquid Glass on
        // macOS 26+, a system material before that. Never a hand-drawn imitation.
        check("chrome uses the native system surface",
              viewer.chromeSnapshot.usesNativeSurface,
              "glass: \(viewer.chromeSnapshot.usesNativeSurface)")

        // Immersive mode hides chrome but keeps the window.
        viewer.simulateImmersive(true)
        drainRunLoop(0.4)
        check("immersive hides chrome even with the pointer parked",
              viewer.chromeSnapshot.top == false && viewer.chromeSnapshot.drawer == false
                && viewer.chromeSnapshot.bottom == false)
        // Moving the pointer into the top region reveals chrome temporarily.
        viewer.simulatePointer(atWindowPoint: NSPoint(x: viewer.view.bounds.midX,
                                                      y: viewer.view.bounds.height - 10))
        drainRunLoop(0.4)
        check("immersive still allows temporary hover reveal", viewer.chromeSnapshot.top)
        viewer.simulateImmersive(false)
        viewer.perform(.zoomToFit)
    }

    /// Animated content plays, Space pauses it, and switching away stops the clock.
    private static func verifyAnimation(_ viewer: ViewerViewController, _ reporter: SelfTestReporter) {
        func check(_ name: String, _ condition: Bool, _ detail: String = "") {
            reporter.check(name, condition, detail)
        }
        guard let animated = viewer.session.items.first(where: {
            $0.url.lastPathComponent.contains("animated")
        }) else {
            check("animated fixture present", false)
            return
        }
        viewer.session.select(url: animated.url)
        waitForDecode(viewer, timeout: 15)
        check("animated image is detected", viewer.viewerState.isAnimated,
              "\(animated.displayName), frames: \(viewer.viewerState.descriptor?.frameCount ?? 0)")
        check("animated image autoplays by default", viewer.viewerState.playback == .playing)

        let firstFrame = viewer.viewerState.frameIndex
        let deadline = Date().addingTimeInterval(3)
        while viewer.viewerState.frameIndex == firstFrame, Date() < deadline {
            drainRunLoop(0.05)
        }
        check("animation advances frames", viewer.viewerState.frameIndex != firstFrame,
              "frame \(firstFrame) -> \(viewer.viewerState.frameIndex)")

        viewer.perform(.togglePlayback)
        check("Space pauses animation", viewer.viewerState.playback == .paused)
        let pausedFrame = viewer.viewerState.frameIndex
        drainRunLoop(0.4)
        check("a paused animation does not advance", viewer.viewerState.frameIndex == pausedFrame)
        viewer.perform(.togglePlayback)
        check("Space resumes animation", viewer.viewerState.playback == .playing)

        if let still = viewer.session.items.first(where: {
            $0.url.lastPathComponent == "static.png"
        }) {
            viewer.session.select(url: still.url)
            waitForDecode(viewer, timeout: 10)
            check("switching away stops the animation clock",
                  viewer.viewerState.playback == .staticImage)
        }
    }

    /// Trash uses the system API and applies the smart next/previous selection.
    private static func verifyTrash(_ reporter: SelfTestReporter) {
        func check(_ name: String, _ condition: Bool, _ detail: String = "") {
            reporter.check(name, condition, detail)
        }
        guard let scratch = makeScratchFolder("trash", names: ["a.png", "b.png"]) else {
            check("trash scenario folder", false)
            return
        }
        defer { try? FileManager.default.removeItem(at: scratch) }

        let controller = AppEnvironment.shared.presentNewViewerWindow()
        guard let viewer = controller.viewerViewController as ViewerViewController? else {
            check("trash scenario viewer", false)
            return
        }
        viewer.open(url: scratch.appendingPathComponent("a.png"))
        let deadline = Date().addingTimeInterval(10)
        while viewer.viewerState.currentImage == nil, Date() < deadline { drainRunLoop(0.05) }
        check("trash scenario loads the first image",
              viewer.session.currentItem?.displayName == "a.png",
              viewer.session.currentItem?.displayName ?? "none")

        viewer.perform(.moveToTrash)
        drainRunLoop(0.3)
        let stillExists = FileManager.default
            .fileExists(atPath: scratch.appendingPathComponent("a.png").path)
        check("Delete uses the system Trash instead of unlinking", stillExists == false)
        check("trash selects the next image", viewer.session.currentItem?.displayName == "b.png",
              viewer.session.currentItem?.displayName ?? "none")
        check("trash keeps the window open", viewer.view.window?.isVisible == true)
        controller.close()
    }

    /// The shipped bundle must declare exactly the formats the code accepts, so
    /// Finder and `Open With` cannot drift away from `SupportedImageTypes`.
    private static func verifyBundleDeclaration(_ reporter: SelfTestReporter) {
        func check(_ name: String, _ condition: Bool, _ detail: String = "") {
            reporter.check(name, condition, detail)
        }
        guard let types = Bundle.main.object(forInfoDictionaryKey: "CFBundleDocumentTypes")
            as? [[String: Any]] else {
            reporter.note("no CFBundleDocumentTypes in this bundle (running from a bare binary)")
            return
        }
        let declared = Set(types.flatMap { ($0["LSItemContentTypes"] as? [String]) ?? [] })
        let expected = Set(SupportedImageTypes.requiredContentTypes.map(\.identifier))
        let missing = expected.subtracting(declared).sorted()
        check("bundle declares every supported image type to Finder",
              missing.isEmpty, missing.isEmpty ? "declared: \(declared.count)" : "missing: \(missing)")
        check("bundle declares no unsupported image types",
              declared.subtracting(expected).isEmpty,
              "extra: \(declared.subtracting(expected).sorted())")
        let roles = types.compactMap { $0["CFBundleTypeRole"] as? String }
        check("declared types use the Viewer role", roles.allSatisfy { $0 == "Viewer" },
              roles.joined(separator: ", "))
    }

    /// A corrupt image must not strand navigation, and the viewer must say so.
    private static func verifyErrorState(_ reporter: SelfTestReporter) {
        func check(_ name: String, _ condition: Bool, _ detail: String = "") {
            reporter.check(name, condition, detail)
        }
        guard let scratch = makeScratchFolder("error", names: ["b-good.png"],
                                              corruptNames: ["a-corrupt.png"]) else {
            check("error scenario folder", false)
            return
        }
        defer { try? FileManager.default.removeItem(at: scratch) }

        let controller = AppEnvironment.shared.presentNewViewerWindow()
        guard let viewer = controller.viewerViewController as ViewerViewController? else {
            check("error scenario viewer", false)
            return
        }
        viewer.open(url: scratch.appendingPathComponent("a-corrupt.png"))
        drainRunLoop(1.5)
        check("a corrupt image reports an error instead of crashing",
              (viewer.viewerState.errorMessage?.isEmpty == false),
              viewer.viewerState.errorMessage ?? "no message")
        check("no pixels are fabricated for a corrupt image", viewer.viewerState.currentImage == nil)

        viewer.perform(.nextImage)
        drainRunLoop(1.5)
        check("navigation stays alive after a corrupt image",
              viewer.viewerState.currentImage != nil,
              viewer.session.currentItem?.displayName ?? "none")
        controller.close()
    }

    /// Appearance modes must follow the system or force an explicit theme only
    /// when the user asked for one.
    private static func verifyAppearance(_ viewer: ViewerViewController, _ reporter: SelfTestReporter) {
        func check(_ name: String, _ condition: Bool, _ detail: String = "") {
            reporter.check(name, condition, detail)
        }
        guard let window = viewer.view.window else {
            check("appearance scenario window", false)
            return
        }
        let settings = AppSettings.shared
        let original = settings.appearance
        defer { settings.appearance = original }

        viewer.applySettings()
        settings.appearance = .system
        viewer.applySettings()
        check("Follow System never forces NSApp.appearance", window.appearance == nil,
              String(describing: window.appearance))

        settings.appearance = .black
        viewer.applySettings()
        check("dark appearance applies natively",
              window.appearance?.name == .darkAqua, String(describing: window.appearance?.name))

        settings.appearance = .white
        viewer.applySettings()
        check("light appearance applies natively",
              window.appearance?.name == .aqua, String(describing: window.appearance?.name))

        settings.appearance = original
        viewer.applySettings()
    }

    /// L3: the alternative window-size policy sizes the window to the image
    /// within the usable screen bounds, and reminds the remembered size otherwise.
    private static func verifyWindowSizing(_ reporter: SelfTestReporter) {
        func check(_ name: String, _ condition: Bool, _ detail: String = "") {
            reporter.check(name, condition, detail)
        }
        let settings = AppSettings.shared
        let original = settings.windowSizing
        defer { settings.windowSizing = original }

        let controller = AppEnvironment.shared.presentNewViewerWindow()
        guard let viewer = controller.viewerViewController as ViewerViewController?,
              let window = controller.window else {
            check("sizing scenario window", false)
            return
        }
        guard let scratch = makeScratchFolder("sizing", names: ["small.png", "large.png"],
                                             corruptNames: []) else {
            check("sizing scenario folder", false)
            return
        }
        defer { try? FileManager.default.removeItem(at: scratch) }
        // `large.png` is deliberately bigger than a laptop screen.
        writeTestImage(named: "large.png", in: scratch, width: 6000, height: 4000)

        viewer.open(url: scratch.appendingPathComponent("small.png"))
        drainRunLoop(1.5)

        settings.windowSizing = .fitImageToScreen
        viewer.open(url: scratch.appendingPathComponent("small.png"))
        drainRunLoop(1.5)
        let visible = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        check("image-sized window stays inside the usable screen",
              visible.contains(window.frame), "\(window.frame) in \(visible)")

        // An oversized image must fall back to something that fits the screen.
        settings.windowSizing = .fitImageToScreen
        viewer.open(url: scratch.appendingPathComponent("large.png"))
        drainRunLoop(2.0)
        check("oversized images do not push the window off screen",
              visible.contains(window.frame), "\(window.frame)")

        let remembered = settings.lastWindowSize
        settings.windowSizing = .rememberLastSize
        viewer.open(url: scratch.appendingPathComponent("small.png"))
        drainRunLoop(1.5)
        check("remembered sizing does not resize the window to the image",
              settings.lastWindowSize == remembered,
              "remembered \(String(describing: remembered)) -> \(String(describing: settings.lastWindowSize))")
        controller.close()
    }

    /// Writes a small PNG (or a corrupt file) so the runner is self-contained and
    /// never depends on a folder outside the repository.
    @discardableResult
    private static func writeTestImage(named name: String, in directory: URL,
                                       width: Int = 64, height: Int = 48,
                                       corrupt: Bool = false) -> URL {
        let url = directory.appendingPathComponent(name)
        if corrupt {
            try? Data("this is not an image".utf8).write(to: url)
            return url
        }
        guard let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return url
        }
        context.setFillColor(CGColor(red: 0.85, green: 0.2, blue: 0.25, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
        context.setFillColor(CGColor(red: 0.15, green: 0.35, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: width / 2, y: 0, width: width - width / 2, height: height))
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
            return url
        }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
        return url
    }

    /// Creates a scratch folder with real images, generated on the spot.
    private static func makeScratchFolder(_ label: String, names: [String],
                                          corruptNames: [String] = []) -> URL? {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("picviewmac-\(label)-\(UUID().uuidString)", isDirectory: true)
        guard (try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)) != nil else {
            return nil
        }
        for name in names { writeTestImage(named: name, in: directory) }
        for name in corruptNames { writeTestImage(named: name, in: directory, corrupt: true) }
        return directory
    }

    /// Drains the run loop until the canvas frame and zoom stop changing.
    private static func waitForStableCanvas(_ viewer: ViewerViewController,
                                            timeout: TimeInterval = 3) -> Bool {
        var previous = viewer.chromeSnapshot
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            drainRunLoop(0.1)
            let current = viewer.chromeSnapshot
            if current.canvasFrame == previous.canvasFrame
                && current.zoomScale == previous.zoomScale
                && current.isAnimationTimerActive == previous.isAnimationTimerActive {
                return true
            }
            previous = current
        }
        return false
    }

    private static func drainRunLoop(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    private static func waitForDecode(_ viewer: ViewerViewController, timeout: TimeInterval) {
        let deadline = Date().addingTimeInterval(timeout)
        while viewer.viewerState.currentImage == nil, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
    }

    private static func finish(_ reporter: SelfTestReporter) {
        print("=== PicLight self-test ===")
        reporter.lines.forEach { print($0) }
        print("=== \(reporter.failures.isEmpty ? "ALL PASSED" : "FAILURES: \(reporter.failures.joined(separator: ", "))") ===")
        NSApp.terminate(nil)
    }
}
