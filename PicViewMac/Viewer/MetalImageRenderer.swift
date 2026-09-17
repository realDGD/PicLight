import Foundation
import CoreGraphics
import Metal
import simd

/// Draws a decoded bitmap with Metal: one textured quad, a transform supplied by the
/// CPU, mandatory mipmaps and linear magnification.
///
/// What it deliberately does **not** do: decode. Metal cannot speed up PNG
/// decompression (measured: the decode is ~18 s of inflate + row filtering for the
/// investigation image, while a texture upload is 41 ms), so the renderer's job is
/// interaction only — zoom, pan, rotate and mirror without re-rasterizing on the CPU.
public final class MetalImageRenderer {

    /// Whether Metal can present this bitmap, and the one texture format it uses.
    ///
    /// Every supported source is uploaded as **BGRA premultiplied**, via the single
    /// `CGContext` pass the upload already performs. That is deliberate rather than a
    /// per-layout table: `byteOrder32Little` + `premultipliedFirst` is BGRA in memory,
    /// but the same byte order with `premultipliedLast` is *ABGR*, so a table with one
    /// wrong entry yields a plausible-looking render with rotated channels. The first
    /// version of this file did exactly that (a 16-bit word swap showed up in the
    /// parity test), and converting inside the upload removes the whole class of error.
    ///
    /// Anything else — 16-bit, float, indexed/palette, grey — is refused so the canvas
    /// draws it with Quartz (spec §7), never narrowed or mis-rendered.
    public struct TextureLayout: Equatable {
        public let pixelFormat: MTLPixelFormat
        public let bytesPerPixel: Int
    }

    public static func textureLayout(for image: CGImage) -> TextureLayout? {
        guard image.bitsPerComponent == 8, image.bitsPerPixel == 32 else { return nil }
        switch image.alphaInfo {
        case .premultipliedFirst, .premultipliedLast, .first, .last, .noneSkipFirst, .noneSkipLast:
            return TextureLayout(pixelFormat: .bgra8Unorm, bytesPerPixel: 4)
        case .none, .alphaOnly:
            return nil
        @unknown default:
            return nil
        }
    }

    public static func canRender(_ image: CGImage) -> Bool { textureLayout(for: image) != nil }

    /// RGBA components of a colour, tolerating colour spaces with fewer components.
    ///
    /// `NSColor.clear.cgColor` is monochrome — two components — so reading index 2 or 3
    /// of its `components` traps. That crashed the first version of the parity tests,
    /// and a background colour is exactly the kind of value a caller passes without
    /// thinking about its space.
    static func rgba(_ color: CGColor) -> (red: Double, green: Double, blue: Double, alpha: Double) {
        if let sRGB = CGColorSpace(name: CGColorSpace.sRGB),
           let converted = color.converted(to: sRGB, intent: .defaultIntent, options: nil),
           let components = converted.components, components.count >= 4 {
            return (Double(components[0]), Double(components[1]),
                    Double(components[2]), Double(components[3]))
        }
        let components = color.components ?? []
        switch components.count {
        case 0: return (0, 0, 0, Double(color.alpha))
        case 1: let v = Double(components[0]); return (v, v, v, Double(color.alpha))
        case 2: let v = Double(components[0]); return (v, v, v, Double(components[1]))
        default:
            return (Double(components[0]), Double(components[1]), Double(components[2]),
                    components.count > 3 ? Double(components[3]) : Double(color.alpha))
        }
    }

    // MARK: - Instance

    let device: MTLDevice
    let queue: MTLCommandQueue
    var commandQueue: MTLCommandQueue? { queue }
    private let pipeline: MTLRenderPipelineState
    private let sampler: MTLSamplerState
    private var texture: MTLTexture?
    private var textureKey: CGImage?
    private var corners = [SIMD2<Float>](repeating: .zero, count: 4)
    private let uvs: [SIMD2<Float>] = [SIMD2(0, 1), SIMD2(1, 1), SIMD2(0, 0), SIMD2(1, 0)]

    /// `nil` when Metal is unavailable or the shader library cannot be loaded, which
    /// is the signal for the canvas to keep using Quartz.
    public init?(device: MTLDevice? = MTLCreateSystemDefaultDevice(),
                 library: MTLLibrary? = nil) {
        guard let device, let library = library ?? MetalLibraryLocator.defaultLibrary(device: device),
              let queue = device.makeCommandQueue(),
              let vertexFunction = library.makeFunction(name: "imageVertex"),
              let fragmentFunction = library.makeFunction(name: "imageFragment")
        else { return nil }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        // Premultiplied source-over.
        descriptor.colorAttachments[0].isBlendingEnabled = true
        descriptor.colorAttachments[0].sourceRGBBlendFactor = .one
        descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        descriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
        descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        guard let pipeline = try? device.makeRenderPipelineState(descriptor: descriptor) else { return nil }

        // Mandatory mipmaps (spec §9.4): bilinear minification without a mip chain
        // regressed against the current Quartz renderer by 1.5-2.6x on real content,
        // and mipmapped sampling also renders faster. Magnification stays linear (D6).
        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.minFilter = .linear
        samplerDescriptor.magFilter = .linear
        samplerDescriptor.mipFilter = .linear
        samplerDescriptor.sAddressMode = .clampToEdge
        samplerDescriptor.tAddressMode = .clampToEdge
        guard let sampler = device.makeSamplerState(descriptor: samplerDescriptor) else { return nil }

        self.device = device
        self.queue = queue
        self.pipeline = pipeline
        self.sampler = sampler
    }

    public var isReady: Bool { true }

    /// Uploads `image` once per identity change, generating the mip chain.
    @discardableResult
    public func prepareTexture(for image: CGImage) -> Bool {
        guard let layout = Self.textureLayout(for: image), image.width > 0, image.height > 0 else { return false }
        if textureKey === image, texture != nil { return true }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: layout.pixelFormat, width: image.width, height: image.height, mipmapped: true)
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else { return false }

        // Draw into the canonical BGRA context, flipping so that row zero is the image's
        // *top* row: Metal's UV origin is top-left while a CGContext is bottom-up, and a
        // silent flip here produced a plausible-looking but wrong render during the
        // D-series gate. This pass also performs the channel- and alpha-order conversion,
        // so no source layout can reach the GPU un-converted.
        let colorSpace = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue
            | CGImageAlphaInfo.premultipliedFirst.rawValue
        guard let context = CGContext(data: nil, width: image.width, height: image.height,
                                      bitsPerComponent: 8, bytesPerRow: image.width * layout.bytesPerPixel,
                                      space: colorSpace, bitmapInfo: bitmapInfo) else { return false }
        context.translateBy(x: 0, y: CGFloat(image.height))
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let data = context.data else { return false }
        texture.replace(region: MTLRegionMake2D(0, 0, image.width, image.height), mipmapLevel: 0,
                        withBytes: data, bytesPerRow: context.bytesPerRow)

        guard let commandBuffer = queue.makeCommandBuffer(),
              let blit = commandBuffer.makeBlitCommandEncoder() else { return false }
        blit.generateMipmaps(for: texture)
        blit.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        self.texture = texture
        textureKey = image
        return true
    }

    /// Texture storage in bytes, including the mip chain (4/3 of the base level).
    public var textureBytes: Int {
        guard let texture else { return 0 }
        return texture.width * texture.height * 4 * 4 / 3
    }

    public var hasMipmaps: Bool { (texture?.mipmapLevelCount ?? 1) > 1 }

    /// Renders one frame into an offscreen texture. Used by the parity tests, which
    /// compare this against the Quartz renderer pixel for pixel.
    public func renderOffscreen(image: CGImage, sourcePixelSize: CGSize, viewport: ViewportState,
                                viewSize: CGSize, contentsScale: CGFloat,
                                backgroundColor: CGColor, into texture: MTLTexture) -> Bool {
        guard let commandBuffer = queue.makeCommandBuffer() else { return false }
        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = texture
        descriptor.colorAttachments[0].loadAction = .clear
        descriptor.colorAttachments[0].storeAction = .store
        let rgba = Self.rgba(backgroundColor)
        descriptor.colorAttachments[0].clearColor = MTLClearColor(
            red: rgba.red, green: rgba.green, blue: rgba.blue, alpha: rgba.alpha)
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else { return false }
        encode(image: image, sourcePixelSize: sourcePixelSize, viewport: viewport,
               viewSize: viewSize, contentsScale: contentsScale, into: encoder)
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        return true
    }

    /// Encodes one quad into `encoder`.
    public func encode(image: CGImage, sourcePixelSize: CGSize, viewport: ViewportState,
                       viewSize: CGSize, contentsScale: CGFloat,
                       into encoder: MTLRenderCommandEncoder) {
        guard prepareTexture(for: image) else { return }
        let drawableSize = CGSize(width: viewSize.width * contentsScale, height: viewSize.height * contentsScale)
        corners = Self.quadCorners(sourcePixelSize: sourcePixelSize, viewport: viewport,
                                  viewSize: viewSize, contentsScale: contentsScale,
                                  drawableSize: drawableSize)
        encoder.setRenderPipelineState(pipeline)
        corners.withUnsafeBytes { bytes in
            encoder.setVertexBytes(bytes.baseAddress!, length: bytes.count, index: 0)
        }
        uvs.withUnsafeBytes { bytes in
            encoder.setVertexBytes(bytes.baseAddress!, length: bytes.count, index: 1)
        }
        encoder.setFragmentTexture(texture, index: 0)
        encoder.setFragmentSamplerState(sampler, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    }

    // MARK: - Geometry (the same viewport math the Quartz fallback uses)

    /// Transforms the source rectangle exactly as `ImageCanvasView.draw` does, then
    /// converts view points to clip space using the *drawable* size, never `bounds`:
    /// on a Retina layer the two differ by the backing scale, and mixing them halves
    /// or doubles the image.
    static func quadCorners(sourcePixelSize: CGSize, viewport: ViewportState, viewSize: CGSize,
                            contentsScale: CGFloat, drawableSize: CGSize) -> [SIMD2<Float>] {
        let displayed = ViewportState.displayedPixelSize(sourcePixelSize,
                                                        quarterTurns: viewport.normalizedQuarterTurns)
        var transform = CGAffineTransform.identity
        transform = transform.translatedBy(x: viewSize.width / 2, y: viewSize.height / 2)
        transform = transform.scaledBy(x: viewport.zoomScale, y: viewport.zoomScale)
        transform = transform.rotated(by: CGFloat(viewport.normalizedQuarterTurns) * .pi / 2)
        if viewport.mirroredHorizontally { transform = transform.scaledBy(x: -1, y: 1) }
        transform = transform.translatedBy(x: -(viewport.normalizedCenter.x - 0.5) * displayed.width,
                                          y: -(viewport.normalizedCenter.y - 0.5) * displayed.height)
        let halfWidth = sourcePixelSize.width / 2
        let halfHeight = sourcePixelSize.height / 2
        // Order matches `uvs`: bottom-left, bottom-right, top-left, top-right.
        let points = [CGPoint(x: -halfWidth, y: -halfHeight), CGPoint(x: halfWidth, y: -halfHeight),
                      CGPoint(x: -halfWidth, y: halfHeight), CGPoint(x: halfWidth, y: halfHeight)]
        let scaleX = drawableSize.width > 0 ? contentsScale / drawableSize.width * 2 : 0
        let scaleY = drawableSize.height > 0 ? contentsScale / drawableSize.height * 2 : 0
        return points.map { point in
            let transformed = point.applying(transform)
            return SIMD2<Float>(Float(transformed.x * scaleX - 1), Float(transformed.y * scaleY - 1))
        }
    }
}
