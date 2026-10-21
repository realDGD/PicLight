import AppKit

/// Which part of the viewer a pointer position belongs to. Pure geometry so the
/// routing can be unit tested without synthesising mouse events.
public enum ViewerPointerZone: Equatable, Sendable {
    /// Reserved: nothing hovers at the top any more, because the standard AppKit
    /// titlebar lives there and is always visible. Kept so the geometry stays total
    /// and a future top surface can reuse it.
    case topChrome
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
    /// Height of an optional top surface. Zero in the current layout, where the
    /// window management strip is the standard titlebar rather than viewer chrome.
    public var topBarHeight: CGFloat
    public var drawerWidth: CGFloat

    public init(topBarHeight: CGFloat, drawerWidth: CGFloat) {
        self.topBarHeight = topBarHeight
        self.drawerWidth = drawerWidth
    }

    /// There is no left-edge trigger: the drawer opens only from an explicit control. The edge
    /// of an *open* drawer still belongs to the drawer, because its surface is only interactive
    /// while it is on screen.
    ///
    /// The bounds test is inclusive on every edge on purpose: `CGRect.contains`
    /// excludes `maxX`/`maxY`, which would leave the window's outermost pixel row
    /// and column unable to trigger anything.
    public func zone(for point: CGPoint, in bounds: CGRect,
                     drawerVisible: Bool, minimapRect: CGRect? = nil) -> ViewerPointerZone {
        guard bounds.width > 0, bounds.height > 0,
              point.x >= bounds.minX, point.x <= bounds.maxX,
              point.y >= bounds.minY, point.y <= bounds.maxY else { return .canvas }
        if topBarHeight > 0, point.y >= bounds.maxY - topBarHeight { return .topChrome }
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
    /// Image gestures that reach the root came through a sibling overlay rather
    /// than the canvas. Keep one destination for those unhandled events.
    weak var canvas: ImageCanvasView?
    /// Pointer moved within the window, in this view's coordinates. A native
    /// titlebar can lie above this view's bounds.
    var onPointerMoved: ((CGPoint) -> Void)?
    /// Pointer left the window entirely.
    var onPointerExited: (() -> Void)?

    private var trackingArea: NSTrackingArea?
    /// NSEvent owns its monitor token; removing it is also needed when the view
    /// leaves a window. The token is read in deinit, which Swift treats as
    /// nonisolated even though this AppKit view is confined to the main thread.
    nonisolated(unsafe) private var windowMouseMovedMonitor: Any?
    nonisolated(unsafe) private weak var windowBoundaryView: NSView?
    nonisolated(unsafe) private var windowBoundaryTrackingArea: NSTrackingArea?

    override var acceptsFirstResponder: Bool { true }

    private var imageInputTarget: ImageCanvasView? {
        guard let canvas, canvas.renderImage != nil,
              !canvas.isHiddenOrHasHiddenAncestor, canvas.alphaValue > 0.01 else { return nil }
        return canvas
    }

    /// A focus follows mouse utility can make the window key without a click.
    /// Restore image keyboard input in that path while keeping a live control's
    /// responder, including the field editor AppKit gives text fields.
    func restoreCanvasFirstResponder() {
        guard let canvas = imageInputTarget, let window else { return }
        if let responder = window.firstResponder as? NSView,
           responder !== self, responder !== canvas,
           !responder.isHiddenOrHasHiddenAncestor,
           responder is NSControl || responder is NSTextView {
            return
        }
        window.makeFirstResponder(canvas)
    }

    private func canvasReceiving(_ event: NSEvent) -> ImageCanvasView? {
        guard let canvas = imageInputTarget,
              canvas.bounds.contains(canvas.convert(event.locationInWindow, from: nil)) else {
            return nil
        }
        return canvas
    }

    override func scrollWheel(with event: NSEvent) {
        guard let canvas = canvasReceiving(event) else {
            super.scrollWheel(with: event)
            return
        }
        canvas.scrollWheel(with: event)
    }

    override func magnify(with event: NSEvent) {
        guard let canvas = canvasReceiving(event) else {
            super.magnify(with: event)
            return
        }
        canvas.magnify(with: event)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let windowMouseMovedMonitor { NSEvent.removeMonitor(windowMouseMovedMonitor) }
        windowMouseMovedMonitor = nil
        if let window {
            windowMouseMovedMonitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) {
                [weak self, weak window] event in
                MainActor.assumeIsolated {
                    guard let self, let window, self.window === window,
                          event.window === window, window.isKeyWindow else { return }
                    let point = self.convert(event.locationInWindow, from: nil)
                    // Content movement already comes through the tracking area.
                    // A native opaque titlebar lives outside that rectangle.
                    if !self.bounds.contains(point) { self.onPointerMoved?(point) }
                }
                return event
            }
        }
        updateTrackingAreas()
    }

    deinit {
        if let windowMouseMovedMonitor { NSEvent.removeMonitor(windowMouseMovedMonitor) }
        if let windowBoundaryView, let windowBoundaryTrackingArea {
            MainActor.assumeIsolated {
                windowBoundaryView.removeTrackingArea(windowBoundaryTrackingArea)
            }
        }
    }

    /// Content tracking has already exited when the pointer reaches a native
    /// titlebar. Track the enclosing window frame as well to receive the final
    /// departure through its top edge. The frame only owns boundary events.
    /// Re-check its identity after titlebar/full-screen changes in case AppKit
    /// replaces the enclosing view while keeping this content view.
    func refreshWindowBoundaryTracking() {
        let frameView = window?.contentView?.superview
        guard frameView !== windowBoundaryView else { return }
        if let windowBoundaryView, let windowBoundaryTrackingArea {
            windowBoundaryView.removeTrackingArea(windowBoundaryTrackingArea)
        }
        windowBoundaryView = frameView
        windowBoundaryTrackingArea = nil
        guard let frameView else { return }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        frameView.addTrackingArea(area)
        windowBoundaryTrackingArea = area
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
        refreshWindowBoundaryTracking()
    }

    override func mouseMoved(with event: NSEvent) {
        guard let window, event.window === window, window.isKeyWindow else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point) else { return }
        onPointerMoved?(point)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window, event.window === window, window.isKeyWindow else { return }
        // Dragging counts as pointer activity so chrome does not fade mid-gesture.
        onPointerMoved?(convert(event.locationInWindow, from: nil))
    }

    override func mouseEntered(with event: NSEvent) {
        guard let window, event.window === window, window.isKeyWindow else { return }
        onPointerMoved?(convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        guard let window, event.window === window else { return }
        if window.frame.contains(window.convertPoint(toScreen: event.locationInWindow)) {
            onPointerMoved?(convert(event.locationInWindow, from: nil))
            return
        }
        onPointerExited?()
    }
}
