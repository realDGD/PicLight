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

    public init(wheelMode: WheelMode = .zoom, swipeMode: SwipeMode = .smart,
                switchThreshold: CGFloat = 0.12) {
        self.wheelMode = wheelMode
        self.swipeMode = swipeMode
        self.switchThreshold = switchThreshold
    }

    public mutating func beginGesture() {
        accumulated = 0
        didSwitchInGesture = false
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
    ///   - canPanInDirection: `false` when the image is already at the edge that
    ///     this swipe direction would reveal.
    public mutating func routeSwipe(deltaX: CGFloat, viewWidth: CGFloat, isZoomedIn: Bool,
                                    canPanInDirection: Bool) -> GestureIntent {
        guard viewWidth > 0 else { return .none }
        switch swipeMode {
        case .disabled:
            return isZoomedIn ? .pan(CGSize(width: deltaX, height: 0)) : .none
        case .alwaysPan:
            guard isZoomedIn else { return switchIntent(deltaX: deltaX, viewWidth: viewWidth) }
            return .pan(CGSize(width: deltaX, height: 0))
        case .alwaysSwitch:
            return switchIntent(deltaX: deltaX, viewWidth: viewWidth)
        case .smart:
            if isZoomedIn && canPanInDirection {
                accumulated = 0
                return .pan(CGSize(width: deltaX, height: 0))
            }
            return switchIntent(deltaX: deltaX, viewWidth: viewWidth)
        }
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
