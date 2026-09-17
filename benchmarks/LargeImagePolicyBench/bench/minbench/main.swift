// D-series: minification quality — bilinear vs mipmapped vs Quartz .high reference.
// Offscreen, deterministic: renders the same source at several minification ratios
// with two sub-pixel offsets, then reports
//   * shimmer  = RMS difference between the two offsets (aliasing/temporal instability, lower better)
//   * deviation from the Quartz reference (RMSE, lower = closer to area-average)
//   * retained detail (mean |Laplacian|, higher = sharper)
//   * GPU time per frame, texture memory
//
//   minbench <image> [--width 3200] [--height 2000] [--scales 2,4,8,16]
import AppKit
import Metal
import MetalKit
import CoreGraphics
import ImageIO
import Darwin

func mbNow() -> Double { Double(clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)) / 1e9 }

let shaderSource = """
#include <metal_stdlib>
using namespace metal;
struct VOut { float4 pos [[position]]; float2 uv; };
vertex VOut v_main(uint vid [[vertex_id]],
                   constant float2 *corners [[buffer(0)]],
                   constant float2 *uvs [[buffer(1)]]) {
    VOut o; o.pos = float4(corners[vid], 0.0, 1.0); o.uv = uvs[vid]; return o;
}
fragment float4 f_main(VOut in [[stage_in]],
                       texture2d<float> tex [[texture(0)]],
                       sampler samp [[sampler(0)]]) {
    return tex.sample(samp, in.uv);
}
"""

struct Stats {
    var rms: Double          // RMS vs the Quartz reference
    var shimmer: Double      // RMS between two sub-pixel offsets
    var detail: Double       // mean |Laplacian| (sharpness proxy)
    var mean: Double
}

func stats(_ a: [UInt8], _ b: [UInt8]?, _ ref: [UInt8]?, width: Int, height: Int) -> Stats {
    var sumSq = 0.0, sum = 0.0, shimmerSq = 0.0, lap = 0.0
    let n = width * height
    for i in 0..<n {
        let o = i * 4
        let v = (Double(a[o]) + Double(a[o + 1]) + Double(a[o + 2])) / 3.0
        sum += v
        if let b { let w = (Double(b[o]) + Double(b[o + 1]) + Double(b[o + 2])) / 3.0; shimmerSq += (v - w) * (v - w) }
        if let ref { let r = (Double(ref[o]) + Double(ref[o + 1]) + Double(ref[o + 2])) / 3.0; sumSq += (v - r) * (v - r) }
    }
    // Laplacian on interior pixels only
    var count = 0
    for y in 1..<(height - 1) {
        for x in 1..<(width - 1) {
            func g(_ xx: Int, _ yy: Int) -> Double {
                let o = (yy * width + xx) * 4
                return (Double(a[o]) + Double(a[o + 1]) + Double(a[o + 2])) / 3.0
            }
            lap += abs(4 * g(x, y) - g(x - 1, y) - g(x + 1, y) - g(x, y - 1) - g(x, y + 1))
            count += 1
        }
    }
    return Stats(rms: sqrt(sumSq / Double(n)), shimmer: sqrt(shimmerSq / Double(n)),
                 detail: count > 0 ? lap / Double(count) : 0, mean: sum / Double(n))
}

final class MinBench {
    let device: MTLDevice
    let queue: MTLCommandQueue
    let pipeline: MTLRenderPipelineState
    var source: CGImage
    let width: Int, height: Int

    init(image: CGImage, width: Int, height: Int) throws {
        device = MTLCreateSystemDefaultDevice()!
        queue = device.makeCommandQueue()!
        self.source = image
        self.width = width
        self.height = height
        let library = try device.makeLibrary(source: shaderSource, options: nil)
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = library.makeFunction(name: "v_main")
        desc.fragmentFunction = library.makeFunction(name: "f_main")
        desc.colorAttachments[0].pixelFormat = .rgba8Unorm
        pipeline = try device.makeRenderPipelineState(descriptor: desc)
    }

    func makeTexture(mipmapped: Bool) -> (MTLTexture, Int) {
        let w = source.width, h = source.height
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: w, height: h, mipmapped: mipmapped)
        d.usage = [.shaderRead]
        d.storageMode = .shared
        let tex = device.makeTexture(descriptor: d)!
        let cs = source.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(source, in: CGRect(x: 0, y: 0, width: w, height: h))
        tex.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: ctx.data!, bytesPerRow: ctx.bytesPerRow)
        var mipSeconds = 0.0
        if mipmapped {
            let t = mbNow()
            let cb = queue.makeCommandBuffer()!
            let blit = cb.makeBlitCommandEncoder()!
            blit.generateMipmaps(for: tex)
            blit.endEncoding()
            cb.commit()
            cb.waitUntilCompleted()
            mipSeconds = mbNow() - t
        }
        return (tex, Int(mipSeconds * 1000))
    }

    /// Renders the source at `minification` into an offscreen texture, with the quad
    /// shifted by `subPixel` pixels to expose aliasing instability.
    func render(tex: MTLTexture, minification: Double, subPixel: Double, mipFilter: MTLSamplerMinMagFilter, mipmapped: Bool) -> ([UInt8], Double) {
        let samplerDesc = MTLSamplerDescriptor()
        samplerDesc.minFilter = mipFilter
        samplerDesc.magFilter = .linear
        samplerDesc.mipFilter = mipmapped ? .linear : .notMipmapped
        samplerDesc.sAddressMode = .clampToEdge
        samplerDesc.tAddressMode = .clampToEdge
        let sampler = device.makeSamplerState(descriptor: samplerDesc)!

        let target = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false)
        target.usage = [.renderTarget, .shaderRead]
        target.storageMode = .shared
        let out = device.makeTexture(descriptor: target)!

        let quadW = Double(source.width) * minification
        let quadH = Double(source.height) * minification
        let x0 = (Double(width) - quadW) / 2 + subPixel
        let y0 = (Double(height) - quadH) / 2
        func ndc(_ x: Double, _ y: Double) -> SIMD2<Float> {
            SIMD2(Float(x / Double(width) * 2 - 1), Float(y / Double(height) * 2 - 1))
        }
        let corners: [SIMD2<Float>] = [ndc(x0, y0), ndc(x0 + quadW, y0), ndc(x0, y0 + quadH), ndc(x0 + quadW, y0 + quadH)]
        let uvs: [SIMD2<Float>] = [SIMD2(0, 1), SIMD2(1, 1), SIMD2(0, 0), SIMD2(1, 0)]

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = out
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

        let cb = queue.makeCommandBuffer()!
        let enc = cb.makeRenderCommandEncoder(descriptor: pass)!
        enc.setRenderPipelineState(pipeline)
        enc.setVertexBuffer(device.makeBuffer(bytes: corners, length: MemoryLayout<SIMD2<Float>>.size * 4), offset: 0, index: 0)
        enc.setVertexBuffer(device.makeBuffer(bytes: uvs, length: MemoryLayout<SIMD2<Float>>.size * 4), offset: 0, index: 1)
        enc.setFragmentTexture(tex, index: 0)
        enc.setFragmentSamplerState(sampler, index: 0)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        enc.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
        let gpu = (cb.gpuEndTime - cb.gpuStartTime) * 1000

        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        out.getBytes(&bytes, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        return (bytes, gpu)
    }

    /// Quartz `.high` reference: area-average resampling, the current app's behaviour.
    func reference(minification: Double, subPixel: Double) -> [UInt8] {
        let cs = source.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                            space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.interpolationQuality = .high
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let quadW = Double(source.width) * minification
        let quadH = Double(source.height) * minification
        let x0 = (Double(width) - quadW) / 2 + subPixel
        let y0 = (Double(height) - quadH) / 2
        ctx.draw(source, in: CGRect(x: x0, y: y0, width: quadW, height: quadH))
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        memcpy(&bytes, ctx.data!, bytes.count)
        // CGContext is bottom-up; the Metal readback is top-down. Normalise to top-down.
        var flipped = [UInt8](repeating: 0, count: bytes.count)
        let rowBytes = width * 4
        for y in 0..<height {
            let src = (height - 1 - y) * rowBytes
            let dst = y * rowBytes
            flipped.replaceSubrange(dst..<(dst + rowBytes), with: bytes[src..<(src + rowBytes)])
        }
        return flipped
    }
}

// ---- main ----
let args = Array(CommandLine.arguments.dropFirst())
guard let path = args.first else { print("usage: minbench <image> [--width 3200] [--height 2000] [--scales 2,4,8,16]"); exit(2) }
func arg(_ n: String, _ d: String) -> String {
    guard let i = args.firstIndex(of: n), i + 1 < args.count else { return d }
    return args[i + 1]
}
let W = Int(arg("--width", "3200"))!, H = Int(arg("--height", "2000"))!
let scales = arg("--scales", "2,4,8,16").split(separator: ",").compactMap { Double($0) }

let pattern = arg("--pattern", "")
var procedural: CGImage?
if !pattern.isEmpty {
    let pw = Int(arg("--pattern-size", "4096"))!
    let ph = pw * 5 / 8
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: pw, height: ph, bitsPerComponent: 8, bytesPerRow: pw * 4,
                        space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    var bytes = [UInt8](repeating: 255, count: pw * ph * 4)
    var seed: UInt64 = 0x123456789ABCDEF
    func rnd() -> UInt8 { seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17; return UInt8(truncatingIfNeeded: seed >> 33) }
    for y in 0..<ph {
        for x in 0..<pw {
            let o = (y * pw + x) * 4
            let v: UInt8
            switch pattern {
            case "checker": v = ((x + y) % 2 == 0) ? 240 : 15
            case "lines":   v = (x % 2 == 0) ? 240 : 15
            case "finegrid": v = ((x % 4 == 0) || (y % 4 == 0)) ? 250 : 10
            default:        v = rnd()
            }
            bytes[o] = v; bytes[o + 1] = v; bytes[o + 2] = v; bytes[o + 3] = 255
        }
    }
    memcpy(ctx.data!, bytes, bytes.count)
    procedural = ctx.makeImage()
}
let image: CGImage
if let procedural { image = procedural }
else if let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
        let loaded = CGImageSourceCreateImageAtIndex(src, 0, nil) { image = loaded }
else { print("cannot read \(path)"); exit(1) }

let bench = try MinBench(image: image, width: W, height: H)
print("### minbench source=\(image.width)x\(image.height) target=\(W)x\(H) input=\(pattern.isEmpty ? (path as NSString).lastPathComponent : pattern)")

let (texMip, mipMs) = bench.makeTexture(mipmapped: true)
let (texNoMip, _) = bench.makeTexture(mipmapped: false)
print("texture = \(image.width * image.height * 4 / 1048576) MiB base, \(image.width * image.height * 4 * 4 / 3 / 1048576) MiB with mips, mip generation = \(mipMs) ms")
print("")
print(String(format: "%-6@ %-22@ %8@ %8@ %8@ %8@", "scale" as NSString, "variant" as NSString, "rmse_ref" as NSString, "shimmer" as NSString, "detail" as NSString, "gpu_ms" as NSString))
for scale in scales {
    let minification = 1.0 / scale
    let ref0 = bench.reference(minification: minification, subPixel: 0)
    let ref1 = bench.reference(minification: minification, subPixel: 0.5)
    let r0 = stats(ref0, ref1, nil, width: W, height: H)
    print(String(format: "%-6.0f %-22@ %8.2f %8.2f %8.3f %8@", scale, "D3 Quartz .high" as NSString, r0.rms, r0.shimmer, r0.detail, "-" as NSString))
    for (label, tex, mip) in [("D1 bilinear no-mip", texNoMip, false), ("D2 mipmapped linear", texMip, true)] {
        let (a, gpuA) = bench.render(tex: tex, minification: minification, subPixel: 0, mipFilter: .linear, mipmapped: mip)
        let (b, _) = bench.render(tex: tex, minification: minification, subPixel: 0.5, mipFilter: .linear, mipmapped: mip)
        let s = stats(a, b, ref0, width: W, height: H)
        print(String(format: "%-6.0f %-22@ %8.2f %8.2f %8.3f %8.3f", scale, label as NSString, s.rms, s.shimmer, s.detail, gpuA))
    }
    print("")
}
