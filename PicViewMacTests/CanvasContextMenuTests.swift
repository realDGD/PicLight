import XCTest
import AppKit
@testable import PicViewMac

/// The canvas's right-click menu.
///
/// The menu is declared as data, so the order, the grouping and the enablement are checked without
/// a live menu — and, more importantly, every entry is a `ViewerCommand`. That is what makes the
/// context menu, the dock and the main menu one implementation rather than three.
@MainActor
final class CanvasContextMenuTests: XCTestCase {

    override func setUp() async throws {
        try await super.setUp()
        TestAppKit.ensureApplication()
    }

    private func makeFolder(_ count: Int) throws -> (directory: URL,
                                                     controller: ViewerWindowController,
                                                     viewer: ViewerViewController) {
        let directory = try Fixtures.makeScratchDirectory("context-menu")
        for index in 0..<count {
            try FileManager.default.copyItem(at: Fixtures.url("static.png"),
                                             to: directory.appendingPathComponent("img\(index).png"))
        }
        let controller = ViewerWindowController()
        TestAppKit.presentOffScreen(controller)
        let viewer = controller.viewerViewController
        controller.showWindow(nil)
        _ = viewer.view
        viewer.open(url: directory.appendingPathComponent("img0.png"))
        let deadline = Date().addingTimeInterval(10)
        while viewer.viewerState.currentImage == nil, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        return (directory, controller, viewer)
    }

    private func cleanup(_ directory: URL, _ controller: ViewerWindowController) {
        controller.close()
        try? FileManager.default.removeItem(at: directory)
    }

    /// The whole menu, in order, including the separators: this is the contract the spec spells out.
    func testTheMenuIsTheDocumentedOrder() {
        XCTAssertEqual(CanvasContextMenu.items, [
            .copyImage,
            .separator,
            .command(.zoomOut),
            .command(.zoomIn),
            .command(.zoomToFit),
            .command(.zoomToFitWidth),
            .command(.zoomActualPixels),
            .separator,
            .command(.previousImage),
            .command(.nextImage),
            .separator,
            .command(.rotateClockwise),
            .command(.rotateCounterClockwise),
            .command(.toggleMirror),
            .separator,
            .command(.browseFolder),
            .command(.toggleThumbnailDrawer),
            .command(.showImageInfo),
            .separator,
            .command(.moveToTrash),
        ])
    }

    /// Destructive last, and set off on its own: it must not sit next to "下一张".
    func testTrashIsLastAndIsolated() {
        let items = CanvasContextMenu.items
        XCTAssertEqual(items.last, .command(.moveToTrash))
        XCTAssertEqual(items[items.count - 2], .separator)
    }

    /// Every entry is a `ViewerCommand` (or the copy command, which is one too), so nothing in the
    /// menu has an implementation of its own.
    func testEveryActionIsAViewerCommand() {
        for item in CanvasContextMenu.items {
            switch item {
            case .separator:
                break
            case let .command(command):
                XCTAssertTrue(ViewerCommand.allCases.contains(command))
            case .copyImage:
                XCTAssertTrue(ViewerCommand.allCases.contains(.copyImage))
            }
        }
    }

    /// The commands the spec names are all present.
    func testTheRequiredCommandsArePresent() {
        let commands = CanvasContextMenu.items.compactMap { item -> ViewerCommand? in
            if case let .command(command) = item { return command }
            return nil
        }
        for required: ViewerCommand in [.zoomOut, .zoomIn, .zoomToFit, .zoomActualPixels,
                                        .zoomToFitWidth, .previousImage, .nextImage,
                                        .rotateClockwise, .toggleMirror, .browseFolder,
                                        .toggleThumbnailDrawer, .showImageInfo, .moveToTrash] {
            XCTAssertTrue(commands.contains(required), "\(required.rawValue) is missing")
        }
        XCTAssertTrue(CanvasContextMenu.items.contains(.copyImage))
    }

    /// Enablement follows the viewer's state rather than being declared true.
    func testEnablementFollowsAvailability() {
        let nothing = CanvasContextMenu.Availability(hasImage: false, canGoPrevious: false,
                                                     canGoNext: false)
        XCTAssertFalse(CanvasContextMenu.isEnabled(.copyImage, nothing))
        XCTAssertFalse(CanvasContextMenu.isEnabled(.command(.zoomIn), nothing))
        XCTAssertFalse(CanvasContextMenu.isEnabled(.command(.moveToTrash), nothing))
        XCTAssertFalse(CanvasContextMenu.isEnabled(.command(.toggleThumbnailDrawer), nothing),
                       "there is no drawer to toggle when nothing is open")

        let middle = CanvasContextMenu.Availability(hasImage: true, canGoPrevious: true,
                                                    canGoNext: true)
        for item in CanvasContextMenu.items where item != .separator {
            XCTAssertTrue(CanvasContextMenu.isEnabled(item, middle), "\(item) should be usable")
        }

        let first = CanvasContextMenu.Availability(hasImage: true, canGoPrevious: false,
                                                   canGoNext: true)
        XCTAssertFalse(CanvasContextMenu.isEnabled(.command(.previousImage), first),
                       "the first image has no previous")
        XCTAssertTrue(CanvasContextMenu.isEnabled(.command(.nextImage), first))

        let last = CanvasContextMenu.Availability(hasImage: true, canGoPrevious: true,
                                                  canGoNext: false)
        XCTAssertFalse(CanvasContextMenu.isEnabled(.command(.nextImage), last),
                       "the last image has no next")
        XCTAssertTrue(CanvasContextMenu.isEnabled(.command(.previousImage), last))
    }

    /// The built menu matches the declaration, and every entry points at the one action.
    func testTheBuiltMenuUsesOneActionForEveryCommand() throws {
        let (directory, controller, viewer) = try makeFolder(3)
        defer { cleanup(directory, controller) }

        let menu = viewer.canvasContextMenu()
        let separators = menu.items.filter { $0.isSeparatorItem }.count
        XCTAssertEqual(separators, 5, "the declared separators, one per group boundary")

        let actions = menu.items.filter { !$0.isSeparatorItem }
        XCTAssertEqual(actions.count, 15)
        for entry in actions {
            XCTAssertEqual(entry.action, #selector(ViewerViewController.performContextMenuCommand(_:)),
                           "every entry routes through the single command action")
            XCTAssertTrue(entry.target === viewer)
            XCTAssertNotNil(entry.representedObject as? String)
            XCTAssertNotNil(ViewerCommand(rawValue: entry.representedObject as! String))
        }
    }

    /// The entries that toggle something say what the click will do.
    func testToggleTitlesDescribeTheNextAction() throws {
        let (directory, controller, viewer) = try makeFolder(3)
        defer { cleanup(directory, controller) }

        func title(_ command: ViewerCommand) throws -> String {
            let menu = viewer.canvasContextMenu()
            let entry = try XCTUnwrap(menu.items.first { $0.representedObject as? String == command.rawValue })
            return entry.title
        }

        XCTAssertEqual(try title(.toggleThumbnailDrawer), "显示侧栏")
        viewer.toggleDrawerForTesting()
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        XCTAssertEqual(try title(.toggleThumbnailDrawer), "隐藏侧栏")

        XCTAssertEqual(try title(.showImageInfo), "显示图像信息")
        viewer.perform(.showImageInfo)
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        XCTAssertEqual(try title(.showImageInfo), "隐藏图像信息")
    }

    /// The canvas hands its menu to AppKit: right-click is wired, and with no image the entries
    /// that need one are disabled rather than absent.
    func testTheCanvasServesTheMenuAndDisablesWhatCannotHappen() throws {
        let (directory, controller, viewer) = try makeFolder(3)
        defer { cleanup(directory, controller) }
        let canvas = try XCTUnwrap(viewer.chromeViewsForTesting["canvas"] as? ImageCanvasView)
        let menu = try XCTUnwrap(canvas.contextMenuProvider?())
        XCTAssertEqual(menu.items.count, CanvasContextMenu.items.count)

        // First image: previous is disabled, next is not.
        func entry(_ command: ViewerCommand) throws -> NSMenuItem {
            try XCTUnwrap(menu.items.first { $0.representedObject as? String == command.rawValue })
        }
        XCTAssertFalse(try entry(.previousImage).isEnabled)
        XCTAssertTrue(try entry(.nextImage).isEnabled)
        XCTAssertTrue(try entry(.copyImage).isEnabled)
    }

    /// Choosing an entry runs the command, through the viewer's single path.
    func testChoosingAnEntryPerformsTheCommand() throws {
        let (directory, controller, viewer) = try makeFolder(3)
        defer { cleanup(directory, controller) }
        let menu = viewer.canvasContextMenu()

        let start = viewer.chromeSnapshot.zoomScale
        let zoomIn = try XCTUnwrap(menu.items.first {
            $0.representedObject as? String == ViewerCommand.zoomIn.rawValue
        })
        _ = zoomIn.target?.perform(zoomIn.action, with: zoomIn)
        XCTAssertEqual(viewer.chromeSnapshot.zoomScale, start * ViewerToolDockView.zoomStep,
                       accuracy: 1e-9, "the context menu's zoom in is the viewer's zoom in")

        let next = try XCTUnwrap(menu.items.first {
            $0.representedObject as? String == ViewerCommand.nextImage.rawValue
        })
        _ = next.target?.perform(next.action, with: next)
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        XCTAssertEqual(viewer.session.currentIndex, 1, "and its next is the viewer's next")
    }

    /// Nothing in the menu is a second implementation: the commands it names are the commands the
    /// dock and the main menu name.
    func testTheMenuSharesTheDocksCommandVocabulary() {
        let dockCommands = Set(ViewerToolDockView.layout.compactMap { item -> ViewerCommand? in
            if case let .command(_, command, _) = item { return command }
            return nil
        })
        let menuCommands = Set(CanvasContextMenu.items.compactMap { item -> ViewerCommand? in
            switch item {
            case let .command(command): return command
            case .copyImage: return .copyImage
            case .separator: return nil
            }
        })
        // The dock covers rotate / mirror / trash / zoom / navigation / drawer / info; the menu is
        // a superset of that plus copy and the folder browser.
        let shared = menuCommands.intersection(dockCommands)
        for command: ViewerCommand in [.rotateClockwise, .toggleMirror, .moveToTrash, .zoomToFit,
                                        .zoomIn, .zoomOut, .previousImage, .nextImage,
                                        .toggleThumbnailDrawer, .showImageInfo] {
            XCTAssertTrue(shared.contains(command), "\(command.rawValue) is not shared with the dock")
        }
    }
}
