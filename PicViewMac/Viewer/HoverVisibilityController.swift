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
public struct HoverVisibilityModel: Sendable {
    public struct Timing: Sendable {
        public var drawerOpenDelay: TimeInterval = 0.15
        public var drawerCloseDelay: TimeInterval = 0.25
        public var minimapIdleFadeDelay: TimeInterval = 1.5

        public init() {}
    }

    public var timing = Timing()
    /// The dock's own state machine, driven from the same tick so the timer that
    /// hides the drawer also hides the dock.
    public var toolDock = ToolDockVisibilityModel()

    public private(set) var drawerVisible = false
    public private(set) var minimapVisible = false

    /// Immersive mode hides the viewer's overlay chrome. The standard titlebar and
    /// the window itself are untouched.
    public var immersive = false
    /// Minimap is only permitted while the image is zoomed past Fit.
    public var isZoomedIn = false
    /// A modal-ish surface keeps the drawer awake.
    public var isInteracting = false
    /// A pinned drawer reserves space and stays open until the user unpins it.
    public private(set) var drawerPinned = false

    private var drawerRequestedAt: TimeInterval?
    private var drawerExitedAt: TimeInterval?
    private var lastPointerActivity: TimeInterval = 0
    private var lastMinimapActivity: TimeInterval = 0

    public init() {}

    // MARK: - Inputs

    public mutating func pointerMoved(at time: TimeInterval) {
        lastPointerActivity = time
    }

    /// Pins or unpins the drawer. The caller re-evaluates visibility afterwards.
    public mutating func setDrawerPinned(_ pinned: Bool, at time: TimeInterval) {
        drawerPinned = pinned
        if pinned {
            drawerVisible = true
            drawerRequestedAt = time
            drawerExitedAt = nil
        } else {
            // Fall back to the hover rules: if the pointer is elsewhere, the
            // drawer closes after the usual delay.
            drawerRequestedAt = nil
            drawerExitedAt = time
        }
        lastPointerActivity = time
    }

    public mutating func pointerEnteredLeftEdge(at time: TimeInterval) {
        drawerRequestedAt = time
        drawerExitedAt = nil
    }

    /// Pointer entered the drawer itself; it stays open while the pointer is inside.
    public mutating func pointerEnteredDrawer(at time: TimeInterval) {
        drawerRequestedAt = time
        drawerExitedAt = nil
    }

    public mutating func pointerExitedDrawer(at time: TimeInterval) {
        drawerRequestedAt = nil
        drawerExitedAt = time
    }

    public mutating func zoomActivity(at time: TimeInterval) {
        lastMinimapActivity = time
        lastPointerActivity = time
    }

    public mutating func setImmersive(_ value: Bool, at time: TimeInterval) {
        immersive = value
        toolDock.setImmersive(value, at: time)
        if !value {
            // Leaving immersive mode restores a pinned drawer.
            if drawerPinned { drawerVisible = true }
            return
        }
        drawerVisible = false
        minimapVisible = false
        // Entering immersive mode forgets the region the pointer was already
        // resting in, so chrome stays hidden until the pointer moves again.
        drawerRequestedAt = nil
        drawerExitedAt = nil
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

        if let requestedAt = drawerRequestedAt {
            if time - requestedAt >= timing.drawerOpenDelay { drawerVisible = true }
            lastPointerActivity = time
        }
        if drawerPinned, !immersive { drawerVisible = true }
        if let exitedAt = drawerExitedAt, drawerRequestedAt == nil, !drawerPinned,
           time - exitedAt >= timing.drawerCloseDelay {
            drawerVisible = false
            drawerExitedAt = nil
        }
        if drawerPinned, drawerRequestedAt == nil {
            // A pinned drawer keeps its close timer from firing.
            drawerExitedAt = nil
        }

        if isZoomedIn {
            if time - lastMinimapActivity <= timing.minimapIdleFadeDelay {
                minimapVisible = true
            } else {
                minimapVisible = false
            }
        } else {
            minimapVisible = false
        }

        toolDock.update(at: time)

        return snapshot != before
    }

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
