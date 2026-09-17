import AppKit
import MetalKit
import CoreGraphics

/// Host for the on-demand Metal canvas.
///
/// It is *not* the gesture owner: `hitTest` returns nil so every mouse and trackpad
/// event keeps flowing to `ImageCanvasView`, which stays the single interaction
/// surface the controller and the tests talk to.
///
/// Drawing is event-driven. A static image must not keep a 60/120 Hz loop alive
/// (measured: continuous rendering costs 34 mW against 5.4 mW on demand, and on a
/// 240 Hz panel the waste is larger still), so the view is paused and redraws only
/// when the canvas asks.
final class MetalCanvasSurface: MTKView, MTKViewDelegate {

    private let renderer: MetalImageRenderer
    private var renderImage: RenderImage?
    private var viewport = ViewportState()
    private var backgroundColor: CGColor = NSColor.clear.cgColor

    init?(frame: NSRect, renderer: MetalImageRenderer) {
        self.renderer = renderer
        super.init(frame: frame, device: renderer.device)
        delegate = self
        colorPixelFormat = .bgra8Unorm
        framebufferOnly = true
        isPaused = true
        enableSetNeedsDisplay = true
        autoResizeDrawable = true
        layer?.isOpaque = false
        wantsLayer = true
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func update(renderImage: RenderImage?, viewport: ViewportState, backgroundColor: NSColor) {
        self.renderImage = renderImage
        self.viewport = viewport
        self.backgroundColor = backgroundColor.cgColor
        guard renderImage != nil else { return }
        // Colour management belongs on the surface: a Display-P3 image must be
        // composited as P3 rather than reinterpreted as sRGB downstream (spec §10).
        (layer as? CAMetalLayer)?.colorspace = renderImage?.bitmap.colorSpace
            ?? CGColorSpace(name: CGColorSpace.sRGB)
        setNeedsDisplay(bounds)
    }

    /// Sizing is handled by `autoResizeDrawable`; the renderer reads `drawableSize`
    /// every frame, so nothing needs to be rebuilt when it changes.
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let renderImage,
              let descriptor = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let queue = renderer.commandQueue,
              let commandBuffer = queue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor)
        else { return }

        let rgba = MetalImageRenderer.rgba(backgroundColor)
        descriptor.colorAttachments[0].clearColor = MTLClearColor(
            red: rgba.red, green: rgba.green, blue: rgba.blue, alpha: rgba.alpha)
        encoder.setViewport(MTLViewport(originX: 0, originY: 0,
                                        width: Double(drawable.texture.width),
                                        height: Double(drawable.texture.height),
                                        znear: 0, zfar: 1))
        renderer.encode(image: renderImage.bitmap,
                        sourcePixelSize: renderImage.sourcePixelSize,
                        viewport: viewport,
                        viewSize: bounds.size,
                        contentsScale: window?.backingScaleFactor ?? 2,
                        into: encoder)
        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}
