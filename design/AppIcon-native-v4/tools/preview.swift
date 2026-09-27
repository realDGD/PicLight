import AppKit
import ImageIO

let root = URL(fileURLWithPath: CommandLine.arguments[1])
let space = CGColorSpace(name: CGColorSpace.sRGB)!
final class Sheet {
    let width: Int, height: Int
    let context: CGContext
    init(_ width: Int, _ height: Int) {
        self.width = width; self.height = height
        context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    }
    func fill(_ x: Double, _ y: Double, _ w: Double, _ h: Double, _ color: NSColor) {
        context.setFillColor(color.cgColor)
        context.fill(CGRect(x: x, y: Double(height)-y-h, width: w, height: h))
    }
    func image(_ relative: String, _ x: Double, _ y: Double, _ size: Double) {
        let url = root.appendingPathComponent(relative)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            fatalError("Missing image: \(url.path)")
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: x, y: Double(height)-y-size, width: size, height: size))
    }
    func text(_ string: String, _ x: Double, _ y: Double, _ size: Double, _ color: NSColor, bold: Bool = false) {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        let font = bold ? NSFont.boldSystemFont(ofSize: size) : NSFont.systemFont(ofSize: size)
        let t = NSAttributedString(string: string, attributes: [.font:font,.foregroundColor:color])
        t.draw(at: NSPoint(x: x, y: Double(height)-y-t.size().height))
        NSGraphicsContext.restoreGraphicsState()
    }
    func save(_ name: String) {
        let url = root.appendingPathComponent("preview/\(name)")
        let out = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(out, context.makeImage()!, nil)
        precondition(CGImageDestinationFinalize(out))
        print(url.path)
    }
}
let paper = NSColor(white:0.96,alpha:1)
let ink = NSColor(white:0.12,alpha:1)
let gray = NSColor(white:0.46,alpha:1)
let canvas = Sheet(1440,1100)
canvas.fill(0,0,1440,1100,paper)
canvas.text("PicLight · 原生玻璃外缘",40,28,32,ink,bold:true)
canvas.text("无蓝色底板 · 无额外雾化层 · 无手绘玻璃边框",40,75,20,gray)
let items = [
    ("Default", "浅色 · 默认彩色", false),
    ("Dark", "深色 · 默认彩色", true),
    ("ClearLight", "浅色 · 系统 Clear", false),
    ("ClearDark", "深色 · 系统 Clear", true)
]
for (i,item) in items.enumerated() {
    let x=40.0+Double(i%2)*700
    let y=128.0+Double(i/2)*436
    let tile = item.2 ? NSColor(white:0.085,alpha:1) : NSColor(white:1,alpha:1)
    canvas.fill(x,y,660,406,tile)
    canvas.image("preview/native/\(item.0)-27.png",x+151,y+24,358)
    canvas.text(item.1,x+22,y+22,17,item.2 ? .white : ink,bold:true)
}
canvas.text("Apple ictool · macOS 27 导出；图标透明外观与系统玻璃滑块是独立机制。",40,1016,18,gray)
canvas.text("此处为 PNG 导出预览；桌面背景的动态合成仍需系统内验收。尚未接入应用。",40,1046,17,gray)
canvas.save("01-native-light-dark.png")

let comparison = Sheet(1440,520)
comparison.fill(0,0,1440,520,paper)
comparison.text("macOS 26 / 27 · 同一份原生图标",34,25,28,ink,bold:true)
for (i,pair) in [(26,"Default"),(27,"Default"),(26,"Dark"),(27,"Dark")].enumerated() {
    let x=35.0+Double(i)*355
    comparison.image("preview/native/\(pair.1)-\(pair.0).png",x,104,310)
    comparison.text("macOS \(pair.0) · \(pair.1)",x+16,436,20,ink)
}
comparison.save("02-macOS26-27.png")

let small = Sheet(1200,740)
small.fill(0,0,1200,740,paper)
small.text("小尺寸检查 · 1:1 像素",35,24,28,ink,bold:true)
for (row,mode) in ["Default","Dark"].enumerated() {
    small.text(mode,35,84+Double(row)*317,20,ink,bold:true)
    var x=135.0
    for size in [256,128,64,32,16] {
        let y=98.0+Double(row)*317
        let cell=Double(size)+100
        small.image("preview/sizes/\(mode)-\(size).png",x+(cell-Double(size))/2,y+(256-Double(size))/2,Double(size))
        small.text("\(size) px",x+26,y+267,17,gray)
        x+=cell
    }
}
small.save("03-small-sizes.png")
