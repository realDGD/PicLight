import AppKit

/// Which part of the viewer a pointer position belongs to. Pure geometry so the
/// routing can be unit tested without synthesising mouse events.
public enum ViewerPointerZone: Equatable, Sendable {
    /// The ~44 px band at the top that reveals the hover bar.
    case topChrome
    /// The narrow invisible strip at the left edge that opens the drawer.
    case leftEdgeHotZone
    /// Anywhere over the drawer while it is open.
    case drawerSurface
    /// Over the navigator minimap.
    case minimapSurface
    /// The image area itself.
    case canvas
}

/// Zone geometry for one viewer. `bounds` is the viewer's content rect and the
/// point is in the same (non-flipped) coordinate space.
public struct ViewerZoneGeometry: Equatable, Sendable {
    public var topBarHeight: CGFloat
    public var hotZoneWidth: CGFloat
    public var drawerWidth: CGFloat

    public init(topBarHeight: CGFloat, hotZoneWidth: CGFloat, drawerWidth: CGFloat) {
        self.topBarHeight = topBarHeight
        self.hotZoneWidth = hotZoneWidth
        self.drawerWidth = drawerWidth
    }

    /// Top band wins over the left edge, which wins over the drawer surface: the
    /// narrow hot zone is exactly `hotZoneWidth`, never the drawer's full width.
    ///
    /// The bounds test is inclusive on every edge on purpose: `CGRect.contains`
    /// excludes `maxX`/`maxY`, which would leave the window's outermost pixel row
    /// and column unable to trigger anything.
    public func zone(for point: CGPoint, in bounds: CGRect,
                     drawerVisible: Bool, minimapRect: CGRect? = nil) -> ViewerPointerZone {
        guard bounds.width > 0, bounds.height > 0,
              point.x >= bounds.minX, point.x <= bounds.maxX,
              point.y >= bounds.minY, point.y <= bounds.maxY else { return .canvas }
        if point.y >= bounds.maxY - topBarHeight { return .topChrome }
        if point.x <= bounds.minX + hotZoneWidth { return .leftEdgeHotZone }
        if drawerVisible, point.x <= bounds.minX + drawerWidth { return .drawerSurface }
        if let minimapRect, minimapRect.width > 0, minimapRect.height > 0,
           minimapRect.insetBy(dx: -0.5, dy: -0.5).contains(point) { return .minimapSurface }
        return .canvas
    }
}

/// The single view that owns pointer tracking for a viewer.
///
/// Chrome views deliberately install no tracking areas of their own: hover must
/// not depend on which subview happens to be on top, and hidden chrome must never
/// be the reason pointer movement stops being noticed.
final class ViewerRootView: NSView {
    /// Pointer moved inside the content area, in this view's coordinates.
    var onPointerMoved: ((CGPoint) -> Void)?
    /// Pointer left the content area entirely.
    var onPointerExited: (() -> Void)?

    private var trackingArea: NSTrackingArea?

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateTrackingAreas()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self, userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        onPointerMoved?(convert(event.locationInWindow, from: nil))
    }

    override func mouseDragged(with event: NSEvent) {
        // Dragging counts as pointer activity so chrome does not fade mid-gesture.
        onPointerMoved?(convert(event.locationInWindow, from: nil))
    }

    override func mouseEntered(with event: NSEvent) {
        onPointerMoved?(convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        onPointerExited?()
    }
}
