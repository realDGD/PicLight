import XCTest
import AppKit
@testable import PicViewMac

final class WindowPlacementStoreTests: XCTestCase {
    private let screen = NSRect(x: 0, y: 0, width: 1600, height: 1000)

    func testRememberedFrameIsClampedIntoTheVisibleFrame() {
        let offscreen = NSRect(x: 5000, y: 5000, width: 900, height: 700)
        let clamped = WindowPlacementStore.clamp(offscreen, into: screen)
        XCTAssertEqual(clamped.maxX, screen.maxX)
        XCTAssertEqual(clamped.maxY, screen.maxY)
        XCTAssertEqual(clamped.width, 900)
        XCTAssertEqual(clamped.height, 700)
    }

    func testFrameLargerThanTheScreenShrinksToFit() {
        let huge = NSRect(x: 0, y: 0, width: 4000, height: 3000)
        let clamped = WindowPlacementStore.clamp(huge, into: screen)
        XCTAssertEqual(clamped.width, screen.width)
        XCTAssertEqual(clamped.height, screen.height)
    }

    func testTinyFrameKeepsAUsableMinimumSize() {
        let tiny = NSRect(x: 10, y: 10, width: 40, height: 20)
        let clamped = WindowPlacementStore.clamp(tiny, into: screen)
        XCTAssertGreaterThanOrEqual(clamped.width, 320)
        XCTAssertGreaterThanOrEqual(clamped.height, 240)
    }

    func testImageSizedWindowUsesImagePixelsWhenTheyFitOnScreen() {
        let frame = WindowPlacementStore.imageSizedFrame(
            imagePixels: CGSize(width: 800, height: 600),
            chromeInsets: NSEdgeInsets(top: 44, left: 0, bottom: 40, right: 0),
            visibleFrame: screen
        )
        XCTAssertEqual(frame.width, 800)
        XCTAssertEqual(frame.height, 600 + 44 + 40)
        XCTAssertTrue(screen.contains(frame))
    }

    func testOversizedImageFallsBackToFitSizedWindow() {
        let frame = WindowPlacementStore.imageSizedFrame(
            imagePixels: CGSize(width: 20_000, height: 12_000),
            chromeInsets: NSEdgeInsets(top: 44, left: 0, bottom: 40, right: 0),
            visibleFrame: screen
        )
        XCTAssertLessThanOrEqual(frame.width, screen.width)
        XCTAssertLessThanOrEqual(frame.height, screen.height)
        XCTAssertTrue(screen.contains(frame))
    }

    func testCascadeNeverExactlyOverlapsThePreviousWindow() {
        let base = NSRect(x: 100, y: 100, width: 800, height: 600)
        let first = WindowPlacementStore.cascadedFrame(base: base, index: 1, visibleFrame: screen)
        let second = WindowPlacementStore.cascadedFrame(base: base, index: 2, visibleFrame: screen)
        XCTAssertNotEqual(first.origin, second.origin)
        XCTAssertNotEqual(first.origin, base.origin)
        XCTAssertTrue(screen.contains(first))
        XCTAssertTrue(screen.contains(second))
    }

    func testDisconnectedMonitorRecoversIntoTheAvailableScreen() {
        // A frame remembered on a monitor that is no longer attached.
        let disconnected = NSRect(x: 3000, y: 200, width: 900, height: 700)
        let recovered = WindowPlacementStore.clamp(disconnected, into: screen)
        XCTAssertTrue(screen.contains(recovered))
    }

    @MainActor
    func testViewerWindowControllerRemembersContentSizeNotFullScreenFrame() {
        let controller = ViewerWindowController()
        defer { controller.close() }
        let window = try? XCTUnwrap(controller.window)
        XCTAssertNotNil(window)
        AppSettings.shared.lastWindowSize = nil
        controller.window?.setContentSize(NSSize(width: 900, height: 640))
        controller.window?.delegate?.windowDidResize?(Notification(name: NSWindow.didResizeNotification,
                                                                  object: controller.window))
        XCTAssertEqual(AppSettings.shared.lastWindowSize?.width ?? 0, 900, accuracy: 2)
    }
}

final class HoverVisibilityTests: XCTestCase {
    func testTopChromeRevealsImmediatelyAndHidesAfterTheDelayedFade() {
        var model = HoverVisibilityModel()
        model.pointerEnteredTop(at: 0)
        XCTAssertTrue(model.update(at: 0))
        XCTAssertTrue(model.topVisible)

        model.pointerExitedTop(at: 1.0)
        XCTAssertFalse(model.update(at: 1.1), "the fade delay has not elapsed yet")
        XCTAssertTrue(model.topVisible)
        XCTAssertTrue(model.update(at: 1.4))
        XCTAssertFalse(model.topVisible)
    }

    func testIdlePointerEventuallyHidesChrome() {
        var model = HoverVisibilityModel()
        // The pointer stays inside the top region but never moves again.
        model.pointerEnteredTop(at: 0)
        XCTAssertTrue(model.update(at: 0))
        XCTAssertTrue(model.topVisible)

        XCTAssertFalse(model.update(at: 1.0), "still within the idle window")
        XCTAssertTrue(model.topVisible)
        XCTAssertTrue(model.update(at: 2.0), "idle inactivity hides chrome after ~1.5–2 s")
        XCTAssertFalse(model.topVisible)
    }

    func testPointerActivityKeepsTheMinimapAliveAndFitHidesIt() {
        var model = HoverVisibilityModel()
        model.setZoomedIn(true, at: 0)
        XCTAssertTrue(model.update(at: 0.2))
        XCTAssertTrue(model.minimapVisible)

        XCTAssertTrue(model.update(at: 5))
        XCTAssertFalse(model.minimapVisible, "the minimap fades after ~1.5 s idle")

        model.zoomActivity(at: 6)
        _ = model.update(at: 6.1)
        XCTAssertTrue(model.minimapVisible, "zoom or pan interaction brings it back")

        model.setZoomedIn(false, at: 6.2)
        _ = model.update(at: 6.3)
        XCTAssertFalse(model.minimapVisible, "the minimap never shows at Fit")
    }

    func testDrawerOpensAfterTheDelayAndClosesAfterTheLeaveDelay() {
        var model = HoverVisibilityModel()
        model.pointerEnteredLeftEdge(at: 0)
        XCTAssertFalse(model.update(at: 0.05), "150 ms reveal delay")
        XCTAssertFalse(model.drawerVisible)
        XCTAssertTrue(model.update(at: 0.2))
        XCTAssertTrue(model.drawerVisible)

        model.pointerExitedDrawer(at: 1.0)
        XCTAssertFalse(model.update(at: 1.1), "250 ms close delay")
        XCTAssertTrue(model.drawerVisible)
        XCTAssertTrue(model.update(at: 1.3))
        XCTAssertFalse(model.drawerVisible)
    }

    func testPointerInsideTheDrawerKeepsItOpen() {
        var model = HoverVisibilityModel()
        model.pointerEnteredDrawer(at: 0)
        _ = model.update(at: 0.2)
        XCTAssertTrue(model.drawerVisible)
        for step in 1...20 {
            model.pointerEnteredDrawer(at: Double(step))
            _ = model.update(at: Double(step))
        }
        XCTAssertTrue(model.drawerVisible)
    }

    func testImmersiveModeStartsHiddenButStillAllowsHoverReveal() {
        var model = HoverVisibilityModel()
        model.pointerEnteredTop(at: 0)
        _ = model.update(at: 0)
        XCTAssertTrue(model.topVisible)

        model.setImmersive(true, at: 1)
        XCTAssertFalse(model.topVisible)
        XCTAssertFalse(model.bottomVisible)
        XCTAssertTrue(model.chromeHidden)

        model.pointerEnteredTop(at: 2)
        _ = model.update(at: 2)
        XCTAssertTrue(model.topVisible, "immersive mode still reveals chrome on hover")
    }

    func testBottomBarFollowsTheSameHoverFadeBehavior() {
        var model = HoverVisibilityModel()
        XCTAssertFalse(model.bottomVisible)
        model.pointerEnteredTop(at: 0)
        _ = model.update(at: 0.1)
        XCTAssertTrue(model.bottomVisible)
        model.pointerExitedTop(at: 0.2)
        _ = model.update(at: 0.6)
        XCTAssertFalse(model.bottomVisible)
    }
}
