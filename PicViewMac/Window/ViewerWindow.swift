import AppKit

/// A standard `NSWindow` with the standard titlebar: the window-management strip
/// at the top is AppKit's, not a custom hover bar. Native tabbing is disabled and
/// no overlay windows are used.
public final class ViewerWindow: NSWindow {

    /// What the titlebar does, as the user chose it.
    public enum TitlebarMode: String, CaseIterable, Sendable {
        case autoHide
        case alwaysVisible

        public init(_ behavior: TitlebarBehavior) {
            self = behavior == .autoHide ? .autoHide : .alwaysVisible
        }
    }

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

    /// What the titlebar does. `autoHide` is the default; `alwaysVisible` is the standard window.
    ///
    /// `applied*` rather than plain stored properties: the window's *actual* titlebar state is what
    /// these track, and a fresh window has not applied anything yet. Initialising them to the
    /// defaults instead would make the first `applyTitlebarMode(.autoHide)` a no-op — which is
    /// exactly the bug where the window kept the visible titlebar its initialiser had set up.
    private var appliedTitlebarMode: TitlebarMode?
    private var appliedTitlebarState: TitlebarVisibilityModel.State?
    public var titlebarMode: TitlebarMode { appliedTitlebarMode ?? .autoHide }
    /// The auto-hide state the window is currently presenting.
    public var titlebarState: TitlebarVisibilityModel.State { appliedTitlebarState ?? .hidden }
    /// How many times the titlebar has actually changed state, so a test can prove a pointer sweep
    /// does not re-issue the transition.
    public private(set) var titlebarTransitionCount = 0

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
        // The default is auto-hide, and the window's real state must match from the start rather
        // than only after the first settings notification.
        applyTitlebarMode(.autoHide)
    }

    /// The standard macOS window: real traffic lights, native full screen, native tabbing off.
    ///
    /// Deliberately does *not* decide the titlebar's look any more — that is `applyTitlebarMode`,
    /// which the viewer drives from the user's setting.
    public func configureStandardViewerChrome() {
        tabbingMode = Self.policy.tabbingMode
        // The titlebar's appearance is `applyTitlebarMode`'s business; nothing here sets it, so
        // there is one authority for whether the bar is visible.
        isMovableByWindowBackground = false
        collectionBehavior = [.fullScreenPrimary]
        isReleasedWhenClosed = false
        Self.defaultMinimumSize = NSSize(width: 480, height: 320)
        minSize = Self.defaultMinimumSize
        title = "PicLight"
        // The window is a normal window for Mission Control, tiling and Stage Manager.
        styleMask.insert(.titled)
    }

    // MARK: - Titlebar

    /// Applies the user's titlebar mode. Switching to auto-hide lets the content reach the top of
    /// the window (`.fullSizeContentView`); switching back to always-visible removes it again, so
    /// the standard window path — content below a permanent titlebar — is exactly what it was.
    ///
    /// `.fullSizeContentView` is the mechanism the spec asks to verify, and it is the only one that
    /// works: the traffic lights live in a titlebar view that AppKit keeps, so the content can be
    /// laid out under it and the bar itself made invisible with `titlebarAppearsTransparent` +
    /// `titleVisibility = .hidden`. The window stays a standard `.titled` window throughout, which
    /// is what keeps Mission Control, native tiling, Stage Manager and full screen working.
    public func applyTitlebarMode(_ mode: TitlebarMode) {
        guard mode != appliedTitlebarMode else { return }
        appliedTitlebarMode = mode
        switch mode {
        case .alwaysVisible:
            styleMask.remove(.fullSizeContentView)
            titlebarSeparatorStyle = .automatic
            appliedTitlebarState = nil
            applyTitlebarState(.full)
        case .autoHide:
            styleMask.insert(.fullSizeContentView)
            titlebarSeparatorStyle = .none
            appliedTitlebarState = nil
            applyTitlebarState(.hidden)
        }
    }

    /// Applies one of the auto-hide states. In always-visible mode this restores the standard
    /// titlebar instead of hiding anything.
    public func applyTitlebarState(_ state: TitlebarVisibilityModel.State) {
        guard titlebarMode == .autoHide else {
            // Always-visible mode is the standard window: the titlebar and its buttons are AppKit's.
            guard appliedTitlebarState != .full else { return }
            appliedTitlebarState = .full
            titleVisibility = .visible
            titlebarAppearsTransparent = false
            refreshTrafficLights()
            return
        }
        guard state != appliedTitlebarState else { return }
        appliedTitlebarState = state
        titlebarTransitionCount += 1
        switch state {
        case .hidden, .trafficLightsOnly:
            // Both keep the bar itself invisible; they differ only in whether the controls are
            // shown, which `refreshTrafficLights` decides.
            titlebarAppearsTransparent = true
            titleVisibility = .hidden
        case .full:
            titlebarAppearsTransparent = false
            titleVisibility = .visible
        }
        refreshTrafficLights()
    }

    /// Shows or hides the real traffic-light controls, and does nothing else to them.
    ///
    /// Never called in native full screen: there the system owns the top strip and manages the
    /// controls itself, and a second authority would fight it (the same reason
    /// `windowDidEnterFullScreen` restores them).
    public func refreshTrafficLights() {
        guard !styleMask.contains(.fullScreen) else { return }
        let visible = titlebarMode == .alwaysVisible || titlebarState != .hidden
        for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            guard let button = standardWindowButton(type) else { continue }
            button.isHidden = !visible
            button.alphaValue = visible ? 1 : 0
        }
        // The titlebar accessories go with the bar they live in. The viewer's own drawer button is
        // one of them, and a lone control floating over the top-left of the image — with no bar
        // around it — is exactly what "hidden" must not look like. The drawer is still reachable
        // from the dock, the context menu and its shortcut.
        for accessory in titlebarAccessoryViewControllers {
            accessory.isHidden = !visible
        }
    }

    /// The traffic-light controls' union frame in this window's base coordinates, or nil when they
    /// are not laid out. Used to place zone A over the controls rather than over a guessed inset.
    public var trafficLightsFrame: CGRect? {
        let frames = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton]
            .compactMap { standardWindowButton($0)?.frame }
        guard frames.count == 3, let first = frames.first else { return nil }
        var union = first
        for frame in frames.dropFirst() { union = union.union(frame) }
        guard union.width > 0, union.height > 0 else { return nil }
        // The buttons live in AppKit's titlebar view; converting through the content view puts
        // their frames into the window's base coordinate space, which is what the caller's
        // `bounds` is measured in.
        guard let content = contentView, let container = union.isEmpty ? nil : content.superview
        else { return union }
        return content.convert(union, from: container)
    }

    /// Restores the system's own management of the controls, for the events where it takes over.
    public func restoreSystemTitlebarControl() {
        for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            guard let button = standardWindowButton(type) else { continue }
            button.isHidden = false
            button.alphaValue = 1
        }
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
