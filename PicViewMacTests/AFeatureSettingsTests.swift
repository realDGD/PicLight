import XCTest
import AppKit
@testable import PicViewMac

@MainActor
final class AFeatureSettingsTests: XCTestCase {
    func testRemovingOneShortcutRemainsRemovedAfterReload() {
        let suite = "piclight.a-shortcuts.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let shortcuts = ShortcutStore(defaults: defaults)
        XCTAssertTrue(shortcuts.setShortcut(nil, for: .toggleMirror))
        let reloaded = ShortcutStore(defaults: defaults)
        XCTAssertNil(reloaded.shortcut(for: .toggleMirror),
                     "a removed shortcut must not reappear at the next launch")
        XCTAssertNotNil(reloaded.shortcut(for: .nextImage))
    }
    func testBulkShortcutChangesPersistAndBothDeleteKeysMatch() {
        let suite = "piclight.a-bulk.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let shortcuts = ShortcutStore(defaults: defaults)
        shortcuts.clearAll()
        let cleared = ShortcutStore(defaults: defaults)
        XCTAssertTrue(ViewerCommand.allCases.allSatisfy { cleared.shortcut(for: $0) == nil })
        cleared.restoreDefaults()
        let restored = ShortcutStore(defaults: defaults)
        XCTAssertEqual(restored.shortcut(for: .randomImage)?.key, "r")
        XCTAssertEqual(restored.shortcut(for: .moveToTrash)?.modifiers, [])
        XCTAssertEqual(restored.shortcut(for: .moveToTrashWithoutConfirmation)?.modifiers, [.command])
        XCTAssertEqual(ShortcutDefinition(key: String(UnicodeScalar(NSDeleteFunctionKey)!), modifiers: []),
                       restored.shortcut(for: .moveToTrash))
    }

    func testNewSettingsPersistWithBoundedSensitivityAndNormalizedExclusions() {
        let suite = "piclight.a-settings.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        XCTAssertTrue(settings.quitAfterLastWindowClosed)
        XCTAssertFalse(settings.loopBrowsing)
        XCTAssertEqual(settings.wheelZoomSensitivity, 0.0015)
        settings.quitAfterLastWindowClosed = false
        settings.loopBrowsing = true
        settings.defaultAlwaysOnTop = true
        settings.confirmBeforeTrash = true
        settings.hideMinimap = true
        settings.titlebar = .alwaysHidden
        settings.dockDisplayPolicy = .alwaysVisible
        settings.navigationDisplayPolicy = .alwaysHidden
        settings.doubleClickMode = .folderBrowser
        settings.excludedExtensions = [".PNG", "*.JpG", "gif"]
        settings.wheelZoomSensitivity = .infinity
        XCTAssertEqual(settings.wheelZoomSensitivity, 0.0015)
        settings.wheelZoomSensitivity = 1
        XCTAssertEqual(settings.wheelZoomSensitivity, 0.02)
        let next = AppSettings(defaults: defaults)
        XCTAssertFalse(next.quitAfterLastWindowClosed)
        XCTAssertTrue(next.loopBrowsing && next.defaultAlwaysOnTop && next.confirmBeforeTrash && next.hideMinimap)
        XCTAssertEqual(next.titlebar, .alwaysHidden)
        XCTAssertEqual(next.dockDisplayPolicy, .alwaysVisible)
        XCTAssertEqual(next.navigationDisplayPolicy, .alwaysHidden)
        XCTAssertEqual(next.doubleClickMode, .folderBrowser)
        XCTAssertEqual(next.excludedExtensions, ["png", "jpg", "gif"])
        XCTAssertEqual(AppSettings.normalizeExcludedExtensions(".PNG， *.jpg;GIF jpg /bad"), ["png", "jpg", "gif"])
    }

    func testSensitivityChangesWheelFactorWithoutChangingAnchor() {
        var low = GestureRouter(wheelMode: .zoom), high = GestureRouter(wheelMode: .zoom)
        low.wheelZoomSensitivity = 0.0015
        high.wheelZoomSensitivity = 0.01
        let point = CGPoint(x: 17, y: 28)
        guard case let .zoom(lowFactor, lowAnchor) = low.routeWheel(deltaY: -20, deltaX: 0, anchor: point),
              case let .zoom(highFactor, highAnchor) = high.routeWheel(deltaY: -20, deltaX: 0, anchor: point) else {
            return XCTFail("wheel should produce zoom intent")
        }
        XCTAssertGreaterThan(highFactor, lowFactor)
        XCTAssertEqual(lowAnchor, point)
        XCTAssertEqual(highAnchor, point)
    }

}
