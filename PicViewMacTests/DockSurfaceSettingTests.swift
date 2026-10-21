import XCTest
import AppKit
@testable import PicViewMac

/// The tool dock's surface is the user's choice: frosted material, native Liquid Glass, or the left
/// column's material.
@MainActor
final class DockSurfaceSettingTests: XCTestCase {

    override func setUp() async throws {
        try await super.setUp()
        TestAppKit.ensureApplication()
    }

    private func settle(_ seconds: TimeInterval = 0.4) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    /// The setting round-trips, and defaults to the glass the dock has always used.
    func testTheSettingRoundTripsAndDefaultsToLiquidGlass() throws {
        let suite = "dock-surface-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertEqual(AppSettings(defaults: defaults).dockSurface, .liquidGlass)
        let settings = AppSettings(defaults: defaults)
        for surface in DockSurface.allCases {
            settings.dockSurface = surface
            XCTAssertEqual(AppSettings(defaults: defaults).dockSurface, surface,
                           "\(surface) survives a reload")
        }
        defaults.set("nonsense", forKey: "dockSurface")
        XCTAssertEqual(AppSettings(defaults: defaults).dockSurface, .liquidGlass,
                       "an unknown value falls back to the default")
    }

    /// Each choice is a different system surface, and the dock's own content survives the swap.
    func testEachChoiceIsADifferentSurface() throws {
        let dock = ViewerToolDockView()
        dock.frame = NSRect(x: 0, y: 0, width: 400, height: 52)
        dock.layoutSubtreeIfNeeded()

        dock.applySurface(.frosted)
        XCTAssertEqual((dock as MaterialHostView).style, .hud, "frosted is the plain HUD material")
        XCTAssertFalse(dock.usesNativeGlass, "not glass")
        XCTAssertTrue(dock.usesSystemMaterial)

        dock.applySurface(.liquidGlass)
        XCTAssertEqual((dock as MaterialHostView).style, .dock)
        let glassAvailable = ProcessInfo.processInfo.isOperatingSystemAtLeast(
            OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0))
        XCTAssertEqual(dock.usesNativeGlass, glassAvailable,
                       "Liquid Glass is the native glass where the OS has it")

        dock.applySurface(.sidebar)
        XCTAssertEqual((dock as MaterialHostView).style, .sidebar)
        XCTAssertTrue(dock.isSidebarMaterial, "and the left column's material is that material")
        XCTAssertFalse(dock.usesNativeGlass)

        // The surface is the bottom layer, so the buttons and readouts are still on top and usable.
        XCTAssertEqual(dock.subviews.first.map { $0 is NSVisualEffectView || String(describing: type(of: $0)).contains("Glass") }, true,
                       "the surface is the dock's first subview, under its content")
    }

    /// A viewer puts the setting on its dock, and follows a change.
    func testTheViewerAppliesTheSettingToItsDock() throws {
        let settings = AppSettings.shared
        let original = settings.dockSurface
        settings.dockSurface = .frosted
        defer { settings.dockSurface = original }

        let controller = ViewerWindowController()
        TestAppKit.presentOffScreen(controller)
        let viewer = controller.viewerViewController
        _ = viewer.view
        defer { TestAppKit.close(controller) }
        settle()

        viewer.applySettings()
        let dock = try XCTUnwrap(viewer.chromeViewsForTesting["toolDock"] as? ViewerToolDockView)
        XCTAssertEqual((dock as MaterialHostView).style, .hud, "the dock takes the configured surface")

        settings.dockSurface = .sidebar
        viewer.applySettings()
        settle()
        XCTAssertEqual((dock as MaterialHostView).style, .sidebar, "and follows a change")
        XCTAssertTrue(dock.isSidebarMaterial)
    }
}
