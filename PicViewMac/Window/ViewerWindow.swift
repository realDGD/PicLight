import AppKit

/// A standard `NSWindow` with the standard titlebar: the window-management strip
/// at the top is AppKit's, not a custom hover bar. Native tabbing is disabled and
/// no overlay windows are used.
public final class ViewerWindow: NSWindow {
    public struct Policy: Sendable {
        public let styleMask: NSWindow.StyleMask
        public let tabbingMode: NSWindow.TabbingMode

        /// `.fullSizeContentView` is deliberately absent: content starts below the
        /// titlebar, so nothing has to fake a titlebar inside the content area.
        public static let `default` = Policy(
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            tabbingMode: .disallowed
        )
    }

    public static let policy = Policy.default

    public init(contentRect: NSRect) {
        // Enforced here as well as at launch so the invariant holds no matter how
        // a viewer window comes into existence; the setting is app-wide and
        // idempotent.
        NSWindow.allowsAutomaticWindowTabbing = false
        super.init(
            contentRect: contentRect,
            styleMask: Self.policy.styleMask,
            backing: .buffered,
            defer: false
        )
        configureStandardViewerChrome()
    }

    /// The standard macOS titlebar: visible title, opaque bar, real traffic lights.
    public func configureStandardViewerChrome() {
        tabbingMode = Self.policy.tabbingMode
        titleVisibility = .visible
        titlebarAppearsTransparent = false
        titlebarSeparatorStyle = .automatic
        isMovableByWindowBackground = false
        collectionBehavior = [.fullScreenPrimary]
        isReleasedWhenClosed = false
        Self.defaultMinimumSize = NSSize(width: 480, height: 320)
        minSize = Self.defaultMinimumSize
        title = "PicLight"
        // The window is a normal window for Mission Control, tiling and Stage Manager.
        styleMask.insert(.titled)
    }

    /// The unpinned minimum window size. Pinning the drawer raises it so the
    /// remaining canvas stays usable.
    public static var defaultMinimumSize = NSSize(width: 480, height: 320)

    /// Keeps at least `minimumCanvasWidth` for the image when the drawer reserves
    /// leading space.
    public func applyMinimumSize(drawerWidth: CGFloat, minimumCanvasWidth: CGFloat = 320) {
        minSize = drawerWidth > 0
            ? NSSize(width: drawerWidth + minimumCanvasWidth, height: Self.defaultMinimumSize.height)
            : Self.defaultMinimumSize
    }

    public override var canBecomeKey: Bool { true }
    public override var canBecomeMain: Bool { true }
}
