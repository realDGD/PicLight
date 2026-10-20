import Metal
import XCTest

@testable import PicViewMac

final class AnimationFrameBufferTests: XCTestCase {
    private func make(
        _ name: String = "composite.gif", gpu: Bool = false,
        fullCache: Bool = false, url: URL? = nil
    ) async throws -> AnimationFrameBuffer {
        let url = url ?? Fixtures.url("animation/\(name)")
        let descriptor = try await ImageIODecoder().inspect(url)
        let device = gpu ? try XCTUnwrap(MTLCreateSystemDefaultDevice()) : nil
        let buffer = AnimationFrameBuffer(
            url: url, descriptor: descriptor, device: device,
            allowsFullCache: fullCache)
        buffer.start()
        return buffer
    }

    private func waitFrame(_ buffer: AnimationFrameBuffer, sequence: Int, elapsed: Double? = nil) async
        -> AnimationFrameLease?
    {
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if let frame = buffer.frame(sequence: sequence, elapsed: elapsed) { return frame }
            try? await Task.sleep(for: .milliseconds(2))
        }
        return nil
    }

    func testRollingQueueKeepsLeasedPixelsImmutableAndReleasesSlots() async throws {
        for gpu in [false, true] {
            let buffer = try await make(gpu: gpu)
            defer { buffer.stop() }
            var first = await waitFrame(buffer, sequence: 0)
            XCTAssertNotNil(first)
            let second = await waitFrame(buffer, sequence: 1)
            let third = await waitFrame(buffer, sequence: 2)
            XCTAssertNotNil(second)
            XCTAssertNotNil(third)
            let before = try pixels(XCTUnwrap(first))
            try? await Task.sleep(for: .milliseconds(30))
            XCTAssertEqual(buffer.diagnostics.slots, 3)
            XCTAssertEqual(buffer.diagnostics.leased, 3)
            XCTAssertNil(buffer.frame(sequence: 3, elapsed: nil), "all three slots are pinned")
            XCTAssertEqual(
                try pixels(XCTUnwrap(first)), before, "a GPU reader must never see an overwritten texture")
            first = nil
            let fourth = await waitFrame(buffer, sequence: 3)
            XCTAssertEqual(fourth?.index, 3)
            XCTAssertEqual(buffer.diagnostics.sourceOpens, 1, "one source across frames")
            XCTAssertLessThanOrEqual(buffer.diagnostics.allocatedBytes, 80 * 1024 * 1024)
            withExtendedLifetime((second, third, fourth)) {}
        }
    }

    func testReadyQueueSkipsExpiredFramesWithoutShowingFutureFrames() async throws {
        let buffer = try await make()
        defer { buffer.stop() }
        var first = await waitFrame(buffer, sequence: 0)
        XCTAssertNotNil(first)
        first = nil
        let current = await waitFrame(buffer, sequence: 6, elapsed: 0.5)
        XCTAssertEqual(current?.index, 6)
        XCTAssertNil(
            buffer.frame(sequence: 5, elapsed: 0.5), "expired frames are never substituted for the target")
    }

    func testTinyAnimationCanCacheWithinSmallBudgetAndReuseFramesAcrossLoops() async throws {
        let buffer = try await make(fullCache: true)
        defer { buffer.stop() }
        let last = await waitFrame(buffer, sequence: 7)
        XCTAssertEqual(last?.index, 7)
        XCTAssertTrue(buffer.diagnostics.fullCache)
        let nextLoop = buffer.frame(sequence: 8, elapsed: 0.7)
        XCTAssertEqual(nextLoop?.index, 0)
        XCTAssertEqual(buffer.diagnostics.decoded, 8)
    }

    func testLatePlaybackCanUseTheNewestReadyFrameWithoutRewindingOrShowingFutureFrames() async throws {
        for gpu in [false, true] {
            let buffer = try await make(gpu: gpu)
            defer { buffer.stop() }
            let deadline = Date().addingTimeInterval(3)
            while !buffer.isPrimed, Date() < deadline {
                try await Task.sleep(for: .milliseconds(2))
            }
            // A late display callback finds zero, one and two ready. The source
            // clock has reached six; showing two keeps motion instead of holding
            // the much older previous image while the decoder catches up.
            let frame = buffer.frame(sequence: 6, elapsed: 0.5, minimumSequence: 0)
            XCTAssertEqual(frame?.sequence, 2)
            XCTAssertNotNil(frame?.bitmapForCopy())
            XCTAssertNil(buffer.frame(sequence: 1, elapsed: 0.5, minimumSequence: 3),
                         "never rewind, and never substitute a future ready frame")
        }
    }

    func testCancellationAndReplacementPreventOldFramePublication() async throws {
        let directory = try Fixtures.makeScratchDirectory("animation-replace")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("image.gif")
        try FileManager.default.copyItem(at: Fixtures.url("animation/composite.gif"), to: url)
        let buffer = try await make(url: url)
        let first = await waitFrame(buffer, sequence: 0)
        XCTAssertNotNil(first)
        try FileManager.default.removeItem(at: url)
        try FileManager.default.copyItem(at: Fixtures.url("animation/short-delay.gif"), to: url)
        XCTAssertNil(buffer.frame(sequence: 1, elapsed: 0.025), "same path, different file")
        buffer.stop()
        XCTAssertNil(buffer.frame(sequence: 0, elapsed: nil))
    }

    func testThreeSlotsAdaptToDriverPaddingWithinBudget() async throws {
        let url = Fixtures.url("animation/composite.apng")
        let descriptor = try await ImageIODecoder().inspect(url)
        let buffer = AnimationFrameBuffer(
            url: url, descriptor: descriptor,
            device: try XCTUnwrap(MTLCreateSystemDefaultDevice()), budgetBytes: 128 * 1024,
            allowsFullCache: false)
        defer { buffer.stop() }
        buffer.start()
        let first = await waitFrame(buffer, sequence: 0)
        XCTAssertNotNil(first, buffer.diagnostics.error ?? "no frame")
        XCTAssertEqual(buffer.diagnostics.slots, 3)
        XCTAssertLessThanOrEqual(buffer.diagnostics.allocatedBytes, 128 * 1024)
    }

    func testGPUPlaybackAndCopyPixelsMatchAllFormatOraclesAcrossFrameJumps() async throws {
        for name in ["composite.gif", "composite.apng", "composite.webp", "poster-default.apng"] {
            let buffer = try await make(name, gpu: true)
            defer { buffer.stop() }
            var expected = try Data(contentsOf: Fixtures.url("animation/\(name).rgba"))
            expected.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
                for i in stride(from: 0, to: raw.count, by: 4) {
                    for c in 0..<3 { raw[i + c] = UInt8((Int(raw[i + c]) * Int(raw[i + 3]) + 127) / 255) }
                }
            }
            let bytes = 96 * 64 * 4
            let count = expected.count / bytes
            for sequence in [0, count - 1, count, count + 1] {
                let ready = await waitFrame(buffer, sequence: sequence)
                let frame = try XCTUnwrap(ready)
                let image = try XCTUnwrap(frame.bitmapForCopy(), "copy must reflect the displayed GPU frame")
                let context = try XCTUnwrap(
                    CGContext(
                        data: nil, width: 96, height: 64,
                        bitsPerComponent: 8, bytesPerRow: 96 * 4,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                context.setBlendMode(.copy)
                context.draw(image, in: CGRect(x: 0, y: 0, width: 96, height: 64))
                let actual = Data(bytes: context.data!, count: bytes)
                let index = sequence % count
                XCTAssertEqual(
                    actual, expected.subdata(in: index * bytes..<(index + 1) * bytes),
                    "\(name), sequence \(sequence)")
            }
        }
    }

    func testFinitePlaybackCanStillProduceLastFrameAfterADeadlineMiss() async throws {
        let url = Fixtures.url("animation/composite.gif")
        let descriptor = try await ImageIODecoder().inspect(url)
        let buffer = AnimationFrameBuffer(
            url: url, descriptor: descriptor, device: nil,
            allowsFullCache: false, totalPlays: 1)
        defer { buffer.stop() }
        buffer.start()
        let frame = await waitFrame(buffer, sequence: 7, elapsed: 100)
        XCTAssertEqual(frame?.index, 7, "catch-up must clamp to the final play")
    }

    func testWorkerUsesCurrentClockBetweenDisplayCallbacks() async throws {
        let buffer = try await make()
        defer { buffer.stop() }
        var first = await waitFrame(buffer, sequence: 0)
        XCTAssertNotNil(first)
        buffer.updateClock(elapsed: 0, running: true)
        // No new display callback while slots one and two fill. When zero becomes
        // free, sequence three (140–260 ms) has already expired.
        try await Task.sleep(for: .milliseconds(300))
        first = nil
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertNil(
            buffer.frame(sequence: 3, elapsed: nil),
            "producer must not decode using the stale zero-time sample")
        let current = await waitFrame(buffer, sequence: 4)
        XCTAssertEqual(current?.index, 4)
    }

    func testStartupWaitsForTheBoundedLookaheadBuffer() async throws {
        let buffer = try await make()
        defer { buffer.stop() }
        let deadline = Date().addingTimeInterval(3)
        while buffer.diagnostics.ready < 3, Date() < deadline {
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertEqual(buffer.diagnostics.ready, 3)
        XCTAssertTrue(buffer.isPrimed, "start only after frame zero and two lookahead frames are ready")
        let first = buffer.frame(sequence: 0, elapsed: nil)
        XCTAssertEqual(first?.index, 0)
    }

    private func pixels(_ frame: AnimationFrameLease) throws -> Data {
        if let image = frame.bitmap { return image.dataProvider!.data! as Data }
        let texture = try XCTUnwrap(frame.texture)
        let device = texture.device
        let pitch = (texture.width * 4 + 255) / 256 * 256
        let options: MTLResourceOptions = device.hasUnifiedMemory ? .storageModeShared : .storageModeManaged
        let staging = try XCTUnwrap(device.makeBuffer(length: pitch * texture.height, options: options))
        let command = try XCTUnwrap(device.makeCommandQueue()?.makeCommandBuffer())
        let blit = try XCTUnwrap(command.makeBlitCommandEncoder())
        blit.copy(
            from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(),
            sourceSize: MTLSize(width: texture.width, height: texture.height, depth: 1),
            to: staging, destinationOffset: 0, destinationBytesPerRow: pitch,
            destinationBytesPerImage: pitch * texture.height)
        if staging.storageMode == .managed { blit.synchronize(resource: staging) }
        blit.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        return Data(bytes: staging.contents(), count: staging.length)
    }
}
