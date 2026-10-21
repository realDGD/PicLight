import AppKit

/// A standard `NSWindow` with the standard titlebar: the window-management strip
/// at the top is AppKit's, not a custom hover bar. Native tabbing is disabled and
/// no overlay windows are used.
public final class ViewerWindow: NSWindow {

    /// What the titlebar does, as the user chose it.
    public enum TitlebarMode: String, CaseIterable, Sendable {
        case autoHide
        case alwaysVisible
        case alwaysHidden

        public init(_ behavior: TitlebarBehavior) {
            switch behavior {
            case .autoHide: self = .autoHide
            case .alwaysVisible: self = .alwaysVisible
            case .alwaysHidden: self = .alwaysHidden
            }
        }
    }

    public struct Policy: Sendable {
        public let styleMask: NSWindow.StyleMask
        public let tabbingMode: NSWindow.TabbingMode

        /// The base style is the ordinary native window. Auto-hide adds full-size
        /// content once for the mode, independently of subsequent hover states.
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
    private let titlebarBackdrop = TitlebarBackdropView()
    private var titlebarBackdropConstraints: [NSLayoutConstraint] = []

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

    /// The mode, auto-hide state, and browser override all feed one native titlebar
    /// presentation. Auto-hide overlays the native bar without changing the image layout.
    public func applyTitlebarMode(_ mode: TitlebarMode) {
        guard mode != appliedTitlebarMode else { return }
        appliedTitlebarMode = mode
        appliedTitlebarState = nil
        applyTitlebarState(mode == .alwaysVisible ? .full : .hidden)
    }

    public func applyTitlebarState(_ state: TitlebarVisibilityModel.State) {
        let effectiveState: TitlebarVisibilityModel.State =
            isTopBarMergedWithContent || titlebarMode == .alwaysVisible ? .full
            : titlebarMode == .alwaysHidden ? .hidden : state
        let stateChanged = appliedTitlebarState != effectiveState
        appliedTitlebarState = effectiveState
        if stateChanged, titlebarMode == .autoHide { titlebarTransitionCount += 1 }

        // Auto-hide changes presentation only: every hover state uses the same image area.
        // Always-visible mode reserves the ordinary native strip; the browser owns its merged row.
        let fullSize = isTopBarMergedWithContent || titlebarMode != .alwaysVisible
        if styleMask.contains(.fullSizeContentView) != fullSize {
            // AppKit otherwise changes the outer window height to preserve content size.
            let outerFrame = frame
            if fullSize {
                styleMask.insert(.fullSizeContentView)
            } else {
                styleMask.remove(.fullSizeContentView)
            }
            setFrame(outerFrame, display: false)
        }
        let nativeBarVisible = !isTopBarMergedWithContent && effectiveState == .full
        titlebarSeparatorStyle = nativeBarVisible ? .automatic : .none
        titlebarAppearsTransparent = !nativeBarVisible
        titleVisibility = nativeBarVisible ? .visible : .hidden
        refreshTrafficLights()
        if nativeBarVisible, stateChanged { relayoutTitleWithAccessoriesInPlace() }
        updateTitlebarBackdrop()
    }

    /// An opaque backing under the native material keeps saturated image pixels from tinting it.
    /// It reserves no content space and has no controls or hit targets of its own.
    private func updateTitlebarBackdrop() {
        guard let contentView else { return }
        if titlebarBackdrop.superview !== contentView {
            NSLayoutConstraint.deactivate(titlebarBackdropConstraints)
            titlebarBackdrop.removeFromSuperview()
            titlebarBackdrop.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(titlebarBackdrop)
            titlebarBackdropConstraints = [
                titlebarBackdrop.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
                titlebarBackdrop.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
                titlebarBackdrop.topAnchor.constraint(equalTo: contentView.topAnchor),
                NSLayoutConstraint(item: titlebarBackdrop, attribute: .bottom, relatedBy: .equal,
                                   toItem: contentLayoutGuide, attribute: .top,
                                   multiplier: 1, constant: 0),
            ]
            NSLayoutConstraint.activate(titlebarBackdropConstraints)
        }
        titlebarBackdrop.isHidden = titlebarMode != .autoHide || titlebarState != .full
            || isTopBarMergedWithContent || styleMask.contains(.fullScreen)
    }

    /// The browser shares one native top row with the traffic lights. Leaving it
    /// always recomputes the ordinary image layout, even when the user's mode stayed
    /// always-visible throughout the visit.
    public var isTopBarMergedWithContent = false {
        didSet {
            guard isTopBarMergedWithContent != oldValue else { return }
            applyTitlebarState(isTopBarMergedWithContent ? .full : titlebarState)
        }
    }

    /// The viewer's own titlebar accessories — the drawer button. Registered by the window controller
    /// so the window can take them in and out of the titlebar together with the bar itself.
    public var viewerAccessories: [NSTitlebarAccessoryViewController] = []

    /// Image metadata must leave the merged browser row to its navigation controls.
    public var imageOnlyAccessories: [NSTitlebarAccessoryViewController] = []

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
            let eligible = !isTopBarMergedWithContent
                || !imageOnlyAccessories.contains { $0 === accessory }
            let accessoryVisible = visible && eligible
            let present = titlebarAccessoryViewControllers.contains { $0 === accessory }
            if accessoryVisible, !present {
                addTitlebarAccessoryViewController(accessory)
            } else if !accessoryVisible, present,
                      let index = titlebarAccessoryViewControllers.firstIndex(where: { $0 === accessory }) {
                removeTitlebarAccessoryViewController(at: index)
            }
            accessory.isHidden = !accessoryVisible
            accessory.view.isHidden = !accessoryVisible
            accessory.view.alphaValue = accessoryVisible ? 1 : 0
            if accessoryVisible, !present { accessoryPresenceChanged = true }
        }
        if accessoryPresenceChanged { relayoutTitleWithAccessoriesInPlace() }
    }

    /// Set when an accessory was just put back into the titlebar, so the title is laid out again.
    private var accessoryPresenceChanged = false

    /// AppKit computes the title's frame *before* a titlebar accessory lands, and while the bar is
    /// away the title is hidden, so the frame it computes when the bar comes back is the leading-edge
    /// one: measured with the drawer button re-inserted at x 78…108 the title sat at x=82 — on top of
    /// the button — and stayed there until something else changed the title. Toggling the visibility
    /// makes AppKit lay the title out again with the accessory in place (measured: back to x=351, the
    /// centre of a 900 pt window). A same-value `title` assignment and `needsLayout` on the theme
    /// frame both leave it where it was.
    private func relayoutTitleWithAccessoriesInPlace() {
        accessoryPresenceChanged = false
        guard titleVisibility == .visible else { return }
        titleVisibility = .hidden
        titleVisibility = .visible
    }

    /// The traffic-light controls' union frame in this window's base coordinates, or nil when they
    /// are not laid out. Used to place zone A over the controls rather than over a guessed inset.
    public var trafficLightsFrame: CGRect? {
        let frames = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton]
            .compactMap { type -> CGRect? in
                guard let button = standardWindowButton(type) else { return nil }
                return button.convert(button.bounds, to: nil)
            }
        guard frames.count == 3, let first = frames.first else { return nil }
        var union = first
        for frame in frames.dropFirst() { union = union.union(frame) }
        guard union.width > 0, union.height > 0 else { return nil }
        return union
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
        setViewerAccessoriesVisible(true)
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

private final class TitlebarBackdropView: NSView {
    override var isOpaque: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
