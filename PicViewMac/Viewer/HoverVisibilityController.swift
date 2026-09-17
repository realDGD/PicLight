import Foundation
import CoreGraphics

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

        return snapshot != before
    }

    public var snapshot: Snapshot {
        Snapshot(drawer: drawerVisible, minimap: minimapVisible)
    }

    public struct Snapshot: Equatable, Sendable {
        public let drawer: Bool
        public let minimap: Bool
    }

    /// Keyboard navigation must always work, even with all overlay chrome hidden.
    public var chromeHidden: Bool { !drawerVisible && !minimapVisible }
}
