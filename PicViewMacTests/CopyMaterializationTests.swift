import XCTest
import AppKit
import CoreGraphics
@testable import PicViewMac

/// H: Copy Image — registration vs actual TIFF materialization.
///
/// The lazy registration is already covered (`CopyImageTests`: a copy returns in < 0.25 s and
/// decodes nothing). This file measures what the audit asks for: the moment a consumer actually
/// asks for `public.tiff`, how long does the encode take, how much memory does it need, how big is
/// the payload, and is it on the main thread.
@MainActor
final class CopyMaterializationTests: XCTestCase {

    override func setUp() async throws {
        try await super.setUp()
        TestAppKit.ensureApplication()
    }

    private func footprintBytes() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size
            / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { ints in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), ints, &count)
            }
        }
        return result == KERN_SUCCESS ? Int(info.phys_footprint) : 0
    }

    private func makeBitmap(width: Int, height: Int) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.3, green: 0.5, blue: 0.7, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    /// Encode once and report every number the audit asks for: wall time, output size, footprint
    /// before, peak around the encode, footprint after.
    private func measure(_ label: String, image: CGImage) -> (seconds: Double, bytes: Int,
                                                              footprintBefore: Int,
                                                              footprintPeak: Int, footprintAfter: Int) {
        let before = footprintBytes()
        var peak = before
        var output = Data()
        let started = Date()
        // The pasteboard calls the provider on the main thread — this is the same thread, timing
        // the same code path a paste would run.
        for _ in 0..<3 {
            autoreleasepool {
                output = BitmapPasteboardProvider.tiffData(from: image) ?? Data()
            }
            peak = max(peak, footprintBytes())
        }
        let seconds = Date().timeIntervalSince(started) / 3
        let after = footprintBytes()
        print("METRIC H \(label): encode=\(String(format: "%.3f", seconds))s/run "
            + "output=\(output.count) bytes footprint \(before) → peak \(peak) → \(after) bytes")
        return (seconds, output.count, before, peak, after)
    }

    /// The numbers for the report: 1080p, 4K, 8K — the largest in-budget bitmap a viewer window
    /// will ever hand to Copy.
    func testTiffMaterializationAt1080p4KAnd8K() {
        let results: [(String, CGImage)] = [
            ("1080p", makeBitmap(width: 1920, height: 1080)),
            ("4K", makeBitmap(width: 3840, height: 2160)),
            ("8K", makeBitmap(width: 7680, height: 4320)),
        ]
        for (label, image) in results {
            let r = measure(label, image: image)
            XCTAssertGreaterThan(r.bytes, 0, "a TIFF is produced")
            // The TIFF of a full-size 8K bitmap is ~127 MB uncompressed; anything past that is a
            // second full copy appearing somewhere it should not.
            XCTAssertLessThanOrEqual(r.bytes, Int(Double(image.width * image.height * 4) * 1.25) + 4096,
                                     "\(label) TIFF output is bounded by the bitmap's own size")
        }
    }

    /// The whole round trip a paste takes: register, then read `public.tiff` through the real
    /// pasteboard. Registration cost is measured separately so the two phases are never blurred.
    func testPasteboardRoundTripDistinguishesRegistrationFromMaterialization() throws {
        let image = makeBitmap(width: 3840, height: 2160)

        let registerStarted = Date()
        XCTAssertTrue(ImagePasteboardWriter.write(fileURL: URL(fileURLWithPath: "/tmp/h.png"),
                                                  image: image,
                                                  to: .general))
        let registerSeconds = Date().timeIntervalSince(registerStarted)

        let materializeStarted = Date()
        let data = try XCTUnwrap(NSPasteboard.general.data(forType: .tiff))
        let materializeSeconds = Date().timeIntervalSince(materializeStarted)

        print("METRIC H pasteboard round trip: registration=\(String(format: "%.4f", registerSeconds))s "
            + "materialization=\(String(format: "%.3f", materializeSeconds))s "
            + "tiff=\(data.count) bytes")
        XCTAssertLessThan(registerSeconds, 0.25,
                          "registration stays lazy (took \(registerSeconds) s)")
        let rep = try XCTUnwrap(NSBitmapImageRep(data: data))
        XCTAssertEqual(rep.pixelsWide, 3840)
        XCTAssertEqual(rep.pixelsHigh, 2160)
    }
}