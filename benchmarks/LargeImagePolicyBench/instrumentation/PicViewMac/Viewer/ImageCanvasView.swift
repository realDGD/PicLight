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
            needsDisplay = true
        }
    }

    /// The bitmap currently on screen. Read-only on purpose: pixels cannot be
    /// published without the geometry they belong to.
    public var image: CGImage? { renderImage?.bitmap }

    public var viewport = ViewportState() {
        didSet { needsDisplay = true; onViewportChange?(viewport) }
    }

    public var backgroundColor: NSColor = .clear {
        didSet { needsDisplay = true }
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
        let benchT0 = benchNow()
        let benchHadImage = renderImage != nil
        BenchTrace.markFromAnyThread(String(format: "canvas draw ENTER image=%@ zoom=%.4f bounds=%.0fx%.0f",
                                           benchHadImage ? "yes" : "nil", viewport.zoomScale,
                                           bounds.width, bounds.height))
        defer {
            BenchTrace.noteDraw(duration: benchNow() - benchT0, dirty: dirtyRect,
                                bounds: bounds, hasImage: benchHadImage)
        }
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        backgroundColor.setFill()
        bounds.fill()
        guard let renderImage else { return }
        if max(renderImage.bitmap.width, renderImage.bitmap.height) > DecodeBudget.maximumLongEdge {
            // Tripwire: an oversized bitmap reaching the canvas is the original bug.
            BenchTrace.noteTraversal("canvas rasterization(oversized:\(renderImage.bitmap.width)x\(renderImage.bitmap.height))")
        }

        // The bitmap is mapped over the source rectangle: a bounded proxy and a
        // native bitmap must produce identical geometry for the same source.
        let source = renderImage.sourcePixelSize
        let quarterTurns = viewport.normalizedQuarterTurns
        let displayed = ViewportState.displayedPixelSize(imagePixelSize, quarterTurns: quarterTurns)
        let zoom = viewport.zoomScale

        context.saveGState()
        context.interpolationQuality = zoom < 0.999 ? .high : .none
        context.translateBy(x: bounds.midX, y: bounds.midY)
        context.scaleBy(x: zoom, y: zoom)
        context.rotate(by: CGFloat(quarterTurns) * .pi / 2)
        if viewport.mirroredHorizontally { context.scaleBy(x: -1, y: 1) }
        let offsetX = (viewport.normalizedCenter.x - 0.5) * displayed.width
        let offsetY = (viewport.normalizedCenter.y - 0.5) * displayed.height
        context.translateBy(x: -offsetX, y: -offsetY)
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

    public override func layout() {
        super.layout()
        refit()
    }
}
