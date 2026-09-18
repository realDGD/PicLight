import Foundation
import CoreGraphics

/// Pure hover/idle state machine for the tool dock.
///
/// The dock auto-hides: it is on screen while the pointer is inside the invisible
/// strip along the bottom centre of the image area, and while it is pinned. The
/// delays are asymmetric on purpose — a short show delay keeps the dock feeling
/// attached to the pointer, a longer hide delay keeps it from flickering when the
/// pointer merely sweeps across the bottom edge.
public struct ToolDockVisibilityModel: Sendable {
    public struct Timing: Sendable {
        public var showDelay: TimeInterval = 0.05
        public var hideDelay: TimeInterval = 0.7

        public init() {}
    }

    public var timing = Timing()

    public private(set) var visible = false
    public private(set) var pinned = false

    /// Whether a usable image is on screen. Without one the dock has nothing to act
    /// on, so it stays away regardless of the pointer.
    public private(set) var hasImage = false
    /// Immersive mode takes the whole overlay chrome away. A pinned dock comes back
    /// when the user leaves it.
    public var immersive = false
    /// Whether the pointer is inside the reveal strip.
    public private(set) var pointerInZone = false

    private var enteredAt: TimeInterval?
    private var exitedAt: TimeInterval?

    public init() {}

    // MARK: - Inputs

    /// The image appeared or went away. Appearing shows the dock briefly, so the
    /// user discovers it, and then starts the usual hide countdown.
    public mutating func setHasImage(_ value: Bool, at time: TimeInterval) {
        guard value != hasImage else { return }
        hasImage = value
        if value {
            visible = true
            enteredAt = nil
            exitedAt = time
        } else {
            visible = false
            enteredAt = nil
            exitedAt = nil
        }
    }

    /// Pins or unpins. Unpinning falls back to the hover rules: if the pointer is
    /// elsewhere, the dock closes after the usual delay.
    public mutating func setPinned(_ value: Bool, at time: TimeInterval) {
        pinned = value
        if value {
            visible = true
            enteredAt = nil
            exitedAt = nil
        } else {
            enteredAt = pointerInZone ? time : nil
            exitedAt = pointerInZone ? nil : time
        }
    }

    public mutating func setPointer(inZone inside: Bool, at time: TimeInterval) {
        guard inside != pointerInZone else { return }
        pointerInZone = inside
        if inside {
            enteredAt = time
            exitedAt = nil
        } else {
            enteredAt = nil
            exitedAt = time
        }
    }

    public mutating func setImmersive(_ value: Bool, at time: TimeInterval) {
        immersive = value
        if value {
            visible = false
            enteredAt = nil
            exitedAt = nil
        } else if pinned {
            visible = true
            enteredAt = nil
            exitedAt = nil
        } else {
            // Leaving immersive mode shows the dock again, then it hides as usual.
            visible = true
            enteredAt = nil
            exitedAt = time
        }
    }

    // MARK: - Evaluation

    @discardableResult
    public mutating func update(at time: TimeInterval) -> Bool {
        let before = visible
        if !hasImage || immersive {
            visible = false
        } else if pinned {
            visible = true
        } else if pointerInZone {
            if let enteredAt, time - enteredAt >= timing.showDelay { visible = true }
        } else if let exitedAt, time - exitedAt >= timing.hideDelay {
            visible = false
        }
        return visible != before
    }

    public var snapshot: Bool { visible }
}

/// Pure hover/idle state machine for the viewer's overlay chrome. The window
/// management strip is the standard AppKit titlebar and is always visible, so
/// there is no top state left to track here.
///
/// The three surfaces it tracks — the thumbnail drawer, the minimap and the tool dock — are
/// independent: each has its own inputs and its own rule. They share the tick that evaluates
/// them and nothing else, so a pointer event that concerns one cannot move another.
public struct HoverVisibilityModel: Sendable {
    public struct Timing: Sendable {
        public var minimapIdleFadeDelay: TimeInterval = 1.5

        public init() {}
    }

    public var timing = Timing()
    /// The dock's own state machine. Independent of the drawer's: the two share the tick that
    /// drives them, never a flag.
    public var toolDock = ToolDockVisibilityModel()

    /// Whether the thumbnail drawer is open. Explicitly controlled — see `setDrawerOpen`.
    ///
    /// It used to open from a hover over the window's left edge, with its own open/close timers
    /// running alongside a separate pinned flag. That is gone: a drawer that appears because the
    /// pointer crossed the left edge is a drawer that appears by accident, and having two
    /// authorities for one surface meant the timers and the flag could disagree. The state is now
    /// exactly the user's choice, and the pointer cannot change it.
    public private(set) var drawerOpen = false
    public private(set) var minimapVisible = false

    /// Immersive mode hides the viewer's overlay chrome. The standard titlebar and
    /// the window itself are untouched.
    public var immersive = false
    /// Minimap is only permitted while the image is zoomed past Fit.
    public var isZoomedIn = false

    /// Wall-clock time of the last pointer activity. Recorded so a pointer-driven rule has one
    /// place to read it from; no current rule keys on it, which is the point — the drawer is not
    /// a pointer-driven surface any more.
    private var lastPointerActivity: TimeInterval = 0
    private var lastMinimapActivity: TimeInterval = 0

    public init() {}

    // MARK: - Inputs

    public mutating func pointerMoved(at time: TimeInterval) {
        lastPointerActivity = time
    }

    /// The drawer's only entry point: the titlebar's sidebar button and the `缩略图抽屉` command
    /// both land here, and nothing else may change it.
    public mutating func setDrawerOpen(_ open: Bool, at time: TimeInterval) {
        drawerOpen = open
        lastPointerActivity = time
    }

    public mutating func toggleDrawer(at time: TimeInterval) {
        setDrawerOpen(!drawerOpen, at: time)
    }

    /// The pointer is over the drawer's surface. Counts as activity — the drawer must not be
    /// mistaken for the pointer having left the window — but cannot open or close anything.
    public mutating func pointerOverDrawer(at time: TimeInterval) {
        lastPointerActivity = time
    }

    public mutating func zoomActivity(at time: TimeInterval) {
        lastMinimapActivity = time
        lastPointerActivity = time
    }

    public mutating func setImmersive(_ value: Bool, at time: TimeInterval) {
        immersive = value
        toolDock.setImmersive(value, at: time)
        // Immersive suppresses the drawer's *appearance* without forgetting the user's choice, so
        // leaving immersive mode restores exactly the state they left.
        if value { minimapVisible = false }
    }

    public mutating func setZoomedIn(_ value: Bool, at time: TimeInterval) {
        isZoomedIn = value
        if value { lastMinimapActivity = time } else { minimapVisible = false }
    }

    // MARK: - Evaluation

    /// Recomputes visibility. Returns `true` when something changed and the
    /// chrome needs to be re-rendered.
    @discardableResult
    public mutating func update(at time: TimeInterval) -> Bool {
        let before = snapshot

        if isZoomedIn {
            minimapVisible = time - lastMinimapActivity <= timing.minimapIdleFadeDelay
        } else {
            minimapVisible = false
        }

        toolDock.update(at: time)

        return snapshot != before
    }

    /// The drawer as the user sees it: open, and not suppressed by immersive mode.
    public var drawerVisible: Bool { drawerOpen && !immersive }

    public var snapshot: Snapshot {
        Snapshot(drawer: drawerVisible, minimap: minimapVisible, toolDock: toolDock.visible)
    }

    public struct Snapshot: Equatable, Sendable {
        public let drawer: Bool
        public let minimap: Bool
        public let toolDock: Bool
    }

    /// Keyboard navigation must always work, even with all overlay chrome hidden.
    public var chromeHidden: Bool { !drawerVisible && !minimapVisible && !toolDock.visible }
}
