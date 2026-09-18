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

    /// Native-detail tiles drawn over the bounded proxy. The proxy is always drawn
    /// first, so a missing or late tile degrades to exactly what was on screen before
    /// rather than to a hole.
    public var nativeTiles: [NativeTile] = [] {
        didSet {
            guard nativeTiles.map({ $0.key }) != oldValue.map({ $0.key }) else { return }
            // Tiles on screen are protected from the texture budget: a warm upload must never evict
            // what is being drawn.
            metalRenderer?.protectedTileKeys = Set(nativeTiles.map { $0.key })
            pushToMetal()
            needsDisplay = true
        }
    }

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
    /// Kept so tile textures can be trimmed from the viewer's side; the surface holds the
    /// same renderer.
    private var metalRenderer: MetalImageRenderer?

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
            metalRenderer = nil
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
        metalRenderer = renderer
        pushToMetal()
        needsDisplay = true
    }

    private func pushToMetal() {
        guard let surface = metalSurface else { return }
        let renderable = renderImage.map { MetalImageRenderer.canRender($0.bitmap) } ?? false
        let renderableTiles = renderable ? nativeTiles.filter { MetalImageRenderer.canRender($0.image) } : []
        surface.update(renderImage: renderable ? renderImage : nil,
                       nativeTiles: renderableTiles,
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
        rotate(toQuarterTurns: viewport.normalizedQuarterTurns + 1)
    }

    public func rotateCounterClockwise() {
        rotate(toQuarterTurns: viewport.normalizedQuarterTurns + 3)
    }

    /// Rotation and mirroring carry the image point under the view centre across the
    /// change. Reusing the same normalized pair would keep the *numbers* and move the
    /// user somewhere else entirely — the pair means different image points once the
    /// axes have turned.
    private func rotate(toQuarterTurns turns: Int) {
        guard imagePixelSize != .zero else { return }
        let source = imagePixelSize
        var updated = viewport
        let imagePoint = viewport.imagePointUnderViewCenter(sourcePixelSize: source)
        updated.viewRotationQuarterTurns = turns
        updated.normalizedCenter = ViewportState.normalizedCenter(
            keeping: imagePoint, sourcePixelSize: source,
            quarterTurns: updated.normalizedQuarterTurns,
            mirroredHorizontally: updated.mirroredHorizontally)
        updated.fitScale = ViewportState.fitScale(
            imagePixels: ViewportState.displayedPixelSize(source, quarterTurns: updated.normalizedQuarterTurns),
            viewPoints: bounds.size)
        updated.clampCenter(imagePixels: source, viewPoints: bounds.size, backingScale: backingScale)
        viewport = updated
    }

    public func toggleMirror() {
        guard imagePixelSize != .zero else { return }
        let source = imagePixelSize
        var updated = viewport
        let imagePoint = viewport.imagePointUnderViewCenter(sourcePixelSize: source)
        updated.toggleMirror()
        updated.normalizedCenter = ViewportState.normalizedCenter(
            keeping: imagePoint, sourcePixelSize: source,
            quarterTurns: updated.normalizedQuarterTurns,
            mirroredHorizontally: updated.mirroredHorizontally)
        updated.clampCenter(imagePixels: source, viewPoints: bounds.size, backingScale: backingScale)
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
        // Interpolation is about *backing* pixels, not points: at 100 % on a 2× display
        // zoomScale is 0.5 point per source pixel, so the old `zoom < 0.999` test called a
        // true 1:1 pixel view a minification and smoothed it — which is exactly the blur
        // the Retina case reported. Minify → smooth; 1:1 and above → leave the pixels alone.
        let physicalScale = zoom * backingScale

        context.saveGState()
        context.interpolationQuality = physicalScale < 0.999 ? .high : .none
        context.concatenate(viewport.imageToViewTransform(sourcePixelSize: source,
                                                         viewSize: bounds.size))
        context.draw(renderImage.bitmap, in: CGRect(x: -source.width / 2, y: -source.height / 2,
                                                    width: source.width, height: source.height))
        // Native detail over the proxy: the same transform, each tile in its own source
        // rectangle. Tiles overlap by their gutter, and the overlapping pixels are the
        // same pixels, so no seam shows and no blend is needed.
        for tile in nativeTiles where MetalImageRenderer.canRender(tile.image) {
            context.draw(tile.image, in: ViewportState.centredSourceRect(tile.sourceRect,
                                                                        sourcePixelSize: source))
        }
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
            // Panning is not a zoom: reporting it as one made every drag re-evaluate the
            // whole-image decode level, which is the wrong job for a gesture that only
            // moves the viewport (spec §9.5 / the tile window owns pan).
            var updated = viewport
            updated.pan(byViewDelta: delta, imagePixels: imagePixelSize, viewPoints: bounds.size)
            viewport = updated
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

    /// Drops GPU textures for tiles the viewer no longer publishes, so texture memory
    /// follows the tile cache instead of growing on its own.
    public func trimTileTextures(keeping keys: Set<NativeTileKey>) {
        metalRenderer?.trimTileTextures(keeping: keys)
    }

    /// Uploads warm tiles on the renderer's background queue, so a pan onto them is a draw
    /// rather than a main-thread upload (measured: 204 tiles cost 88 ms synchronously). The
    /// variant is fixed per batch so nothing mutable is shared with the upload thread.
    public func warmTileTextures(_ tiles: [NativeTile]) {
        metalRenderer?.warmTilesInBackground(tiles, variant: tileVariant)
    }

    /// The tile texture flavour for the current magnification (mipmapped while tiles are
    /// minified). Setting it drops the other flavour, so the GPU cache cannot hold both.
    public func setTileMipmapsEnabled(_ enabled: Bool) {
        let variant: MetalImageRenderer.TileTextureVariant = enabled ? .mipmapped : .baseOnly
        guard variant != tileVariant else { return }
        tileVariant = variant
        metalRenderer?.tileVariantForEncoding = variant
        metalRenderer?.dropTileTextures(of: enabled ? .baseOnly : .mipmapped)
    }

    private var tileVariant: MetalImageRenderer.TileTextureVariant = .baseOnly

    /// Texture cache diagnostics, for tests and the acceptance runner.
    public func tileTextureDiagnostics() -> (resident: Int, bytes: Int, budget: Int, uploads: Int,
                                             hits: Int, backgroundUploads: Int,
                                             synchronousUploads: Int) {
        guard let renderer = metalRenderer else { return (0, 0, 0, 0, 0, 0, 0) }
        return renderer.tileTextureDiagnostics()
    }

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
