import XCTest
import AppKit
@testable import PicViewMac

/// The auto-hiding titlebar: three states, two reveal zones, and the reasons not to hide.
///
/// The contract the redesign changes is "the standard titlebar is always visible". Everything the
/// old contract protected is still checked here — the window stays an ordinary titled `NSWindow`
/// and the controls stay AppKit's own — but the default is now that the bar gets out of the way of
/// the picture and comes back when the pointer asks for it.
@MainActor
final class TitlebarVisibilityTests: XCTestCase {

    override func setUp() async throws {
        try await super.setUp()
        TestAppKit.ensureApplication()
    }

    // MARK: - Default and migration

    /// Auto-hide is the default for a fresh install…
    func testAutoHideIsTheDefault() {
        let suiteName = "titlebar-visibility-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.titlebar, .autoHide)
        XCTAssertEqual(TitlebarBehavior.autoHide.localizedName, "自动隐藏")
        XCTAssertEqual(TitlebarBehavior.alwaysVisible.localizedName, "始终显示")
    }

    /// …and for an install that has never written the key, which is the same thing here: the key is
    /// new, so a user who had no setting reads the default. A user who *has* chosen keeps it.
    func testAnExistingExplicitChoiceIsPreserved() {
        let suiteName = "titlebar-visibility-migration-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        // Nothing written: the default.
        XCTAssertEqual(AppSettings(defaults: defaults).titlebar, .autoHide)

        // The user chooses always-visible, and a later launch must not take it away.
        AppSettings(defaults: defaults).titlebar = .alwaysVisible
        XCTAssertEqual(AppSettings(defaults: defaults).titlebar, .alwaysVisible)

        // A raw value written by hand is read too.
        defaults.set("alwaysVisible", forKey: "titlebar")
        XCTAssertEqual(AppSettings(defaults: defaults).titlebar, .alwaysVisible)
    }

    // MARK: - The three states

    /// Zone A reveals only the traffic lights; zone B reveals the whole titlebar.
    func testZoneARevealsOnlyTheTrafficLightsAndZoneBPromotes() {
        var model = TitlebarVisibilityModel()
        XCTAssertEqual(model.state, .hidden, "the default is a titlebar that is away")
        XCTAssertFalse(model.showsTrafficLights)
        XCTAssertFalse(model.showsTitlebarChrome)

        model.setPointer(inTrafficLightsZone: true, inTitlebarZone: false, at: 0)
        XCTAssertEqual(model.state, .trafficLightsOnly)
        XCTAssertTrue(model.showsTrafficLights, "the controls are what zone A is for")
        XCTAssertFalse(model.showsTitlebarChrome, "and it must not bring the whole bar")

        // Sliding from A into B promotes.
        model.setPointer(inTrafficLightsZone: false, inTitlebarZone: true, at: 0.1)
        XCTAssertEqual(model.state, .full)
        XCTAssertTrue(model.showsTrafficLights)
        XCTAssertTrue(model.showsTitlebarChrome)
    }

    /// B directly reveals the whole bar, without passing through A.
    func testZoneBRevealsTheWholeTitlebarDirectly() {
        var model = TitlebarVisibilityModel()
        model.setPointer(inTrafficLightsZone: false, inTitlebarZone: true, at: 0)
        XCTAssertEqual(model.state, .full)
    }

    /// Sliding back from B into A does not demote: a bar that collapsed while the pointer travelled
    /// along it would be unusable.
    func testMovingFromBIntoADoesNotDemote() {
        var model = TitlebarVisibilityModel()
        model.setPointer(inTrafficLightsZone: false, inTitlebarZone: true, at: 0)
        XCTAssertEqual(model.state, .full)

        model.setPointer(inTrafficLightsZone: true, inTitlebarZone: false, at: 0.1)
        XCTAssertEqual(model.state, .full, "the bar stays up")
    }

    /// The hide delay is the spec's 0.7 s, and it is measured from the pointer leaving.
    func testItHidesSevenTenthsOfASecondAfterThePointerLeaves() {
        XCTAssertEqual(TitlebarVisibilityModel.Timing().hideDelay, 0.7, accuracy: 1e-9)
        var model = TitlebarVisibilityModel()
        model.setPointer(inTrafficLightsZone: false, inTitlebarZone: true, at: 1.0)

        model.setPointer(inTrafficLightsZone: false, inTitlebarZone: false, at: 1.0)
        XCTAssertEqual(model.state, .full, "leaving does not hide it immediately")
        model.update(at: 1.0 + model.timing.hideDelay - 0.05)
        XCTAssertEqual(model.state, .full)
        XCTAssertTrue(model.update(at: 1.0 + model.timing.hideDelay + 0.05))
        XCTAssertEqual(model.state, .hidden)
    }

    /// Never hiding while a drag, a sheet or full screen is in progress, and no countdown is left
    /// running to fire the moment the block lifts.
    func testItDoesNotHideWhileBlocked() {
        for reason in [TitlebarVisibilityModel.BlockReason.windowDrag, .sheet, .fullScreen] {
            var model = TitlebarVisibilityModel()
            model.setPointer(inTrafficLightsZone: false, inTitlebarZone: true, at: 0)
            model.setBlocked(reason, true, at: 0.1)
            // Leaving the zone while blocked.
            model.setPointer(inTrafficLightsZone: false, inTitlebarZone: false, at: 0.5)
            for step in 1...20 { model.update(at: 0.5 + Double(step) * 0.5) }
            XCTAssertEqual(model.state, .full, "\(reason) must keep the titlebar up")

            model.setBlocked(reason, false, at: 11)
            model.update(at: 11)
            XCTAssertEqual(model.state, .full,
                           "\(reason): lifting the block must not hide it instantly either")
            model.update(at: 11 + model.timing.hideDelay + 0.05)
            XCTAssertEqual(model.state, .hidden, "\(reason): and then the normal delay applies")
        }
    }

    /// Always-visible mode ignores the pointer entirely.
    func testAlwaysVisibleModeNeverHides() {
        var model = TitlebarVisibilityModel()
        model.setAutoHiding(false, at: 0)
        XCTAssertEqual(model.state, .full)
        XCTAssertTrue(model.showsTrafficLights)
        XCTAssertTrue(model.showsTitlebarChrome)

        model.setPointer(inTrafficLightsZone: false, inTitlebarZone: false, at: 0.1)
        for step in 1...20 { model.update(at: 0.1 + Double(step) * 0.5) }
        XCTAssertEqual(model.state, .full, "the pointer is not a factor in this mode")

        // And switching back to auto-hide puts it under the pointer's rules again.
        model.setAutoHiding(true, at: 11)
        model.setPointer(inTrafficLightsZone: false, inTitlebarZone: false, at: 11)
        model.update(at: 11 + model.timing.hideDelay + 0.05)
        XCTAssertEqual(model.state, .hidden)
    }

    /// Immersive mode blocks it through the same mechanism as full screen, so entering immersive
    /// does not drop the titlebar into a state the pointer would then have to fix.
    func testImmersiveModeBlocksHiding() {
        var chrome = ViewerChromeModel()
        chrome.titlebar.setPointer(inTrafficLightsZone: false, inTitlebarZone: true, at: 0)
        XCTAssertEqual(chrome.snapshot.titlebar, .full)

        chrome.setImmersive(true, at: 0.5)
        chrome.titlebar.setPointer(inTrafficLightsZone: false, inTitlebarZone: false, at: 0.6)
        _ = chrome.update(at: 5)
        XCTAssertEqual(chrome.snapshot.titlebar, .full,
                       "immersive suppresses the viewer's own chrome, not the window's titlebar")
    }

    // MARK: - Zones

    /// Zone A is over the real controls, and B is everything else along the top.
    func testTheZonesAreDerivedFromTheTrafficLightControls() {
        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 700)
        let lights = CGRect(x: 7, y: 672, width: 52, height: 14)
        let zones = TitlebarZoneGeometry.zones(in: bounds, trafficLights: lights)

        XCTAssertEqual(zones.a.maxX, lights.maxX + 8, accuracy: 0.5,
                       "zone A reaches just past the controls")
        XCTAssertEqual(zones.a.maxY, bounds.maxY, "both strips are at the very top")
        XCTAssertEqual(zones.a.height, TitlebarZoneGeometry.zoneHeight, accuracy: 0.5)
        XCTAssertEqual(zones.b.minX, zones.a.maxX, "B starts where A ends")
        XCTAssertEqual(zones.b.maxX, bounds.maxX, "and B runs to the other edge")
        XCTAssertTrue(zones.a.intersection(zones.b).isEmpty, "the zones must not overlap")
    }

    /// Without the controls to measure (no window yet, or the system has taken them), zone A falls
    /// back to the standard macOS leading inset rather than to nothing.
    func testZoneAFallsBackToTheStandardInset() {
        let zones = TitlebarZoneGeometry.zones(in: CGRect(x: 0, y: 0, width: 800, height: 600),
                                              trafficLights: nil)
        XCTAssertEqual(zones.a.width, TitlebarZoneGeometry.fallbackTrafficLightWidth, accuracy: 0.5)
        XCTAssertGreaterThan(zones.a.width, 0)
        XCTAssertEqual(zones.b.maxX, 800, accuracy: 0.5)
    }

    /// The zone height is the spec's "narrow upward reveal region", not a large fraction of the
    /// image: it must be possible to move the pointer near the top without arming anything.
    func testTheTopStripIsNarrow() {
        XCTAssertLessThanOrEqual(TitlebarZoneGeometry.zoneHeight, 40)
        XCTAssertGreaterThanOrEqual(TitlebarZoneGeometry.zoneHeight, 20)
    }

    // MARK: - Reduce Motion

    /// There is no slide to disable: the state is a direct change to AppKit's own titlebar
    /// properties, which is the strongest possible form of "Reduce Motion: no slide".
    func testReduceMotionHasNothingToDisable() {
        // The model carries no animation parameters at all — only the hide delay, which is timing
        // rather than motion.
        let model = TitlebarVisibilityModel()
        XCTAssertEqual(model.timing.hideDelay, 0.7, accuracy: 1e-9)
        // And the window applies a state by setting three properties, never by animating a frame.
        let window = ViewerWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300))
        defer { window.close() }
        window.applyTitlebarState(.trafficLightsOnly)
        XCTAssertTrue(window.titlebarAppearsTransparent)
        XCTAssertEqual(window.titleVisibility, .hidden)
        XCTAssertEqual(window.titlebarState, .trafficLightsOnly)
    }
}
