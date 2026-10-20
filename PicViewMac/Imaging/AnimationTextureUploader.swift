import CoreGraphics
import Foundation
import Metal

/// Only canonical sRGB, integer 8-bit packed pixels are eligible. Other images
/// retain the CGContext color-managed conversion path.
struct AnimationPacked32Layout {
    let offsets: SIMD4<UInt32>
    let flags: UInt32
    init?(image: CGImage) {
        guard image.bitsPerComponent == 8, image.bitsPerPixel == 32, !image.isMask,
            image.decode == nil, !image.bitmapInfo.contains(.floatComponents),
            image.colorSpace == CGColorSpace(name: CGColorSpace.sRGB)
        else { return nil }
        let order = image.bitmapInfo.intersection(.byteOrderMask)
        guard order.isEmpty || order == .byteOrder32Big || order == .byteOrder32Little else { return nil }
        var channels: SIMD4<UInt32>
        switch image.alphaInfo {
        case .last, .premultipliedLast, .noneSkipLast: channels = SIMD4(0, 1, 2, 3)
        case .first, .premultipliedFirst, .noneSkipFirst: channels = SIMD4(1, 2, 3, 0)
        default: return nil
        }
        if order == .byteOrder32Little { channels = SIMD4(repeating: 3) &- channels }
        offsets = channels
        let opaque = image.alphaInfo == .noneSkipLast || image.alphaInfo == .noneSkipFirst
        let premultiplied = image.alphaInfo == .premultipliedLast || image.alphaInfo == .premultipliedFirst
        flags = (opaque ? 1 : 0) | (premultiplied ? 2 : 0)
    }
}

/// All conversion and GPU waits occur on the serial decode worker, never in draw().
final class AnimationTextureUploader {
    let staging: MTLBuffer
    private let queue: MTLCommandQueue
    private let converter: AnimationPacked32Converter?
    private let rowBytes: Int
    private let width: Int
    private let height: Int

    init(device: MTLDevice, width: Int, height: Int) throws {
        self.width = width
        self.height = height
        rowBytes = (width * 4 + 255) / 256 * 256
        let options: MTLResourceOptions = device.hasUnifiedMemory ? .storageModeShared : .storageModeManaged
        guard let queue = device.makeCommandQueue(),
            let staging = device.makeBuffer(length: rowBytes * height, options: options)
        else {
            throw ImageDecodeError.noDisplayableImage
        }
        self.queue = queue
        self.staging = staging
        converter = try? AnimationPacked32Converter(device: device)
    }

    func upload(_ image: CGImage, to texture: MTLTexture) throws -> CGColorSpace {
        let layout =
            image.width == width && image.height == height ? AnimationPacked32Layout(image: image) : nil
        let data = layout == nil ? nil : image.dataProvider?.data as Data?
        let gpu = converter != nil && layout != nil && (data?.count ?? 0) >= image.bytesPerRow * height
        let color =
            image.colorSpace?.model == .rgb ? image.colorSpace! : CGColorSpace(name: CGColorSpace.sRGB)!
        if gpu, let data {
            data.withUnsafeBytes { raw in
                for y in 0..<height {
                    memcpy(
                        staging.contents().advanced(by: y * rowBytes),
                        raw.baseAddress!.advanced(by: y * image.bytesPerRow), width * 4)
                }
            }
        } else {
            let detached = try AnimationImageSource.detached(image)
            guard
                let context = CGContext(
                    data: staging.contents(), width: width, height: height,
                    bitsPerComponent: 8, bytesPerRow: rowBytes, space: color,
                    bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue
                        | CGImageAlphaInfo.premultipliedFirst.rawValue)
            else {
                throw ImageDecodeError.noDisplayableImage
            }
            context.setBlendMode(.copy)
            context.interpolationQuality = .high
            context.draw(detached, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        if staging.storageMode == .managed { staging.didModifyRange(0..<staging.length) }
        guard let command = queue.makeCommandBuffer() else { throw ImageDecodeError.noDisplayableImage }
        if gpu, let layout, let converter {
            try converter.encode(
                layout: layout, buffer: staging, rowBytes: rowBytes, to: texture, command: command)
        } else {
            guard let blit = command.makeBlitCommandEncoder() else {
                throw ImageDecodeError.noDisplayableImage
            }
            blit.copy(
                from: staging, sourceOffset: 0, sourceBytesPerRow: rowBytes,
                sourceBytesPerImage: rowBytes * height,
                sourceSize: MTLSize(width: width, height: height, depth: 1),
                to: texture, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin())
            blit.endEncoding()
        }
        if texture.mipmapLevelCount > 1 {
            guard let blit = command.makeBlitCommandEncoder() else {
                throw ImageDecodeError.noDisplayableImage
            }
            blit.generateMipmaps(for: texture)
            blit.endEncoding()
        }
        command.commit()
        command.waitUntilCompleted()
        guard command.status == .completed else { throw ImageDecodeError.noDisplayableImage }
        return color
    }
}

final class AnimationPacked32Converter {
    private let pipeline: MTLComputePipelineState
    init(device: MTLDevice) throws {
        guard let library = MetalLibraryLocator.defaultLibrary(device: device),
            let function = library.makeFunction(name: "animationNormalize32")
        else {
            throw ImageDecodeError.noDisplayableImage
        }
        pipeline = try device.makeComputePipelineState(function: function)
    }
    func encode(
        layout: AnimationPacked32Layout, buffer: MTLBuffer, rowBytes: Int, to texture: MTLTexture,
        command: MTLCommandBuffer
    ) throws {
        struct Parameters {
            var rowBytes, width, height, flags: UInt32
            var offsets: SIMD4<UInt32>
        }
        var p = Parameters(
            rowBytes: UInt32(rowBytes), width: UInt32(texture.width), height: UInt32(texture.height),
            flags: layout.flags, offsets: layout.offsets)
        guard let encoder = command.makeComputeCommandEncoder() else {
            throw ImageDecodeError.noDisplayableImage
        }
        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(buffer, offset: 0, index: 0)
        encoder.setBytes(&p, length: MemoryLayout<Parameters>.stride, index: 1)
        encoder.setTexture(texture, index: 0)
        encoder.dispatchThreads(
            MTLSize(width: texture.width, height: texture.height, depth: 1),
            threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
        encoder.endEncoding()
    }
}
