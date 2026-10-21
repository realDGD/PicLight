import Foundation
import AppKit

/// Opt-in gesture diagnostics.
///
/// Set `PICVIEW_TRACE_GESTURES=1` in the environment and the app writes what it receives to
/// `/tmp/picview-gesture-trace.log` (and to stderr), which answers in one run the question a
/// screenshot cannot: does the app receive the pinch at all, does the canvas, does the viewport
/// change, and does something put it back.
///
/// Off by default, and free when off: every entry point returns on one boolean.
public enum GestureTrace {
    public static let isEnabled = ProcessInfo.processInfo.environment["PICVIEW_TRACE_GESTURES"] != nil
    public static let logURL = URL(fileURLWithPath: "/tmp/picview-gesture-trace.log")

    private static let lock = NSLock()
    nonisolated(unsafe) private static var started = false

    /// Called once, as early in launch as possible.
    public static func start() {
        guard isEnabled, !started else { return }
        started = true
        try? FileManager.default.removeItem(at: logURL)
        note("=== PicLight gesture trace, pid \(ProcessInfo.processInfo.processIdentifier), "
             + "macOS \(ProcessInfo.processInfo.operatingSystemVersionString) ===")
        // Before AppKit dispatches anything: this answers "does the gesture reach the app at all?",
        // which is the difference between a system/permissions problem and a dispatch problem.
        NSEvent.addLocalMonitorForEvents(matching: [.magnify, .scrollWheel]) { event in
            switch event.type {
            case .magnify:
                // The view AppKit is about to deliver to: computed here, before dispatch, because
                // "the gesture arrived but went somewhere else" is the failure a screenshot cannot
                // show.
                var target = "no-window"
                if let window = event.window, let content = window.contentView {
                    let inContent = content.convert(event.locationInWindow, from: nil)
                    if let hit = content.hitTest(inContent) {
                        target = "\(type(of: hit)) hidden=\(hit.isHidden) alpha=\(hit.alphaValue)"
                    } else {
                        target = "nil (nothing hit-testable)"
                    }
                }
                note("app.received magnify window=\(event.window?.windowNumber ?? -1) "
                     + "at=(\(Int(event.locationInWindow.x)),\(Int(event.locationInWindow.y))) "
                     + "magnification=\(event.magnification) phase=\(event.phase.rawValue) "
                     + "key=\(event.window?.isKeyWindow ?? false) target=\(target)")
            case .scrollWheel where event.phase == .began:
                note("app.received scroll begin window=\(event.window?.windowNumber ?? -1) "
                     + "at=(\(Int(event.locationInWindow.x)),\(Int(event.locationInWindow.y))) "
                     + "d=\(event.scrollingDeltaX),\(event.scrollingDeltaY) "
                     + "precise=\(event.hasPreciseScrollingDeltas)")
            default:
                break
            }
            return event
        }
        note("monitor installed")
    }

    public static func note(_ message: @autoclosure () -> String) {
        guard isEnabled else { return }
        let line = String(format: "%.3f ", ProcessInfo.processInfo.systemUptime) + message() + "\n"
        lock.lock()
        defer { lock.unlock() }
        FileHandle.standardError.write(Data(line.utf8))
        if let handle = try? FileHandle(forWritingTo: logURL) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? line.write(to: logURL, atomically: true, encoding: .utf8)
        }
    }
}
