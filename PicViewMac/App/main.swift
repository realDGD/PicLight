import AppKit

// PicLight — a native, minimalist macOS image viewer.
// AppKit owns the app/window lifecycle; decode, folder and viewport logic live in
// focused types covered by XCTest.
let application = NSApplication.shared
let delegate = AppDelegate()
application.setActivationPolicy(.regular)
application.delegate = delegate
application.run()
