import XCTest
import AppKit
@testable import PicViewMac

/// The image mode's top strip: the file name, and the picture's pixel size on the right.
///
/// It replaces the system title that used to be drawn on a transparent bar (white text straight on the
/// picture, unreadable over a bright image) and the bottom-left HUD whose hover/idle trigger nobody
/// could predict — what that readout was actually consulted for was the size.
@MainActor
final class TitleStripTests: XCTestCase {

    override func setUp() async throws {
        try await super.setUp()
        TestAppKit.ensureApplication()
    }

    private func settle(_ seconds: TimeInterval = 0.5) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    private func makeViewer() throws -> (controller: ViewerWindowController, viewer: ViewerViewController) {
        let controller = ViewerWindowController()
        TestAppKit.presentOffScreen(controller)
        controller.window?.setFrame(NSRect(x: 0, y: 0, width: 1000, height: 760), display: false)
        controller.showWindow(nil)
        let viewer = controller.viewerViewController
        _ = viewer.view
        return (controller, viewer)
    }

    private func strip(_ viewer: ViewerViewController) throws -> TitleStripView {
        try XCTUnwrap(viewer.chromeViewsForTesting["titleStrip"] as? TitleStripView,
                      "the image mode's top strip")
    }

    /// It names the picture and gives its real pixel size, and it is a glass surface like the dock.
    func testTheStripNamesThePictureAndItsSize() throws {
        let (controller, viewer) = try makeViewer()
        defer { TestAppKit.close(controller) }
        let file = Fixtures.url("static.png")
        viewer.open(url: file)
        settle(1.0)

        let expected = try XCTUnwrap(ImageHeaderProbe.pixelSize(of: file))
        let view = try strip(viewer)
        XCTAssertEqual(view.renderedTitle, file.lastPathComponent, "the file name")
        XCTAssertEqual(view.renderedSize, "\(Int(expected.width)) × \(Int(expected.height))",
                       "and the source's own pixel size, not the window's")
        // The strip reads like the left column: the sidebar material, not glass over the picture.
        // Reported twice — "why does the dock read better than the titlebar", then "I want it like the
        // left column's background" — and the answer is the material: glass is a tint over the image,
        // `.sidebar` is what macOS gives a window's sidebar.
        XCTAssertTrue(view.usesSystemMaterial, "the strip is a system surface")
        XCTAssertFalse(view.usesNativeGlass,
                       "and deliberately not glass: the picture must not show through the file name")
        XCTAssertTrue(view.isSidebarMaterial,
                      "the left column's material, blended within the window rather than behind it")
    }

    /// It *is* the titlebar in this mode: on screen when the bar is, gone when the bar is away — and
    /// the window's own title is hidden so nothing is drawn twice.
    func testTheStripFollowsTheTitlebarAndTheSystemTitleStepsAside() throws {
        let (controller, viewer) = try makeViewer()
        defer { TestAppKit.close(controller) }
        let window = try XCTUnwrap(controller.window as? ViewerWindow)
        viewer.open(url: Fixtures.url("static.png"))
        settle(1.0)
        let view = try strip(viewer)

        // Away, at rest.
        settle(TitlebarVisibilityModel.Timing().hideDelay + 0.6)
        XCTAssertEqual(window.titlebarState, .hidden)
        XCTAssertTrue(view.isHidden, "no strip while the bar is away")

        // Revealed.
        let zones = viewer.titlebarRevealZones
        viewer.simulatePointer(atWindowPoint: viewer.view.convert(
            CGPoint(x: zones.b.midX, y: zones.b.midY), to: nil))
        settle(0.6)
        XCTAssertEqual(window.titlebarState, .full)
        XCTAssertFalse(view.isHidden, "the strip is the revealed bar")
        XCTAssertTrue(window.titlebarAppearsTransparent,
                      "the window's bar has no surface of its own: the strip is the surface")
        XCTAssertEqual(window.titleVisibility, .hidden,
                       "so the system's white-on-the-picture title is not drawn")
        XCTAssertEqual(view.frame.width, viewer.view.bounds.width, accuracy: 1,
                       "and it spans the window")
        XCTAssertGreaterThan(view.frame.height, 20, "with a titlebar's height")
    }

    /// A hairline separates the strip from the picture, the way a titlebar's separator does.
    func testTheStripHasATitlebarHairline() throws {
        let (controller, viewer) = try makeViewer()
        defer { TestAppKit.close(controller) }
        viewer.open(url: Fixtures.url("static.png"))
        settle(0.8)
        let view = try strip(viewer)
        XCTAssertFalse(view.separatorForTesting.isHidden, "the separator is drawn")
        XCTAssertEqual(view.separatorForTesting.frame.width, view.bounds.width, accuracy: 1,
                       "and spans the strip")
        XCTAssertLessThanOrEqual(view.separatorForTesting.frame.height, 1,
                                 "a hairline, not a band")
    }

    /// The bottom-left readout is gone, together with its setting.
    func testTheOldBottomInfoBarIsGone() throws {
        let (controller, viewer) = try makeViewer()
        defer { TestAppKit.close(controller) }
        viewer.open(url: Fixtures.url("static.png"))
        settle(1.0)

        XCTAssertNil(viewer.chromeViewsForTesting["bottomBar"],
                     "the hover/idle readout was removed, not merely hidden")
        XCTAssertFalse(viewer.chromeSnapshot.bottom,
                       "and nothing reports it as being on screen")
    }

    /// An empty window shows no size, and no stale name either.
    func testAnEmptyWindowShowsNothingInTheStrip() throws {
        let (controller, viewer) = try makeViewer()
        defer { TestAppKit.close(controller) }
        settle(0.6)
        let view = try strip(viewer)
        XCTAssertEqual(view.renderedTitle, "")
        XCTAssertEqual(view.renderedSize, "")
    }
}
