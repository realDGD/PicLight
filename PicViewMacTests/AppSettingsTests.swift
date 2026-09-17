import XCTest
import AppKit
@testable import PicViewMac

@MainActor
final class AppSettingsTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var settings: AppSettings!

    override func setUp() async throws {
        try await super.setUp()
        TestAppKit.ensureApplication()
        suiteName = "picviewmac.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        settings = AppSettings(defaults: defaults)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        try await super.tearDown()
    }

    func testDefaultsMatchTheSpecTable() {
        XCTAssertEqual(settings.thumbnailFilenames, .hover)
        XCTAssertEqual(settings.sortKey, .filename)
        XCTAssertEqual(settings.sortDirection, .ascending)
        XCTAssertEqual(settings.openBehavior, .newWindow)
        XCTAssertTrue(settings.showTopFilename)
        XCTAssertEqual(settings.bottomFields, [.index, .zoom, .dimensions])
        XCTAssertEqual(settings.windowSizing, .rememberLastSize)
        XCTAssertEqual(settings.wheelMode, .zoom)
        XCTAssertEqual(settings.swipeMode, .smart)
        XCTAssertEqual(settings.doubleClickMode, .fitDoubleFit)
        XCTAssertTrue(settings.autoplayAnimations)
        XCTAssertEqual(settings.animationLoop, .followSource)
        XCTAssertEqual(settings.deleteFollowUp, .smart)
        XCTAssertEqual(settings.appearance, .system)
        XCTAssertFalse(settings.immersive)
    }

    func testValuesPersistAcrossInstances() {
        settings.thumbnailFilenames = .always
        settings.sortKey = .fileSize
        settings.sortDirection = .descending
        settings.openBehavior = .reuseCurrent
        settings.wheelMode = .pan
        settings.swipeMode = .alwaysSwitch
        settings.doubleClickMode = .actualPixels
        settings.autoplayAnimations = false
        settings.showTopFilename = false
        settings.bottomFields = [.index, .colorSpace]
        settings.appearance = .black

        let reloaded = AppSettings(defaults: defaults)
        XCTAssertEqual(reloaded.thumbnailFilenames, .always)
        XCTAssertEqual(reloaded.sortKey, .fileSize)
        XCTAssertEqual(reloaded.sortDirection, .descending)
        XCTAssertEqual(reloaded.openBehavior, .reuseCurrent)
        XCTAssertEqual(reloaded.wheelMode, .pan)
        XCTAssertEqual(reloaded.swipeMode, .alwaysSwitch)
        XCTAssertEqual(reloaded.doubleClickMode, .actualPixels)
        XCTAssertFalse(reloaded.autoplayAnimations)
        XCTAssertFalse(reloaded.showTopFilename)
        XCTAssertEqual(reloaded.bottomFields, [.index, .colorSpace])
        XCTAssertEqual(reloaded.appearance, .black)
    }

    func testFollowingTheSystemNeverForcesAnAppearance() {
        XCTAssertNil(ViewerAppearanceMode.system.nsAppearance,
                     "Follow System must not force NSApp.appearance")
        XCTAssertNotNil(ViewerAppearanceMode.black.nsAppearance)
        XCTAssertNotNil(ViewerAppearanceMode.white.nsAppearance)
    }

    func testLastWindowSizeRoundTripsAndRejectsGarbage() {
        XCTAssertNil(settings.lastWindowSize)
        settings.lastWindowSize = CGSize(width: 1024, height: 768)
        XCTAssertEqual(settings.lastWindowSize, CGSize(width: 1024, height: 768))
        defaults.set("nonsense", forKey: "lastWindowSize")
        XCTAssertNil(settings.lastWindowSize)
    }

    func testUnknownBottomFieldValuesFallBackToTheDefaultSet() {
        defaults.set(["nonsense"], forKey: "bottomFields")
        XCTAssertEqual(AppSettings(defaults: defaults).bottomFields, [.index, .zoom, .dimensions])
    }
}

@MainActor
final class ShortcutStoreTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var store: ShortcutStore!

    override func setUp() async throws {
        try await super.setUp()
        TestAppKit.ensureApplication()
        suiteName = "picviewmac.shortcuts.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        store = ShortcutStore(defaults: defaults)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        try await super.tearDown()
    }

    func testDefaultsCoverTheCoreViewerCommands() {
        for command in [ViewerCommand.nextImage, .previousImage, .zoomToFit,
                        .zoomActualPixels, .zoomDoubleFit, .rotateClockwise,
                        .toggleMirror, .moveToTrash, .togglePlayback,
                        .nextPage, .previousPage, .showImageInfo] {
            XCTAssertNotNil(store.shortcut(for: command), "\(command) needs a default shortcut")
        }
    }

    func testSpaceTogglesPlaybackAndArrowsNavigate() {
        XCTAssertEqual(store.shortcut(for: .togglePlayback)?.key, " ")
        XCTAssertEqual(store.shortcut(for: .nextImage)?.key, String(UnicodeScalar(NSRightArrowFunctionKey)!))
        XCTAssertEqual(store.shortcut(for: .previousImage)?.key, String(UnicodeScalar(NSLeftArrowFunctionKey)!))
    }

    func testFixedSystemShortcutsAreNotCustomizable() {
        for command in [ViewerCommand.open, .close, .settings, .toggleFullScreen] {
            XCTAssertTrue(command.isFixedSystemShortcut, "\(command) must stay a system shortcut")
        }
        XCTAssertFalse(ViewerCommand.rotateClockwise.isFixedSystemShortcut)
    }

    func testConflictingShortcutIsRejectedAndNothingChanges() {
        let taken = ShortcutDefinition(key: "r", modifiers: [.command])
        XCTAssertEqual(store.conflictingCommand(for: taken, excluding: .toggleMirror), .rotateClockwise)

        let before = store.shortcut(for: .toggleMirror)
        let accepted = store.setShortcut(taken, for: .toggleMirror)
        XCTAssertFalse(accepted, "a conflict must be rejected, not silently override the other command")
        XCTAssertEqual(store.shortcut(for: .toggleMirror), before)
        XCTAssertEqual(store.shortcut(for: .rotateClockwise), taken)
    }

    func testNonConflictingShortcutIsAcceptedAndPersisted() {
        let custom = ShortcutDefinition(key: "j", modifiers: [.command, .option])
        XCTAssertTrue(store.setShortcut(custom, for: .toggleMirror))
        XCTAssertEqual(store.shortcut(for: .toggleMirror), custom)

        let reloaded = ShortcutStore(defaults: defaults)
        XCTAssertEqual(reloaded.shortcut(for: .toggleMirror), custom)
    }

    func testShortcutCanBeCleared() {
        XCTAssertTrue(store.setShortcut(nil, for: .toggleMirror))
        XCTAssertNil(store.shortcut(for: .toggleMirror))
    }

    func testDisplayStringUsesStandardModifierGlyphs() {
        let definition = ShortcutDefinition(key: "r", modifiers: [.command, .shift])
        XCTAssertEqual(definition.displayString, "⇧⌘R")
    }

    func testModifierSetBridgesToEventFlags() {
        let definition = ShortcutDefinition(key: "m", modifiers: [.command, .option])
        XCTAssertTrue(definition.modifiers.eventFlags.contains(.command))
        XCTAssertTrue(definition.modifiers.eventFlags.contains(.option))
        XCTAssertFalse(definition.modifiers.eventFlags.contains(.shift))
    }
}
