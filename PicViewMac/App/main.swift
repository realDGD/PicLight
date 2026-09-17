import AppKit

// PicLight — a native, minimalist macOS image viewer.
// AppKit owns the app/window lifecycle; decode, folder and viewport logic live in
// focused types covered by XCTest.

// Headless release probe: answers "can this packaged app reach its Metal resources?"
// without starting the GUI, so verify-release.sh can check the real bundle layout.
if MetalProbe.isRequested {
    exit(MetalProbe.run())
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.setActivationPolicy(.regular)
application.delegate = delegate
application.run()
