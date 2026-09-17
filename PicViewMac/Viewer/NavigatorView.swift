import AppKit

/// Bottom-right navigator. Geometry comes from the shared `ViewportState`, so it
/// only appears when `zoom > Fit`.
///
/// Layering is explicit and matters: the glass is a background, the preview image
/// sits above it, and the viewport outline sits above the preview. A material
/// applied as a plain subview would composite *over* this view's own drawing,
/// which blurred both the preview and the viewport frame and made the frame
/// refract into several ghost outlines.
public final class NavigatorView: NSView {
    /// The largest box the navigator may occupy. Its actual size follows the image
    /// aspect inside this box, so a portrait image does not sit in a landscape frame
    /// surrounded by empty glass.
    public nonisolated static let defaultSize = NSSize(width: 168, height: 120)
    /// Aspect ratios are only followed within these bounds: a panorama or a very tall
    /// image would otherwise collapse the navigator into a sliver.
    public nonisolated static let minimumAspect: CGFloat = 0.5      // 1:2
    public nonisolated static let maximumAspect: CGFloat = 2.0      // 2:1
    /// Preferred minimum length of the shorter side, so the navigator stays readable
    /// and clickable.
    ///
    /// This is a preference, not a guarantee: for an image whose aspect is clamped to
    /// the extremes (1:2 or 2:1), the maximum box cannot honour it - a 1:2 image
    /// filling a 120 pt height is only 60 pt wide. In that case the aspect clamp and
    /// the maximum box win, and the navigator simply gets narrow.
    public nonisolated static let preferredMinimumShortSide: CGFloat = 68

    /// The navigator's size for an image, clamped to the rules above.
    public nonisolated static func size(forImagePixels pixels: CGSize,
                                        maximum: NSSize,
                                        minimumShortSide: CGFloat = preferredMinimumShortSide) -> NSSize {
        guard pixels.width > 0, pixels.height > 0 else { return maximum }
        let aspect = min(max(pixels.width / pixels.height, minimumAspect), maximumAspect)
        var width = maximum.width
        var height = width / aspect
        if height > maximum.height {
            height = maximum.height
            width = height * aspect
        }
        if width < minimumShortSide && aspect >= 1 {
            width = minimumShortSide
            height = width / aspect
        } else if height < minimumShortSide && aspect < 1 {
            height = minimumShortSide
            width = height * aspect
        }
        return NSSize(width: min(width, maximum.width), height: min(height, maximum.height))
    }

    /// Preview resolution: the logical size at 2x, so the preview is never a
    /// re-sample of a full-resolution source and never blurry on Retina.
    public nonisolated static var previewPixelSize: Int {
        Int(Self.maximumPreviewSide * 2)
    }

    /// Largest preview side the navigator can need, independent of actor state.
    public nonisolated static let maximumPreviewSide: CGFloat = 168

    public var onCenterRequested: ((CGPoint) -> Void)?

    private let background = MaterialHostView(style: .chrome)
    private let previewLayerView = NSView()
    private let previewImageView = NSImageView()
    /// The outline lives in its own view above the preview. Adding the shape layer
    /// straight to the navigator's layer was not enough: the preview view's layer is
    /// created lazily, so it could end up appended *after* the outline and cover it.
    private let viewportOverlayView = PassthroughView()
    private let viewportLayer = CAShapeLayer()

    private var sizeConstraints: [NSLayoutConstraint] = []
    private var previewImage: CGImage?
    private var isDraggingViewport = false

    /// Counts how often a new preview bitmap is installed, so tests can prove that
    /// panning and zooming only move the viewport rectangle.
    public private(set) var previewGenerationCount = 0

    public var visibleNormalizedRect: CGRect = .zero {
        didSet { updateViewportOverlay() }
    }

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true

        // 1. Glass background, at the back.
        background.translatesAutoresizingMaskIntoConstraints = false
        addSubview(background)

        // 2. Preview image, above the glass.
        previewLayerView.translatesAutoresizingMaskIntoConstraints = false
        previewLayerView.wantsLayer = true
        previewLayerView.layer?.cornerRadius = 6
        previewLayerView.layer?.masksToBounds = true
        previewImageView.translatesAutoresizingMaskIntoConstraints = false
        previewImageView.imageScaling = .scaleProportionallyUpOrDown
        previewLayerView.addSubview(previewImageView)
        addSubview(previewLayerView)

        // 3. Viewport outline, in its own view above the preview.
        viewportOverlayView.translatesAutoresizingMaskIntoConstraints = false
        viewportOverlayView.wantsLayer = true
        viewportOverlayView.layer?.addSublayer(viewportLayer)
        addSubview(viewportOverlayView)

        viewportLayer.fillColor = NSColor.controlAccentColor.withAlphaComponent(0.12).cgColor
        viewportLayer.strokeColor = NSColor.controlAccentColor.cgColor
        viewportLayer.lineWidth = 1.5
        viewportLayer.isGeometryFlipped = false

        NSLayoutConstraint.activate([
            background.leadingAnchor.constraint(equalTo: leadingAnchor),
            background.trailingAnchor.constraint(equalTo: trailingAnchor),
            background.topAnchor.constraint(equalTo: topAnchor),
            background.bottomAnchor.constraint(equalTo: bottomAnchor),

            previewLayerView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            previewLayerView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            previewLayerView.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            previewLayerView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),

            previewImageView.leadingAnchor.constraint(equalTo: previewLayerView.leadingAnchor),
            previewImageView.trailingAnchor.constraint(equalTo: previewLayerView.trailingAnchor),
            previewImageView.topAnchor.constraint(equalTo: previewLayerView.topAnchor),
            previewImageView.bottomAnchor.constraint(equalTo: previewLayerView.bottomAnchor),

            viewportOverlayView.leadingAnchor.constraint(equalTo: leadingAnchor),
            viewportOverlayView.trailingAnchor.constraint(equalTo: trailingAnchor),
            viewportOverlayView.topAnchor.constraint(equalTo: topAnchor),
            viewportOverlayView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: - Content

    /// Installs a new preview bitmap. Called once per displayed image, not on
    /// every pan or zoom.
    public func setPreviewImage(_ image: CGImage?) {
        previewImage = image
        previewGenerationCount += 1
        previewImageView.image = image.map {
            NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height))
        }
        updateViewportOverlay()
    }

    public var hasPreviewImage: Bool { previewImage != nil }

    /// Pixel size of the current preview, for tests that assert the preview is a
    /// bounded downsample rather than the original image.
    public var previewPixelSize: CGSize {
        guard let previewImage else { return .zero }
        return CGSize(width: previewImage.width, height: previewImage.height)
    }

    public var viewportStrokeWidth: CGFloat { viewportLayer.lineWidth }

    /// Exposed so structure tests can assert the z-order that keeps the frame
    /// crisp: background first, then preview, then the viewport overlay.
    var backgroundSurface: NSView { background }
    var previewSurface: NSView { previewLayerView }
    var viewportOverlaySurface: NSView { viewportOverlayView }
    var viewportOverlayLayer: CAShapeLayer { viewportLayer }

    // MARK: - Geometry

    /// Maps the main viewport onto the minimap rectangle, preserving aspect ratio.
    public nonisolated static func imageRect(in bounds: NSRect, imagePixels: CGSize) -> NSRect {
        guard imagePixels.width > 0, imagePixels.height > 0 else { return .zero }
        let scale = min(bounds.width / imagePixels.width, bounds.height / imagePixels.height)
        let size = NSSize(width: imagePixels.width * scale, height: imagePixels.height * scale)
        return NSRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
                      width: size.width, height: size.height)
    }

    public nonisolated static func viewportRect(in imageRect: NSRect, normalized: CGRect) -> NSRect {
        NSRect(
            x: imageRect.minX + normalized.minX * imageRect.width,
            y: imageRect.minY + (1 - normalized.maxY) * imageRect.height,
            width: normalized.width * imageRect.width,
            height: normalized.height * imageRect.height
        )
    }

    private var previewBounds: NSRect { bounds.insetBy(dx: 4, dy: 4) }

    private var currentImageRect: NSRect {
        guard let previewImage else { return .zero }
        return Self.imageRect(in: previewBounds,
                              imagePixels: CGSize(width: previewImage.width, height: previewImage.height))
    }

    /// Aligns the stroke to the backing pixel grid so a 1.5 pt line stays sharp.
    private func aligned(_ rect: NSRect) -> NSRect {
        let scale = window?.backingScaleFactor ?? 2
        let offset = 0.5 / scale
        return rect.insetBy(dx: offset, dy: offset)
    }

    private func updateViewportOverlay() {
        guard !bounds.isEmpty, bounds.width > 1, bounds.height > 1 else {
            viewportLayer.path = nil
            return
        }
        let imageRect = currentImageRect
        guard imageRect.width > 0 else {
            viewportLayer.path = nil
            return
        }
        let rect = Self.viewportRect(in: imageRect, normalized: visibleNormalizedRect)
        viewportLayer.path = CGPath(rect: aligned(rect), transform: nil)
        viewportLayer.isHidden = false
    }

    public override func layout() {
        super.layout()
        // The shape layer is not constraint driven; keep it in step with its view,
        // and express the rectangle in that view's coordinates.
        viewportLayer.frame = viewportOverlayView.bounds
        updateViewportOverlay()
    }

    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateViewportOverlay()
    }

    // MARK: - Interaction

    private func normalizedPoint(for event: NSEvent) -> CGPoint? {
        let target = currentImageRect
        guard target.width > 0, target.height > 0 else { return nil }
        let point = convert(event.locationInWindow, from: nil)
        let x = (point.x - target.minX) / target.width
        let y = 1 - (point.y - target.minY) / target.height
        return CGPoint(x: min(max(x, 0), 1), y: min(max(y, 0), 1))
    }

    public override func mouseDown(with event: NSEvent) {
        guard let point = normalizedPoint(for: event) else { return }
        let viewport = Self.viewportRect(in: currentImageRect, normalized: visibleNormalizedRect)
        isDraggingViewport = viewport.contains(convert(event.locationInWindow, from: nil))
        onCenterRequested?(point)
    }

    public override func mouseDragged(with event: NSEvent) {
        guard isDraggingViewport, let point = normalizedPoint(for: event) else { return }
        onCenterRequested?(point)
    }

    public override func mouseUp(with event: NSEvent) {
        isDraggingViewport = false
    }

    /// The navigator is a control, so it takes clicks but never hover: pointer
    /// tracking belongs to the viewer root view.
    public override func hitTest(_ point: NSPoint) -> NSView? {
        isHidden ? nil : super.hitTest(point)
    }
}
