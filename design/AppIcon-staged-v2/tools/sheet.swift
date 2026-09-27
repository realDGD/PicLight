// sheet — compose the one-page overview sheet for the PicLight app icon.
//
// Layout follows the reference artwork: a light-mode panel, a dark-mode panel, and a right-hand
// column with the three appearances a user can pick (Default / Monochrome / Tinted).
// The ladder inside each panel is drawn at TRUE pixel sizes; 01/02-size-ladder.png show the
// same ladder on its own at a larger presentation size.
//
// usage: sheet <parts-dir> <out.png>
//   parts-dir must contain:
//     light-big.png dark-big.png                 large tiles (1024 renders)
//     light-256/128/64/32/16.png                 true-size ladder
//     dark-256/128/64/32/16.png
//     app-default.png app-mono.png app-tint.png  appearance thumbnails (256 renders)
import Foundation
import CoreGraphics
import ImageIO
import AppKit

let args = Array(CommandLine.arguments.dropFirst())
guard args.count >= 2 else { print("usage: sheet <parts-dir> <out.png>"); exit(1) }
let dir = args[0].hasSuffix("/") ? String(args[0].dropLast()) : args[0]
let outPath = args[1]

// ------------------------------------------------------------------ geometry
let W: CGFloat = 1900, H: CGFloat = 1000
let headH: CGFloat = 104, footY: CGFloat = 900
let splitDark: CGFloat = 760, splitRight: CGFloat = 1560
let bigScale: CGFloat = 0.34                 // 1024 render -> 348 pt tile
let bigTop: CGFloat = 132
let ladderTop: CGFloat = 522
let captionY: CGFloat = 838
let ladderSizes = [256, 128, 64, 32, 16]
let ladderGap: CGFloat = 26

let ctx = CGContext(data: nil, width: Int(W), height: Int(H), bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> CGColor { CGColor(red: r, green: g, blue: b, alpha: 1) }
func fill(_ rect: CGRect, _ color: CGColor) { ctx.setFillColor(color); ctx.fill(rect) }
func load(_ name: String) -> CGImage? {
    guard let s = CGImageSourceCreateWithURL(URL(fileURLWithPath: "\(dir)/\(name)") as CFURL, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(s, 0, nil)
}
func text(_ s: String, centerX: CGFloat, topY: CGFloat, size: CGFloat, color: NSColor, bold: Bool = false) {
    let font = bold ? NSFont.boldSystemFont(ofSize: size) : NSFont.systemFont(ofSize: size)
    let str = NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color])
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
    let sz = str.size()
    str.draw(at: NSPoint(x: centerX - sz.width / 2, y: H - topY - sz.height))
    NSGraphicsContext.restoreGraphicsState()
}
@discardableResult
func place(_ img: CGImage, cx: CGFloat, top: CGFloat, scale: CGFloat = 1) -> CGSize {
    let w = CGFloat(img.width) * scale, h = CGFloat(img.height) * scale
    ctx.interpolationQuality = .high
    ctx.draw(img, in: CGRect(x: cx - w / 2, y: H - top - h, width: w, height: h))
    return CGSize(width: w, height: h)
}

// ------------------------------------------------------------------ bands
fill(CGRect(x: 0, y: 0, width: W, height: H), rgb(1, 1, 1))
let panelH = footY - headH
fill(CGRect(x: 0, y: H - footY, width: splitDark, height: panelH), rgb(1, 1, 1))
fill(CGRect(x: splitDark, y: H - footY, width: splitRight - splitDark, height: panelH), rgb(0.055, 0.055, 0.075))
fill(CGRect(x: splitRight, y: H - footY, width: W - splitRight, height: panelH), rgb(0.965, 0.965, 0.973))
ctx.setStrokeColor(rgb(0.85, 0.85, 0.87)); ctx.setLineWidth(1)
for bx in [splitDark, splitRight] { ctx.stroke(CGRect(x: bx - 0.5, y: H - footY, width: 1, height: panelH)) }
ctx.stroke(CGRect(x: 0.5, y: H - footY, width: W - 1, height: 1))

// ------------------------------------------------------------------ header
text("PicLight — app icon", centerX: W / 2, topY: 20, size: 34, color: .black, bold: true)
text("Liquid Glass icon document (macOS 26 / 27) + legacy asset catalog for macOS 14–15",
     centerX: W / 2, topY: 60, size: 17, color: NSColor(calibratedWhite: 0.38, alpha: 1))

// ------------------------------------------------------------------ panels
func panel(x0: CGFloat, x1: CGFloat, prefix: String, caption: String,
           captionColor: NSColor, labelColor: NSColor) {
    if let big = load("\(prefix)-big.png") { place(big, cx: (x0 + x1) / 2, top: bigTop, scale: bigScale) }
    let total = ladderSizes.reduce(CGFloat(0)) { $0 + CGFloat($1) } + ladderGap * CGFloat(ladderSizes.count - 1)
    var x = x0 + ((x1 - x0) - total) / 2
    for s in ladderSizes {
        guard let img = load("\(prefix)-\(s).png") else { continue }
        let sz = max(place(img, cx: x + CGFloat(s) / 2, top: ladderTop).height, 40)
        text("\(s) × \(s)", centerX: x + CGFloat(s) / 2, topY: ladderTop + sz + 8, size: 15, color: labelColor)
        x += CGFloat(s) + ladderGap
    }
    text(caption, centerX: (x0 + x1) / 2, topY: captionY, size: 26, color: captionColor, bold: true)
}
panel(x0: 0, x1: splitDark, prefix: "light", caption: "Light Mode",
      captionColor: .black, labelColor: NSColor(calibratedWhite: 0.25, alpha: 1))
panel(x0: splitDark, x1: splitRight, prefix: "dark", caption: "Dark Mode",
      captionColor: .white, labelColor: NSColor(calibratedWhite: 0.82, alpha: 1))

// ------------------------------------------------------------------ appearances column
let cxCol = (splitRight + W) / 2 + 4
var top: CGFloat = bigTop + 10
for (label, file) in [("Default", "app-default.png"), ("Monochrome", "app-mono.png"), ("Tinted", "app-tint.png")] {
    if let img = load(file) { place(img, cx: cxCol, top: top, scale: 0.5) }
    text(label, centerX: cxCol, topY: top + 134, size: 16, color: NSColor(calibratedWhite: 0.25, alpha: 1))
    top += 212
}
text("user-selectable", centerX: cxCol, topY: 812, size: 15, color: NSColor(calibratedWhite: 0.5, alpha: 1))
text("appearances", centerX: cxCol, topY: 834, size: 15, color: NSColor(calibratedWhite: 0.5, alpha: 1))

// ------------------------------------------------------------------ footer
text("Sizes above are drawn at true pixel size.  Generated by Resources/AppIcon/build-icons.sh — not yet wired into the app.",
     centerX: W / 2, topY: footY + 34, size: 16, color: NSColor(calibratedWhite: 0.42, alpha: 1))

guard let dst = CGImageDestinationCreateWithURL(URL(fileURLWithPath: outPath) as CFURL,
                                                "public.png" as CFString, 1, nil) else { exit(2) }
CGImageDestinationAddImage(dst, ctx.makeImage()!, nil)
CGImageDestinationFinalize(dst)
print("wrote \(outPath)  \(Int(W))x\(Int(H))")
