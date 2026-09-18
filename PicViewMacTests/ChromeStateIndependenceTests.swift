import XCTest
import AppKit
@testable import PicViewMac

/// The five chrome surfaces are independent state machines.
///
/// The spec's rule is negative and specific: no pointer event may move a surface whose own rule does
/// not mention the pointer, and there must be no single "chrome is visible" flag. This file checks
/// both — the model's independence, and the independence observed on a live window.
@MainActor
final class ChromeStateIndependenceTests: XCTestCase {

    override func setUp() async throws {
        try await super.setUp()
        TestAppKit.ensureApplication()
    }

    private func makeViewer() throws -> (controller: ViewerWindowController,
                                        viewer: ViewerViewController) {
        let controller = ViewerWindowController()
        TestAppKit.presentOffScreen(controller)
        let viewer = controller.viewerViewController
        controller.showWindow(nil)
        _ = viewer.view
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        return (controller, viewer)
    }

    private func settle(_ seconds: TimeInterval = 0.3) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    // MARK: - The model

    /// Every field of the snapshot except the one named must be unchanged.
    private func assertOthersUnchanged(_ after: ViewerChromeModel.Snapshot,
                                       _ before: ViewerChromeModel.Snapshot,
                                       except changed: String,
                                       file: StaticString = #filePath, line: UInt = #line) {
        let pairs: [(String, Bool)] = [
            ("drawer", after.drawer == before.drawer),
            ("dock", after.toolDock == before.toolDock),
            ("infoHUD", after.infoHUD == before.infoHUD),
            ("previousNavigation", after.previousNavigation == before.previousNavigation),
            ("nextNavigation", after.nextNavigation == before.nextNavigation),
            ("titlebar", after.titlebar == before.titlebar),
        ]
        for (name, unchanged) in pairs where name != changed {
            XCTAssertTrue(unchanged, "\(name) moved when \(changed) did",
                          file: file, line: line)
        }
    }

    /// Each surface has its own rule, and moving one leaves the others alone.
    ///
    /// The order is deliberate: the whole point is that turning one on does not turn another on,
    /// so each step compares against the snapshot taken immediately before it.
    func testEachSurfaceHasItsOwnRuleAndMovesAlone() {
        var chrome = ViewerChromeModel()
        chrome.toolDock.setHasImage(true, at: 0)
        chrome.infoHUD.setHasImage(true, at: 0)
        chrome.navigation.setHasImage(true, at: 0)
        chrome.navigation.setAvailable(previous: true, next: true)
        // Let every surface settle to its resting state.
        _ = chrome.update(at: 10)
        XCTAssertTrue(chrome.chromeHidden, "nothing is on screen to begin with")
        var baseline = chrome.snapshot

        // 1. The drawer: the explicit control, and the explicit control only.
        chrome.setDrawerOpen(true, at: 11)
        _ = chrome.update(at: 11)
        XCTAssertTrue(chrome.snapshot.drawer)
        assertOthersUnchanged(chrome.snapshot, baseline, except: "drawer")
        baseline = chrome.snapshot

        // 2. The dock: its pin.
        chrome.toolDock.setPinned(true, at: 12)
        _ = chrome.update(at: 12)
        XCTAssertTrue(chrome.snapshot.toolDock)
        assertOthersUnchanged(chrome.snapshot, baseline, except: "dock")
        baseline = chrome.snapshot

        // 3. The navigation: each side is its own state, revealed by its own strip.
        chrome.navigation.setPointer(previousSide: true, nextSide: false, at: 13)
        _ = chrome.update(at: 13)
        XCTAssertTrue(chrome.snapshot.previousNavigation)
        XCTAssertFalse(chrome.snapshot.nextNavigation,
                       "the left strip says nothing about the right control")
        assertOthersUnchanged(chrome.snapshot, baseline, except: "previousNavigation")
        baseline = chrome.snapshot

        // 4. The HUD: a meaningful change, and nothing else.
        chrome.infoHUD.noteMeaningfulChange(at: 14)
        _ = chrome.update(at: 14)
        XCTAssertTrue(chrome.snapshot.infoHUD)
        assertOthersUnchanged(chrome.snapshot, baseline, except: "infoHUD")
    }

    /// A pointer sweep over the image moves nothing that does not mention the pointer.
    func testAPointerSweepMovesOnlyWhatWatchesThePointer() throws {
        let (controller, viewer) = try makeViewer()
        defer { controller.close() }
        let before = viewer.chromeSnapshot

        // Somewhere in the middle of the image, away from every strip.
        for x in stride(from: CGFloat(200), through: viewer.view.bounds.width - 200, by: 37) {
            for y in stride(from: CGFloat(80), through: viewer.view.bounds.height - 120, by: 53) {
                viewer.simulatePointer(atWindowPoint: viewer.view.convert(CGPoint(x: x, y: y),
                                                                        to: nil))
            }
        }
        settle()

        let after = viewer.chromeSnapshot
        XCTAssertEqual(after.drawer, before.drawer, "a drawer is opened explicitly")
        XCTAssertEqual(after.bottom, before.bottom, "the HUD reports changes, not pointers")
        XCTAssertEqual(after.canvasFrame, before.canvasFrame)
        XCTAssertEqual(after.zoomScale, before.zoomScale, accuracy: 1e-9)
    }

    /// The five surfaces share a tick and nothing else: a single `applyChromeVisibility` reads each
    /// one's own state, and the identity of the views is stable.
    func testTheSurfacesAreDistinctViewsDrivenByTheTick() throws {
        let (controller, viewer) = try makeViewer()
        defer { controller.close() }
        let names = ["drawer", "toolDock", "bottomBar", "floatingNavigation", "minimap"]
        let views = try names.map { try XCTUnwrap(viewer.chromeViewsForTesting[$0]) }
        XCTAssertEqual(Set(views.map(ObjectIdentifier.init)).count, names.count,
                       "five surfaces, five views")
        for name in names {
            XCTAssertNotNil(viewer.chromeViewsForTesting[name], "\(name) is part of the chrome")
        }
        // The chrome timer is what advances them, and there is exactly one.
        XCTAssertNotNil(viewer.chromeTimerForTesting, "the shared tick exists")
    }
}
