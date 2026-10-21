import XCTest
import AppKit
@testable import PicViewMac

@MainActor
private final class SettingsWindowFrameRecorder: NSObject, NSWindowDelegate {
    var frames: [NSRect] = []

    func windowDidMove(_ notification: Notification) {
        if let window = notification.object as? NSWindow { frames.append(window.frame) }
    }

    func windowDidResize(_ notification: Notification) {
        if let window = notification.object as? NSWindow { frames.append(window.frame) }
    }
}

/// The settings window follows the reference settings window: the width is
/// fixed and the user cannot resize it, the height tracks the selected pane,
/// and every row has to fit — there is no scroller behind a pane.
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

    private func viewController(of controller: SettingsWindowController) throws -> SettingsViewController {
        let viewController = try XCTUnwrap(controller.window?.contentViewController as? SettingsViewController)
        viewController.loadViewIfNeeded()
        return viewController
    }

    /// Selects a pane the way the tab strip does, then lets the window settle.
    private func select(_ title: String, in controller: SettingsWindowController) throws -> SettingsViewController {
        let viewController = try viewController(of: controller)
        viewController.selectPane(title)
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        return viewController
    }

    private func controls(in view: NSView) -> [NSView] {
        allViews(in: view).filter {
            $0 is NSButton || $0 is NSPopUpButton || $0 is NSSlider
                || ($0 is NSTextField && !($0 is NSTokenField))
        }
    }

    /// Rows inside a scroll view are scrolled content, not clipped rows.
    private func isInsideScrollView(_ view: NSView) -> Bool {
        var ancestor = view.superview
        while let current = ancestor {
            if current is NSScrollView { return true }
            ancestor = current.superview
        }
        return false
    }

    func testTheWindowCannotBeResizedByTheUser() throws {
        let controller = try makeWindow()
        let window = try XCTUnwrap(controller.window)
        XCTAssertTrue(window.styleMask.contains(.titled))
        XCTAssertTrue(window.styleMask.contains(.closable))
        XCTAssertFalse(window.styleMask.contains(.resizable),
                       "the panes are laid out for one width, so it must not be resizable")
    }

    func testTheWindowWidthIsPinnedAndTheHeightTracksThePane() throws {
        let controller = try makeWindow()
        let window = try XCTUnwrap(controller.window)
        let viewController = try viewController(of: controller)
        for title in viewController.paneTitlesForTesting {
            viewController.selectPane(title)
            window.contentView?.layoutSubtreeIfNeeded()
            let expected = viewController.preferredContentHeight()
            XCTAssertEqual(window.contentMinSize.width, SettingsMetrics.windowWidth)
            XCTAssertEqual(window.contentMinSize.height, expected, accuracy: 1,
                           "\(title): the window is pinned to the height the pane needs")
            XCTAssertEqual(window.contentMaxSize.height, expected, accuracy: 1)
            XCTAssertEqual(window.contentView?.bounds.height ?? 0, expected, accuracy: 1,
                           "\(title): the content is laid out at the pane height")
            XCTAssertEqual(window.contentView?.bounds.width ?? 0, SettingsMetrics.windowWidth, accuracy: 1,
                           "\(title): no row may push the window wider than its fixed width")
        }
    }

    /// Navigation applies its final geometry synchronously; no window animator
    /// may keep stretching the old pane after the new category is shown.
    func testVisiblePaneSwitchAppliesStableGeometryImmediately() throws {
        let controller = try makeWindow()
        let window = try XCTUnwrap(controller.window)
        TestAppKit.moveOffScreen(window)
        controller.showWindow(nil)
        let settings = try viewController(of: controller)
        let top = window.frame.maxY
        for pane in ["看图", "通用", "看图"] {
            settings.selectPane(pane)
            let expected = settings.preferredContentHeight()
            XCTAssertEqual(window.contentView?.bounds.height ?? 0, expected, accuracy: 1)
            XCTAssertEqual(window.frame.maxY, top, accuracy: 1)
            let frame = window.frame
            if pane == "看图" {
                for category in ["一般", "外观", "鼠标", "翻页", "打开", "一般"] {
                    settings.selectViewerSubPane(category)
                    XCTAssertEqual(window.frame, frame, "viewer categories share one stable window size")
                }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
            XCTAssertEqual(window.frame, frame, "no delayed animation may change the committed geometry")
        }
    }

    func testMouseAndPagingSwitchNeverMovesTheVisibleWindow() throws {
        let controller = try makeWindow()
        let window = try XCTUnwrap(controller.window)
        controller.showWindow(nil)
        let settings = try select("看图", in: controller)
        settings.selectViewerSubPane("鼠标")
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        let frame = window.frame
        XCTAssertEqual(window.contentView?.bounds.width ?? 0, SettingsMetrics.windowWidth, accuracy: 0.5)
        let recorder = SettingsWindowFrameRecorder()
        window.delegate = recorder
        defer { window.delegate = nil }
        let categories = try XCTUnwrap(allViews(in: settings.view).compactMap { $0 as? SettingsCategoryBar }.first)
        for title in ["翻页", "鼠标", "翻页", "鼠标"] {
            recorder.frames.removeAll()
            let index = try XCTUnwrap(settings.viewerSubTitlesForTesting.firstIndex(of: title))
            categories.buttons[index].performClick(nil)
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
            XCTAssertEqual(window.frame, frame, "\(title): final window frame")
            for sample in recorder.frames {
                XCTAssertEqual(sample, frame, "\(title): intermediate move/resize")
            }
        }
    }

    /// A row that does not fit is a row the user cannot reach: panes have no
    /// scroller behind them.
    func testEveryPaneFitsItsHeight() throws {
        let controller = try makeWindow()
        let viewController = try viewController(of: controller)
        let heights = viewController.paneContentHeightsForTesting()
        XCTAssertEqual(heights.map(\.title), viewController.paneTitlesForTesting)
        for entry in heights {
            XCTAssertGreaterThanOrEqual(entry.available, SettingsMetrics.minPaneHeight - 0.5,
                                        "\(entry.title): the pane has a real size")
            XCTAssertLessThanOrEqual(entry.content, entry.available + 0.5,
                                     "\(entry.title): \(entry.content) pt of rows in "
                                       + "\(entry.available) pt of pane")
        }
    }

    func testEveryViewerSubTabFitsTheCard() throws {
        let controller = try makeWindow()
        let viewController = try select("看图", in: controller)
        let heights = viewController.viewerSubPaneHeightsForTesting()
        XCTAssertEqual(heights.map(\.title), viewController.viewerSubTitlesForTesting)
        for entry in heights {
            XCTAssertGreaterThan(entry.available, 0, "\(entry.title): the card has a real height")
            XCTAssertLessThanOrEqual(entry.content, entry.available + 0.5,
                                     "\(entry.title): \(entry.content) pt of rows in "
                                       + "\(entry.available) pt of card")
        }
    }

    func testNoControlIsClippedInAnyPane() throws {
        let controller = try makeWindow()
        let viewController = try viewController(of: controller)
        for title in viewController.paneTitlesForTesting {
            viewController.selectPane(title)
            controller.window?.contentView?.layoutSubtreeIfNeeded()
            let container = viewController.paneContainerForTesting
            for control in controls(in: container) where !isInsideScrollView(control) {
                let frame = container.convert(control.bounds, from: control)
                XCTAssertGreaterThan(frame.height, 0, "\(title): \(type(of: control)) has a real height")
                XCTAssertFalse(control.isHiddenOrHasHiddenAncestor, "\(title): hidden control")
                XCTAssertTrue(container.bounds.insetBy(dx: -0.5, dy: -0.5).contains(frame),
                              "\(title): \(type(of: control)) at \(frame) escapes \(container.bounds)")
            }
        }
    }

    /// Checkbox rows without their own label line up in the control column,
    /// exactly as the reference window's follow-up rows do.
    func testCheckboxRowsAlignWithTheControlsColumn() throws {
        let controller = try makeWindow()
        let viewController = try select("看图", in: controller)
        viewController.selectViewerSubPane("外观")
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        let container = try XCTUnwrap(viewController.viewerSubPaneView("外观"))
        let views = allViews(in: container)
        let popup = try XCTUnwrap(views.compactMap { $0 as? NSPopUpButton }.first)
        let groupControls = try XCTUnwrap(popup.superview)
        let controlColumnX = container.convert(groupControls.bounds, from: groupControls).minX
        for title in ["显示顶部文件名", "隐藏鸟瞰视图（右下角）"] {
            let checkbox = try XCTUnwrap(views.compactMap { $0 as? NSButton }.first { $0.title == title })
            let frame = container.convert(checkbox.bounds, from: checkbox)
            XCTAssertEqual(frame.minX, controlColumnX, accuracy: 0.5,
                           "\(title) belongs in the controls column")
            XCTAssertGreaterThan(frame.height, 0)
        }
    }

    /// Every pane and sub-tab is reachable from the strip, and the viewer keeps
    /// the reference window's six sub-tabs.
    func testNativeToolbarOffersEveryPaneAndViewerSubTab() throws {
        let controller = try makeWindow()
        let window = try XCTUnwrap(controller.window)
        let viewController = try viewController(of: controller)
        let toolbar = try XCTUnwrap(window.toolbar)
        XCTAssertEqual(window.toolbarStyle, .preference)
        XCTAssertEqual(toolbar.displayMode, .iconAndLabel)
        let items = toolbar.items.filter { $0.itemIdentifier.rawValue.hasPrefix("PicLight.Settings.") }
        XCTAssertEqual(items.map(\.label), ["通用", "看图", "高级", "快捷键", "格式关联", "关于"])
        XCTAssertTrue(items.allSatisfy { $0.image != nil && $0.action != nil })
        XCTAssertEqual(viewController.viewerSubTitlesForTesting,
                       ["一般", "外观", "浏览", "打开", "鼠标", "翻页"])
        let viewer = try XCTUnwrap(items.first { $0.label == "看图" })
        NSApp.sendAction(try XCTUnwrap(viewer.action), to: viewer.target, from: viewer)
        XCTAssertEqual(viewController.selectedPaneTitle, "看图")
        XCTAssertEqual(toolbar.selectedItemIdentifier, viewer.itemIdentifier)
        XCTAssertEqual(window.title, "看图")
    }

    func testGroupHeadingSharesTheFirstSettingRow() throws {
        let controller = try makeWindow()
        let settings = try select("看图", in: controller)
        settings.selectViewerSubPane("外观")
        settings.view.layoutSubtreeIfNeeded()
        let pane = try XCTUnwrap(settings.viewerSubPaneView("外观"))
        let labels = allViews(in: pane).compactMap { $0 as? NSTextField }
        let group = try XCTUnwrap(labels.first { $0.stringValue == "查看外观" })
        let setting = try XCTUnwrap(labels.first { $0.stringValue == "顶栏" })
        let groupFrame = pane.convert(group.bounds, from: group)
        let settingFrame = pane.convert(setting.bounds, from: setting)
        XCTAssertEqual(groupFrame.midY, settingFrame.midY, accuracy: 1,
                       "reference S03 places the group and first setting on the same line")
        XCTAssertLessThan(groupFrame.maxX, settingFrame.minX)
    }

    func testViewerCategoriesKeepTheSameCardHeightAndIncludeLiveFolderTable() throws {
        let controller = try makeWindow()
        let settings = try select("看图", in: controller)
        let height = settings.preferredContentHeight()
        for title in settings.viewerSubTitlesForTesting {
            settings.selectViewerSubPane(title)
            XCTAssertEqual(settings.preferredContentHeight(), height, accuracy: 1,
                           "switching a viewer category keeps the card geometry")
        }
        settings.selectViewerSubPane("打开")
        settings.view.layoutSubtreeIfNeeded()
        let pane = try XCTUnwrap(settings.viewerSubPaneView("打开"))
        XCTAssertTrue(settings.folderList.isDescendant(of: pane))
        XCTAssertTrue(settings.folderList.table.isDescendant(of: pane))
        XCTAssertNotNil(settings.folderList.addButton.image)
        XCTAssertNotNil(settings.folderList.removeButton.image)
        settings.selectPane("快捷键")
        XCTAssertEqual(settings.shortcutTable.tableColumns.map(\.title), ["操作", "键值", "类型"])
        XCTAssertEqual(settings.shortcutTable.numberOfRows, ViewerCommand.allCases.count)
    }

    /// The filename preference is gone; the drawer always shows names.
    func testTheFilenamePreferenceIsNoLongerOffered() throws {
        let controller = try makeWindow()
        let viewController = try viewController(of: controller)
        var titles: [String] = []
        for pane in viewController.paneTitlesForTesting {
            viewController.selectPane(pane)
            if pane == "看图" {
                for sub in viewController.viewerSubTitlesForTesting {
                    viewController.selectViewerSubPane(sub)
                    viewController.view.layoutSubtreeIfNeeded()
                    titles += allViews(in: viewController.paneContainerForTesting)
                        .compactMap { $0 as? NSPopUpButton }.flatMap { $0.itemTitles }
                }
            } else {
                viewController.view.layoutSubtreeIfNeeded()
                titles += allViews(in: viewController.paneContainerForTesting)
                    .compactMap { $0 as? NSPopUpButton }.flatMap { $0.itemTitles }
            }
        }
        // The enum is gone from the production code, so the old labels are spelled out here:
        // this is the check that a future change cannot quietly reintroduce the preference.
        for stale in ["从不", "始终", "悬停时"] {
            XCTAssertFalse(titles.contains(stale),
                           "“\(stale)” must not be offered any more")
        }
        // Sanity: the popups really were inspected — the browse pane keeps its sort key.
        XCTAssertTrue(titles.contains(ImageSortKey.allCases[0].localizedName),
                      "the browsing pane keeps its other popups")
    }
}
