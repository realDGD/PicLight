import XCTest
import AppKit
@testable import PicViewMac

/// The dock's position readout: `current / total`, taken from `FolderSession.positionDescription`
/// and from nowhere else.
///
/// The point of the test is the "nowhere else" part. A dock that maintained its own index would
/// be a second source of truth for the one number the viewer, the drawer and the info HUD all
/// have to agree about.
@MainActor
final class ToolDockPositionTests: XCTestCase {

    override func setUp() async throws {
        try await super.setUp()
        TestAppKit.ensureApplication()
    }

    private func makeFolder(_ count: Int, preferring name: String = "b.png")
        throws -> (directory: URL, start: URL, controller: ViewerWindowController,
                   viewer: ViewerViewController, dock: ViewerToolDockView) {
        let directory = try Fixtures.makeScratchDirectory("dock-position")
        for index in 0..<count {
            try FileManager.default.copyItem(at: Fixtures.url("static.png"),
                                             to: directory.appendingPathComponent("img\(index).png"))
        }
        let controller = ViewerWindowController()
        TestAppKit.presentOffScreen(controller)
        let viewer = controller.viewerViewController
        controller.showWindow(nil)
        _ = viewer.view
        let start = directory.appendingPathComponent(name)
        viewer.open(url: FileManager.default.fileExists(atPath: start.path)
                    ? start : directory.appendingPathComponent("img0.png"))
        let deadline = Date().addingTimeInterval(10)
        while viewer.viewerState.currentImage == nil, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        let dock = try XCTUnwrap(viewer.chromeViewsForTesting["toolDock"] as? ViewerToolDockView)
        return (directory, start, controller, viewer, dock)
    }

    /// The readout is the session's own description, character for character.
    func testTheReadoutIsTheSessionsPositionDescription() throws {
        let (directory, _, controller, viewer, dock) = try makeFolder(7)
        defer {
            controller.close()
            try? FileManager.default.removeItem(at: directory)
        }

        XCTAssertEqual(dock.positionReadoutText, viewer.session.positionDescription)
        XCTAssertEqual(dock.positionReadoutText, "\(viewer.session.currentIndex! + 1) / 7")
    }

    /// Navigating moves the readout, and it keeps agreeing with the session at every step.
    func testTheReadoutFollowsNavigationExactly() throws {
        let (directory, _, controller, viewer, dock) = try makeFolder(5)
        defer {
            controller.close()
            try? FileManager.default.removeItem(at: directory)
        }

        for _ in 0..<3 {
            viewer.perform(.nextImage)
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
            XCTAssertEqual(dock.positionReadoutText, viewer.session.positionDescription)
        }
        for _ in 0..<2 {
            viewer.perform(.previousImage)
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
            XCTAssertEqual(dock.positionReadoutText, viewer.session.positionDescription)
        }
    }

    /// The HUD and the dock report the same position, because they read the same thing.
    func testTheDockAndTheHUDNeverDisagree() throws {
        let (directory, _, controller, viewer, dock) = try makeFolder(4)
        defer {
            controller.close()
            try? FileManager.default.removeItem(at: directory)
        }

        for command in [ViewerCommand.nextImage, .nextImage, .previousImage, .lastImage, .firstImage] {
            viewer.perform(command)
            RunLoop.current.run(until: Date().addingTimeInterval(0.4))
            let description = viewer.session.positionDescription
            XCTAssertEqual(dock.positionReadoutText, description)
            // The HUD builds its line from the same property, so its first field is that value.
            let bar = try XCTUnwrap(viewer.chromeViewsForTesting["bottomBar"] as? BottomInfoBarView)
            XCTAssertTrue(bar.renderedText.hasPrefix(description),
                          "the HUD leads with the position: \(bar.renderedText)")
        }
    }

    /// Opening one image gives `1 / 1`, not `0 / 1` or an empty string.
    func testASingleImageFolderReportsOneOfOne() throws {
        let (directory, _, controller, viewer, dock) = try makeFolder(1)
        defer {
            controller.close()
            try? FileManager.default.removeItem(at: directory)
        }
        XCTAssertEqual(dock.positionReadoutText, "1 / 1")
        XCTAssertEqual(dock.positionReadoutText, viewer.session.positionDescription)
    }

    /// With nothing open the readout is empty rather than a stale or invented number.
    func testNoFolderMeansNoPosition() throws {
        let controller = ViewerWindowController()
        TestAppKit.presentOffScreen(controller)
        defer { controller.close() }
        let viewer = controller.viewerViewController
        _ = viewer.view
        let dock = try XCTUnwrap(viewer.chromeViewsForTesting["toolDock"] as? ViewerToolDockView)
        // `FolderSession.positionDescription` is the one source, and for an empty session it says
        // "— / 0": no index at all, and a total of zero. The dock must not improve on that with an
        // invented "1 / 1" or a stale index from whatever was open before.
        XCTAssertEqual(dock.positionReadoutText, viewer.session.positionDescription)
        XCTAssertEqual(dock.positionReadoutText, "— / 0")
    }
}
