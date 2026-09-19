import XCTest
import AppKit
@testable import PicViewMac

/// Navigation from a corrupt image: the package's acceptance run reports that
/// `.nextImage` on a corrupt file does not reach the next picture. This drives the same scenario
/// directly, so the answer is a decode path or the runner's own state.
@MainActor
final class CorruptImageNavigationTests: XCTestCase {

    override func setUp() async throws {
        try await super.setUp()
        TestAppKit.ensureApplication()
    }

    private func pump(until condition: () -> Bool, timeout: TimeInterval = 10) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return condition()
    }

    func testNextImageAfterACorruptImageReachesTheNextPicture() throws {
        let directory = try Fixtures.makeScratchDirectory("corrupt-nav")
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("this is not an image".utf8)
            .write(to: directory.appendingPathComponent("a-corrupt.png"))
        try FileManager.default.copyItem(at: Fixtures.url("static.png"),
                                         to: directory.appendingPathComponent("b-good.png"))

        let controller = ViewerWindowController()
        TestAppKit.presentOffScreen(controller)
        defer { controller.close() }
        let viewer = controller.viewerViewController
        controller.showWindow(nil)
        _ = viewer.view
        viewer.open(url: directory.appendingPathComponent("a-corrupt.png"))

        XCTAssertTrue(pump(until: { viewer.viewerState.errorMessage?.isEmpty == false }),
                      "the corrupt image reports an error")
        XCTAssertEqual(viewer.session.items.count, 2, "both files are in the folder")
        XCTAssertEqual(viewer.session.currentItem?.displayName, "a-corrupt.png")
        XCTAssertEqual(viewer.session.currentIndex, 0)

        viewer.perform(.nextImage)
        XCTAssertTrue(pump(until: { viewer.viewerState.currentImage != nil }),
                      "the next image decodes after the corrupt one "
                        + "(current item: \(viewer.session.currentItem?.displayName ?? "none"))")
        XCTAssertEqual(viewer.session.currentItem?.displayName, "b-good.png")
    }

    /// The same through the keyboard path, which is how a user moves on.
    func testKeyboardNextAfterACorruptImageReachesTheNextPicture() throws {
        let directory = try Fixtures.makeScratchDirectory("corrupt-nav-key")
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("not an image either".utf8)
            .write(to: directory.appendingPathComponent("a-corrupt.png"))
        try FileManager.default.copyItem(at: Fixtures.url("static.png"),
                                         to: directory.appendingPathComponent("b-good.png"))

        let controller = ViewerWindowController()
        TestAppKit.presentOffScreen(controller)
        defer { controller.close() }
        let viewer = controller.viewerViewController
        controller.showWindow(nil)
        _ = viewer.view
        viewer.open(url: directory.appendingPathComponent("a-corrupt.png"))
        XCTAssertTrue(pump(until: { viewer.viewerState.errorMessage?.isEmpty == false }))

        // Right arrow is the documented "next image" key.
        if let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                        timestamp: 0, windowNumber: 0, context: nil,
                                        characters: "\u{f703}", charactersIgnoringModifiers: "\u{f703}",
                                        isARepeat: false, keyCode: 124) {
            viewer.keyDown(with: event)
        }
        XCTAssertTrue(pump(until: { viewer.viewerState.currentImage != nil }),
                      "arrow-key navigation survives a corrupt image")
        XCTAssertEqual(viewer.session.currentItem?.displayName, "b-good.png")
    }
}