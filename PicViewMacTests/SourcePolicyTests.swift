import XCTest
import AppKit
@testable import PicViewMac

/// Structural policies that are cheaper and more reliable to assert against the
/// production sources and live AppKit objects than through the UI.
///
/// The source scans read the repository through `#filePath`, so they always look
/// at the code that was actually compiled alongside this test.
final class SourcePolicyTests: XCTestCase {
    private static var repositoryRoot: URL {
        // .../PicViewMacTests/SourcePolicyTests.swift -> repository root
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private static func productionSources() throws -> [(name: String, text: String)] {
        let root = repositoryRoot.appendingPathComponent("PicViewMac")
        guard let enumerator = FileManager.default.enumerator(at: root,
                                                             includingPropertiesForKeys: nil) else {
            throw XCTSkip("production sources are not reachable from \(root.path)")
        }
        var sources: [(String, String)] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            sources.append((url.lastPathComponent, text))
        }
        XCTAssertGreaterThan(sources.count, 20, "the scan must actually see the production sources")
        return sources
    }

    private static func lines(in sources: [(name: String, text: String)],
                              containing needles: [String]) -> [String] {
        var hits: [String] = []
        for (name, text) in sources {
            for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let code = line.trimmingCharacters(in: .whitespaces)
                guard !code.hasPrefix("//"), !code.hasPrefix("///") else { continue }
                for needle in needles where line.contains(needle) {
                    hits.append("\(name):\(index + 1): \(code)")
                }
            }
        }
        return hits
    }

    // MARK: - Native tabs

    func testProductionCodeNeverUsesNativeWindowTabs() throws {
        let sources = try Self.productionSources()
        let hits = Self.lines(in: sources, containing: ["addTabbedWindow", "tabGroup", "tabbedWindows"])
        XCTAssertTrue(hits.isEmpty,
                      "native window tabs are forbidden, found:\n\(hits.joined(separator: "\n"))")
    }

    func testProductionCodeNeverUsesPanelsOrOverlayWindowsForChrome() throws {
        let sources = try Self.productionSources()
        let hits = Self.lines(in: sources, containing: ["NSPanel", "addChildWindow", "addChildWindow:ordered:"])
        XCTAssertTrue(hits.isEmpty,
                      "hover chrome must be subviews, never panels or child windows, found:\n"
                      + hits.joined(separator: "\n"))
    }

    func testProductionCodeUsesExactlyOneTopLevelWindowTypeForViewers() throws {
        let sources = try Self.productionSources()
        let windowSubclasses = sources.filter {
            $0.text.contains(": NSWindow {") || $0.text.contains(": NSWindow,")
        }
        XCTAssertEqual(windowSubclasses.count, 1,
                       "exactly one viewer window type may exist, found \(windowSubclasses.map(\.name))")
        XCTAssertEqual(windowSubclasses.first?.name, "ViewerWindow.swift")
    }

    // MARK: - Offline

    func testProductionCodeHasNoNetworkCodePaths() throws {
        let sources = try Self.productionSources()
        let hits = Self.lines(in: sources, containing: [
            "URLSession", "NSURLConnection", "CFNetwork", "Network.framework",
            "NWConnection", "URLRequest", "http://", "https://",
        ])
        XCTAssertTrue(hits.isEmpty,
                      "the app must work offline; no network code may exist, found:\n"
                      + hits.joined(separator: "\n"))
    }

    func testProductionCodeShipsNoThirdPartyImageDecoder() throws {
        let sources = try Self.productionSources()
        let hits = Self.lines(in: sources, containing: ["libwebp", "dwebp", "cwebp", "WebPDecoder", "import WebP"])
        XCTAssertTrue(hits.isEmpty,
                      "system ImageIO passes the WebP parity matrix, so no libwebp dependency is allowed, found:\n"
                      + hits.joined(separator: "\n"))
        // ImageIO remains the only type that actually conforms to the protocol.
        let conformance = try NSRegularExpression(
            pattern: "(struct|class|actor|enum)\\s+\\w+[^\\n]*:\\s*[^\\n]*\\bImageDecoding\\b")
        var conformingTypes: [String] = []
        for (name, text) in sources {
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            for match in conformance.matches(in: text, range: range) {
                if let hit = Range(match.range, in: text) {
                    conformingTypes.append("\(name): \(text[hit])")
                }
            }
        }
        XCTAssertEqual(conformingTypes.count, 1,
                       "only one decoder implementation may exist, found: \(conformingTypes)")
        XCTAssertTrue(conformingTypes.first?.hasPrefix("ImageIODecoder.swift") == true)
    }

    // MARK: - Appearance structure

    @MainActor
    func testChromeSurfacesUseTheSystemMaterialOrNativeGlass() {
        let expectedGlass = ProcessInfo.processInfo.isOperatingSystemAtLeast(
            OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0))
        for style in [MaterialHostView.Style.chrome, MaterialHostView.Style.drawer] {
            let host = MaterialHostView(style: style)
            XCTAssertEqual(host.usesNativeGlass, expectedGlass,
                           "glass must be chosen by an availability guard, matching the running OS")
            let usesSystemSurface = host.subviews.contains { subview in
                if subview is NSVisualEffectView { return true }
                if #available(macOS 26.0, *), subview is NSGlassEffectView { return true }
                return false
            }
            XCTAssertTrue(usesSystemSurface,
                          "the surface must be a system-provided view, never hand-drawn")
        }
    }

    func testGlassIsNotHandDrawn() throws {
        let sources = try Self.productionSources()
        let hits = Self.lines(in: sources, containing: [
            "CIGaussianBlur", "CABackdropLayer", "NSVisualEffectView.Material.underPageBackground" ,
            "blurRadius = ", "CIFilter(name:",
        ])
        XCTAssertTrue(hits.isEmpty,
                      "glass must come from the system, not from a hand-built blur, found:\n"
                      + hits.joined(separator: "\n"))
    }

    @MainActor
    func testImageCanvasIsNotWrappedInGlassOrMaterial() {
        let viewer = ViewerViewController()
        _ = viewer.view
        let canvas = viewer.chromeSnapshot.canvasView
        XCTAssertFalse(canvas is MaterialHostView,
                       "the image canvas itself must never sit behind a glass surface")
        XCTAssertFalse(canvas is NSVisualEffectView)
        XCTAssertTrue(canvas is ImageCanvasView)
    }

    func testAppearancePolicyIsPureAndTestable() {
        XCTAssertNil(ViewerAppearanceMode.system.nsAppearance,
                     "Follow System must not force a global appearance")
        XCTAssertNotNil(ViewerAppearanceMode.black.nsAppearance)
        XCTAssertNotNil(ViewerAppearanceMode.darkGray.nsAppearance)
        XCTAssertNotNil(ViewerAppearanceMode.white.nsAppearance)
        XCTAssertEqual(ViewerAppearanceMode.system.localizedName, "跟随系统")
    }

    func testReduceMotionAndReduceTransparencyHaveFallbackPolicies() {
        // The decision functions are pure, so both branches are verifiable even
        // though the system switches themselves cannot be toggled from a test.
        XCTAssertEqual(AccessibilityAppearance.chromeFadeDuration(reduceMotion: false), 0.3, accuracy: 0.0001)
        XCTAssertEqual(AccessibilityAppearance.chromeFadeDuration(reduceMotion: true), 0, accuracy: 0.0001,
                       "Reduce Motion collapses transitions instead of fighting them")
        XCTAssertEqual(AccessibilityAppearance.chromeAnimationDuration(reduceMotion: false), 0.15, accuracy: 0.0001)
        XCTAssertEqual(AccessibilityAppearance.chromeAnimationDuration(reduceMotion: true), 0, accuracy: 0.0001)
        XCTAssertFalse(AccessibilityAppearance.surfaceIsTranslucent(reduceTransparency: true),
                       "Reduce Transparency must drop the translucent material")
        XCTAssertTrue(AccessibilityAppearance.surfaceIsTranslucent(reduceTransparency: false))

        // The live values are read from the workspace, not hard-coded.
        _ = AccessibilityAppearance.reduceTransparency
        _ = AccessibilityAppearance.reduceMotion
    }

    @MainActor
    func testAppearanceChangePathIsWiredToTheWindow() {
        let controller = ViewerWindowController()
        defer { controller.close() }
        let viewer = controller.viewerViewController
        _ = viewer.view
        guard let window = controller.window else { return XCTFail("no window") }

        XCTAssertNil(window.appearance, "the default is Follow System: nothing is forced")

        AppSettings.shared.appearance = .black
        viewer.applySettings()
        XCTAssertEqual(window.appearance?.name, .darkAqua)

        AppSettings.shared.appearance = .white
        viewer.applySettings()
        XCTAssertEqual(window.appearance?.name, .aqua)

        AppSettings.shared.appearance = .system
        viewer.applySettings()
        XCTAssertNil(window.appearance, "switching back to Follow System clears the override")
    }
}
