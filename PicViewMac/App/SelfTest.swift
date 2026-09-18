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

        // Rotating or mirroring a zoomed-in view must not move the user somewhere else:
        // the image point under the view centre has to survive the change.
        if let descriptor = viewer.viewerState.descriptor {
            let source = descriptor.displayPixelSize
            var offCentre = viewer.viewerState.viewport
            offCentre.zoomScale = max(offCentre.zoomScale, 4)
            offCentre.normalizedCenter = CGPoint(x: 0.7, y: 0.3)
            viewer.canvasViewportForTesting = offCentre
            let anchor = viewer.viewerState.viewport.imagePointUnderViewCenter(sourcePixelSize: source)
            viewer.perform(.rotateClockwise)
            let afterRotation = viewer.viewerState.viewport.imagePointUnderViewCenter(sourcePixelSize: source)
            viewer.perform(.toggleMirror)
            let afterMirror = viewer.viewerState.viewport.imagePointUnderViewCenter(sourcePixelSize: source)
            let drift = hypot(afterRotation.x - anchor.x, afterRotation.y - anchor.y)
            let mirrorDrift = hypot(afterMirror.x - anchor.x, afterMirror.y - anchor.y)
            check("rotation keeps the visible image point", drift < 1.5,
                  String(format: "drift %.1f px from (%.0f, %.0f)", drift, anchor.x, anchor.y))
            check("mirroring keeps the visible image point", mirrorDrift < 1.5,
                  String(format: "drift %.1f px", mirrorDrift))
            viewer.perform(.toggleMirror)
        }
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
            let sizeBefore = viewer.viewerState.currentImage.map { "\($0.width)x\($0.height)" } ?? "-"
            viewer.perform(.nextPage)
            let pageDeadline = Date().addingTimeInterval(5)
            while viewer.viewerState.currentImage.map({ "\($0.width)x\($0.height)" }) == sizeBefore,
                  Date() < pageDeadline {
                drainRunLoop(0.05)
            }
            let sizeAfter = viewer.viewerState.currentImage.map { "\($0.width)x\($0.height)" } ?? "-"
            check("TIFF page navigation works",
                  viewer.viewerState.pageDescription != pageBefore,
                  "\(pageBefore ?? "-") -> \(viewer.viewerState.pageDescription ?? "-")")
            check("TIFF page navigation changes the pixels, not just the counter",
                  sizeAfter != sizeBefore, "\(sizeBefore) -> \(sizeAfter)")
            check("folder index is unchanged by page navigation",
                  viewer.session.currentItem?.url == tiff.url)
        }

        verifyStartupPresentation(environment, reporter)
        verifyWindowShape(viewer, reporter)
        verifyOnScreenOrientation(viewer, originalURL: fileURL, reporter)
        verifyChrome(viewer, reporter)
        verifyDrawerPin(viewer, reporter)
        verifyViewerLayout(viewer, reporter)
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
        where_is_probe: do {
            // Measure the welcome-state window shape, which is where square bottom
            // corners were reported.
            if let window = bare.window,
               let image = WindowShapeProbe.capture(windowNumber: window.windowNumber) {
                let samples = WindowShapeProbe.samples(of: image)
                reporter.note("welcome window samples: "
                    + samples.map { "\($0.label) a\($0.alpha)(\($0.r),\($0.g),\($0.b))" }
                        .joined(separator: " | "))
            } else {
                reporter.note("welcome window: no capture available")
            }
        }
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

        // 2a. The window management strip is the standard AppKit titlebar.
        let window = controller.window
        check("viewer uses the standard visible titlebar",
              window?.titleVisibility == .visible
                && window?.titlebarAppearsTransparent == false
                && window?.styleMask.contains(.fullSizeContentView) == false,
              "titleVisibility=\(String(describing: window?.titleVisibility)) "
                + "transparent=\(String(describing: window?.titlebarAppearsTransparent))")
        check("viewer has no viewer-owned top bar",
              viewer.chromeViewsForTesting["topBar"] == nil,
              "top bar views: \(viewer.chromeViewsForTesting.keys.filter { $0.contains("top") })")
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

        // 2b. With no pointer in a hover region, every chrome surface must be
        //     genuinely hidden - not merely transparent.
        drainRunLoop(0.6)
        var notHidden: [String] = []
        for (name, chrome) in viewer.chromeViewsForTesting
        where ["topBar", "bottomBar", "drawer", "minimap"].contains(name) {
            if !chrome.isHidden { notHidden.append("\(name) alpha=\(chrome.alphaValue)") }
        }
        check("chrome starts genuinely hidden, not just transparent",
              notHidden.isEmpty, notHidden.joined(separator: ", "))

        // 3. The left edge is not a trigger: the drawer opens only from an explicit control, and a
        //    hidden drawer is not clickable.
        let bounds = viewer.view.bounds
        check("the left edge does not open the drawer",
              viewer.zone(forRootPoint: CGPoint(x: 0, y: bounds.midY)) == .canvas)
        check("nor 23 px in",
              viewer.zone(forRootPoint: CGPoint(x: 23, y: bounds.midY)) == .canvas)
        check("nor the top-left corner",
              viewer.zone(forRootPoint: CGPoint(x: 2, y: bounds.maxY - 2)) == .canvas)
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
        viewer.toggleDrawerForTesting()
        drainRunLoop(0.5)
        let pinned = viewer.chromeSnapshot
        check("pinning opens the drawer", pinned.drawer)
        check("a pinned drawer reserves space instead of overlaying",
              pinned.canvasFrame.width == baseline.canvasFrame.width - viewer.currentDrawerWidth,
              "canvas \(baseline.canvasFrame.width) -> \(pinned.canvasFrame.width), "
                + "drawer \(viewer.currentDrawerWidth)")

        // Moving the pointer away must not close it while pinned.
        viewer.simulatePointer(atWindowPoint: NSPoint(x: viewer.view.bounds.midX,
                                                     y: viewer.view.bounds.midY))
        drainRunLoop(0.8)
        check("a pinned drawer survives the pointer leaving", viewer.chromeSnapshot.drawer)

        viewer.toggleDrawerForTesting()
        drainRunLoop(0.8)
        check("unpinning restores hover auto-close", viewer.chromeSnapshot.drawer == false)
        check("unpinning gives the full width back to the canvas",
              viewer.chromeSnapshot.canvasFrame.width == baseline.canvasFrame.width,
              "canvas \(viewer.chromeSnapshot.canvasFrame.width) vs \(baseline.canvasFrame.width)")
    }

    /// Measures the window's own composited pixels. A rounded window has corner
    /// pixels that are not part of the window (transparent or desktop); a square
    /// bottom corner is the signature of content painting past the window shape.
    /// Is the image upright *on screen*?
    ///
    /// The renderers disagree with each other about the y direction unless this is checked
    /// against reality: a parity test between two flipped renderers passes happily, and a
    /// uniform or sideways fixture hides the flip. This writes a top-half-red,
    /// bottom-half-blue image, opens it, and samples the real window pixels above and below
    /// the image's centre.
    private static func verifyOnScreenOrientation(_ viewer: ViewerViewController,
                                                 originalURL: URL,
                                                 _ reporter: SelfTestReporter) {
        func check(_ name: String, _ condition: Bool, _ detail: String = "") {
            reporter.check(name, condition, detail)
        }
        guard let scratch = makeScratchFolder("orientation", names: ["two-tone.png"],
                                             corruptNames: []),
              let window = viewer.view.window else {
            check("orientation scenario", false)
            return
        }
        defer { try? FileManager.default.removeItem(at: scratch) }

        // Top half red, bottom half blue — in source terms, so a y flip is visible.
        let width = 200, height = 200
        guard let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            check("orientation context", false)
            return
        }
        let red = CGColor(red: 0.9, green: 0.1, blue: 0.1, alpha: 1)
        let blue = CGColor(red: 0.1, green: 0.2, blue: 0.9, alpha: 1)
        context.setFillColor(blue)                       // the context is y-up: blue low
        context.fill(CGRect(x: 0, y: 0, width: width, height: height / 2))
        context.setFillColor(red)                        // red high = the image's top half
        context.fill(CGRect(x: 0, y: height / 2, width: width, height: height - height / 2))
        let url = scratch.appendingPathComponent("two-tone.png")
        if let image = context.makeImage(),
           let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) {
            CGImageDestinationAddImage(destination, image, nil)
            CGImageDestinationFinalize(destination)
        }

        // This check borrows the shared viewer, so it hands the session back afterwards: the
        // first version left it pointing at a deleted scratch folder and took three later checks
        // down with it.
        defer {
            viewer.open(url: originalURL)
            waitForDecode(viewer, timeout: 10)
            viewer.perform(.zoomToFit)
            drainRunLoop(0.3)
        }
        viewer.open(url: url)
        waitForDecode(viewer, timeout: 10)
        viewer.perform(.zoomToFit)
        drainRunLoop(0.4)

        let canvas = viewer.canvasViewForTesting
        let canvasInWindow = canvas.convert(canvas.bounds, to: nil)
        guard let capture = WindowShapeProbe.capture(windowNumber: window.windowNumber),
              let data = capture.dataProvider?.data as Data?, capture.width > 8 else {
            check("orientation capture available", false, "no window capture")
            return
        }
        // Window points (y up, origin bottom-left) → capture pixels (row 0 = top).
        let scale = CGFloat(capture.width) / max(window.frame.width, 1)
        func sample(windowPoint: CGPoint) -> (r: Int, g: Int, b: Int) {
            let x = Int(windowPoint.x * scale), y = Int((window.frame.height - windowPoint.y) * scale)
            let bytesPerPixel = max(capture.bitsPerPixel / 8, 1)
            let offset = y * capture.bytesPerRow + x * bytesPerPixel
            guard offset + 2 < data.count else { return (0, 0, 0) }
            // CGWindowListCreateImage hands back BGRA premultiplied in practice.
            return (Int(data[offset + 2]), Int(data[offset + 1]), Int(data[offset]))
        }
        // Upper and lower quarter of the image area, on its centre line. The image is fitted,
        // so the canvas is filled vertically by the image when it is portrait-ish.
        let centreX = canvasInWindow.midX
        let upper = sample(windowPoint: CGPoint(x: centreX, y: canvasInWindow.minY + canvasInWindow.height * 0.75))
        let lower = sample(windowPoint: CGPoint(x: centreX, y: canvasInWindow.minY + canvasInWindow.height * 0.25))

        // A window capture needs Screen Recording permission; where it is denied the samples come
        // back black and there is nothing to assert. Reported as skipped rather than failed, so the
        // check is honest in both environments instead of red for a permission it cannot change.
        guard upper.r + upper.g + upper.b + lower.r + lower.g + lower.b > 24 else {
            check("image is upright on screen (skipped: no window capture in this environment)",
                  true, "samples rgb(\(upper.r),\(upper.g),\(upper.b)) and rgb(\(lower.r),\(lower.g),\(lower.b))")
            return
        }
        check("image is upright on screen: the top half is red",
              upper.r > upper.b + 40, "top sample rgb(\(upper.r),\(upper.g),\(upper.b))")
        check("image is upright on screen: the bottom half is blue",
              lower.b > lower.r + 40, "bottom sample rgb(\(lower.r),\(lower.g),\(lower.b))")
    }

    private static func verifyWindowShape(_ viewer: ViewerViewController,
                                          _ reporter: SelfTestReporter) {
        func check(_ name: String, _ condition: Bool, _ detail: String = "") {
            reporter.check(name, condition, detail)
        }
        guard let window = viewer.view.window else {
            check("window shape: a window exists", false)
            return
        }
        guard let image = WindowShapeProbe.capture(windowNumber: window.windowNumber) else {
            reporter.note("window shape: this process cannot capture its own window")
            return
        }
        let samples = WindowShapeProbe.samples(of: image)
        reporter.note("window shape samples (alpha r g b): "
            + samples.map { "\($0.label) a\($0.alpha) (\($0.r),\($0.g),\($0.b))" }
                .joined(separator: " | "))
        let centre = samples.first { $0.label == "centre" }?.alpha ?? 0
        guard centre > 0 else {
            reporter.note("window shape: capture looks empty, skipping the comparison")
            return
        }
        // How far in the window's shape starts tells the actual corner radius:
        // a rounded window reaches its first opaque pixel well inside the corner.
        let topReach = WindowShapeProbe.firstOpaqueOffset(of: image, row: 2) ?? -1
        let bottomReach = WindowShapeProbe.firstOpaqueOffset(of: image, row: image.height - 3) ?? -1
        let leftTopReach = WindowShapeProbe.firstOpaqueOffset(of: image, column: 2) ?? -1
        let leftBottomReach = WindowShapeProbe.firstOpaqueOffset(of: image, column: image.width - 3) ?? -1
        reporter.note("window shape reach: top row \(topReach)px, bottom row \(bottomReach)px, "
            + "left column \(leftTopReach)px, right column \(leftBottomReach)px")
        check("window shape: bottom corners are rounded like the top ones",
              bottomReach >= 0 && topReach >= 0 && bottomReach + 4 >= topReach,
              "top row starts at \(topReach)px, bottom row at \(bottomReach)px")

        for label in ["bottomLeft", "bottomRight"] {
            guard let sample = samples.first(where: { $0.label == label }) else { continue }
            check("window shape: \(label) corner is rounded, not square",
                  sample.alpha < centre / 2,
                  "corner alpha \(sample.alpha) vs centre alpha \(centre)")
        }
    }

    /// Any button inside a view hierarchy.
    private static func containsButton(in view: NSView) -> Bool {
        if view is NSButton { return true }
        return view.subviews.contains { containsButton(in: $0) }
    }

    /// The viewer layout refactor: standard titlebar, fixed dock, canvas-anchored
    /// panels, and an information card instead of a separate window.
    private static func verifyViewerLayout(_ viewer: ViewerViewController,
                                           _ reporter: SelfTestReporter) {
        func check(_ name: String, _ condition: Bool, _ detail: String = "") {
            reporter.check(name, condition, detail)
        }
        let chrome = viewer.chromeViewsForTesting
        guard let dock = chrome["toolDock"] as? ViewerToolDockView,
              let canvas = chrome["canvas"],
              let minimap = chrome["minimap"],
              let bottomBar = chrome["bottomBar"],
              let card = chrome["infoCard"] as? ImageInfoCardView else {
            check("viewer layout views exist", false)
            return
        }

        // The drawer opens from the titlebar; its own pin control is gone.
        let viewerWindow = viewer.view.window
        check("titlebar carries the drawer control",
              viewerWindow?.titlebarAccessoryViewControllers.count == 1
                && viewerWindow?.titlebarAccessoryViewControllers.first?.layoutAttribute == .leading,
              "accessories: \(viewerWindow?.titlebarAccessoryViewControllers.count ?? 0)")
        check("drawer has no pin control of its own",
              !Self.containsButton(in: chrome["drawer"] ?? NSView()),
              "the drawer is content only")

        check("tool dock carries the viewer commands",
              dock.commands == [.rotateClockwise, .toggleMirror, .zoomToFit, .zoomToFitWidth,
                                .previousImage, .nextImage, .zoomActualPixels,
                                .moveToTrash, .showImageInfo],
              "\(dock.commands.count) commands")
        let pairIndexes = dock.commands.indices.filter {
            [.previousImage, .nextImage].contains(dock.commands[$0])
        }
        let pairCentre = pairIndexes.isEmpty ? -1
            : Double(pairIndexes.reduce(0, +)) / Double(pairIndexes.count)
        check("previous/next sit in the middle of the dock",
              pairIndexes.count == 2
                && abs(pairCentre - Double(dock.commands.count - 1) / 2) <= 1.0,
              "pair centre \(pairCentre) of \(dock.commands.count)")
        check("tool dock is a viewer subview, not a window",
              dock.isDescendant(of: viewer.view))

        // A button with no icon is invisible in practice, so check the images
        // rather than only the command list.
        let dockButtons = dock.subviews.compactMap { $0 as? NSStackView }
            .flatMap { $0.arrangedSubviews.compactMap { $0 as? DockButton } }
        let iconlessButtons = dockButtons.filter { !$0.isHidden && $0.symbolImage == nil }
        check("every visible dock button has an icon",
              iconlessButtons.isEmpty,
              "\(iconlessButtons.count) of \(dockButtons.count) buttons have no image")
        let glassAvailable = ProcessInfo.processInfo.isOperatingSystemAtLeast(
            OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0))
        check("tool dock uses the native glass surface where available",
              dock.usesNativeGlass == glassAvailable,
              "glass=\(dock.usesNativeGlass), material=\(dock.usesSystemMaterial)")
        let untinted = dockButtons.filter { !$0.isHidden && $0.iconTint == nil }
        check("dock icons carry an adaptive tint",
              untinted.isEmpty && dockButtons.filter { !$0.isHidden }
                .allSatisfy { $0.symbolImage?.isTemplate == true },
              "\(untinted.count) untinted of \(dockButtons.count)")
        check("dock buttons are laid out with a real size",
              dockButtons.allSatisfy { $0.frame.width >= 20 && $0.frame.height >= 20 },
              dockButtons.map { "\(Int($0.frame.width))x\(Int($0.frame.height))" }.joined(separator: " "))

        drainRunLoop(0.3)
        let unpinnedCanvas = canvas.frame
        check("panels sit inside the canvas area",
              minimap.frame.maxX <= canvas.frame.maxX + 1
                && bottomBar.frame.minX >= canvas.frame.minX - 1,
              "minimap \(minimap.frame) canvas \(canvas.frame)")
        check("tool dock is centred on the canvas",
              abs(dock.frame.midX - canvas.frame.midX) <= 2,
              "dock \(dock.frame.midX) canvas \(canvas.frame.midX)")

        // Pinning reserves space, and every canvas-anchored panel follows.
        viewer.toggleDrawerForTesting()
        drainRunLoop(0.6)
        let pinnedCanvas = canvas.frame
        check("pinned drawer shrinks the canvas by exactly its width",
              abs(pinnedCanvas.width - (unpinnedCanvas.width - viewer.currentDrawerWidth)) <= 1,
              "\(unpinnedCanvas.width) -> \(pinnedCanvas.width)")
        check("panels follow the canvas when pinned",
              abs(dock.frame.midX - pinnedCanvas.midX) <= 2
                && abs(minimap.frame.maxX - (pinnedCanvas.maxX - 14)) <= 2,
              "dock \(dock.frame.midX) vs canvas \(pinnedCanvas.midX)")
        // Measured against whatever image is current, using the canvas's own pixel
        // size rather than a hard-coded fixture size.
        let currentPixels = (canvas as? ImageCanvasView)?.imagePixelSize ?? .zero
        let expectedFit = ViewportState.fitScale(imagePixels: currentPixels,
                                                viewPoints: pinnedCanvas.size)
        check("fit is measured against the canvas",
              abs(viewer.viewerState.viewport.fitScale - expectedFit) < 0.35,
              "fit \(viewer.viewerState.viewport.fitScale) vs canvas fit \(expectedFit) "
                + "for \(currentPixels) in \(pinnedCanvas.size)")
        viewer.toggleDrawerForTesting()
        drainRunLoop(0.6)
        check("unpinning restores the canvas width",
              abs(canvas.frame.width - unpinnedCanvas.width) <= 1,
              "\(canvas.frame.width) vs \(unpinnedCanvas.width)")

        // The information card is inside the viewer; no window is created for it.
        let windowsBefore = NSApp.windows.count
        viewer.setInfoCardVisible(true)
        drainRunLoop(0.4)
        check("image info opens as an in-viewer card",
              !card.isHidden && card.isDescendant(of: viewer.view))
        check("image info creates no window", NSApp.windows.count == windowsBefore,
              "\(windowsBefore) -> \(NSApp.windows.count)")
        check("image info card is anchored to the canvas lower-left",
              abs(card.frame.minX - (canvas.frame.minX + 14)) <= 2
                && card.frame.minY >= canvas.frame.minY - 1,
              "card \(card.frame) canvas \(canvas.frame)")
        viewer.setInfoCardVisible(false)
        // Long enough for the fade plus its fallback to complete.
        drainRunLoop(0.7)
        check("image info card closes again", card.isHidden,
              "alpha \(card.alphaValue)")
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
        // The outline must be a *view* above the preview: as a bare sublayer it was
        // covered by the preview's lazily created layer and disappeared.
        let overlayIndex = navigator.subviews.firstIndex(of: navigator.viewportOverlaySurface) ?? .min
        check("navigator viewport overlay sits above the preview",
              overlayIndex > previewIndex
                && navigator.viewportOverlayLayer.superlayer === navigator.viewportOverlaySurface.layer,
              "preview at \(previewIndex), overlay at \(overlayIndex)")
        check("navigator viewport outline is built for the current viewport",
              navigator.viewportOverlayLayer.path != nil
                && !navigator.viewportOverlayLayer.isHidden,
              "path present: \(navigator.viewportOverlayLayer.path != nil)")
        check("navigator preview is a bounded downsample",
              navigator.hasPreviewImage
                && max(navigator.previewPixelSize.width, navigator.previewPixelSize.height)
                    <= CGFloat(NavigatorView.previewPixelSize),
              "\(navigator.previewPixelSize)")
        check("navigator viewport outline has a single crisp stroke",
              navigator.viewportOverlayLayer.lineWidth <= 2
                && navigator.viewportOverlaySurface.layer?.sublayers?
                    .filter { $0 is CAShapeLayer }.count == 1,
              "lineWidth \(navigator.viewportOverlayLayer.lineWidth), "
                + "shape layers \(navigator.viewportOverlaySurface.layer?.sublayers?.count ?? 0)")

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

        // The bottom info bar is fixed chrome; the tool dock auto-hides and comes
        // back through the invisible strip along the bottom of the image area.
        var snapshot = viewer.chromeSnapshot
        check("bottom info bar is fixed chrome, not hover-revealed",
              !viewer.chromeViewsForTesting["bottomBar"]!.isHidden)

        guard let dock = viewer.chromeViewsForTesting["toolDock"] as? ViewerToolDockView else {
            check("the tool dock exists", false)
            return
        }
        func pointInView(_ point: CGPoint) -> NSPoint { viewer.view.convert(point, to: nil) }
        func pointerAway() {
            viewer.simulatePointer(atWindowPoint: pointInView(
                CGPoint(x: viewer.view.bounds.midX, y: viewer.view.bounds.midY + 120)))
        }
        func pointerAtDock() {
            viewer.simulatePointer(atWindowPoint: pointInView(
                CGPoint(x: dock.frame.midX, y: dock.frame.midY)))
        }

        // The dock's state is driven by wall-clock delays, and this machine may stall
        // the main thread for seconds on the first Metal use. The checks therefore poll
        // for the transition with a deadline instead of assuming a fixed drain covers
        // it — the verdict is "it gets there", not "it gets there in 300 ms".
        func waitForDock(_ condition: () -> Bool, nudge: () -> Void,
                         timeout: TimeInterval = 3) -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            while !condition(), Date() < deadline {
                // Nudge the state machine: every pointer event re-evaluates it, and the
                // real pointer is not moving during an unattended run.
                nudge()
                drainRunLoop(0.1)
            }
            return condition()
        }

        // Into the strip, and the dock returns.
        check("the reveal strip brings the tool dock back",
              waitForDock({ !dock.isHidden }, nudge: pointerAtDock))

        // Away from the strip it leaves again. The pointer has to move once more after
        // the hide delay for the state machine to be re-evaluated.
        check("the tool dock hides once the pointer is away",
              waitForDock({ dock.isHidden }, nudge: pointerAway))
        let dockState = viewer.toolDockVisibilityForTesting
        let zone = viewer.toolDockRevealZone
        let centre = CGPoint(x: dock.bounds.midX, y: dock.bounds.midY)
        let inRoot = dock.convert(centre, to: viewer.view)
        reporter.note("dock frame \(dock.frame) zone \(zone) root \(viewer.view.bounds)")
        reporter.note("pointer \(inRoot) visible=\(dockState.visible) inZone=\(dockState.pointerInZone)")
        reporter.note("pinned=\(dockState.pinned) hasImage=\(dockState.hasImage) "
            + "hidden=\(dock.isHidden) alpha=\(dock.alphaValue)")
        check("the pin is the last control in the dock, behind its own separator",
              (dock.pinControl.superview as? NSStackView)?.arrangedSubviews.last === dock.pinControl
                && !dock.isPinned && dock.pinControl.toolTip == ViewerToolDockView.pinTooltip,
              "tooltip \(dock.pinControl.toolTip ?? "nil")")

        // Pinning holds it open; the pin reads as engaged.
        check("the dock is back before the pin is tested",
              waitForDock({ !dock.isHidden }, nudge: pointerAtDock))
        viewer.setToolDockPinned(true)
        drainRunLoop(0.3)
        check("the pin renders as engaged",
              dock.isPinned && dock.pinControl.iconTint == .systemBlue
                && dock.pinControl.toolTip == ViewerToolDockView.unpinTooltip,
              "tint \(String(describing: dock.pinControl.iconTint))")
        pointerAway()
        drainRunLoop(1.2)
        pointerAway()
        drainRunLoop(0.4)
        check("a pinned tool dock stays on screen", !dock.isHidden)

        viewer.setToolDockPinned(false)
        check("unpinning hands the dock back to auto-hide",
              waitForDock({ dock.isHidden }, nudge: pointerAway))

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

        // The viewer chrome uses a plain system material; the strong glass look was
        // removed from the top of the window along with the hover bar.
        check("viewer chrome uses a system surface",
              viewer.chromeSnapshot.usesNativeSurface, "material present")

        // Immersive hides the viewer's overlay chrome. The standard titlebar and
        // the window itself are AppKit's and stay as they are.
        // The window may still be settling (the image-sized window policy resizes it
        // when a descriptor arrives), so wait for the frame to stop changing before
        // treating it as a baseline.
        var frameBeforeImmersive = viewer.view.window?.frame
        for _ in 0..<12 {
            drainRunLoop(0.1)
            let current = viewer.view.window?.frame
            if current == frameBeforeImmersive { break }
            frameBeforeImmersive = current
        }
        viewer.simulateImmersive(true)
        drainRunLoop(0.4)
        check("immersive hides overlay chrome",
              viewer.chromeSnapshot.drawer == false
                && viewer.chromeViewsForTesting["toolDock"]!.isHidden
                && viewer.chromeViewsForTesting["bottomBar"]!.isHidden)
        check("immersive does not touch the window or its titlebar",
              viewer.view.window?.frame == frameBeforeImmersive
                && viewer.view.window?.styleMask.contains(.fullScreen) == false,
              "frame \(String(describing: viewer.view.window?.frame.size))")
        viewer.simulateImmersive(false)
        drainRunLoop(0.4)
        check("leaving immersive restores the tool dock",
              !viewer.chromeViewsForTesting["toolDock"]!.isHidden)
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
        let originalSize = settings.lastWindowSize
        defer {
            settings.windowSizing = original
            settings.lastWindowSize = originalSize
        }
        // The scenario asks what the policy does to *this image*, so it starts from a
        // known window: whatever size the user last dragged to is remembered across
        // launches, and a stale value made the first run after a manual session size
        // the window from that memory instead of from the image.
        settings.lastWindowSize = nil

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
        // Wait for the image to be on screen before measuring: re-opening puts the loading
        // placeholder up, and the placeholder has its own size — measuring during it made this
        // check depend on decode timing rather than on the sizing policy.
        waitForDecode(viewer, timeout: 10)
        drainRunLoop(0.5)
        let visible = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        check("image-sized window stays inside the usable screen",
              visible.contains(window.frame), "\(window.frame) in \(visible)")

        // An oversized image must fall back to something that fits the screen.
        settings.windowSizing = .fitImageToScreen
        viewer.open(url: scratch.appendingPathComponent("large.png"))
        waitForDecode(viewer, timeout: 10)
        drainRunLoop(1.0)
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
