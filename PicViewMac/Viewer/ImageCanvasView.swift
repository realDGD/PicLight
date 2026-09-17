import AppKit

/// Layer-backed canvas that draws the current `RenderImage` with the viewport
/// transform. Color-space information travels with the image; nothing is
/// flattened to unmanaged device RGB.
///
/// Geometry comes from the render image's descriptor, never from the bitmap: a
/// bounded proxy is smaller than the source it represents, so `bitmap.width/height`
/// must not leak into Fit, pan clamping, rotation or the navigator.
public final class ImageCanvasView: NSView {
    public var renderImage: RenderImage? {
        didSet {
            guard renderImage != oldValue else { return }
            pushToMetal()
            needsDisplay = true
        }
    }

    /// The bitmap currently on screen. Read-only on purpose: pixels cannot be
    /// published without the geometry they belong to.
    public var image: CGImage? { renderImage?.bitmap }

    public var viewport = ViewportState() {
        didSet { pushToMetal(); needsDisplay = true; onViewportChange?(viewport) }
    }

    public var backgroundColor: NSColor = .clear {
        didSet { pushToMetal(); needsDisplay = true }
    }

    // MARK: - Metal

    /// Creates the renderer; injectable so a test can force the Quartz fallback.
    ///
    /// `PICLIGHT_DISABLE_METAL=1` forces the Quartz path at runtime. It exists for A/B
    /// measurement and support triage (the animation frame path is measured both ways
    /// in the large-image notes) and never changes behaviour unless set.
    var metalRendererFactory: () -> MetalImageRenderer? = {
        if ProcessInfo.processInfo.environment["PICLIGHT_DISABLE_METAL"] == "1" { return nil }
        return MetalImageRenderer()
    }
    private var metalSurface: MetalCanvasSurface?

    /// True when this canvas is drawing through Metal rather than Quartz.
    public var isUsingMetal: Bool { metalSurface != nil }

    /// True when the bitmap on screen can actually be presented by Metal. A 16-bit or
    /// indexed bitmap cannot, and then the Quartz path draws it — with the same
    /// source-rectangle geometry, never an oversized native decode.
    public var isUsingMetalForCurrentImage: Bool {
        guard metalSurface != nil, let renderImage else { return false }
        return MetalImageRenderer.canRender(renderImage.bitmap)
    }

    /// Metal is set up only inside a real window, so headless tests and the drawing
    /// they assert keep exercising the Quartz path.
    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else {
            metalSurface?.removeFromSuperview()
            metalSurface = nil
            needsDisplay = true
            return
        }
        guard metalSurface == nil, let renderer = metalRendererFactory(),
              let surface = MetalCanvasSurface(frame: bounds, renderer: renderer) else {
            needsDisplay = true
            return
        }
        addSubview(surface)
        metalSurface = surface
        pushToMetal()
        needsDisplay = true
    }

    private func pushToMetal() {
        guard let surface = metalSurface else { return }
        let renderable = renderImage.map { MetalImageRenderer.canRender($0.bitmap) } ?? false
        surface.update(renderImage: renderable ? renderImage : nil,
                       viewport: viewport, backgroundColor: backgroundColor)
    }

    public var wheelMode: WheelMode = .zoom { didSet { router.wheelMode = wheelMode } }
    public var swipeMode: SwipeMode = .smart { didSet { router.swipeMode = swipeMode } }
    public var doubleClickMode: DoubleClickMode = .fitDoubleFit

    /// -1 previous, +1 next. The canvas never touches folder state itself.
    public var onNavigate: ((Int) -> Void)?
    public var onViewportChange: ((ViewportState) -> Void)?
    public var onDoubleClickAction: (() -> Void)?
    public var onPointerActivity: (() -> Void)?
    public var onZoomChanged: (() -> Void)?

    public var backingScale: CGFloat { window?.backingScaleFactor ?? 2 }

    private var router = GestureRouter()
    private var isDragging = false

    public override var isFlipped: Bool { false }
    public override var acceptsFirstResponder: Bool { true }
    public override var mouseDownCanMoveWindow: Bool { false }

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: - Geometry helpers

    /// Logical source size of the image being shown. Zero when nothing is loaded.
    public var imagePixelSize: CGSize { renderImage?.sourcePixelSize ?? .zero }

    public func refit() {
        guard renderImage != nil, bounds.width > 0, bounds.height > 0 else { return }
        var updated = viewport
        updated.fitScale = ViewportState.fitScale(imagePixels: imagePixelSize, viewPoints: bounds.size)
        updated.clampCenter(imagePixels: imagePixelSize, viewPoints: bounds.size, backingScale: backingScale)
        viewport = updated
    }

    public func setZoomToFit() {
        guard renderImage != nil else { return }
        var updated = viewport
        updated.fitScale = ViewportState.fitScale(imagePixels: imagePixelSize, viewPoints: bounds.size)
        updated.zoomScale = updated.fitScale
        updated.normalizedCenter = CGPoint(x: 0.5, y: 0.5)
        viewport = updated
        onZoomChanged?()
    }

    public func setZoomToFitWidth() {
        guard renderImage != nil else { return }
        var updated = viewport
        updated.fitScale = ViewportState.fitScale(imagePixels: imagePixelSize, viewPoints: bounds.size)
        updated.zoomScale = ViewportState.fitWidthScale(imagePixels: imagePixelSize,
                                                       viewPoints: bounds.size)
        updated.normalizedCenter = CGPoint(x: 0.5, y: 0.5)
        viewport = updated
        onZoomChanged?()
    }

    public func setZoomToActualPixels() {
        var updated = viewport
        updated.zoomScale = ViewportState.actualPixelScale(backingScale: backingScale)
        updated.clampCenter(imagePixels: imagePixelSize, viewPoints: bounds.size, backingScale: backingScale)
        viewport = updated
        onZoomChanged?()
    }

    public func toggleFitAndDoubleFit() {
        guard renderImage != nil else { return }
        var updated = viewport
        let fit = ViewportState.fitScale(imagePixels: imagePixelSize, viewPoints: bounds.size)
        if updated.isAtFit {
            updated.fitScale = fit
            updated.zoomScale = ViewportState.doubleFitScale(fit: fit)
        } else {
            updated.fitScale = fit
            updated.zoomScale = fit
            updated.normalizedCenter = CGPoint(x: 0.5, y: 0.5)
        }
        viewport = updated
        onZoomChanged?()
    }

    public func rotateClockwise() {
        var updated = viewport
        updated.rotateClockwise()
        updated.fitScale = ViewportState.fitScale(
            imagePixels: ViewportState.displayedPixelSize(imagePixelSize, quarterTurns: updated.normalizedQuarterTurns),
            viewPoints: bounds.size
        )
        viewport = updated
    }

    public func rotateCounterClockwise() {
        var updated = viewport
        updated.rotateCounterClockwise()
        updated.fitScale = ViewportState.fitScale(
            imagePixels: ViewportState.displayedPixelSize(imagePixelSize, quarterTurns: updated.normalizedQuarterTurns),
            viewPoints: bounds.size
        )
        viewport = updated
    }

    public func toggleMirror() {
        var updated = viewport
        updated.toggleMirror()
        viewport = updated
    }

    private func canPan(deltaX: CGFloat) -> Bool {
        guard renderImage != nil else { return false }
        let rect = viewport.visibleNormalizedRect(imagePixels: imagePixelSize,
                                                  viewPoints: bounds.size)
        return deltaX > 0 ? rect.minX > 0.001 : rect.maxX < 0.999
    }

    // MARK: - Drawing

    public override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        backgroundColor.setFill()
        bounds.fill()
        // When the surface is presenting this bitmap, the canvas paints only the
        // background. An unsupported bitmap (16-bit, indexed) falls through to the
        // Quartz path below instead of leaving an empty canvas.
        if isUsingMetalForCurrentImage { return }
        guard let renderImage else { return }

        // The bitmap is mapped over the source rectangle: a bounded proxy and a
        // native bitmap must produce identical geometry for the same source. The
        // transform is shared with the Metal path so a rotated view cannot mean two
        // different things.
        let source = renderImage.sourcePixelSize
        let zoom = viewport.zoomScale

        context.saveGState()
        context.interpolationQuality = zoom < 0.999 ? .high : .none
        context.concatenate(viewport.imageToViewTransform(sourcePixelSize: source,
                                                         viewSize: bounds.size))
        context.draw(renderImage.bitmap, in: CGRect(x: -source.width / 2, y: -source.height / 2,
                                                    width: source.width, height: source.height))
        context.restoreGState()
    }

    // MARK: - Interaction

    /// Where a scroll event came from. A trackpad gesture produces two phases: the
    /// fingers, then - after they lift - a momentum coast that macOS keeps sending.
    enum ScrollGestureOrigin: Equatable {
        case mouseWheel
        case trackpadFingers
        case trackpadMomentum
    }

    nonisolated static func gestureOrigin(preciseDeltas: Bool, phase: NSEvent.Phase,
                                          momentumPhase: NSEvent.Phase) -> ScrollGestureOrigin {
        guard preciseDeltas else { return .mouseWheel }
        return momentumPhase == [] ? .trackpadFingers : .trackpadMomentum
    }

    public override func scrollWheel(with event: NSEvent) {
        onPointerActivity?()
        let point = convert(event.locationInWindow, from: nil)
        let deltaX = event.scrollingDeltaX
        let deltaY = event.scrollingDeltaY
        let origin = Self.gestureOrigin(preciseDeltas: event.hasPreciseScrollingDeltas,
                                        phase: event.phase,
                                        momentumPhase: event.momentumPhase)
        // Fingers may navigate; coasting momentum may only finish moving the image.
        let isMomentum = origin == .trackpadMomentum
        let isTrackpad = origin != .mouseWheel

        // A clearly horizontal gesture pans, or reaches the edge and switches; the
        // vertical axis keeps the configured wheel behaviour in every state, so
        // zooming does not turn into panning once the image is enlarged.
        if abs(deltaX) > abs(deltaY) * 1.5 {
            if !isMomentum, event.phase == .began || event.phase == .mayBegin { router.beginGesture() }
            let intent = router.routeSwipe(
                deltaX: deltaX, deltaY: deltaY, viewWidth: bounds.width,
                isZoomedIn: viewport.isZoomedIn,
                canPanInDirection: canPan(deltaX: deltaX),
                canSwitch: !isMomentum
            )
            apply(intent)
            if !isMomentum, event.phase == .ended || event.phase == .cancelled { router.endGesture() }
            return
        }

        let intent = router.routeWheel(
            deltaY: deltaY, deltaX: deltaX, anchor: point,
            modifierZoomOut: event.modifierFlags.contains(.option)
        )
        apply(intent)
    }

    public override func magnify(with event: NSEvent) {
        onPointerActivity?()
        let point = convert(event.locationInWindow, from: nil)
        apply(router.routePinch(magnification: event.magnification, anchor: point))
    }

    private func apply(_ intent: GestureIntent) {
        switch intent {
        case .none:
            break
        case let .zoom(factor, anchor):
            var updated = viewport
            updated.zoom(to: updated.zoomScale * factor, around: anchor, viewPoints: bounds.size,
                         imagePixels: imagePixelSize,
                         minScale: min(viewport.fitScale, ViewportState.actualPixelScale(backingScale: backingScale)) * 0.25,
                         maxScale: max(viewport.fitScale * 40, 8))
            viewport = updated
            onZoomChanged?()
        case let .pan(delta):
            var updated = viewport
            updated.pan(byViewDelta: delta, imagePixels: imagePixelSize, viewPoints: bounds.size)
            viewport = updated
            onZoomChanged?()
        case .previousImage:
            onNavigate?(-1)
        case .nextImage:
            onNavigate?(1)
        }
    }

    public override func mouseDown(with event: NSEvent) {
        onPointerActivity?()
        if event.clickCount == 2 {
            switch doubleClickMode {
            case .fitDoubleFit: toggleFitAndDoubleFit()
            case .actualPixels: setZoomToActualPixels()
            case .toggleImmersive: onDoubleClickAction?()
            }
            return
        }
        isDragging = viewport.isZoomedIn
    }

    public override func mouseDragged(with event: NSEvent) {
        guard isDragging else { return }
        var updated = viewport
        updated.pan(byViewDelta: CGSize(width: event.deltaX, height: event.deltaY),
                    imagePixels: imagePixelSize, viewPoints: bounds.size)
        viewport = updated
    }

    public override func mouseUp(with event: NSEvent) {
        isDragging = false
    }

    /// True while the pointer is dragging the image or the window is being resized:
    /// the moment never to start a bounded decode for a new level (§9.5).
    public var isInteracting: Bool {
        isDragging || (window?.inLiveResize ?? false)
    }

    /// Called after the canvas geometry (bounds or backing scale) changes, for the
    /// resize-driven level decision. Deliberately not called for viewport changes:
    /// zoom and pan must stay free.
    public var onGeometryChange: (() -> Void)?

    public override func layout() {
        super.layout()
        if let metalSurface, metalSurface.frame != bounds {
            metalSurface.frame = bounds
            pushToMetal()
        }
        refit()
        onGeometryChange?()
    }

    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        refit()
        onGeometryChange?()
    }
}
