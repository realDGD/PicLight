import XCTest
import AppKit
@testable import PicViewMac

final class WindowPolicyTests: XCTestCase {
    @MainActor
    func testViewerWindowPolicyDisablesNativeTabsAndKeepsStandardStyle() {
        let policy = ViewerWindow.policy
        XCTAssertTrue(policy.styleMask.contains(.titled))
        XCTAssertTrue(policy.styleMask.contains(.closable))
        XCTAssertTrue(policy.styleMask.contains(.miniaturizable))
        XCTAssertTrue(policy.styleMask.contains(.resizable))
        XCTAssertFalse(policy.styleMask.contains(.fullSizeContentView),
                       "content sits below the standard titlebar, not underneath it")
        // NOTE: `NSWindow.StyleMask.borderless` has raw value 0, so
        // `contains(.borderless)` is true for every style mask; the meaningful
        // check is that the mask is not exactly borderless and keeps a title bar.
        XCTAssertNotEqual(policy.styleMask, .borderless)
        XCTAssertEqual(policy.tabbingMode, .disallowed)
    }

    @MainActor
    func testViewerWindowIsAnOrdinaryWindowWithTheStandardTitlebar() {
        let window = ViewerWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600))
        defer { window.close() }
        XCTAssertTrue(window.isKind(of: NSWindow.self))
        XCTAssertNotEqual(window.styleMask, .borderless, "the viewer is not a true borderless window")
        XCTAssertTrue(window.styleMask.contains(.titled), "a title bar is what keeps tiling and Mission Control working")
        XCTAssertEqual(window.tabbingMode, .disallowed)
        XCTAssertEqual(window.titleVisibility, .visible,
                       "the standard titlebar is always visible; there is no hover titlebar")
        XCTAssertFalse(window.titlebarAppearsTransparent)
        XCTAssertFalse(window.styleMask.contains(.fullSizeContentView))
        XCTAssertNotNil(window.standardWindowButton(.closeButton))
        XCTAssertNotNil(window.standardWindowButton(.miniaturizeButton))
        XCTAssertNotNil(window.standardWindowButton(.zoomButton))
        XCTAssertTrue(window.collectionBehavior.contains(.fullScreenPrimary))
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
