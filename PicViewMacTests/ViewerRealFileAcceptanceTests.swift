import XCTest
import AppKit
@testable import PicViewMac

/// The acceptance run against real files: the investigation image, a plain multi-image folder, and a
/// fixture folder holding every shape the redesign has to survive.
///
/// The 48k image is read from where it lives on this machine and the whole class is skipped when it
/// is absent, so the suite stays portable while still doing the real work here. Everything these
/// tests assert is driven through the production paths — the viewer's own open, the gallery's own
/// reload, the pasteboard writer — rather than through the pieces underneath them.
@MainActor
final class ViewerRealFileAcceptanceTests: XCTestCase {

    /// The investigation image: 48000 x 32000, 2.07 GB on disk.
    private static let investigationImage = URL(
        fileURLWithPath: "/Users/dgd/Downloads/万萝图/万萝图.png")

    override func setUp() async throws {
        try await super.setUp()
        TestAppKit.ensureApplication()
    }

    // MARK: - Helpers

    private func makeViewer() -> (ViewerWindowController, ViewerViewController) {
        let controller = ViewerWindowController()
        TestAppKit.presentOffScreen(controller)
        let viewer = controller.viewerViewController
        controller.showWindow(nil)
        _ = viewer.view
        return (controller, viewer)
    }

    @discardableResult
    private func open(_ url: URL, in viewer: ViewerViewController,
                      timeout: TimeInterval = 60, settle: TimeInterval = 0.5) -> Bool {
        viewer.open(url: url)
        let deadline = Date().addingTimeInterval(timeout)
        while viewer.viewerState.currentImage == nil, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        RunLoop.current.run(until: Date().addingTimeInterval(settle))
        return viewer.viewerState.currentImage != nil
    }

    /// The same, for the async tests: `Task.sleep` yields to the main actor's queue, which a
    /// blocking `RunLoop.run` inside an async function does not reliably do.
    @discardableResult
    private func openAsync(_ url: URL, in viewer: ViewerViewController,
                           timeout: TimeInterval = 90, settle: TimeInterval = 0.5) async -> Bool {
        viewer.open(url: url)
        let deadline = Date().addingTimeInterval(timeout)
        while viewer.viewerState.currentImage == nil, Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        try? await Task.sleep(nanoseconds: UInt64(settle * 1_000_000_000))
        return viewer.viewerState.currentImage != nil
    }

    private func settle(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    private static func residentMemoryBytes() -> UInt64? {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size
            / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.resident_size : nil
    }

    /// A folder holding every shape the spec lists.
    private func makeShapeFixture() throws -> URL {
        let directory = try Fixtures.makeScratchDirectory("shape-fixture")
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let shapes: [(String, Int, Int)] = [
            ("wide-3x2.png", 600, 400),
            ("ultrawide-10x1.png", 2000, 200),
            ("portrait-1x3.png", 200, 600),
            ("square.png", 400, 400),
            ("small-16.png", 16, 16),
            ("large-4000.png", 4000, 2500),
        ]
        for (name, width, height) in shapes {
            try writePNG(named: name, in: directory, width: width, height: height)
        }
        // Animated, straight from the fixtures: the viewer has a separate path for these.
        try FileManager.default.copyItem(at: Fixtures.url("animated-infinite.gif"),
                                         to: directory.appendingPathComponent("animated-infinite.gif"))
        return directory
    }

    private func writePNG(named name: String, in directory: URL,
                          width: Int, height: Int) throws {
        let url = directory.appendingPathComponent(name)
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.3, green: 0.4, blue: 0.6, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let destination = try XCTUnwrap(
            CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }

    // MARK: - 18.1 Single-image mode on the investigation image

    /// The real file opens, is bounded, reports its true geometry, and does not explode memory.
    func testThe48kImageOpensBoundedAndKeepsMemoryBounded() throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: Self.investigationImage.path),
                          "the investigation image is not on this machine")
        guard let rssBefore = Self.residentMemoryBytes() else {
            throw XCTSkip("task_info is unavailable")
        }

        let (controller, viewer) = makeViewer()
        defer { controller.close() }
        XCTAssertTrue(open(Self.investigationImage, in: viewer, timeout: 120),
                      "the investigation image must open")

        let bitmap = try XCTUnwrap(viewer.viewerState.currentImage)
        XCTAssertLessThanOrEqual(max(bitmap.width, bitmap.height), DecodeBudget.maximumLongEdge,
                                 "the bitmap handed to the renderer is bounded")
        XCTAssertEqual(viewer.viewerState.descriptor?.displayPixelSize,
                       CGSize(width: 48000, height: 32000),
                       "while the descriptor keeps the source geometry")

        // Rapid panning at native detail must not grow the process without bound.
        viewer.perform(.zoomActualPixels)
        settle(1.0)
        for _ in 0..<6 {
            viewer.panForTesting(byViewports: 0.4)
            settle(0.3)
        }
        settle(2.0)
        let rssAfter = Self.residentMemoryBytes() ?? rssBefore
        let deltaMB = Double(Int64(rssAfter) - Int64(rssBefore)) / 1_048_576
        print(String(format: "METRIC 48k open+pan RSS before %.1f MB, after %.1f MB, delta %+.1f MB",
                     Double(rssBefore) / 1_048_576, Double(rssAfter) / 1_048_576, deltaMB))
        XCTAssertLessThan(deltaMB, 1500,
                          "opening and panning a 48k image must stay bounded "
                            + "(measured \(Int(deltaMB)) MB)")
    }

    /// The drawer's square slot, the always-visible filename and the info HUD, on the real file.
    func testTheInvestigationImageShowsItsThumbnailCentredWithItsNameAndReadout() throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: Self.investigationImage.path),
                          "the investigation image is not on this machine")
        let (controller, viewer) = makeViewer()
        defer { controller.close() }
        XCTAssertTrue(open(Self.investigationImage, in: viewer, timeout: 120))

        // The drawer: an ultra-wide source in a square slot, centred, with its name.
        viewer.toggleDrawerForTesting()
        settle(1.0)
        let drawer = try XCTUnwrap(viewer.chromeViewsForTesting["drawer"] as? ThumbnailDrawerView)
        let cell = try XCTUnwrap(drawer.cellForTesting(row: 0))
        cell.layoutSubtreeIfNeeded()
        let slot = cell.thumbnailSlotView.bounds
        let box = cell.thumbnailImageView.frame
        XCTAssertEqual(box.midX, slot.midX, accuracy: 0.5,
                       "an ultra-wide thumbnail is centred horizontally")
        XCTAssertEqual(box.midY, slot.midY, accuracy: 0.5,
                       "and vertically — it must not sit at the top of the slot")
        XCTAssertEqual(slot.width, ThumbnailCellView.thumbnailSlotSize, accuracy: 0.5,
                       "in the fixed square slot")
        XCTAssertFalse(cell.nameLabelView.isHidden, "with its filename always visible")
        XCTAssertEqual((cell.nameLabelView as? NSTextField)?.stringValue, "万萝图.png")

        // The info HUD reports the position, the zoom and the pixel dimensions.
        let bar = try XCTUnwrap(viewer.chromeViewsForTesting["bottomBar"] as? BottomInfoBarView)
        XCTAssertFalse(bar.isHidden, "the readout appears for the image that just arrived")
        XCTAssertTrue(bar.renderedText.contains("48000 × 32000"),
                      "the real dimensions: \(bar.renderedText)")
        XCTAssertTrue(bar.renderedText.contains("1 / 1"), bar.renderedText)
        settle(InfoHUDVisibilityModel.Timing().idleFadeDelay + 0.6)
        XCTAssertTrue(bar.isHidden, "and then it fades")

        // The drawer never opens from a pointer position.
        let before = viewer.chromeSnapshot.drawer
        for x in [0, 1, 5, 23] as [CGFloat] {
            viewer.simulatePointer(atWindowPoint: viewer.view.convert(
                CGPoint(x: x, y: viewer.view.bounds.midY), to: nil))
        }
        settle(0.5)
        XCTAssertEqual(viewer.chromeSnapshot.drawer, before,
                       "the left edge must not open the drawer")
    }

    /// Copy Image on the real file: responsive, bounded, and honest about what it places.
    func testCopyingThe48kImageIsBoundedAndOffersTheOriginal() throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: Self.investigationImage.path),
                          "the investigation image is not on this machine")
        let (controller, viewer) = makeViewer()
        defer { controller.close() }
        XCTAssertTrue(open(Self.investigationImage, in: viewer, timeout: 120))
        let bitmap = try XCTUnwrap(viewer.viewerState.currentImage)

        let started = Date()
        XCTAssertTrue(viewer.copyImageToPasteboard())
        let cost = Date().timeIntervalSince(started)
        XCTAssertLessThan(cost, 0.5, "copy must return without decoding (took \(cost) s)")

        let pasteboard = NSPasteboard.general
        let url = try XCTUnwrap(pasteboard.string(forType: .fileURL))
        XCTAssertEqual(URL(string: url)?.standardizedFileURL.path,
                       Self.investigationImage.standardizedFileURL.path,
                       "the original file is offered by reference")
        let data = try XCTUnwrap(pasteboard.data(forType: .tiff))
        let rep = try XCTUnwrap(NSBitmapImageRep(data: data))
        XCTAssertEqual(rep.pixelsWide, bitmap.width,
                       "and the pixels are the bounded bitmap, not a 6 GB full decode")
        XCTAssertLessThan(data.count, 256 * 1024 * 1024, "the payload is bounded")
    }

    /// The titlebar behaves in both modes on a real window, with the real controls.
    func testTheTitlebarRevealsInTwoLevelsOnTheInvestigationImage() throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: Self.investigationImage.path),
                          "the investigation image is not on this machine")
        let (controller, viewer) = makeViewer()
        defer { controller.close() }
        XCTAssertTrue(open(Self.investigationImage, in: viewer, timeout: 120))
        let window = try XCTUnwrap(controller.window as? ViewerWindow)
        XCTAssertEqual(window.titlebarMode, .autoHide, "auto-hide is the default")
        XCTAssertEqual(window.titlebarState, .hidden)

        // Zone A: the controls only.
        let zones = viewer.titlebarRevealZones
        viewer.simulatePointer(atWindowPoint: viewer.view.convert(
            CGPoint(x: zones.a.midX, y: zones.a.midY), to: nil))
        settle(0.4)
        XCTAssertEqual(window.titlebarState, .trafficLightsOnly)
        XCTAssertEqual(window.titleVisibility, .hidden, "no full titlebar in zone A")
        XCTAssertEqual(window.standardWindowButton(.closeButton)?.isHidden, false,
                       "and the real control is on screen")

        // Zone B: the whole bar.
        viewer.simulatePointer(atWindowPoint: viewer.view.convert(
            CGPoint(x: zones.b.midX, y: zones.b.midY), to: nil))
        settle(0.4)
        XCTAssertEqual(window.titlebarState, .full)
        XCTAssertEqual(window.titleVisibility, .visible)
    }

    // MARK: - 18.2 Folder browser on the real folders

    /// The browser over a plain multi-image folder: layouts, slider, tree, sorting and navigation.
    func testTheFolderBrowserOverAPlainFolder() throws {
try SharedSettingsScope.preservingSort {

            let directory = try Fixtures.makeScratchDirectory("plain-folder")
            addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
            for index in 0..<12 {
                try writePNG(named: "photo-\(index).png", in: directory,
                             width: 200 + index * 10, height: 150)
            }
            let (controller, viewer) = makeViewer()
            defer { controller.close() }
            XCTAssertTrue(open(directory.appendingPathComponent("photo-0.png"), in: viewer))

            viewer.perform(.browseFolder)
            settle(0.8)
            XCTAssertEqual(viewer.viewerMode, .folderBrowser)
            let browser = try XCTUnwrap(viewer.folderBrowserForTesting)
            let grid = browser.view.gallery
            viewer.view.layoutSubtreeIfNeeded()

            XCTAssertEqual(grid.itemCount, 12, "the gallery lists the folder")
            XCTAssertEqual(browser.view.treeSidebar.selectedPath,
                           directory.resolvingSymlinksInPath().path,
                           "the tree highlights the current folder")

            // Layout A then layout B.
            browser.view.onLayoutChanged?(.uniformGrid)
            settle(0.3)
            XCTAssertEqual(grid.layoutKindForTesting, .uniformGrid)
            browser.view.onLayoutChanged?(.adaptiveGrid)
            settle(0.3)
            XCTAssertEqual(grid.layoutKindForTesting, .adaptiveGrid)

            // The slider reflows.
            browser.view.onThumbnailSizeChanged?(240)
            settle(0.3)
            XCTAssertEqual(grid.thumbnailSizeForTesting, 240)

            // Sorting is shared with the image mode.
            browser.view.onSortKeyChanged?(.filename)
            browser.view.onSortDirectionChanged?(.descending)
            settle(0.4)
            XCTAssertEqual(AppSettings.shared.sortDirection, .descending)
            XCTAssertEqual(viewer.session.items.first?.displayName, "photo-11.png",
                           "descending by name is a natural (numeric) order, so photo-11 leads")

            // Back, then Return re-enters and opens the selection.
            browser.select(0)
            browser.view.backControl.sendAction(try XCTUnwrap(browser.view.backControl.action),
                                                to: browser.view.backControl.target)
            settle(0.6)
            XCTAssertEqual(viewer.viewerMode, .image)
            XCTAssertEqual(viewer.session.currentIndex, 0)
    
}
}

    /// A folder holding every shape: the drawer slots, the gallery layouts and the viewer all cope.
    func testTheShapeFixtureAcrossBothModes() throws {
        let directory = try makeShapeFixture()
        let (controller, viewer) = makeViewer()
        defer { controller.close() }
        XCTAssertTrue(open(directory.appendingPathComponent("square.png"), in: viewer))

        // Drawer: every shape in its own square slot, centred.
        viewer.toggleDrawerForTesting()
        settle(1.2)
        let drawer = try XCTUnwrap(viewer.chromeViewsForTesting["drawer"] as? ThumbnailDrawerView)
        for row in 0..<drawer.visibleRowCount {
            guard let cell = drawer.cellForTesting(row: row) else { continue }
            cell.layoutSubtreeIfNeeded()
            let slot = cell.thumbnailSlotView.bounds
            let box = cell.thumbnailImageView.frame
            XCTAssertEqual(slot.width, ThumbnailCellView.thumbnailSlotSize, accuracy: 0.5,
                           "row \(row) is a fixed square")
            XCTAssertEqual(box.midX, slot.midX, accuracy: 0.5, "row \(row) centred")
            XCTAssertEqual(box.midY, slot.midY, accuracy: 0.5, "row \(row) centred")
            XCTAssertFalse(cell.nameLabelView.isHidden, "row \(row) shows its name")
        }
        viewer.toggleDrawerForTesting()
        settle(0.5)

        // Browser: both layouts over the mixed shapes.
        viewer.perform(.browseFolder)
        settle(0.8)
        let browser = try XCTUnwrap(viewer.folderBrowserForTesting)
        let grid = browser.view.gallery
        viewer.view.layoutSubtreeIfNeeded()
        XCTAssertEqual(grid.itemCount, 7, "six stills and one animation")
        for kind in GalleryLayoutKind.allCases {
            browser.view.onLayoutChanged?(kind)
            settle(0.4)
            let rows = grid.rowsForTesting(containerWidth: max(grid.bounds.width, 600))
            XCTAssertEqual(rows.flatMap(\.cells).count, 7, "\(kind) places every item")
            for cell in rows.flatMap(\.cells) {
                XCTAssertLessThanOrEqual(cell.imageFrame.width, cell.frame.width + 0.5, "\(kind)")
                XCTAssertLessThanOrEqual(cell.imageFrame.height,
                                         cell.frame.height + 0.5, "\(kind)")
            }
        }

        // The animated item keeps its own path: opening it must not leave the browser in a bad state.
        if let animatedIndex = viewer.session.items.firstIndex(where: {
            $0.displayName.hasSuffix(".gif")
        }) {
            browser.view.gallery.onItemOpened?(animatedIndex)
            settle(1.0)
            XCTAssertEqual(viewer.viewerMode, .image)
            XCTAssertEqual(viewer.session.items[animatedIndex].displayName, "animated-infinite.gif")
        }
    }

    /// A same-path overwrite on a real file: the native-detail path must not serve the old file's
    /// pixels under the new file's identity.
    ///
    /// Driven through the viewer's own scheduler, which is the path the spec's §15 is about. Note
    /// what this does *not* claim: the *displayed* bitmap is served from `DecodeCache`, whose key is
    /// `(url, pageIndex, level)` and carries no file identity, so a running window keeps showing the
    /// previous file until something purges that cache. That is the "thumbnail file identity" item
    /// the spec lists as deferred (§16), and it stays deferred here — see the report's known
    /// limitations.
    func testASamePathOverwriteIsNotServedByTheTilePath() async throws {
        let directory = try Fixtures.makeScratchDirectory("overwrite")
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("live.png")
        try writePNG(named: "live.png", in: directory, width: 800, height: 600)
        let (controller, viewer) = makeViewer()
        defer { controller.close() }
        let opened = await openAsync(file, in: viewer)
        XCTAssertTrue(opened, "the file must open")

        let scheduler = viewer.nativeDetail
        let plan = try XCTUnwrap(NativeTilePlanner.plan(sourceRect: CGRect(x: 0, y: 0,
                                                                         width: 512, height: 512),
                                                       sourcePixelSize: CGSize(width: 800,
                                                                              height: 600),
                                                       tileSize: 512, ring: 0))
        // The unnumbered overload: the viewer tracks its own lifecycle epochs, and a request that
        // carried a smaller number would be ignored as stale — which is the epoch mechanism doing
        // its job, not something to assert around.
        await scheduler.request(plan: plan, source: file)
        let firstIdentity = SourceFileIdentity.read(at: file).versionToken
        let recordedFirst = await scheduler.cache.sourceVersion(for: file.path)
        XCTAssertEqual(recordedFirst, firstIdentity,
                       "the cache knows which file the tiles came from")

        // Replace the file in place with a visibly different one.
        try FileManager.default.removeItem(at: file)
        try writePNG(named: "live.png", in: directory, width: 1200, height: 300)
        let secondIdentity = SourceFileIdentity.read(at: file).versionToken
        XCTAssertNotEqual(firstIdentity, secondIdentity, "the replacement is a different file")

        await scheduler.request(plan: plan, source: file)
        let recordedSecond = await scheduler.cache.sourceVersion(for: file.path)
        XCTAssertEqual(recordedSecond, secondIdentity,
                       "a fresh request reads the file again and stamps the replacement, "
                         + "so the old file's tiles can never be served under it")
    }

}
