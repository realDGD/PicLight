import AppKit

/// A standard `NSWindow`, visually titleless but never a true borderless or
/// special window. Native tabbing is disabled and no overlay windows are used.
public final class ViewerWindow: NSWindow {
    public struct Policy: Sendable {
        public let styleMask: NSWindow.StyleMask
        public let tabbingMode: NSWindow.TabbingMode

        public static let `default` = Policy(
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            tabbingMode: .disallowed
        )
    }

    public static let policy = Policy.default

    public init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: Self.policy.styleMask,
            backing: .buffered,
            defer: false
        )
        configureStandardViewerChrome()
    }

    /// Transparent titlebar, hidden title, no toolbar, real traffic lights kept.
    public func configureStandardViewerChrome() {
        tabbingMode = Self.policy.tabbingMode
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        titlebarSeparatorStyle = .none
        isMovableByWindowBackground = false
        collectionBehavior = [.fullScreenPrimary]
        isReleasedWhenClosed = false
        minSize = NSSize(width: 480, height: 320)
        // The window is a normal window for Mission Control, tiling and Stage Manager.
        styleMask.insert(.titled)
    }

    public override var canBecomeKey: Bool { true }
    public override var canBecomeMain: Bool { true }
}
