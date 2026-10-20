// Export an already-rendered icon onto a transparent legacy macOS canvas.
// Default visible tile side: 824 of 1024 px, plus a small shadow.
// This is output sizing/packaging; artwork stays in the source assets.
import Foundation
import CoreGraphics
import ImageIO

let a = CommandLine.arguments
guard a.count >= 3 else {
    print("usage: export-grid <in.png> <out.png> [canvas=1024] [artFraction=0.8047] [shadowAlpha=0.30]")
    exit(1)
}
let canvas = a.count > 3 ? Int(a[3])! : 1024
let artFraction = a.count > 4 ? Double(a[4])! : 0.8047   // 824/1024 — squircle, shadow excluded
let shadowAlpha = a.count > 5 ? Double(a[5])! : 0.30

guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: a[1]) as CFURL, nil),
      let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
    FileHandle.standardError.write("cannot read \(a[1])\n".data(using: .utf8)!)
    exit(2)
}

let ctx = CGContext(data: nil, width: canvas, height: canvas, bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
let side = Double(canvas) * artFraction
let inset = (Double(canvas) - side) / 2
let rect = CGRect(x: inset, y: inset, width: side, height: side)

// Big Sur-style shadow: soft, short, slightly downward, ~25-30% black.
let blur = side * 0.040
ctx.setShadow(offset: CGSize(width: 0, height: -side * 0.006), blur: CGFloat(blur),
              color: CGColor(red: 0, green: 0, blue: 0, alpha: shadowAlpha))
ctx.interpolationQuality = .high
ctx.draw(img, in: rect)

guard let dst = CGImageDestinationCreateWithURL(URL(fileURLWithPath: a[2]) as CFURL,
                                                "public.png" as CFString, 1, nil) else { exit(2) }
CGImageDestinationAddImage(dst, ctx.makeImage()!, nil)
CGImageDestinationFinalize(dst)
print("wrote \(a[2])  canvas \(canvas)  art \(Int(side))pt  inset \(Int(inset))pt")
