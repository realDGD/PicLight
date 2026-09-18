import XCTest
import CoreGraphics
import ImageIO
import PicPNGStream
@testable import PicViewMac

/// The streaming decoder is only useful if it is *right*, so every test here compares
/// its bytes against ImageIO decoding the same file — ImageIO is the reference, our
/// decoder is the thing under test. A tile with a wrong pixel is worse than a blurry
/// proxy, so this is the load-bearing test file of the native-detail path.
final class PicPNGStreamTests: XCTestCase {

    // MARK: - Helpers

    /// Decodes the whole file with ImageIO and returns tightly packed RGBA8 pixels.
    /// The context uses the decoded image's own colour space, so the comparison is
    /// about pixels, not about colour management.
    private func imageIORGBA(_ url: URL) throws -> (pixels: [UInt8], width: Int, height: Int) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw XCTSkip("ImageIO cannot decode \(url.lastPathComponent)")
        }
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        // sRGB, not the image's own space: a palette PNG decodes with an *indexed* colour
        // space, which cannot back a CGContext ("no context" skip). None of the fixtures
        // compared here carry an ICC profile, so drawing into sRGB is a byte-for-byte
        // pass-through rather than a conversion.
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let ok = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard ok else { throw XCTSkip("no context") }
        return (pixels, width, height)
    }

    /// Runs the streaming decoder over `region` and returns its RGBA8 bytes.
    private func streamRegion(_ url: URL, region: ps_rect) throws -> (pixels: [UInt8], info: ps_info) {
        var info = ps_info()
        var error = [CChar](repeating: 0, count: 256)
        guard let decoder = url.path.withCString({ ps_open($0, &info, &error, 256) }) else {
            throw NSError(domain: "ps_open", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: String(cString: error)])
        }
        defer { ps_close(decoder) }
        XCTAssertEqual(ps_set_region(decoder, region), 1, "region must be accepted")
        var status: Int32 = 1
        while status == 1 {
            status = ps_step(decoder, &error, 256)
        }
        guard status == 0 else {
            throw NSError(domain: "ps_step", code: Int(status),
                          userInfo: [NSLocalizedDescriptionKey: String(cString: error)])
        }
        XCTAssertEqual(ps_rows_done(decoder), info.height)
        guard let base = ps_region_pixels(decoder) else { throw XCTSkip("no region") }
        let count = Int(ps_region_bytes(decoder))
        return ([UInt8](UnsafeBufferPointer(start: base, count: count)), info)
    }

    /// Compares a region decoded by us against the same rectangle from ImageIO.
    private func assertRegionMatchesImageIO(_ name: String, region: ps_rect) throws {
        let url = Fixtures.url(name)
        let reference = try imageIORGBA(url)
        let streamed = try streamRegion(url, region: region)
        XCTAssertEqual(Int(streamed.info.width), reference.width, "\(name) width")
        XCTAssertEqual(Int(streamed.info.height), reference.height, "\(name) height")

        // The reference goes through a premultiplied CGContext because that is the only
        // layout CGContext can produce; our decoder emits the same layout. Wherever alpha
        // is opaque the two must agree byte for byte. Semi-transparent pixels may differ
        // by one unit of premultiplication rounding, so those are counted separately: a
        // real decode error shows up as a large difference, never as a ±1.
        var largeMismatches = 0
        var roundingDiffs = 0
        var firstMismatch = ""
        for y in 0..<Int(region.height) {
            for x in 0..<Int(region.width) {
                let sourceX = Int(region.x) + x, sourceY = Int(region.y) + y
                let referenceOffset = (sourceY * reference.width + sourceX) * 4
                let streamedOffset = (y * Int(region.width) + x) * 4
                for channel in 0..<4 {
                    let expected = reference.pixels[referenceOffset + channel]
                    let actual = streamed.pixels[streamedOffset + channel]
                    if expected == actual { continue }
                    let difference = abs(Int(expected) - Int(actual))
                    if difference <= 1 {
                        roundingDiffs += 1
                    } else {
                        largeMismatches += 1
                        if firstMismatch.isEmpty {
                            firstMismatch = "(\(sourceX),\(sourceY)) channel \(channel): "
                                          + "ImageIO \(expected) vs stream \(actual)"
                        }
                    }
                }
            }
        }
        XCTAssertEqual(largeMismatches, 0, "\(name): \(firstMismatch)")
    }

    // MARK: - Correctness

    func testWholeImageMatchesImageIOPixelForPixel() throws {
        // Full region on both colour layouts. The fixture cycles through all five PNG
        // filter types row by row, so every unfilter branch is compared against ImageIO
        // rather than assumed.
        for name in ["filters-rgb.png", "filters-rgba.png"] {
            let reference = try imageIORGBA(Fixtures.url(name))
            try assertRegionMatchesImageIO(name,
                                           region: ps_rect(x: 0, y: 0,
                                                           width: Int32(reference.width),
                                                           height: Int32(reference.height)))
        }
    }

    func testSubRegionAtAnOddOffsetMatchesImageIO() throws {
        // Odd offsets and odd sizes: catches off-by-one in column mapping and row slicing.
        for region in [ps_rect(x: 37, y: 29, width: 101, height: 73),
                       ps_rect(x: 1, y: 0, width: 254, height: 191),
                       ps_rect(x: 255, y: 191, width: 1, height: 1)] {
            try assertRegionMatchesImageIO("filters-rgb.png", region: region)
        }
        try assertRegionMatchesImageIO("filters-rgba.png",
                                       region: ps_rect(x: 13, y: 7, width: 99, height: 61))
    }

    func testPaletteAndSubByteDepthsMatchImageIO() throws {
        for name in ["indexed-palette.png", "palette-1bit.png", "palette-2bit.png",
                     "gray-4bit.png", "gray-alpha-8bit.png"] {
            let url = Fixtures.url(name)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw XCTSkip("fixture \(name) missing")
            }
            let reference = try imageIORGBA(url)
            try assertRegionMatchesImageIO(name,
                                           region: ps_rect(x: 0, y: 0,
                                                           width: Int32(reference.width),
                                                           height: Int32(reference.height)))
        }
    }

    func testRefusesInterlacedAndSixteenBitSourcesByName() throws {
        for name in ["interlaced-rgb.png", "depth16.png"] {
            let url = Fixtures.url(name)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            var info = ps_info()
            var error = [CChar](repeating: 0, count: 256)
            let decoder = url.path.withCString { ps_open($0, &info, &error, 256) }
            XCTAssertNil(decoder, "\(name) must be refused so the caller falls back to the proxy")
            XCTAssertFalse(String(cString: error).isEmpty, "\(name) must say why")
        }
    }

    func testReportedShapeMatchesImageIO() throws {
        let url = Fixtures.url("filters-rgb.png")
        guard FileManager.default.fileExists(atPath: url.path) else { throw XCTSkip("fixture missing") }
        let reference = try imageIORGBA(url)
        var info = ps_info()
        var error = [CChar](repeating: 0, count: 256)
        guard let decoder = url.path.withCString({ ps_open($0, &info, &error, 256) }) else {
            return XCTFail("open failed: \(String(cString: error))")
        }
        defer { ps_close(decoder) }
        XCTAssertEqual(Int(info.width), reference.width)
        XCTAssertEqual(Int(info.height), reference.height)
        XCTAssertEqual(info.bit_depth, 8)
        XCTAssertEqual(info.interlaced, 0)
    }

    // MARK: - Cancellation and memory

    func testStoppingTheStepsStopsTheWork() throws {
        let url = Fixtures.url("wide-gradient.png")
        guard FileManager.default.fileExists(atPath: url.path) else { throw XCTSkip("fixture missing") }
        var info = ps_info()
        var error = [CChar](repeating: 0, count: 256)
        guard let decoder = url.path.withCString({ ps_open($0, &info, &error, 256) }) else {
            return XCTFail("open failed")
        }
        defer { ps_close(decoder) }
        XCTAssertEqual(ps_set_region(decoder, ps_rect(x: 0, y: 0, width: 64, height: 64)), 1)

        var steps = 0
        while steps < 100 { _ = ps_step(decoder, &error, 256); steps += 1 }
        let reached = ps_rows_done(decoder)
        XCTAssertGreaterThan(reached, 0)
        XCTAssertLessThan(reached, info.height)
        // Nothing advances without a step: this is the cancellation ImageIO cannot offer,
        // where a cancelled 19 s decode kept running to completion.
        XCTAssertEqual(ps_rows_done(decoder), reached, "no background progress after we stop")
        // Closed by the defer above — closing here as well was a double free.
    }

    func testDecodingASmallRegionOfABigImageStaysSmall() throws {
        // 8192×256: a region of it must cost the region, not the image. ImageIO's crop of
        // a 12000×9000 file measured 375 ms and a 0.43 GiB peak — the same as decoding
        // all of it — which is the whole reason this decoder exists.
        let url = Fixtures.url("wide-gradient.png")
        try assertRegionMatchesImageIO("wide-gradient.png",
                                       region: ps_rect(x: 7000, y: 100, width: 300, height: 100))
        let before = footprintBytes()
        let streamed = try streamRegion(url, region: ps_rect(x: 4096, y: 128, width: 512, height: 128))
        let peak = footprintBytes()
        XCTAssertEqual(streamed.pixels.count, 512 * 128 * 4)
        let growth = peak - before
        XCTAssertLessThan(growth, 64 * 1024 * 1024,
                          "a 512×128 region must not cost the whole image (grew \(growth) bytes)")
    }

    private func footprintBytes() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Int(info.phys_footprint) : 0
    }
}
