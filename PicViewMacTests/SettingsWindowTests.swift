import XCTest
import AppKit
@testable import PicViewMac

/// The settings window is a fixed 560×560 panel. It used to be freely resizable, which
/// only ever produced clipped rows and a shortcut list that scrolled out of its box.
@MainActor
final class SettingsWindowTests: XCTestCase {

    override func setUp() async throws {
        try await super.setUp()
        TestAppKit.ensureApplication()
    }

    private var controllers: [SettingsWindowController] = []

    override func tearDown() async throws {
        for controller in controllers { controller.close() }
        controllers.removeAll()
        try await super.tearDown()
    }

    private func makeWindow() throws -> SettingsWindowController {
        let controller = SettingsWindowController()
        controllers.append(controller)
        controller.window?.contentViewController?.loadViewIfNeeded()
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        return controller
    }

    private func allViews(in view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + allViews(in: $0) }
    }

    func testTheWindowCannotBeResizedByTheUser() throws {
        let controller = try makeWindow()
        let window = try XCTUnwrap(controller.window)
        XCTAssertTrue(window.styleMask.contains(.titled))
        XCTAssertTrue(window.styleMask.contains(.closable))
        XCTAssertFalse(window.styleMask.contains(.resizable),
                       "the panel is laid out for one size, so it must not be resizable")
    }

    func testTheContentSizeIsPinnedToTheDesignSize() throws {
        let controller = try makeWindow()
        let window = try XCTUnwrap(controller.window)
        let design = SettingsWindowController.contentSize
        XCTAssertEqual(design, NSSize(width: 560, height: 560))
        XCTAssertEqual(window.contentMinSize, design)
        XCTAssertEqual(window.contentMaxSize, design)
        XCTAssertEqual(controller.contentSizeForTesting, design,
                       "the content is laid out at the design size")
    }

    /// Every tab must fit the fixed height: a row that does not is a row the user cannot
    /// reach, because there is no scroller behind it.
    func testEveryTabFitsTheFixedContentHeight() throws {
        let controller = try makeWindow()
        let viewController = try XCTUnwrap(controller.window?.contentViewController
                                            as? SettingsViewController)
        let heights = viewController.tabContentHeightsForTesting()
        XCTAssertEqual(heights.count, 4, "four tabs: 浏览, 交互, 外观, 快捷键")
        for entry in heights {
            XCTAssertGreaterThan(entry.available, 0, "\(entry.title): the tab has a real size")
            XCTAssertLessThanOrEqual(entry.content, entry.available,
                                     "\(entry.title): \(entry.content) pt of rows in "
                                       + "\(entry.available) pt of tab")
        }
    }

    /// The filename preference is gone; the drawer always shows names.
    func testTheFilenamePreferenceIsNoLongerOffered() throws {
        let controller = try makeWindow()
        let content = try XCTUnwrap(controller.window?.contentView)
        let titles = allViews(in: content).compactMap { $0 as? NSPopUpButton }
            .flatMap { $0.itemTitles }
        for mode in ThumbnailFilenameMode.allCases {
            XCTAssertFalse(titles.contains(mode.localizedName),
                           "“\(mode.localizedName)” must not be offered any more")
        }
        // Sanity: the tab really was inspected — its other preferences are still there.
        XCTAssertTrue(titles.contains(ImageSortKey.allCases[0].localizedName),
                      "the browse tab keeps its other popups")
    }
}
