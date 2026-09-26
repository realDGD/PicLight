import XCTest
import AppKit
@testable import PicViewMac

/// Test-order independence helper.
///
/// `NSApp` is an implicitly unwrapped optional, so touching it before any AppKit
/// object exists crashes with a nil unwrap - which is exactly what happens when a
/// single AppKit-touching test is run on its own via `--filter`, and what made an
/// otherwise green suite fail intermittently under `xcodebuild`.
enum TestAppKit {
    @MainActor
    static func ensureApplication() {
        _ = NSApplication.shared
        NSApplication.shared.setActivationPolicy(.accessory)
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    /// Keeps test windows off the visible display.
    ///
    /// The suite drives real AppKit windows, and a run creates dozens of them; left
    /// on screen they flash in front of whoever is using the machine. Moving a
    /// presented window out of the way keeps every behaviour that matters (view
    /// lifecycle, layout, tracking, hit-testing) while never compositing it in
    /// sight. Acceptance runs of the packaged app are separate and stay visible.
    @MainActor
    static func moveOffScreen(_ window: NSWindow?) {
        window?.setFrameOrigin(NSPoint(x: -30000, y: -30000))
    }

    /// Presents a window for layout work without showing it to the user.
    @MainActor
    static func presentOffScreen(_ controller: ViewerWindowController) {
        controller.present()
        moveOffScreen(controller.window)
    }

    /// Lets the animations AppKit started finish before the test moves on.
    ///
    /// `NSView.animator()` fades are driven by AppKit, and when the main thread is not servicing the
    /// run loop they run on the global dispatch pool. A test that closes its window while one is
    /// still running leaves that pool work behind; enough of them and the pool is full, which is
    /// what made a full-suite run of `TilePlanAndRedrawTests` time out on its own background uploads
    /// (16/16 of those tests pass in isolation in 0.2 s). Measured with `sample`: 64 of 64 pool
    /// threads blocked in `-[NSAnimation _runBlocking]`.
    @MainActor
    static func settleAnimations(_ seconds: TimeInterval = 0.4) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    /// Closes a viewer window *after* its animations have settled. Use this instead of `close()` in
    /// tests that showed a window: it is what keeps one test's animation out of the next test's pool.
    @MainActor
    static func close(_ controller: ViewerWindowController, settle: TimeInterval = 0.4) {
        settleAnimations(settle)
        controller.close()
        settleAnimations(0.05)
    }
}

/// The app's sort order is one shared state (that is the point of the redesign), so a test that
/// changes it has to put it back or every later test in the process inherits it. Restoring is not
/// tidiness: a leaked `.descending` made a dozen unrelated navigation tests fail with "the next
/// image is the wrong one".
@MainActor
enum SharedSettingsScope {
    /// Runs `body` with the sort order it expects, and puts the previous order back afterwards.
    static func preservingSort<T>(key: ImageSortKey? = nil,
                                  direction: SortDirection? = nil,
                                  _ body: () throws -> T) rethrows -> T {
        let settings = AppSettings.shared
        let previousKey = settings.sortKey
        let previousDirection = settings.sortDirection
        if let key { settings.sortKey = key }
        if let direction { settings.sortDirection = direction }
        defer {
            settings.sortKey = previousKey
            settings.sortDirection = previousDirection
        }
        return try body()
    }

    /// The same for an async body, which `rethrows` cannot express.
    static func preservingSort<T>(key: ImageSortKey? = nil,
                                  direction: SortDirection? = nil,
                                  _ body: () async throws -> T) async rethrows -> T {
        let settings = AppSettings.shared
        let previousKey = settings.sortKey
        let previousDirection = settings.sortDirection
        if let key { settings.sortKey = key }
        if let direction { settings.sortDirection = direction }
        defer {
            settings.sortKey = previousKey
            settings.sortDirection = previousDirection
        }
        return try await body()
    }
}

/// Shared access to the generated fixture folder.
enum Fixtures {
    static var directory: URL {
        guard let url = Bundle.module.url(forResource: "Fixtures", withExtension: nil) else {
            fatalError("Fixtures resource is missing from the test bundle")
        }
        return url
    }

    static func url(_ name: String) -> URL {
        directory.appendingPathComponent(name)
    }

    /// Scratch directory so folder tests never touch the fixture folder itself.
    /// A unique scratch directory per call.
    ///
    /// The label is only a readable prefix: a fixed name collides with leftovers
    /// from an earlier run (a crashed suite leaves its directory behind), which then
    /// fails tests with "an item with the same name already exists".
    static func makeScratchDirectory(_ label: String = "scratch") throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("picviewmac-tests", isDirectory: true)
            .appendingPathComponent("\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
