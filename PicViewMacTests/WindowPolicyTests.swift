import XCTest
import AppKit
@testable import PicViewMac

final class WindowPolicyTests: XCTestCase {
    /// The base style mask is the standard window. `.fullSizeContentView` is *added* by the
    /// auto-hide titlebar mode rather than being part of the policy, so the always-visible mode
    /// keeps exactly the mask the standard window path had.
    @MainActor
    func testViewerWindowPolicyDisablesNativeTabsAndKeepsStandardStyle() {
        let policy = ViewerWindow.policy
        XCTAssertTrue(policy.styleMask.contains(.titled))
        XCTAssertTrue(policy.styleMask.contains(.closable))
        XCTAssertTrue(policy.styleMask.contains(.miniaturizable))
        XCTAssertTrue(policy.styleMask.contains(.resizable))
        XCTAssertFalse(policy.styleMask.contains(.fullSizeContentView),
                       "the base policy is the standard window; auto-hide adds this itself")
        // NOTE: `NSWindow.StyleMask.borderless` has raw value 0, so
        // `contains(.borderless)` is true for every style mask; the meaningful
        // check is that the mask is not exactly borderless and keeps a title bar.
        XCTAssertNotEqual(policy.styleMask, .borderless)
        XCTAssertEqual(policy.tabbingMode, .disallowed)
    }

    /// A fresh window starts in the default mode: auto-hide, with the content reaching the top edge
    /// and the titlebar's own chrome away. It is still an ordinary titled `NSWindow` — that is what
    /// keeps Mission Control, tiling and full screen working — and the traffic lights are still the
    /// real standard controls, just not shown yet.
    @MainActor
    func testViewerWindowStartsInTheDefaultAutoHideMode() {
        let window = ViewerWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600))
        defer { window.close() }
        XCTAssertTrue(window.isKind(of: NSWindow.self))
        XCTAssertNotEqual(window.styleMask, .borderless, "the viewer is not a true borderless window")
        XCTAssertTrue(window.styleMask.contains(.titled),
                      "a title bar is what keeps tiling and Mission Control working")
        XCTAssertEqual(window.tabbingMode, .disallowed)
        XCTAssertEqual(window.titlebarMode, .autoHide, "auto-hide is the default")
        XCTAssertEqual(window.titlebarState, .hidden, "and the bar starts away")
        XCTAssertTrue(window.styleMask.contains(.fullSizeContentView),
                      "auto-hide lets the content reach the top of the window")
        XCTAssertTrue(window.titlebarAppearsTransparent,
                      "a hidden titlebar is transparent, not an opaque bar with no title")
        XCTAssertEqual(window.titleVisibility, .hidden)
        XCTAssertNotNil(window.standardWindowButton(.closeButton))
        XCTAssertNotNil(window.standardWindowButton(.miniaturizeButton))
        XCTAssertNotNil(window.standardWindowButton(.zoomButton))
        XCTAssertTrue(window.collectionBehavior.contains(.fullScreenPrimary))
    }

    /// The other mode restores the standard window exactly: an opaque titlebar, content below it,
    /// no `.fullSizeContentView`.
    @MainActor
    func testAlwaysVisibleModeIsTheStandardWindowPath() {
        let window = ViewerWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600))
        defer { window.close() }
        window.applyTitlebarMode(.alwaysVisible)

        XCTAssertEqual(window.titleVisibility, .visible)
        XCTAssertFalse(window.titlebarAppearsTransparent)
        XCTAssertFalse(window.styleMask.contains(.fullSizeContentView),
                       "content sits below the titlebar again")
        XCTAssertTrue(window.styleMask.contains(.titled))
        XCTAssertEqual(window.titlebarState, .full)
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            XCTAssertEqual(window.standardWindowButton(button)?.isHidden, false,
                           "the real controls are shown")
        }
    }

    @MainActor
    func testOpeningTheViewControllerAddsNoExtraWindows() {
        let window = ViewerWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600))
        defer { window.close() }
        let controller = ViewerViewController()
        window.contentViewController = controller
        window.makeKeyAndOrderFront(nil)
        _ = controller.view
        // Hover chrome, drawer and minimap must all live inside the one window.
        let childWindows = window.childWindows ?? []
        XCTAssertTrue(childWindows.isEmpty)
    }
}
