// montage — compose labelled contact sheets from PNGs (no PIL/ImageMagick on this box).
// usage: montage --out out.png [--cols N] [--bg r,g,b] [--cell WxH] [--title "text"] label=path [label=path ...]
// Each cell is drawn fit-inside with the given pixel size; the label is centred under it.
import Foundation
import CoreGraphics
import ImageIO
import AppKit

var out = "/tmp/montage.png"
var cols = 6
var bg: (CGFloat, CGFloat, CGFloat) = (1, 1, 1)
var cell = CGSize(width: 220, height: 220)
var title = ""
var items: [(String, String)] = []

var it = CommandLine.arguments.dropFirst().makeIterator()
while let a = it.next() {
    switch a {
    case "--out": out = it.next() ?? out
    case "--cols": cols = Int(it.next() ?? "6") ?? 6
    case "--bg":
        let c = (it.next() ?? "1,1,1").split(separator: ",").map { Double($0) ?? 1 }
        bg = (CGFloat(c[0]), CGFloat(c[1]), CGFloat(c[2]))
    case "--cell":
        let c = (it.next() ?? "220x220").split(separator: "x").map { Double($0) ?? 220 }
        cell = CGSize(width: c[0], height: c[1])
    case "--title": title = it.next() ?? ""
    default:
        let parts = a.split(separator: "=", maxSplits: 1).map(String.init)
        if parts.count == 2 { items.append((parts[0], parts[1])) }
    }
}

let pad: CGFloat = 16
let labelH: CGFloat = 26
let titleH: CGFloat = title.isEmpty ? 0 : 44
let rows = (items.count + cols - 1) / cols
let W = pad + CGFloat(cols) * (cell.width + pad)
let H = titleH + pad + CGFloat(rows) * (cell.height + labelH + pad)

let cs = CGColorSpaceCreateDeviceRGB()
let ctx = CGContext(data: nil, width: Int(W), height: Int(H), bitsPerComponent: 8, bytesPerRow: 0,
                    space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.setFillColor(red: bg.0, green: bg.1, blue: bg.2, alpha: 1)
ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))

func drawText(_ s: String, centerX: CGFloat, topY: CGFloat, size: CGFloat, color: NSColor, bold: Bool = false) {
    let font = bold ? NSFont.boldSystemFont(ofSize: size) : NSFont.systemFont(ofSize: size)
    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
    let str = NSAttributedString(string: s, attributes: attrs)
    let g = NSGraphicsContext(cgContext: ctx, flipped: false)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = g
    let sz = str.size()
    str.draw(at: NSPoint(x: centerX - sz.width / 2, y: H - topY - sz.height))
    NSGraphicsContext.restoreGraphicsState()
}

if !title.isEmpty {
    drawText(title, centerX: W / 2, topY: 10, size: 26, color: NSColor.black, bold: true)
}

let labelColor = NSColor.black
for (idx, item) in items.enumerated() {
    let r = idx / cols, c = idx % cols
    let x = pad + CGFloat(c) * (cell.width + pad)
    let yTop = titleH + pad + CGFloat(r) * (cell.height + labelH + pad)
    // cell background tile (transparent-source images show against it)
    ctx.setFillColor(red: 0.97, green: 0.97, blue: 0.97, alpha: 1)
    ctx.fill(CGRect(x: x, y: H - yTop - cell.height, width: cell.width, height: cell.height))
    if let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: item.1) as CFURL, nil),
       let img = CGImageSourceCreateImageAtIndex(src, 0, nil) {
        // never upscale: an icon ladder must show true pixel sizes
        let s = min(cell.width / CGFloat(img.width), cell.height / CGFloat(img.height), 1.0)
        let w = CGFloat(img.width) * s, h = CGFloat(img.height) * s
        ctx.interpolationQuality = .high
        ctx.draw(img, in: CGRect(x: x + (cell.width - w) / 2, y: H - yTop - cell.height + (cell.height - h) / 2,
                                 width: w, height: h))
    }
    drawText(item.0, centerX: x + cell.width / 2, topY: yTop + cell.height + 4, size: 15, color: labelColor)
}

guard let dst = CGImageDestinationCreateWithURL(URL(fileURLWithPath: out) as CFURL, "public.png" as CFString, 1, nil) else { exit(2) }
CGImageDestinationAddImage(dst, ctx.makeImage()!, nil)
CGImageDestinationFinalize(dst)
print("wrote \(out)  \(Int(W))x\(Int(H))  (\(items.count) cells, \(cols) cols)")
