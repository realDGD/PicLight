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
let light = NSColor(srgbRed:0.95,green:0.965,blue:0.98,alpha:1)
let dark = NSColor(srgbRed:0.055,green:0.08,blue:0.115,alpha:1)
let ink = NSColor(srgbRed:0.14,green:0.19,blue:0.26,alpha:1)
let gray = NSColor(srgbRed:0.46,green:0.51,blue:0.58,alpha:1)

let reference = Sheet(1440,850)
reference.fill(0,0,720,850,light);reference.fill(720,0,720,850,dark)
reference.text("PicLight",48,36,36,ink,bold:true)
reference.text("参考图还原 · 静态预览",48,84,19,gray)
reference.text("深色外观",768,42,28,.white,bold:true)
reference.text("独立文件 · 尚未接入应用",768,85,19,.lightGray)
reference.image("reference/PicLight-light.png",38,144,644)
reference.image("reference/PicLight-dark.png",758,144,644)
reference.text("LIGHT",48,802,16,gray)
reference.text("DARK",768,802,16,.lightGray)
reference.save("01-reference-preview.png")

let native = Sheet(1500,830)
native.fill(0,0,620,830,light);native.fill(620,0,620,830,dark)
native.fill(1240,0,260,830,NSColor(srgbRed:0.87,green:0.89,blue:0.92,alpha:1))
native.text("Apple 原生液态玻璃",40,32,29,ink,bold:true)
native.text("macOS 27 · 系统实际渲染",40,76,18,gray)
native.text("Dark",660,32,29,.white,bold:true)
native.text("同一份分层 .icon 文件",660,76,18,.lightGray)
native.image("preview/native/Default-27.png",62,145,496)
native.image("preview/native/Dark-27.png",682,145,496)
native.text("系统着色与透明模式",1260,32,18,ink,bold:true)
for (i,name) in ["TintedDark","ClearLight","ClearDark"].enumerated() {
    let y = 96.0 + Double(i)*232
    native.image("preview/native/\(name)-27.png",1291,y,158)
    native.text(name,1285,y+174,16,ink)
}
native.text("边缘高光与折射由 Apple 渲染；与静态还原图存在差异。",40,694,17,gray)
native.text("预览不代表已在所有系统实机验收。",40,725,16,gray)
native.text("1024 × 1024 · Default / Dark / Clear / Tinted",40,780,16,gray)
native.save("02-native-glass-preview.png")

let generations=Sheet(1400,480)
generations.fill(0,0,1400,480,light)
generations.text("同一份 .icon · Apple 渲染代际对比",30,23,27,ink,bold:true)
for (i,item) in [("Default",26),("Default",27),("Dark",26),("Dark",27)].enumerated() {
    let x=30.0+Double(i)*345
    generations.image("preview/native/\(item.0)-\(item.1).png",x,100,300)
    generations.text("macOS \(item.1) · \(item.0)",x+18,418,18,ink)
}
generations.save("03-native-26-27.png")

let sizes=Sheet(1200,800)
sizes.fill(0,0,1200,800,light)
sizes.text("小尺寸检查 · 按实际像素展示",30,24,27,ink,bold:true)
sizes.text("上：参考还原版 ICNS    下：原生 .icon 的旧版兼容 ICNS",30,66,17,gray)
for (row,folder) in ["reference/PicLight-reference.iconset","legacy/PicLight.iconset"].enumerated() {
    var x=30.0
    for s in [256,128,64,32,16] {
        let name = s == 64 ? "icon_32x32@2x.png" : "icon_\(s)x\(s).png"
        let cell=Double(s)+100
        let y=120.0+Double(row)*330
        let display = Double(s)
        sizes.image("\(folder)/\(name)",x+(cell-display)/2,y+(256-display)/2,display)
        sizes.text("\(s) px (1:1)",x+15,y+267,15,gray)
        x += cell
    }
}
sizes.save("04-small-sizes.png")
