import CoreGraphics
import Foundation
import ImageIO
import Metal

/// A lease keeps a slot immutable through both view residency and GPU completion.
final class AnimationFrameLease: @unchecked Sendable {
    let index: Int
    let sequence: Int
    let sourceID: UUID
    let frameCount: Int
    let duration: Double
    let texture: MTLTexture?
    let bitmap: CGImage?
    let colorSpace: CGColorSpace
    private let release: @Sendable () -> Void

    init(
        index: Int, sequence: Int, sourceID: UUID, frameCount: Int, duration: Double,
        texture: MTLTexture?, bitmap: CGImage?, colorSpace: CGColorSpace,
        release: @escaping @Sendable () -> Void
    ) {
        self.index = index
        self.texture = texture
        self.bitmap = bitmap
        self.sequence = sequence
        self.sourceID = sourceID
        self.frameCount = frameCount
        self.duration = duration
        self.colorSpace = colorSpace
        self.release = release
    }
    deinit { release() }

    /// Used only for an explicit Copy Image request; playback never reads back the GPU.
    func bitmapForCopy() -> CGImage? {
        if let bitmap { return bitmap }
        guard let texture else { return nil }
        let device = texture.device
        let pitch = (texture.width * 4 + 255) / 256 * 256
        let options: MTLResourceOptions = device.hasUnifiedMemory ? .storageModeShared : .storageModeManaged
        guard let buffer = device.makeBuffer(length: pitch * texture.height, options: options),
            let command = device.makeCommandQueue()?.makeCommandBuffer(),
            let blit = command.makeBlitCommandEncoder()
        else { return nil }
        blit.copy(
            from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(),
            sourceSize: MTLSize(width: texture.width, height: texture.height, depth: 1),
            to: buffer, destinationOffset: 0, destinationBytesPerRow: pitch,
            destinationBytesPerImage: pitch * texture.height)
        if buffer.storageMode == .managed { blit.synchronize(resource: buffer) }
        blit.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        guard command.status == .completed,
            let provider = CGDataProvider(
                data: Data(bytes: buffer.contents(), count: buffer.length) as CFData)
        else { return nil }
        return CGImage(
            width: texture.width, height: texture.height, bitsPerComponent: 8,
            bitsPerPixel: 32, bytesPerRow: pitch, space: colorSpace,
            bitmapInfo: [
                .byteOrder32Little, CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue),
            ],
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}

final class AnimationFrameBuffer: @unchecked Sendable {
    private enum BufferError: LocalizedError {
        case insufficientBudget(required: Int, budget: Int)
        var errorDescription: String? {
            switch self {
            case .insufficientBudget(let required, let budget):
                return "动画帧资源需要 \(required) 字节，超过 \(budget) 字节预算"
            }
        }
    }
    struct Diagnostics: Sendable {
        var slots = 0, allocatedBytes = 0, decodedWorkingBytes = 0, sourceOpens = 0, decoded = 0
        var ready = 0, leased = 0
        var expiredDecoded = 0, catchupSkipped = 0
        var maximumServiceSeconds = 0.0
        var fullCache = false, workerEnded = false
        var error: String?
    }
    private enum State { case free, working, ready, cached, leased }
    /// Mutable state is protected by the owning buffer's condition; only the worker
    /// writes texture pixels, after all leases have been released.
    private final class Slot: @unchecked Sendable {
        let texture: MTLTexture?
        var bitmap: CGImage?
        var colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        var state = State.free
        var sequence = 0, leases = 0
        var late = false
        init(texture: MTLTexture?) { self.texture = texture }
    }
    private let condition = NSCondition()
    private let worker = DispatchQueue(label: "piclight.animation-decode", qos: .userInitiated)
    private let url: URL
    private let sourceID = UUID()
    private let identity: SourceFileIdentity
    private let descriptor: ImageDescriptor
    private let device: MTLDevice?
    private let budget: Int
    private let allowsFullCache: Bool
    private let totalPlays: Int
    private var slots: [Slot] = []
    private var stopped = false, started = false
    private var targetSequence = 0
    private var lastDeliveredSequence = -1
    private var targetElapsed: Double?
    private var clockRunning = false
    private var clockSampleTime = 0.0
    private var report = Diagnostics()
    private var producingSequence = -1
    struct TraceSnapshot {
        let target: Int, producing: Int
        let slots: [String]
    }
    var traceSnapshot: TraceSnapshot {
        locked {
            TraceSnapshot(target: targetSequence, producing: producingSequence,
                          slots: slots.map { "\($0.state):\($0.sequence):leases=\($0.leases)" })
        }
    }

    func updateClock(elapsed: Double, running: Bool) {
        locked {
            targetElapsed = elapsed
            clockRunning = running
            clockSampleTime = ProcessInfo.processInfo.systemUptime
        }
    }
    var isPrimed: Bool {
        locked {
            guard !stopped, !slots.isEmpty else { return false }
            let needed = report.fullCache ? slots.count : min(3, descriptor.frameCount)
            return slots.filter { $0.state == .ready || $0.state == .cached }.count >= needed
        }
    }

    init(
        url: URL, descriptor: ImageDescriptor, device: MTLDevice?,
        budgetBytes: Int = AnimationResourcePolicy.budgetBytes, allowsFullCache: Bool = true,
        totalPlays: Int = 0
    ) {
        self.url = url
        self.descriptor = descriptor
        self.device = device
        self.budget = max(1024, budgetBytes)
        self.allowsFullCache = allowsFullCache
        self.totalPlays = max(0, totalPlays)
        identity = SourceFileIdentity.read(at: url)
    }

    private func locked<T>(_ body: () -> T) -> T {
        condition.lock()
        defer { condition.unlock() }
        return body()
    }

    func start() {
        let shouldStart = locked { () -> Bool in
            guard !started, !stopped else { return false }
            started = true
            return true
        }
        if shouldStart { worker.async { [self] in run() } }
    }

    /// No decode, upload, GPU wait or source opening on this path.
    func frame(sequence: Int, elapsed: Double?, minimumSequence: Int? = nil) -> AnimationFrameLease? {
        guard sequence >= 0 else { return nil }
        if let minimumSequence, sequence < minimumSequence { return nil }
        guard identity.refersToSameFile(as: SourceFileIdentity.read(at: url)) else {
            stop()
            return nil
        }
        return locked {
            guard !stopped else { return nil }
            targetSequence = max(targetSequence, sequence)
            if let elapsed {
                targetElapsed = elapsed
                clockSampleTime = ProcessInfo.processInfo.systemUptime
            }
            let selected = slots.filter { slot in
                if report.fullCache {
                    return slot.state == .cached && slot.sequence == sequence % descriptor.frameCount
                }
                guard slot.state == .ready else { return false }
                if let minimumSequence {
                    return slot.sequence >= minimumSequence && slot.sequence <= sequence
                }
                return !slot.late && slot.sequence == sequence
            }.max { $0.sequence < $1.sequence }
            for slot in slots where slot.state == .ready && slot.sequence < sequence && slot !== selected {
                slot.bitmap = nil
                slot.state = .free
            }
            condition.broadcast()
            guard let slot = selected else { return nil }
            let delivered = report.fullCache ? sequence : slot.sequence
            lastDeliveredSequence = max(lastDeliveredSequence, delivered)
            slot.leases += 1
            if !report.fullCache { slot.state = .leased }
            let index = delivered % descriptor.frameCount
            let delay = descriptor.frameDurations[index]
            return AnimationFrameLease(
                index: index, sequence: delivered, sourceID: sourceID,
                frameCount: descriptor.frameCount, duration: delay.isFinite && delay > 0 ? delay : 0.1,
                texture: slot.texture,
                bitmap: slot.bitmap, colorSpace: slot.colorSpace
            ) { [self, slot] in
                locked {
                    slot.leases -= 1
                    if slot.leases == 0, slot.state == .leased {
                        slot.state = .free
                        slot.bitmap = nil
                    }
                    condition.broadcast()
                }
            }
        }
    }

    func stop() {
        locked {
            stopped = true
            for slot in slots where slot.leases == 0 { slot.bitmap = nil }
            slots.removeAll()
            condition.broadcast()
        }
    }

    var diagnostics: Diagnostics {
        locked {
            var value = report
            value.ready = slots.filter { $0.state == .ready || $0.state == .cached }.count
            value.leased = slots.filter { $0.leases > 0 }.count
            return value
        }
    }

    private func acquire() -> Slot? {
        condition.lock()
        defer { condition.unlock() }
        while !stopped {
            if let slot = slots.first(where: { $0.state == .free }) {
                slot.state = .working
                return slot
            }
            condition.wait()
        }
        return nil
    }

    private struct Resources {
        let edge: Int
        let uploader: AnimationTextureUploader?
        let textureDescriptor: MTLTextureDescriptor
        let firstTexture: MTLTexture?
        let frameBytes: Int
        let workingBytes: Int
    }

    private func currentSequence(in timeline: AnimationTimeline) -> Int {
        locked {
            guard let elapsed = targetElapsed else { return targetSequence }
            let delta = clockRunning ? max(0, ProcessInfo.processInfo.systemUptime - clockSampleTime) : 0
            return max(targetSequence, timeline.position(at: elapsed + delta).sequence)
        }
    }

    private func allocate(depth: Int) throws -> Resources {
        var edge = AnimationResourcePolicy.maximumEdge(
            size: descriptor.displayPixelSize, budget: budget, highDepth: depth > 8)
        while true {
            let resources = try autoreleasepool {
                let size = descriptor.displayPixelSize
                let scale = min(1, Double(edge) / max(size.width, size.height))
                let width = max(1, Int(size.width * scale))
                let height = max(1, Int(size.height * scale))
                let uploader =
                    depth <= 8
                    ? device.flatMap {
                        try? AnimationTextureUploader(device: $0, width: width, height: height)
                    } : nil
                let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
                    pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: true)
                textureDescriptor.storageMode = .private
                textureDescriptor.usage = [.shaderRead, .shaderWrite]
                let firstTexture = uploader == nil ? nil : device?.makeTexture(descriptor: textureDescriptor)
                if uploader != nil, firstTexture == nil { throw ImageDecodeError.noDisplayableImage }
                let cpuBytes = (width * (depth > 8 ? 8 : 4) + 255) / 256 * 256 * height
                var textureEstimate = 0
                for level in 0..<textureDescriptor.mipmapLevelCount {
                    textureEstimate += max(1, width >> level) * max(1, height >> level) * 4
                }
                let frameBytes =
                    firstTexture.map { $0.allocatedSize > 0 ? $0.allocatedSize : textureEstimate } ?? cpuBytes
                // The pool owns its textures and staging, not ImageIO's internal
                // composition / decode storage. Report that working estimate separately.
                let workingBytes =
                    uploader.map { max($0.staging.allocatedSize, $0.staging.length) } ?? cpuBytes
                return Resources(
                    edge: edge, uploader: uploader, textureDescriptor: textureDescriptor,
                    firstTexture: firstTexture, frameBytes: frameBytes, workingBytes: workingBytes)
            }
            let required = min(3, descriptor.frameCount) * resources.frameBytes + resources.workingBytes
            if required <= budget { return resources }
            guard edge > 1 else { throw BufferError.insufficientBudget(required: required, budget: budget) }
            // Tile / page alignment makes a pixel-count estimate insufficient. Reduce
            // the proxy only as needed, then recheck the driver's actual allocation.
            edge = max(1, min(edge - 1, Int(Double(edge) * sqrt(Double(budget) / Double(required)) * 0.995)))
        }
    }

    private func run() {
        defer {
            locked {
                report.workerEnded = true
                condition.broadcast()
            }
        }
        do {
            guard identity.refersToSameFile(as: SourceFileIdentity.read(at: url)) else {
                throw ImageDecodeError.cannotCreateSource
            }
            let source = try AnimationImageSource(url: url)
            locked { report.sourceOpens = 1 }
            let properties = CGImageSourceCopyPropertiesAtIndex(source.source, 0, nil) as? [CFString: Any]
            let depth = (properties?[kCGImagePropertyDepth] as? NSNumber)?.intValue ?? 8
            let resources = try allocate(depth: depth)
            let edge = resources.edge
            let uploader = resources.uploader
            let frameBytes = resources.frameBytes
            let workingBytes = resources.workingBytes
            let capacity = (budget - workingBytes) / max(1, frameBytes)
            let fullCache =
                allowsFullCache && descriptor.frameCount <= 256 && descriptor.frameCount <= capacity
                && descriptor.frameCount * frameBytes <= AnimationResourcePolicy.smallCacheBytes
            let count = fullCache ? descriptor.frameCount : min(3, descriptor.frameCount)
            var allocated = [Slot(texture: resources.firstTexture)]
            for _ in 1..<count {
                let texture =
                    uploader == nil ? nil : device?.makeTexture(descriptor: resources.textureDescriptor)
                if uploader != nil, texture == nil { throw ImageDecodeError.noDisplayableImage }
                allocated.append(Slot(texture: texture))
            }
            locked {
                if !stopped { slots = allocated }
                report.slots = count
                report.allocatedBytes = frameBytes * count + workingBytes
                report.decodedWorkingBytes =
                    resources.textureDescriptor.width * resources.textureDescriptor.height
                    * (depth > 8 ? 8 : 4)
                report.sourceOpens = 1
                report.fullCache = fullCache
            }
            let durations = descriptor.frameDurations.map { $0.isFinite && $0 > 0 ? $0 : 0.1 }
            let timeline = try AnimationTimeline(durations: durations, loops: totalPlays)
            var sequence = 0
            while !locked({ stopped }) {
                if fullCache && sequence >= descriptor.frameCount { break }
                if totalPlays > 0 && sequence >= totalPlays * descriptor.frameCount { break }
                guard let slot = acquire() else { break }
                if !fullCache {
                    // Preserve ImageIO's sequential compositor. Skipping a few delta
                    // indices can turn catch-up into repeated expensive seeks. Entire
                    // expired loops can be omitted by restarting at frame zero.
                    let loopStart = currentSequence(in: timeline) / descriptor.frameCount * descriptor.frameCount
                    if sequence < loopStart {
                        locked { report.catchupSkipped += loopStart - sequence }
                        sequence = loopStart
                    }
                }
                guard identity.refersToSameFile(as: SourceFileIdentity.read(at: url)) else {
                    throw ImageDecodeError.cannotCreateSource
                }
                let index = sequence % descriptor.frameCount
                locked { producingSequence = sequence }
                let began = ProcessInfo.processInfo.systemUptime
                try autoreleasepool {
                    let image = try source.frame(at: index, maxPixelSize: edge)
                    let hasNewerReady = locked {
                        slots.contains { $0.state == .ready && $0.sequence > lastDeliveredSequence }
                    }
                    if !fullCache, sequence < currentSequence(in: timeline), hasNewerReady {
                        // Materialize sequential dependencies but avoid conversion,
                        // upload and mip generation for a frame already too late.
                        guard image.dataProvider?.data != nil else { throw ImageDecodeError.noDisplayableImage }
                        locked {
                            report.decoded += 1
                            report.expiredDecoded += 1
                            slot.state = .free
                            condition.broadcast()
                        }
                        return
                    }
                    let bitmap: CGImage?
                    let colorSpace: CGColorSpace
                    if let uploader, let texture = slot.texture {
                        colorSpace = try uploader.upload(image, to: texture)
                        bitmap = nil
                    } else {
                        bitmap = try AnimationImageSource.detached(image)
                        colorSpace = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
                    }
                    let unchanged = identity.refersToSameFile(as: SourceFileIdentity.read(at: url))
                    let late = !fullCache && sequence < currentSequence(in: timeline)
                    locked {
                        report.decoded += 1
                        if !unchanged {
                            stopped = true
                            report.error = "动画源文件已改变"
                        }
                        if stopped {
                            slot.state = .free
                        } else {
                            slot.sequence = sequence
                            slot.bitmap = bitmap
                            slot.colorSpace = colorSpace
                            slot.late = late
                            slot.state = fullCache ? .cached : .ready
                        }
                        condition.broadcast()
                    }
                }
                source.releaseDecodedFrame(at: index)
                let service = ProcessInfo.processInfo.systemUptime - began
                locked { report.maximumServiceSeconds = max(report.maximumServiceSeconds, service) }
                sequence += 1
            }
        } catch {
            locked {
                report.error = error.localizedDescription
                stopped = true
                slots.removeAll()
                condition.broadcast()
            }
        }
    }
}
