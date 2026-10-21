import XCTest
import AppKit
@testable import PicViewMac

/// One command, two modes, two left columns.
///
/// Measured before the fix: in the gallery the drawer shortcut changed `drawerOpen` from false to
/// true — a column the user could not see — while the visible left column (the folder tree) stayed
/// as it was, and the change only showed up after going back to the image. The titlebar button had
/// been routed by mode already; the command now follows the same routing.
@MainActor
final class ModeRoutedCommandTests: XCTestCase {

    override func setUp() async throws {
        try await super.setUp()
        TestAppKit.ensureApplication()
    }

    private func pump(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    private func waitUntil(_ timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return condition()
    }

    private func makeViewer(_ items: Int) throws -> (directory: URL, controller: ViewerWindowController,
                                                     viewer: ViewerViewController) {
        let directory = try Fixtures.makeScratchDirectory("mode-command")
        for index in 0..<items {
            try FileManager.default.copyItem(at: Fixtures.url("static.png"),
                                             to: directory.appendingPathComponent("img\(index).png"))
        }
        let controller = ViewerWindowController()
        TestAppKit.presentOffScreen(controller)
        controller.window?.setFrame(NSRect(x: 0, y: 0, width: 1000, height: 760), display: false)
        controller.showWindow(nil)
        let viewer = controller.viewerViewController
        _ = viewer.view
        viewer.open(url: directory.appendingPathComponent("img0.png"))
        XCTAssertTrue(waitUntil(15) { viewer.viewerState.currentImage != nil })
        return (directory, controller, viewer)
    }

    /// In the image mode the command is the drawer, exactly as before.
    func testInImageModeTheCommandTogglesTheDrawer() throws {
        let (directory, controller, viewer) = try makeViewer(3)
        defer {
            TestAppKit.close(controller)
            try? FileManager.default.removeItem(at: directory)
        }
        XCTAssertFalse(viewer.isDrawerOpen)

        viewer.perform(.toggleThumbnailDrawer)
        pump(0.3)
        XCTAssertTrue(viewer.isDrawerOpen, "the image mode's left column is the drawer")

        viewer.perform(.toggleThumbnailDrawer)
        pump(0.3)
        XCTAssertFalse(viewer.isDrawerOpen)
    }

    /// In the gallery it is the gallery's left column, which is the folder tree.
    func testInTheGalleryTheCommandTogglesTheFolderTree() throws {
        let (directory, controller, viewer) = try makeViewer(3)
        defer {
            TestAppKit.close(controller)
            try? FileManager.default.removeItem(at: directory)
        }
        viewer.perform(.browseFolder)
        pump(0.6)
        let drawerBefore = viewer.isDrawerOpen
        let treeBefore = viewer.isFolderTreeSidebarVisible

        viewer.perform(.toggleThumbnailDrawer)
        pump(0.4)

        XCTAssertNotEqual(viewer.isFolderTreeSidebarVisible, treeBefore,
                          "the visible left column is what the command changes")
        XCTAssertEqual(viewer.isDrawerOpen, drawerBefore,
                       "and the drawer it cannot see stays exactly as it was "
                       + "(measured before: drawerOpen false → true)")
    }

    /// The button and the command agree in both modes.
    func testTheButtonAndTheCommandDoTheSameThing() throws {
        let (directory, controller, viewer) = try makeViewer(3)
        defer {
            TestAppKit.close(controller)
            try? FileManager.default.removeItem(at: directory)
        }
        viewer.perform(.browseFolder)
        pump(0.6)

        let treeBefore = viewer.isFolderTreeSidebarVisible
        viewer.perform(.toggleThumbnailDrawer)
        pump(0.4)
        let afterCommand = viewer.isFolderTreeSidebarVisible
        XCTAssertNotEqual(afterCommand, treeBefore)

        viewer.toggleLeftColumn()
        pump(0.4)
        XCTAssertEqual(viewer.isFolderTreeSidebarVisible, treeBefore,
                       "the button undoes what the command did, because they are one behaviour")
    }
}
