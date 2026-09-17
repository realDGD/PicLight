import Foundation
import CoreGraphics

/// Pure hover/idle state machine. The controller feeds it pointer events and
/// periodic ticks; tests feed it synthetic timestamps.
public struct HoverVisibilityModel: Sendable {
    public struct Timing: Sendable {
        public var drawerOpenDelay: TimeInterval = 0.15
        public var drawerCloseDelay: TimeInterval = 0.25
        public var topFadeDelay: TimeInterval = 0.3
        public var chromeIdleHideDelay: TimeInterval = 1.75
        public var minimapIdleFadeDelay: TimeInterval = 1.5

        public init() {}
    }

    public var timing = Timing()

    public private(set) var topVisible = false
    public private(set) var bottomVisible = false
    public private(set) var drawerVisible = false
    public private(set) var minimapVisible = false

    /// Immersive mode starts with every chrome element hidden but still allows
    /// temporary hover reveal.
    public var immersive = false
    /// Minimap is only permitted while the image is zoomed past Fit.
    public var isZoomedIn = false
    /// A modal-ish surface such as the image info panel keeps chrome awake.
    public var isInteracting = false
    /// A pinned drawer stays open until the user unpins it; leaving the region
    /// no longer closes it.
    public private(set) var drawerPinned = false

    private var topEnteredAt: TimeInterval?
    private var topExitedAt: TimeInterval?
    private var drawerRequestedAt: TimeInterval?
    private var drawerExitedAt: TimeInterval?
    private var lastPointerActivity: TimeInterval = 0
    private var lastMinimapActivity: TimeInterval = 0

    public init() {}

    // MARK: - Inputs

    public mutating func pointerMoved(at time: TimeInterval) {
        lastPointerActivity = time
    }

    public mutating func pointerEnteredTop(at time: TimeInterval) {
        topEnteredAt = time
        topExitedAt = nil
        lastPointerActivity = time
    }

    public mutating func pointerExitedTop(at time: TimeInterval) {
        topEnteredAt = nil
        topExitedAt = time
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
        topVisible = false
        bottomVisible = false
        drawerVisible = false
        minimapVisible = false
        // Entering immersive mode forgets the regions the pointer was already
        // resting in, so chrome stays hidden until the pointer moves again.
        topEnteredAt = nil
        topExitedAt = nil
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

        let topShown = topEnteredAt != nil
        if topShown { topVisible = true }
        if let exitedAt = topExitedAt, !topShown,
           time - exitedAt >= timing.topFadeDelay {
            topVisible = false
            topExitedAt = nil
        }
        if !isInteracting, topVisible,
           time - lastPointerActivity >= timing.chromeIdleHideDelay {
            // Inactivity hides chrome even when the pointer is resting inside the
            // top region; any movement reveals it again.
            topVisible = false
            topEnteredAt = nil
        }

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

        // The bottom bar follows the same hover/idle fade behavior as the top bar,
        // in immersive mode as well.
        bottomVisible = topVisible || drawerVisible

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
        Snapshot(top: topVisible, bottom: bottomVisible,
                 drawer: drawerVisible, minimap: minimapVisible)
    }

    public struct Snapshot: Equatable, Sendable {
        public let top: Bool
        public let bottom: Bool
        public let drawer: Bool
        public let minimap: Bool
    }

    /// Keyboard navigation must always work, even with all chrome hidden.
    public var chromeHidden: Bool { !topVisible && !bottomVisible && !drawerVisible }
}
