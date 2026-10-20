import CoreGraphics
import Foundation
import ImageIO

/// Work around ImageIO returning the independent PNG poster for animation index zero.
/// Only that frame is extracted: later frames still use ImageIO's disposal/blend compositor.
/// PNG 3 §4.9 and §11.3.6: fdAT inherits the pre-IDAT properties, with fcTL dimensions.
struct APNGFirstFrame {
    let png: Data
    let canvasWidth: Int
    let canvasHeight: Int
    let width: Int
    let height: Int
    let x: Int
    let y: Int

    static func read(from url: URL) throws -> APNGFirstFrame? {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count >= 8, data.prefix(8) == Data([137, 80, 78, 71, 13, 10, 26, 10]) else { return nil }
        var offset = 8
        var header = Data()
        var inherited = Data()
        var payload = Data()
        var canvasWidth = 0
        var canvasHeight = 0
        var sawIDAT = false
        var animated = false
        var control: [Int]?
        var sequence = 0
        while offset <= data.count - 12 {
            let length = Int(u32(data, offset))
            guard length <= data.count - offset - 12 else { throw ImageDecodeError.noDisplayableImage }
            let start = offset + 8
            let end = start + length
            let type = String(decoding: data[(offset + 4)..<(offset + 8)], as: UTF8.self)
            if type == "fcTL", control != nil { break }
            if type == "IEND" { break }
            switch type {
            case "IHDR":
                guard offset == 8, length == 13 else { throw ImageDecodeError.noDisplayableImage }
                header = data.subdata(in: start..<end)
                canvasWidth = Int(u32(header, 0))
                canvasHeight = Int(u32(header, 4))
            case "acTL":
                guard !sawIDAT, length == 8, u32(data, start) > 0 else {
                    throw ImageDecodeError.noDisplayableImage
                }
                animated = true
            case "IDAT": sawIDAT = true
            case "fcTL":
                // A default image belonging to the animation has no index-zero bug.
                guard sawIDAT else { return nil }
                guard animated, length == 26, u32(data, start) == 0,
                    crc(data[(offset + 4)..<end]) == u32(data, end)
                else { throw ImageDecodeError.noDisplayableImage }
                let w = Int(u32(data, start + 4))
                let h = Int(u32(data, start + 8))
                let x = Int(u32(data, start + 12))
                let y = Int(u32(data, start + 16))
                guard w > 0, h > 0, w <= canvasWidth, h <= canvasHeight,
                    x <= canvasWidth - w, y <= canvasHeight - h,
                    data[start + 24] <= 2, data[start + 25] <= 1
                else { throw ImageDecodeError.noDisplayableImage }
                control = [w, h, x, y]
                sequence = 1
            case "fdAT":
                guard control != nil, length >= 4, Int(u32(data, start)) == sequence,
                    crc(data[(offset + 4)..<end]) == u32(data, end)
                else { throw ImageDecodeError.noDisplayableImage }
                payload.append(chunk("IDAT", data.subdata(in: (start + 4)..<end)))
                sequence += 1
            default:
                if !sawIDAT { inherited.append(data[offset..<(end + 4)]) }
            }
            offset = end + 4
        }
        guard let c = control else { return nil }
        guard !header.isEmpty, !payload.isEmpty else { throw ImageDecodeError.noDisplayableImage }
        header.replaceSubrange(0..<4, with: be32(c[0]))
        header.replaceSubrange(4..<8, with: be32(c[1]))
        var png = Data([137, 80, 78, 71, 13, 10, 26, 10])
        png.append(chunk("IHDR", header))
        png.append(inherited)
        png.append(payload)
        png.append(chunk("IEND", Data()))
        return APNGFirstFrame(
            png: png, canvasWidth: canvasWidth, canvasHeight: canvasHeight,
            width: c[0], height: c[1], x: c[2], y: c[3])
    }

    func decode(maxPixelSize: Int? = nil) -> CGImage? {
        guard
            let source = CGImageSourceCreateWithData(
                png as CFData, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }
        let scale = min(
            1, Double(maxPixelSize ?? max(canvasWidth, canvasHeight)) / Double(max(canvasWidth, canvasHeight))
        )
        let image: CGImage?
        if scale < 1 {
            image = CGImageSourceCreateThumbnailAtIndex(
                source, 0,
                [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: max(
                        1, Int(ceil(Double(max(width, height)) * scale))),
                ] as CFDictionary)
        } else {
            image = CGImageSourceCreateImageAtIndex(
                source, 0, [kCGImageSourceShouldCache: false] as CFDictionary)
        }
        guard let image else { return nil }
        if x == 0, y == 0, width == canvasWidth, height == canvasHeight { return image }
        let w = max(1, Int(Double(canvasWidth) * scale))
        let h = max(1, Int(Double(canvasHeight) * scale))
        let color =
            image.colorSpace?.model == .rgb ? image.colorSpace! : CGColorSpace(name: CGColorSpace.sRGB)!
        // A subrectangle needs a transparent canvas even when the PNG itself is RGB/paletted.
        let highDepth = image.bitsPerComponent > 8
        let info =
            highDepth
            ? CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder16Little.rawValue
                | CGImageAlphaInfo.premultipliedLast.rawValue
            : CGImageAlphaInfo.premultipliedLast.rawValue
        guard
            let context = CGContext(
                data: nil, width: w, height: h, bitsPerComponent: highDepth ? 16 : 8,
                bytesPerRow: 0, space: color, bitmapInfo: info)
        else { return nil }
        context.setBlendMode(.copy)
        context.draw(
            image,
            in: CGRect(
                x: Double(x) * scale, y: Double(canvasHeight - y - height) * scale,
                width: Double(width) * scale, height: Double(height) * scale))
        return context.makeImage()
    }

    private static func u32(_ data: Data, _ i: Int) -> UInt32 {
        (UInt32(data[i]) << 24) | (UInt32(data[i + 1]) << 16) | (UInt32(data[i + 2]) << 8)
            | UInt32(data[i + 3])
    }
    private static func be32(_ value: Int) -> Data {
        let v = UInt32(value)
        return Data([UInt8(v >> 24), UInt8((v >> 16) & 255), UInt8((v >> 8) & 255), UInt8(v & 255)])
    }
    private static let crcTable: [UInt32] = (0..<256).map { value in
        var c = UInt32(value)
        for _ in 0..<8 { c = c & 1 == 0 ? c >> 1 : 0xedb8_8320 ^ (c >> 1) }
        return c
    }
    private static func crc(_ bytes: Data.SubSequence) -> UInt32 {
        var c: UInt32 = 0xffff_ffff
        for byte in bytes { c = crcTable[Int((c ^ UInt32(byte)) & 255)] ^ (c >> 8) }
        return c ^ 0xffff_ffff
    }
    private static func chunk(_ type: String, _ payload: Data) -> Data {
        var body = Data(type.utf8)
        body.append(payload)
        var result = be32(payload.count)
        result.append(body)
        result.append(be32(Int(crc(body))))
        return result
    }
}
