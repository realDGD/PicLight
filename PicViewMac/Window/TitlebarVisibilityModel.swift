import AppKit

/// The auto-hiding titlebar's state machine, and the geometry of the two zones that reveal it.
///
/// There are three states, not two, because the spec asks for two levels of reveal:
///
/// - `hidden` — no titlebar. The content occupies the top of the window.
/// - `trafficLightsOnly` — zone A: the three real `standardWindowButton` controls, and nothing
///   else. The titlebar's background and title stay away.
/// - `full` — zone B: the whole titlebar, background and title included.
///
/// The two zones are strips along the top of the *content*, which in this mode reaches the top of
/// the window: A sits over the traffic-light controls, B is the rest of that strip. Moving into B
/// from A promotes; moving from B into A does not demote, because a titlebar that collapsed while
/// the pointer slid along it would be unusable.
public struct TitlebarVisibilityModel: Sendable {

    public enum State: Equatable, Sendable {
        case hidden
        case trafficLightsOnly
        case full
    }

    /// Reasons the titlebar must not go away. Any one of them holds it where it is.
    public enum BlockReason: Hashable, Sendable {
        /// The window is being dragged. Hiding the bar the user is dragging by is how a window
        /// ends up somewhere unexpected.
        case windowDrag
        /// The pointer is on a traffic-light control and may be about to click it.
        case trafficLightInteraction
        /// A sheet is up: the window controls have to stay where the user can reach them.
        case sheet
        /// Native full screen. The system owns the top strip there.
        case fullScreen
        /// The viewer's left column — the thumbnail drawer — is open. An open column is a working
        /// state, and the bar that carries its control belongs on screen with it.
        case leftColumnOpen
    }

    public struct Timing: Sendable {
        public var hideDelay: TimeInterval = 0.7

        public init() {}
    }

    public var timing = Timing()
    /// Whether the titlebar auto-hides at all. False in "始终显示" mode, where the standard titlebar
    /// is permanently present and none of the rest of this applies.
    public private(set) var isAutoHiding = true
    public private(set) var state: State = .hidden
    public private(set) var blockedReasons: Set<BlockReason> = []

    private var exitedAt: TimeInterval?

    public init() {}

    // MARK: - Inputs

    public mutating func setAutoHiding(_ value: Bool, at time: TimeInterval) {
        guard value != isAutoHiding else { return }
        isAutoHiding = value
        // Always-visible mode is the standard window: the titlebar is simply there.
        if !value { state = .full }
        exitedAt = nil
    }

    /// Shows the whole bar now, whatever the pointer is doing.
    ///
    /// Used when something the user just opened brings its own control with it — the thumbnail
    /// drawer lives in the titlebar, so opening the column shows the bar rather than leaving the
    /// user with a column and no visible way to close it. `exitedAt` is deliberately left alone:
    /// once the reason to stay lifts, the hide delay is measured from when the pointer actually
    /// left, not from the reveal.
    public mutating func reveal() {
        guard isAutoHiding else { return }   // always-visible mode is already showing everything
        state = .full
    }

    /// Adds or removes a reason not to hide.
    ///
    /// Lifting the last reason restarts the countdown rather than letting an old one fire: the hide
    /// delay is measured from the moment the titlebar stopped being needed, and a drag that lasted
    /// longer than the delay must not make the bar vanish the instant the mouse is released.
    public mutating func setBlocked(_ reason: BlockReason, _ blocked: Bool, at time: TimeInterval) {
        let wasBlocked = !blockedReasons.isEmpty
        if blocked { blockedReasons.insert(reason) } else { blockedReasons.remove(reason) }
        if wasBlocked, blockedReasons.isEmpty, exitedAt != nil {
            exitedAt = time
        }
    }

    public mutating func setPointer(inTrafficLightsZone: Bool, inTitlebarZone: Bool,
                                    at time: TimeInterval) {
        // The pointer's position is recorded even while blocked: the countdown that starts here is
        // restarted by `setBlocked` when the last reason to stay lifts, so the bar is never held
        // longer than it should be and never hidden the instant a drag ends.
        guard isAutoHiding else { return }
        if inTitlebarZone {
            state = .full
            exitedAt = nil
        } else if inTrafficLightsZone {
            if state == .hidden { state = .trafficLightsOnly }
            exitedAt = nil
        } else {
            if exitedAt == nil { exitedAt = time }
        }
    }

    // MARK: - Evaluation

    @discardableResult
    public mutating func update(at time: TimeInterval) -> Bool {
        let before = state
        if !isAutoHiding {
            state = .full
            exitedAt = nil
        } else if !blockedReasons.isEmpty {
            // Held: nothing hides while a reason to stay is in force. `exitedAt` is deliberately
            // left alone, because `setBlocked` restarts the delay from the moment the last reason
            // lifts — clearing it here would lose the fact that the pointer has already gone.
            _ = time
        } else if let exitedAt, time - exitedAt >= timing.hideDelay {
            state = .hidden
            self.exitedAt = nil
        }
        return state != before
    }

    /// Whether the native traffic-light controls should be on screen in this state.
    public var showsTrafficLights: Bool { state != .hidden }

    /// Whether the titlebar's background and title should be on screen.
    public var showsTitlebarChrome: Bool { state == .full }
}

/// Where the two reveal zones are.
///
/// A pure function of the traffic-light controls' own frame, so the strips are over the controls
/// rather than over a guessed inset, and a test can check them without a window.
public enum TitlebarZoneGeometry {
    /// How far the strips reach down from the top of the content. The standard titlebar is 28 pt;
    /// the extra is so the pointer does not have to touch the very edge.
    public static let zoneHeight: CGFloat = 30
    /// Used when the traffic-light controls have no frame to measure (no window, or the system has
    /// taken them away): the standard macOS leading inset for three controls.
    public static let fallbackTrafficLightWidth: CGFloat = 78

    /// `trafficLights` is the union of the three controls' frames, in the coordinate space of
    /// `bounds`. `bounds` is the content area: a non-flipped rect whose top edge is `maxY`.
    public static func zones(in bounds: CGRect,
                             trafficLights: CGRect?) -> (a: CGRect, b: CGRect) {
        guard bounds.width > 0, bounds.height > 0 else { return (.null, .null) }
        let height = min(zoneHeight, bounds.height)
        let top = bounds.maxY
        let width = trafficLights.map { min($0.maxX + 8, bounds.width) } ?? fallbackTrafficLightWidth
        let a = CGRect(x: bounds.minX, y: top - height, width: max(0, width), height: height)
        let b = CGRect(x: a.maxX, y: top - height,
                       width: max(0, bounds.width - a.width), height: height)
        return (a, b)
    }
}
