import Foundation
import CoreGraphics

public enum WheelMode: String, CaseIterable, Codable, Sendable {
    case zoom
    case pan
    case navigate
}

public enum SwipeMode: String, CaseIterable, Codable, Sendable {
    case smart
    case alwaysSwitch
    case alwaysPan
    case disabled
}

public enum DoubleClickMode: String, CaseIterable, Codable, Sendable {
    case fitDoubleFit
    case actualPixels
    case toggleImmersive
}

/// What the pointer/gesture wants. The router never navigates folders itself;
/// it only states intent.
public enum GestureIntent: Equatable, Sendable {
    case none
    case zoom(factor: CGFloat, anchor: CGPoint)
    case pan(CGSize)
    case previousImage
    case nextImage
}

/// Pure gesture routing: wheel mode, pinch-always-zoom and the N4 smart swipe
/// state machine with hysteresis.
public struct GestureRouter: Sendable {
    public var wheelMode: WheelMode
    public var swipeMode: SwipeMode
    /// Fraction of the view width a continuous overscroll must exceed before it
    /// switches images, so a small accidental overscroll does not navigate.
    public var switchThreshold: CGFloat

    private var accumulated: CGFloat = 0
    private var didSwitchInGesture = false
    /// Which gesture armed the switch, so the arming can only be redeemed by a
    /// *later* one. While zoomed, one swipe at the edge is not enough: it arms, and
    /// the next swipe performs it - a pan that runs out of image does not navigate.
    private var armedAtGesture: Int?
    private var gestureSerial = 0

    /// `true` when a swipe has armed the switch and the next one will carry it out.
    public var zoomedSwitchArmed: Bool { armedAtGesture != nil }

    public init(wheelMode: WheelMode = .zoom, swipeMode: SwipeMode = .smart,
                switchThreshold: CGFloat = 0.12) {
        self.wheelMode = wheelMode
        self.swipeMode = swipeMode
        self.switchThreshold = switchThreshold
    }

    public mutating func beginGesture() {
        accumulated = 0
        didSwitchInGesture = false
        gestureSerial += 1
        // The arming deliberately survives a gesture boundary: one swipe arms, the
        // next one switches.
    }

    /// Clears the armed state, for example when the image changes.
    public mutating func disarmZoomedSwitch() {
        armedAtGesture = nil
        accumulated = 0
    }

    public mutating func endGesture() { beginGesture() }

    /// Mouse wheel / scroll wheel. Default mode zooms centered on the pointer.
    public mutating func routeWheel(deltaY: CGFloat, deltaX: CGFloat, anchor: CGPoint,
                                    modifierZoomOut: Bool = false) -> GestureIntent {
        switch wheelMode {
        case .zoom:
            guard deltaY != 0 else { return .none }
            let factor = pow(1.0015, -deltaY * (modifierZoomOut ? 0.5 : 1))
            return .zoom(factor: factor, anchor: anchor)
        case .pan:
            return .pan(CGSize(width: deltaX, height: deltaY))
        case .navigate:
            return routeSwipe(deltaX: deltaY != 0 ? deltaY : deltaX, viewWidth: 1,
                              isZoomedIn: false, canPanInDirection: false)
        }
    }

    /// Trackpad pinch always zooms, regardless of the configured wheel mode.
    public mutating func routePinch(magnification: CGFloat, anchor: CGPoint) -> GestureIntent {
        guard magnification != 0 else { return .none }
        return .zoom(factor: 1 + magnification, anchor: anchor)
    }

    /// Trackpad two-finger scroll / swipe.
    /// - Parameters:
    ///   - deltaX: positive means the content is being dragged to the right.
    ///   - deltaY: the vertical part of the same gesture, panned together with the
    ///     horizontal one so a diagonal gesture moves the image instead of splitting
    ///     into a pan and a switch.
    ///   - canPanInDirection: `false` when the image is already at the edge that
    ///     this swipe direction would reveal.
    /// - Parameter canSwitch: `false` while the gesture is coasting on momentum.
    ///   Inertia must never navigate: a fast flick that ends at the edge would
    ///   otherwise keep pushing past the threshold after the fingers have lifted.
    public mutating func routeSwipe(deltaX: CGFloat, deltaY: CGFloat = 0, viewWidth: CGFloat,
                                    isZoomedIn: Bool, canPanInDirection: Bool,
                                    canSwitch: Bool = true) -> GestureIntent {
        guard viewWidth > 0 else { return .none }
        switch swipeMode {
        case .disabled:
            return isZoomedIn ? .pan(CGSize(width: deltaX, height: deltaY)) : .none
        case .alwaysPan:
            // "Always pan" pans whenever there is something to pan; navigating is
            // only what it does where panning is impossible, and never on a coast.
            if isZoomedIn { return .pan(CGSize(width: deltaX, height: deltaY)) }
            guard canSwitch else { return .none }
            return switchIntent(deltaX: deltaX, viewWidth: viewWidth)
        case .alwaysSwitch:
            guard canSwitch else { return .none }
            return switchIntent(deltaX: deltaX, viewWidth: viewWidth)
        case .smart:
            if isZoomedIn && canPanInDirection {
                // Moving away from the edge disarms: the user is looking around again.
                accumulated = 0
                armedAtGesture = nil
                return .pan(CGSize(width: deltaX, height: deltaY))
            }
            // Coasting inertia is allowed to finish a pan but never to navigate.
            guard canSwitch else {
                return isZoomedIn ? .pan(CGSize(width: deltaX, height: deltaY)) : .none
            }
            if isZoomedIn {
                return armedSwitchIntent(deltaX: deltaX, viewWidth: viewWidth)
            }
            return switchIntent(deltaX: deltaX, viewWidth: viewWidth)
        }
    }

    /// The zoomed-state rule: the swipe that reaches the threshold arms the switch,
    /// and only a later gesture redeems it. Continuing the *same* swipe cannot switch,
    /// however far it travels.
    private mutating func armedSwitchIntent(deltaX: CGFloat, viewWidth: CGFloat) -> GestureIntent {
        guard !didSwitchInGesture else { return .none }
        if let armedAtGesture, armedAtGesture < gestureSerial {
            self.armedAtGesture = nil
            didSwitchInGesture = true
            accumulated = 0
            return deltaX > 0 ? .previousImage : .nextImage
        }
        accumulated += deltaX
        guard abs(accumulated) >= viewWidth * switchThreshold else { return .none }
        accumulated = 0
        armedAtGesture = gestureSerial
        return .none
    }

    private mutating func switchIntent(deltaX: CGFloat, viewWidth: CGFloat) -> GestureIntent {
        guard !didSwitchInGesture else { return .none }
        accumulated += deltaX
        guard abs(accumulated) >= viewWidth * switchThreshold else { return .none }
        didSwitchInGesture = true
        let intent: GestureIntent = accumulated > 0 ? .previousImage : .nextImage
        accumulated = 0
        return intent
    }
}
