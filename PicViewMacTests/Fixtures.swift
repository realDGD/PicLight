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
        ThreadAudit.installIfNeeded()
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
        prepareForOffScreen(controller.window)
        controller.present()
        moveOffScreen(controller.window)
    }

    /// Configures a test window so that it cannot leave AppKit animation work behind.
    ///
    /// `NSWindow.animationBehavior` defaults to animating order-front and close. A test window is
    /// moved out of the display's bounds and then closed, and that animation cannot finish off
    /// screen: its driver is left running on a dispatch pool thread. Measured mid-run with `sample`:
    /// 71 threads in the process, **65 of them blocked in `-[NSAnimation _runBlocking]`**, against a
    /// dispatch soft limit of 64 — after which the pool refuses to run new blocks, and the tile
    /// tests that wait on pool work time out (they pass 16/16 in isolation in 0.2 s).
    @MainActor
    static func prepareForOffScreen(_ window: NSWindow?) {
        window?.animationBehavior = .none
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

/// Reports the peak number of live threads in the test process.
///
/// This is the instrument that found the suite's worst failure mode. `NSWindow.animationBehavior`
/// defaults to animating order-front and close; a test window is moved out of the display's bounds
/// and then closed, and that animation cannot finish off screen, so its driver is left running on a
/// dispatch pool thread. Measured mid-run with `sample`: 71 threads, **65 of them blocked in
/// `-[NSAnimation _runBlocking]`**, against a dispatch soft limit of 64 — after which the pool
/// refuses to run new blocks and the tile tests that wait on pool work time out (16/16 of them pass
/// in isolation in 0.2 s). `TestAppKit.prepareForOffScreen` removes the cause; this keeps the
/// symptom measurable, as a single peak number rather than a line per suite.
final class ThreadAudit: NSObject, XCTestObservation, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var installed = false
    nonisolated(unsafe) private static var peak = 0

    static func installIfNeeded() {
        lock.lock()
        defer { lock.unlock() }
        guard !installed else { return }
        installed = true
        XCTestObservationCenter.shared.addTestObserver(ThreadAudit())
    }

    func testCaseDidFinish(_ testCase: XCTestCase) {
        let count = ThreadAudit.liveThreadCount()
        ThreadAudit.lock.lock()
        ThreadAudit.peak = max(ThreadAudit.peak, count)
        ThreadAudit.lock.unlock()
    }

    func testBundleDidFinish(_ testBundle: Bundle) {
        ThreadAudit.lock.lock()
        let peak = ThreadAudit.peak
        ThreadAudit.lock.unlock()
        print("THREAD-AUDIT peak \(peak) threads (dispatch soft limit is 64)")
    }

    /// `task_threads` on this process: the number of Mach threads, which is what the dispatch pool
    /// soft limit is counted against.
    static func liveThreadCount() -> Int {
        var threads: thread_act_array_t?
        var count: mach_msg_type_number_t = 0
        guard task_threads(mach_task_self_, &threads, &count) == KERN_SUCCESS,
              let threads else { return -1 }
        let bytes = vm_size_t(count) * vm_size_t(MemoryLayout<thread_t>.stride)
        vm_deallocate(mach_task_self_, vm_address_t(bitPattern: threads), bytes)
        return Int(count)
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
