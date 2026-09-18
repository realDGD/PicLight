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
    /// The proxy's texture, separately from the tiles': one shared "current texture" field let
    /// a tile's texture be the one bound for the proxy and vice versa, and made the proxy
    /// re-upload whenever a tile had been drawn.
    private var proxyTexture: MTLTexture?
    private var proxyTextureKey: CGImage?
    /// Tile textures, keyed by tile identity rather than by image pointer: the same tile
    /// arrives again after a pan and must not be uploaded twice.
    private let tileTextureLock = NSLock()
    private let uploadQueue = DispatchQueue(label: "picviewmac.tile-textures", qos: .utility)
    /// Which flavour of texture a tile is cached as. Part of the cache key: the two are not
    /// interchangeable, because a tile uploaded without a mip chain at 1.0 would otherwise be
    /// reused at 0.5, where it is minified up to 5:1.
    public enum TileTextureVariant: Hashable, Sendable {
        case baseOnly
        case mipmapped
    }

    private struct TileTextureKey: Hashable {
        let tile: NativeTileKey
        let variant: TileTextureVariant
    }

    private var tileTextures: [TileTextureKey: MTLTexture] = [:]
    private var tileTextureOrder: [TileTextureKey] = []
    private var tileTextureStats = (uploads: 0, hits: 0, background: 0, synchronous: 0)
    /// Bytes of tile texture storage, including each tile's mip chain.
    public private(set) var tileTextureBytes = 0
    public var tileTextureBudget = 192 * 1024 * 1024
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
        // Nearest mip selection, not trilinear: mipmaps stay mandatory for minification (D-series
        // gate), but at 1:1 a trilinear tap blends level 0 with level 1 and softens a view that is
        // already pixel-exact — the "pointless second blur at 1:1" the design warns about. Nearest
        // selection takes level 0 whenever the derivative says 0, and still picks the right level
        // where the image is genuinely minified.
        samplerDescriptor.mipFilter = .nearest
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
        if proxyTextureKey === image, proxyTexture != nil { return true }

        // The proxy needs its mip chain: it is on screen at every zoom, including well below 1:1.
        guard let texture = uploadTexture(for: image, mipmapped: true) else { return false }
        self.proxyTexture = texture
        proxyTextureKey = image
        return true
    }

    /// A coordinate-encoding image of the given size, for tests that need a tile of a specific
    /// shape. Kept next to the upload so a test cannot accidentally build a differently laid out
    /// bitmap than the production path accepts.
    public func encodedTileImage(width: Int, height: Int) -> CGImage? {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                pixels[offset] = UInt8(x % 251)
                pixels[offset + 1] = UInt8(y % 241)
                pixels[offset + 2] = UInt8((x + y) / 2)
                pixels[offset + 3] = 255
            }
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false,
                       intent: .defaultIntent)
    }

    /// Uploads any CGImage as the canonical BGRA texture the shader samples.
    private func uploadTexture(for image: CGImage, mipmapped: Bool) -> MTLTexture? {
        guard let layout = Self.textureLayout(for: image), image.width > 0, image.height > 0 else { return nil }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: layout.pixelFormat, width: image.width, height: image.height,
            mipmapped: mipmapped)
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }

        // Draw into the canonical BGRA context. No flip transform: a CGContext's first
        // memory row *is* the image's top row when the image is drawn without one, which is
        // exactly what the quad's texture coordinates assume (v = 0 at the top corner). An
        // earlier version flipped here on the belief that a CGContext is bottom-up; that made
        // every Metal render a mirror of the same scene drawn by Quartz — invisible to the
        // parity tests because their fixtures were left/right two-tone, and visible to users
        // as tiles landing mirrored inside their own rectangles while the proxy mirrored
        // about the image centre. This pass also performs the channel- and alpha-order
        // conversion, so no source layout can reach the GPU un-converted.
        let colorSpace = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue
            | CGImageAlphaInfo.premultipliedFirst.rawValue
        guard let context = CGContext(data: nil, width: image.width, height: image.height,
                                      bitsPerComponent: 8, bytesPerRow: image.width * layout.bytesPerPixel,
                                      space: colorSpace, bitmapInfo: bitmapInfo) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let data = context.data else { return nil }
        texture.replace(region: MTLRegionMake2D(0, 0, image.width, image.height), mipmapLevel: 0,
                        withBytes: data, bytesPerRow: context.bytesPerRow)

        guard mipmapped else { return texture }
        guard let commandBuffer = queue.makeCommandBuffer(),
              let blit = commandBuffer.makeBlitCommandEncoder() else { return nil }
        blit.generateMipmaps(for: texture)
        blit.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        return texture
    }

    /// Uploads one tile, reusing its texture if it is already resident, and returns it. The
    /// caller binds exactly this texture, so no shared mutable "current texture" can be stale.
    /// Drops tile textures whose tiles are no longer cached, so GPU memory follows the tile
    /// cache instead of growing on its own.
    /// Uploads one tile, reusing its texture if it is already resident, and returns it. The caller
    /// binds exactly this texture, so no shared mutable "current texture" can be stale.
    @discardableResult
    public func prepareTexture(for tile: NativeTile, variant: TileTextureVariant,
                               fromBackground: Bool = false) -> MTLTexture? {
        let key = TileTextureKey(tile: tile.key, variant: variant)
        tileTextureLock.lock()
        if let existing = tileTextures[key] {
            tileTextureStats.hits += 1
            // LRU by use, not by insertion: a tile the user just looked at must survive a pan away
            // and back.
            tileTextureOrder.removeAll { $0 == key }
            tileTextureOrder.append(key)
            tileTextureLock.unlock()
            return existing
        }
        tileTextureLock.unlock()
        // Mipmaps only where the D-series argument applies: tiles are requested as soon as the proxy
        // is out-resolved, which includes the low magnifications (measured threshold ≈ 0.2 for a
        // 48000-pixel source) where a tile is minified up to 5:1. Generation happens on the upload
        // queue, never as a synchronous wait on the main thread.
        let mipmapped = variant == .mipmapped
        guard let uploaded = uploadTexture(for: tile.image, mipmapped: mipmapped) else { return nil }
        tileTextureLock.lock()
        tileTextures[key] = uploaded
        tileTextureOrder.append(key)
        tileTextureBytes += Self.textureBytes(width: uploaded.width, height: uploaded.height,
                                              mipmapped: mipmapped)
        tileTextureStats.uploads += 1
        if fromBackground { tileTextureStats.background += 1 } else { tileTextureStats.synchronous += 1 }
        evictTileTexturesIfNeededLocked()
        tileTextureLock.unlock()
        return uploaded
    }

    /// Real allocation size: a mip chain is 4/3 of the base level, and billing it as the base alone
    /// let a 192 MiB budget hold ~256 MiB.
    static func textureBytes(width: Int, height: Int, mipmapped: Bool) -> Int {
        let base = width * height * 4
        return mipmapped ? base * 4 / 3 : base
    }

    /// Uploads tiles off the main thread. The variant is a parameter, so no mutable flag is read
    /// across threads.
    public func warmTilesInBackground(_ tiles: [NativeTile], variant: TileTextureVariant) {
        guard !tiles.isEmpty else { return }
        uploadQueue.async { [weak self] in
            guard let self else { return }
            for tile in tiles {
                _ = self.prepareTexture(for: tile, variant: variant, fromBackground: true)
            }
        }
    }

    /// Drops textures of one variant when the magnification policy changes, so the GPU cache does
    /// not hold both flavours of the same tile for long.
    public func dropTileTextures(of variant: TileTextureVariant) {
        tileTextureLock.lock(); defer { tileTextureLock.unlock() }
        for (key, texture) in tileTextures where key.variant == variant {
            tileTextureBytes -= Self.textureBytes(width: texture.width, height: texture.height,
                                                  mipmapped: variant == .mipmapped)
            tileTextures.removeValue(forKey: key)
        }
        tileTextureOrder.removeAll { !tileTextures.keys.contains($0) }
    }

    public func tileTextureDiagnostics() -> (resident: Int, bytes: Int, budget: Int, uploads: Int,
                                             hits: Int, backgroundUploads: Int,
                                             synchronousUploads: Int) {
        tileTextureLock.lock(); defer { tileTextureLock.unlock() }
        return (tileTextures.count, tileTextureBytes, tileTextureBudget, tileTextureStats.uploads,
                tileTextureStats.hits, tileTextureStats.background, tileTextureStats.synchronous)
    }

    /// The variant this frame's tiles are drawn with, set once per plan by the viewer. Read and
    /// written on the main thread only — the background uploader takes its variant as a parameter.
    public var tileVariantForEncoding: TileTextureVariant = .baseOnly

    public func trimTileTextures(keeping keys: Set<NativeTileKey>) {
        tileTextureLock.lock(); defer { tileTextureLock.unlock() }
        let doomed = tileTextures.keys.filter { !keys.contains($0.tile) }
        for key in doomed {
            if let texture = tileTextures.removeValue(forKey: key) {
                tileTextureBytes -= Self.textureBytes(width: texture.width, height: texture.height,
                                                      mipmapped: key.variant == .mipmapped)
            }
        }
        tileTextureOrder.removeAll { !tileTextures.keys.contains($0) }
    }

    /// LRU by use, not by insertion.
    private func evictTileTexturesIfNeededLocked() {
        while tileTextureBytes > tileTextureBudget, let oldest = tileTextureOrder.first {
            tileTextureOrder.removeFirst()
            if let texture = tileTextures.removeValue(forKey: oldest) {
                tileTextureBytes -= Self.textureBytes(width: texture.width, height: texture.height,
                                                      mipmapped: oldest.variant == .mipmapped)
            }
        }
    }

    /// Texture storage in bytes, including the mip chain (4/3 of the base level).
    public var textureBytes: Int {
        guard let proxyTexture else { return 0 }
        return proxyTexture.width * proxyTexture.height * 4 * 4 / 3
    }

    public var hasMipmaps: Bool { (proxyTexture?.mipmapLevelCount ?? 1) > 1 }

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

    /// Renders one frame including native-detail tiles. Used by the tests and the
    /// acceptance harness to answer "what does the renderer actually produce at 100 %":
    /// a CPU capture of the window cannot see a Metal layer's contents, and comparing the
    /// *tiles* alone would not prove that they reach the screen.
    public func renderOffscreen(image: CGImage, nativeTiles: [NativeTile],
                                sourcePixelSize: CGSize, viewport: ViewportState,
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
        for tile in nativeTiles {
            encode(tile: tile, sourcePixelSize: sourcePixelSize, viewport: viewport,
                   viewSize: viewSize, contentsScale: contentsScale, into: encoder)
        }
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        return true
    }

    /// Encodes one quad into `encoder`.
    public func encode(image: CGImage, sourcePixelSize: CGSize, viewport: ViewportState,
                       viewSize: CGSize, contentsScale: CGFloat,
                       into encoder: MTLRenderCommandEncoder) {
        guard prepareTexture(for: image), let proxyTexture else { return }
        encodeQuad(sourceRect: CGRect(origin: .zero, size: sourcePixelSize),
                   texture: proxyTexture, sourcePixelSize: sourcePixelSize, viewport: viewport,
                   viewSize: viewSize, contentsScale: contentsScale, into: encoder)
    }

    /// Draws one native-detail tile over the proxy. The tile carries its own source
    /// rectangle and its texture is the tile's own image, so no texture-coordinate
    /// arithmetic happens here — which is also why adjoining tiles cannot disagree about
    /// where their shared edge is.
    public func encode(tile: NativeTile, sourcePixelSize: CGSize, viewport: ViewportState,
                       viewSize: CGSize, contentsScale: CGFloat,
                       into encoder: MTLRenderCommandEncoder) {
        guard let texture = prepareTexture(for: tile, variant: tileVariantForEncoding) else { return }
        _ = texture
        encodeQuad(sourceRect: tile.sourceRect, texture: texture,
                   sourcePixelSize: sourcePixelSize, viewport: viewport, viewSize: viewSize,
                   contentsScale: contentsScale, into: encoder)
    }

    private func encodeQuad(sourceRect: CGRect, texture: MTLTexture, sourcePixelSize: CGSize,
                            viewport: ViewportState, viewSize: CGSize, contentsScale: CGFloat,
                            into encoder: MTLRenderCommandEncoder) {
        let drawableSize = CGSize(width: viewSize.width * contentsScale, height: viewSize.height * contentsScale)
        corners = Self.quadCorners(sourceRect: sourceRect, sourcePixelSize: sourcePixelSize,
                                  viewport: viewport, viewSize: viewSize,
                                  contentsScale: contentsScale, drawableSize: drawableSize)
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
        quadCorners(sourceRect: CGRect(origin: .zero, size: sourcePixelSize),
                    sourcePixelSize: sourcePixelSize, viewport: viewport, viewSize: viewSize,
                    contentsScale: contentsScale, drawableSize: drawableSize)
    }

    /// Corners of an arbitrary source rectangle, for native-detail tiles.
    static func quadCorners(sourceRect: CGRect, sourcePixelSize: CGSize, viewport: ViewportState,
                            viewSize: CGSize, contentsScale: CGFloat,
                            drawableSize: CGSize) -> [SIMD2<Float>] {
        // One transform for both renderers: the Quartz path concatenates the same
        // value, so a rotated or mirrored view cannot drift between the two.
        let transform = viewport.imageToViewTransform(sourcePixelSize: sourcePixelSize,
                                                     viewSize: viewSize)
        let centred = ViewportState.centredSourceRect(sourceRect, sourcePixelSize: sourcePixelSize)
        // Order matches `uvs`: bottom-left, bottom-right, top-left, top-right.
        let points = [CGPoint(x: centred.minX, y: centred.minY), CGPoint(x: centred.maxX, y: centred.minY),
                      CGPoint(x: centred.minX, y: centred.maxY), CGPoint(x: centred.maxX, y: centred.maxY)]
        let scaleX = drawableSize.width > 0 ? contentsScale / drawableSize.width * 2 : 0
        let scaleY = drawableSize.height > 0 ? contentsScale / drawableSize.height * 2 : 0
        return points.map { point in
            let transformed = point.applying(transform)
            return SIMD2<Float>(Float(transformed.x * scaleX - 1), Float(transformed.y * scaleY - 1))
        }
    }
}
