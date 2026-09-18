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

/// Pure idle-fade state machine for the bottom info HUD.
///
/// The HUD is informational: it appears when something it describes changes, and fades once
/// nothing has changed for a moment. It deliberately has no reveal zone and no pointer rule.
/// The pointer crossing the image is not an event about the image, so it must not summon a
/// readout of the image's position, zoom and dimensions.
public struct InfoHUDVisibilityModel: Sendable {
    public struct Timing: Sendable {
        /// Idle time before the fade. The spec asks for 1.5–2.0 s; this sits in the middle,
        /// long enough to read three fields, short enough to get out of the way.
        public var idleFadeDelay: TimeInterval = 1.75

        public init() {}
    }

    public var timing = Timing()
    public private(set) var visible = false
    /// Whether there is an image for the HUD to describe. Without one it stays away and its
    /// fade timer does not start.
    public private(set) var hasImage = false
    /// Immersive mode takes the HUD away immediately, and restores nothing on exit until the
    /// next meaningful change — immersive is the user asking for fewer readouts.
    public var immersive = false

    private var lastChangeAt: TimeInterval?
    private var hasPendingFade = false

    public init() {}

    /// Something the HUD describes changed: a new image, a new page, a new zoom, or a
    /// viewport that moved. This is the only way the HUD becomes visible.
    public mutating func noteMeaningfulChange(at time: TimeInterval) {
        lastChangeAt = time
        hasPendingFade = true
        if hasImage, !immersive { visible = true }
    }

    public mutating func setHasImage(_ value: Bool, at time: TimeInterval) {
        guard value != hasImage else { return }
        hasImage = value
        if value {
            noteMeaningfulChange(at: time)
        } else {
            visible = false
            hasPendingFade = false
            lastChangeAt = nil
        }
    }

    public mutating func setImmersive(_ value: Bool, at time: TimeInterval) {
        immersive = value
        if value {
            visible = false
            // The pending fade is cancelled, not merely postponed: leaving immersive mode must
            // not produce a HUD that was never asked for.
            hasPendingFade = false
            lastChangeAt = nil
        }
    }

    /// Recomputes visibility. Returns `true` when it changed.
    @discardableResult
    public mutating func update(at time: TimeInterval) -> Bool {
        let before = visible
        if !hasImage || immersive {
            visible = false
        } else if hasPendingFade, let lastChangeAt, time - lastChangeAt >= timing.idleFadeDelay {
            visible = false
            hasPendingFade = false
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
public struct ViewerChromeModel: Sendable {
    public struct Timing: Sendable {
        public var minimapIdleFadeDelay: TimeInterval = 1.5

        public init() {}
    }

    public var timing = Timing()
    /// The four overlay surfaces, each with its own state, its own inputs and its own rules.
    /// They share this tick and nothing else: there is no single "chrome is visible" flag, and no
    /// pointer event can move a surface whose rule does not mention the pointer.
    public var toolDock = ToolDockVisibilityModel()
    public var infoHUD = InfoHUDVisibilityModel()

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
        infoHUD.setImmersive(value, at: time)
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
        infoHUD.update(at: time)

        return snapshot != before
    }

    /// The drawer as the user sees it: open, and not suppressed by immersive mode.
    public var drawerVisible: Bool { drawerOpen && !immersive }

    public var snapshot: Snapshot {
        Snapshot(drawer: drawerVisible, minimap: minimapVisible, toolDock: toolDock.visible,
                 infoHUD: infoHUD.visible)
    }

    public struct Snapshot: Equatable, Sendable {
        public let drawer: Bool
        public let minimap: Bool
        public let toolDock: Bool
        public let infoHUD: Bool
    }

    /// Keyboard navigation must always work, even with all overlay chrome hidden.
    public var chromeHidden: Bool {
        !drawerVisible && !minimapVisible && !toolDock.visible && !infoHUD.visible
    }
}
