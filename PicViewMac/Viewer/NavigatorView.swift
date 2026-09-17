import AppKit

/// Bottom-right navigator. Geometry comes from the shared `ViewportState`, so it
/// only appears when `zoom > Fit`.
public final class NavigatorView: MaterialHostView {
    public static let defaultSize = NSSize(width: 168, height: 120)

    public var onCenterRequested: ((CGPoint) -> Void)?

    public var image: CGImage? { didSet { needsDisplay = true } }
    public var visibleNormalizedRect: CGRect = .zero { didSet { needsDisplay = true } }

    private var isDraggingViewport = false

    public override init(style: Style = .chrome) {
        super.init(style: style)
        translatesAutoresizingMaskIntoConstraints = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Maps the main viewport onto the minimap rectangle, preserving aspect ratio.
    public static func imageRect(in bounds: NSRect, imagePixels: CGSize) -> NSRect {
        guard imagePixels.width > 0, imagePixels.height > 0 else { return .zero }
        let scale = min(bounds.width / imagePixels.width, bounds.height / imagePixels.height)
        let size = NSSize(width: imagePixels.width * scale, height: imagePixels.height * scale)
        return NSRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
                      width: size.width, height: size.height)
    }

    public static func viewportRect(in imageRect: NSRect, normalized: CGRect) -> NSRect {
        NSRect(
            x: imageRect.minX + normalized.minX * imageRect.width,
            y: imageRect.minY + (1 - normalized.maxY) * imageRect.height,
            width: normalized.width * imageRect.width,
            height: normalized.height * imageRect.height
        )
    }

    public override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let context = NSGraphicsContext.current?.cgContext, let image else { return }
        let target = Self.imageRect(in: bounds.insetBy(dx: 4, dy: 4),
                                    imagePixels: CGSize(width: image.width, height: image.height))
        context.saveGState()
        context.interpolationQuality = .medium
        context.draw(image, in: target)
        context.restoreGState()

        let viewport = Self.viewportRect(in: target, normalized: visibleNormalizedRect)
        context.setStrokeColor(NSColor.controlAccentColor.cgColor)
        context.setLineWidth(1.5)
        context.stroke(viewport)
        context.setFillColor(NSColor.controlAccentColor.withAlphaComponent(0.18).cgColor)
        context.fill(viewport)
    }

    private var currentImageRect: NSRect {
        guard let image else { return .zero }
        return Self.imageRect(in: bounds.insetBy(dx: 4, dy: 4),
                              imagePixels: CGSize(width: image.width, height: image.height))
    }

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
}
