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
        if isTopBarMergedWithContent {
            // The folder browser owns the top strip: its own toolbar is the top row, so the native
            // bar is drawn transparently over it (title hidden) and the controls — traffic lights
            // and the drawer button — live in that row rather than pushing the content down. The
            // state is recorded as given, so the window still reports whether the bar is up.
            appliedTitlebarState = state
            styleMask.insert(.fullSizeContentView)
            titlebarSeparatorStyle = .none
            titlebarAppearsTransparent = true
            titleVisibility = .hidden
            refreshTrafficLights()
            return
        }
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

    /// While the folder browser is up, the window presents *one* top row: the browser's toolbar
    /// occupies the titlebar strip and the native controls sit in it. Set by the viewer on entering
    /// the browser and cleared on leaving; it is a presentation override, not a user setting.
    public var isTopBarMergedWithContent = false {
        didSet {
            guard isTopBarMergedWithContent != oldValue else { return }
            appliedTitlebarState = nil
            applyTitlebarState(isTopBarMergedWithContent ? .full : .hidden)
        }
    }

    /// The viewer's own titlebar accessories — the drawer button. Registered by the window controller
    /// so the window can take them in and out of the titlebar together with the bar itself.
    public var viewerAccessories: [NSTitlebarAccessoryViewController] = []

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
        // The viewer's accessories ride with the bar. In the image mode that is the *full* (painted)
        // bar, not the lights-only state: there the bar's background is away, and a lone drawer
        // button beside the floating lights reads as a control on the page. In the browser's merged
        // row the bar *is* the toolbar, so the button belongs in it alongside the lights.
        let accessoriesVisible = isTopBarMergedWithContent
            ? titlebarState != .hidden
            : titlebarState == .full
        setViewerAccessoriesVisible(accessoriesVisible)
    }

    /// Takes the viewer's accessories in and out of the titlebar.
    ///
    /// Presence, not `isHidden`. With `.fullSizeContentView` and a hidden title, AppKit keeps an
    /// accessory's view in the window and merely *moves* it: measured at (18, …), floating over the
    /// traffic lights' own (9…69) strip, while the bar was away, and at (78, …) inside the bar when
    /// it was up. Hiding the view left it in the window at the stale floating position, which put
    /// it back on top of the lights. Removing the accessory takes the view out of the window
    /// outright — nothing can float over the image — and adding it back lays it out inside the bar,
    /// so it cannot end up on top of the controls it sits beside.
    private func setViewerAccessoriesVisible(_ visible: Bool) {
        for accessory in viewerAccessories {
            let present = titlebarAccessoryViewControllers.contains { $0 === accessory }
            if visible, !present {
                addTitlebarAccessoryViewController(accessory)
            } else if !visible, present,
                      let index = titlebarAccessoryViewControllers.firstIndex(where: { $0 === accessory }) {
                removeTitlebarAccessoryViewController(at: index)
            }
            accessory.isHidden = !visible
            accessory.view.isHidden = !visible
            accessory.view.alphaValue = visible ? 1 : 0
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
    ///
    /// The accessories come back with the controls: full screen gives the system a titlebar of its
    /// own, and a drawer button left out of it by the auto-hide state would be missing.
    public func restoreSystemTitlebarControl() {
        for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            guard let button = standardWindowButton(type) else { continue }
            button.isHidden = false
            button.alphaValue = 1
        }
        for accessory in viewerAccessories {
            if !titlebarAccessoryViewControllers.contains(where: { $0 === accessory }) {
                addTitlebarAccessoryViewController(accessory)
            }
            accessory.isHidden = false
            accessory.view.isHidden = false
            accessory.view.alphaValue = 1
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
