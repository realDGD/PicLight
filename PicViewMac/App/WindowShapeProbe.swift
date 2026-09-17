import AppKit
import CoreGraphics

// Standalone probe: capture a window of this process and report its corner pixels.
enum WindowShapeProbe {
    struct Sample { let label: String; let x: Int; let y: Int; let alpha: UInt8; let r: UInt8; let g: UInt8; let b: UInt8 }

    static func capture(windowNumber: Int) -> CGImage? {
        CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(windowNumber),
                                [.boundsIgnoreFraming, .nominalResolution])
    }

    /// Scans a row/column for the first pixel that belongs to the window. A large
    /// value means a generous corner radius; a value of 1-2 px means the corner is
    /// effectively square even though the outer pixel is transparent.
    static func firstOpaqueOffset(of image: CGImage, row: Int? = nil, column: Int? = nil,
                                  threshold: UInt8 = 128) -> Int? {
        guard let data = image.dataProvider?.data as Data? else { return nil }
        let bytesPerRow = image.bytesPerRow
        let bytesPerPixel = image.bitsPerPixel / 8
        func alpha(_ x: Int, _ y: Int) -> UInt8 {
            let offset = y * bytesPerRow + x * bytesPerPixel
            guard offset + 3 < data.count else { return 0 }
            return data[offset + 3]
        }
        if let row {
            for x in 0..<image.width where alpha(x, row) >= threshold { return x }
            return nil
        }
        if let column {
            for y in 0..<image.height where alpha(column, y) >= threshold { return y }
            return nil
        }
        return nil
    }

    static func samples(of image: CGImage, inset: Int = 3) -> [Sample] {
        guard let data = image.dataProvider?.data as Data? else { return [] }
        let bytesPerRow = image.bytesPerRow
        let bytesPerPixel = image.bitsPerPixel / 8
        func sample(_ label: String, _ x: Int, _ y: Int) -> Sample {
            let offset = y * bytesPerRow + x * bytesPerPixel
            guard offset + 3 < data.count else { return Sample(label: label, x: x, y: y, alpha: 0, r: 0, g: 0, b: 0) }
            // CGImage from the window server is BGRA premultiplied in practice.
            let b = data[offset], g = data[offset + 1], r = data[offset + 2], a = data[offset + 3]
            return Sample(label: label, x: x, y: y, alpha: a, r: r, g: g, b: b)
        }
        let w = image.width, h = image.height
        return [
            sample("topLeft", inset, inset),
            sample("topRight", w - 1 - inset, inset),
            sample("bottomLeft", inset, h - 1 - inset),
            sample("bottomRight", w - 1 - inset, h - 1 - inset),
            sample("centre", w / 2, h / 2),
        ]
    }
}
