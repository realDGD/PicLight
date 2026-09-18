// Positional correctness probe for native-detail tiles.
//
// Detail energy proves "there are high-frequency pixels here"; it cannot prove they come from
// the right place. This fixture encodes its own coordinates —
//
//     R = x % 251,  G = y % 241,  B = (x * 7 + y * 13) % 239
//
// — so for a size below 251×241 the pair (R, G) *is* the source coordinate, and a rendered
// pixel can be inverted back to the source pixel it came from. The probe prints, for a grid of
// absolute view positions: the source coordinate the geometry says should be there, the
// coordinate the rendered pixel actually came from, and the delta between them. A flip, a
// rotation, an axis swap, a one-pixel shift or a tile permutation each show up as a different
// delta pattern instead of "close enough".
//
// Usage: tileposbench [fixture.png]

import Foundation
import CoreGraphics
import ImageIO
import Metal
import Darwin

func monotonicNS() -> UInt64 { clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) }

// MARK: - Fixture

/// 240×230 keeps (x, y) recoverable from (R, G) for every pixel.
let fixtureWidth = 240
let fixtureHeight = 230

func intensity(x: Int, y: Int) -> (UInt8, UInt8, UInt8) {
    (UInt8(x % 251), UInt8(y % 241), UInt8((x * 7 + y * 13) % 239))
}

func fixturePixels() -> [UInt8] {
    var pixels = [UInt8](repeating: 0, count: fixtureWidth * fixtureHeight * 4)
    for y in 0..<fixtureHeight {
        for x in 0..<fixtureWidth {
            let (r, g, b) = intensity(x: x, y: y)
            let offset = (y * fixtureWidth + x) * 4
            pixels[offset] = r; pixels[offset + 1] = g; pixels[offset + 2] = b; pixels[offset + 3] = 255
        }
    }
    return pixels
}

func imageFrom(_ pixels: [UInt8], width: Int, height: Int) -> CGImage? {
    let provider = CGDataProvider(data: Data(pixels) as CFData)
    return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                   bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                   bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                   provider: provider!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
}

/// Writes the fixture as a PNG on disk, because the tile provider streams a file.
func writeFixture(to url: URL) -> Bool {
    let pixels = fixturePixels()
    guard let image = imageFrom(pixels, width: fixtureWidth, height: fixtureHeight) else { return false }
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
        return false
    }
    CGImageDestinationAddImage(destination, image, nil)
    return CGImageDestinationFinalize(destination)
}

// MARK: - Run

let arguments = CommandLine.arguments
let fixtureURL = URL(fileURLWithPath: arguments.count > 1 ? arguments[1]
                     : "/tmp/piclight-bench/fixtures/pos-240x230.png")
try? FileManager.default.createDirectory(at: fixtureURL.deletingLastPathComponent(),
                                         withIntermediateDirectories: true)
guard writeFixture(to: fixtureURL) else {
    FileHandle.standardError.write(Data("cannot write fixture\n".utf8)); exit(1)
}
let sourceSize = CGSize(width: fixtureWidth, height: fixtureHeight)
guard let device = MTLCreateSystemDefaultDevice() else {
    FileHandle.standardError.write(Data("MTLCreateSystemDefaultDevice returned nil\n".utf8)); exit(1)
}
guard let renderer = MetalImageRenderer(device: device) else {
    FileHandle.standardError.write(Data("MetalImageRenderer init failed (shader/pipeline)\n".utf8))
    exit(1)
}

// The proxy deliberately differs from the fixture (a flat colour): if a tile is missing or
// misbound, the probe sees the flat colour instead of coordinates and says so.
let proxyContext = CGContext(data: nil, width: 120, height: 115, bitsPerComponent: 8,
                             bytesPerRow: 120 * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
proxyContext.setFillColor(CGColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1))
proxyContext.fill(CGRect(x: 0, y: 0, width: 120, height: 115))
let proxy = proxyContext.makeImage()!

let tileSizes = arguments.count > 2 ? [Int(arguments[2])!] : [64, 128]
let viewSizes = [CGSize(width: 200, height: 160), CGSize(width: 100, height: 80)]

// One tile, alone: where does the renderer put it, and what does it show there?
func isolatedTileProbe(renderer: MetalImageRenderer, device: MTLDevice) {
    let tileSize = 64
    let sourceSize = CGSize(width: fixtureWidth, height: fixtureHeight)
    let viewSize = CGSize(width: 200, height: 160)
    var viewport = ViewportState(fitScale: 0.5, zoomScale: 1, normalizedCenter: CGPoint(x: 0.5, y: 0.5))
    viewport.fitScale = ViewportState.fitScale(imagePixels: sourceSize, viewPoints: viewSize)
    guard let plan = NativeTilePlanner.plan(
        sourceRect: NativeTilePlanner.visibleSourceRect(viewport: viewport,
                                                        sourcePixelSize: sourceSize,
                                                        viewSize: viewSize),
        sourcePixelSize: sourceSize, tileSize: tileSize) else { return }
    final class Collector: @unchecked Sendable {
        private let lock = NSLock(); private var storage: [NativeTile] = []
        func append(_ t: NativeTile) { lock.lock(); storage.append(t); lock.unlock() }
        var tiles: [NativeTile] { lock.lock(); defer { lock.unlock() }; return storage }
    }
    let collector = Collector()
    try? PNGNativeTileProvider().produce(plan: plan, source: fixtureURL, pageIndex: 0, gutter: 1,
                                        colorSpace: nil, shouldCancel: { false },
                                        onTile: { collector.append($0) })
    // Pick a tile in the middle of the visible area, but not the first row: a y error should
    // be visible as the tile landing somewhere else.
    guard let tile = collector.tiles.first(where: { $0.key.y == plan.visible.map(\.y).min()! + 1
                                                   && $0.sourceRect.width == CGFloat(tileSize) }) else {
        print("ISOLATED: no suitable tile in the plan")
        return
    }
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .bgra8Unorm, width: Int(viewSize.width), height: Int(viewSize.height), mipmapped: false)
    descriptor.usage = [.renderTarget, .shaderRead]
    descriptor.storageMode = .shared
    guard let target = device.makeTexture(descriptor: descriptor) else { return }
    _ = renderer.renderOffscreen(image: proxy, nativeTiles: [tile], sourcePixelSize: sourceSize,
                                 viewport: viewport, viewSize: viewSize, contentsScale: 1,
                                 backgroundColor: CGColor(red: 0, green: 0, blue: 0, alpha: 1), into: target)
    var pixels = [UInt8](repeating: 0, count: Int(viewSize.width) * Int(viewSize.height) * 4)
    pixels.withUnsafeMutableBytes { bytes in
        target.getBytes(bytes.baseAddress!, bytesPerRow: Int(viewSize.width) * 4,
                        from: MTLRegionMake2D(0, 0, Int(viewSize.width), Int(viewSize.height)), mipmapLevel: 0)
    }
    // Where did it land? A tile pixel is non-grey; the proxy is flat grey 128.
    var minX = Int.max, maxX = Int.min, minY = Int.max, maxY = Int.min
    for y in 0..<Int(viewSize.height) {
        for x in 0..<Int(viewSize.width) {
            let offset = (y * Int(viewSize.width) + x) * 4
            let r = Int(pixels[offset + 2]), g = Int(pixels[offset + 1]), b = Int(pixels[offset])
            // The fixture's channels differ from each other; the proxy is neutral. Saturation
            // identifies tile pixels without assuming the proxy's exact value (it renders as
            // 146, not 128, because CGColor(red:green:blue:) is generic RGB, not sRGB).
            let spread = max(r, g, b) - min(r, g, b)
            if spread > 6 {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
    }
    // Where should it land? Map the tile's centred rect through the transform.
    let transform = viewport.imageToViewTransform(sourcePixelSize: sourceSize, viewSize: viewSize)
    let centred = ViewportState.centredSourceRect(tile.sourceRect, sourcePixelSize: sourceSize)
    let tl = CGPoint(x: centred.minX, y: centred.maxY).applying(transform)
    let br = CGPoint(x: centred.maxX, y: centred.minY).applying(transform)
    let expected = CGRect(x: min(tl.x, br.x), y: min(tl.y, br.y),
                          width: abs(br.x - tl.x), height: abs(br.y - tl.y))
    print("\nISOLATED tile \(tile.key.x),\(tile.key.y) rect=\(tile.sourceRect)")
    print("  landed in view rows \(minY)...\(maxY), columns \(minX)...\(maxX)")
    print("  expected view rect y \(viewSize.height - expected.maxY)...\(viewSize.height - expected.minY)"
          + ", x \(expected.minX)...\(expected.maxX)")
    // And the content at the top of the landed box: is it the tile's top row or its bottom?
    let topRowOffset = (minY * Int(viewSize.width) + (minX + 2)) * 4
    print("  pixel near landed top-left: (\(pixels[topRowOffset + 2]),\(pixels[topRowOffset + 1]),"
          + "\(pixels[topRowOffset]))")
    let (topRowWantedR, topRowWantedG, topRowWantedB) = intensity(x: Int(tile.sourceRect.minX) + 2,
                                                                 y: Int(tile.sourceRect.minY))
    let (bottomRowWantedR, bottomRowWantedG, bottomRowWantedB) = intensity(x: Int(tile.sourceRect.minX) + 2,
                                                                          y: Int(tile.sourceRect.maxY) - 1)
    print("  tile's own top row wants (\(topRowWantedR),\(topRowWantedG),\(topRowWantedB)), "
          + "bottom row wants (\(bottomRowWantedR),\(bottomRowWantedG),\(bottomRowWantedB))")
}

print("tileposbench: fixture \(fixtureWidth)x\(fixtureHeight), proxy 120x115 (flat grey)")
print("Source coordinate recovery: R = x % 251, G = y % 241, B = (x*7 + y*13) % 239")

// Control: a proxy that encodes coordinates too, rendered alone. If *it* lands correctly the
// mapping is right and any tile error is a tile error; if it is flipped as well, the flip is
// in the shared convention or in this probe's own mapping — which would otherwise hide.
func proxyOnlyControl(renderer: MetalImageRenderer, device: MTLDevice) {
    guard let encodingProxy = imageFrom(fixturePixels(), width: fixtureWidth, height: fixtureHeight) else { return }
    let sourceSize = CGSize(width: fixtureWidth, height: fixtureHeight)
    let viewSize = CGSize(width: 200, height: 160)
    var viewport = ViewportState(fitScale: 1, zoomScale: 1, normalizedCenter: CGPoint(x: 0.5, y: 0.5))
    viewport.fitScale = ViewportState.fitScale(imagePixels: sourceSize, viewPoints: viewSize)
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .bgra8Unorm, width: Int(viewSize.width), height: Int(viewSize.height), mipmapped: false)
    descriptor.usage = [.renderTarget, .shaderRead]
    descriptor.storageMode = .shared
    guard let target = device.makeTexture(descriptor: descriptor) else { return }
    _ = renderer.renderOffscreen(image: encodingProxy, nativeTiles: [], sourcePixelSize: sourceSize,
                                 viewport: viewport, viewSize: viewSize, contentsScale: 1,
                                 backgroundColor: CGColor(red: 0, green: 0, blue: 0, alpha: 1), into: target)
    var pixels = [UInt8](repeating: 0, count: Int(viewSize.width) * Int(viewSize.height) * 4)
    pixels.withUnsafeMutableBytes { bytes in
        target.getBytes(bytes.baseAddress!, bytesPerRow: Int(viewSize.width) * 4,
                        from: MTLRegionMake2D(0, 0, Int(viewSize.width), Int(viewSize.height)), mipmapLevel: 0)
    }
    let transform = viewport.imageToViewTransform(sourcePixelSize: sourceSize, viewSize: viewSize)
    print("\nPROXY-ONLY CONTROL (coordinate-encoding proxy, no tiles)")
    var worst = 0
    for row in 0..<5 {
        for column in 0..<5 {
            let fx = (Double(column) + 0.5) / 5, fy = (Double(row) + 0.5) / 5
            let viewPoint = CGPoint(x: fx * viewSize.width, y: fy * viewSize.height)
            let centred = viewPoint.applying(transform.inverted())
            let cx = Int((centred.x + sourceSize.width / 2).rounded(.down))
            let cy = Int((sourceSize.height / 2 - centred.y).rounded(.down))
            guard cx >= 0, cy >= 0, cx < fixtureWidth, cy < fixtureHeight else { continue }
            let px = Int(viewPoint.x.rounded(.down))
            let py = Int((viewSize.height - viewPoint.y).rounded(.down))
            let offset = (py * Int(viewSize.width) + px) * 4
            let (wr, wg, wb) = intensity(x: cx, y: cy)
            let got = (Int(pixels[offset + 2]), Int(pixels[offset + 1]), Int(pixels[offset]))
            let delta = max(abs(got.0 - Int(wr)), abs(got.1 - Int(wg)), abs(got.2 - Int(wb)))
            worst = max(worst, delta)
            if column % 2 == 0 && row % 2 == 0 {
                print("  view(\(px),\(py)) canonical(\(cx),\(cy)) want(\(wr),\(wg),\(wb)) got\(got) delta \(delta)")
            }
        }
    }
    print("  worst delta \(worst) -> proxy \(worst <= 2 ? "LANDS CORRECTLY" : "IS ALSO MISPLACED")")
}

/// 1:1 A/B: render one tile filling the view exactly, and compare the frame against the tile
/// image row by row. This says whether the tile *upload and sampling* preserve row order,
/// independently of any transform or plan.
func tileOneToOne(renderer: MetalImageRenderer, device: MTLDevice, tileSize: Int) {
    let sourceSize = CGSize(width: fixtureWidth, height: fixtureHeight)
    final class Box: @unchecked Sendable {
        private let lock = NSLock(); private var storage: [NativeTile] = []
        func append(_ t: NativeTile) { lock.lock(); storage.append(t); lock.unlock() }
        var tiles: [NativeTile] { lock.lock(); defer { lock.unlock() }; return storage }
    }
    let box = Box()
    let plan = NativeTilePlanner.plan(sourceRect: CGRect(x: 64, y: 64, width: CGFloat(tileSize), height: CGFloat(tileSize)),
                                      sourcePixelSize: sourceSize, tileSize: tileSize)!
    try? PNGNativeTileProvider().produce(plan: plan, source: fixtureURL, pageIndex: 0, gutter: 1,
                                        colorSpace: nil, shouldCancel: { false },
                                        onTile: { box.append($0) })
    let tiles = box.tiles
    guard let tile = tiles.first(where: { $0.key.x == 1 && $0.key.y == 1 && $0.sourceRect.width == CGFloat(tileSize) }),
          let proxyImage = imageFrom(fixturePixels(), width: fixtureWidth, height: fixtureHeight) else { return }
    // Centre the viewport on this tile's centre, 1:1.
    let centre = CGPoint(x: tile.sourceRect.midX / sourceSize.width,
                         y: 1 - tile.sourceRect.midY / sourceSize.height)
    var viewport = ViewportState(fitScale: 1, zoomScale: 1, normalizedCenter: centre)
    viewport.fitScale = 1
    let side = tileSize
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .bgra8Unorm, width: side, height: side, mipmapped: false)
    descriptor.usage = [.renderTarget, .shaderRead]
    descriptor.storageMode = .shared
    guard let target = device.makeTexture(descriptor: descriptor) else { return }
    _ = renderer.renderOffscreen(image: proxyImage, nativeTiles: tiles, sourcePixelSize: sourceSize,
                                 viewport: viewport, viewSize: CGSize(width: side, height: side),
                                 contentsScale: 1,
                                 backgroundColor: CGColor(red: 0, green: 0, blue: 0, alpha: 1), into: target)
    var pixels = [UInt8](repeating: 0, count: side * side * 4)
    pixels.withUnsafeMutableBytes { bytes in
        target.getBytes(bytes.baseAddress!, bytesPerRow: side * 4,
                        from: MTLRegionMake2D(0, 0, side, side), mipmapLevel: 0)
    }
    // The tile's own pixels, straight from its data provider (row 0 = first row in memory).
    let image = tile.image
    var tilePixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
    tilePixels.withUnsafeMutableBytes { bytes in
        guard let context = CGContext(data: bytes.baseAddress, width: image.width, height: image.height,
                                      bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    }
    print("\n1:1 TILE A/B tile \(tile.key.x),\(tile.key.y) rect=\(tile.sourceRect) image \(image.width)x\(image.height)")
    print("  rendered row |  rendered(R,G,B)  | tile image row (R,G,B) | tile image row REVERSED")
    for row in [2, side / 2, side - 3] {
        let rOffset = (row * side + 2) * 4
        let rendered = (Int(pixels[rOffset + 2]), Int(pixels[rOffset + 1]), Int(pixels[rOffset]))
        let tOffset = (row * image.width + 2) * 4
        let asIs = (Int(tilePixels[tOffset]), Int(tilePixels[tOffset + 1]), Int(tilePixels[tOffset + 2]))
        let revRow = image.height - 1 - row
        let revOffset = (revRow * image.width + 2) * 4
        let reversed = (Int(tilePixels[revOffset]), Int(tilePixels[revOffset + 1]), Int(tilePixels[revOffset + 2]))
        let verdict = rendered == asIs ? "as-is" : (rendered == reversed ? "REVERSED" : "neither")
        print("  \(row)           | \(rendered) | \(asIs) | \(reversed)   -> \(verdict)")
    }
}

/// Is the flip in the tile bookkeeping, or in uploading+sampling an image at all? Upload the
/// same kind of image through the plain image path and render it 1:1. Two sizes, because the
/// proxy that works is large and the tiles that fail are small.
func plainImageOneToOne(renderer: MetalImageRenderer, device: MTLDevice, width: Int, height: Int) {
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    for y in 0..<height {
        for x in 0..<width {
            let (r, g, b) = intensity(x: x, y: y)
            let offset = (y * width + x) * 4
            pixels[offset] = r; pixels[offset + 1] = g; pixels[offset + 2] = b; pixels[offset + 3] = 255
        }
    }
    guard let image = imageFrom(pixels, width: width, height: height) else { return }
    let sourceSize = CGSize(width: width, height: height)
    var viewport = ViewportState(fitScale: 1, zoomScale: 1, normalizedCenter: CGPoint(x: 0.5, y: 0.5))
    viewport.fitScale = 1
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
    descriptor.usage = [.renderTarget, .shaderRead]
    descriptor.storageMode = .shared
    guard let target = device.makeTexture(descriptor: descriptor) else { return }
    _ = renderer.renderOffscreen(image: image, nativeTiles: [], sourcePixelSize: sourceSize,
                                 viewport: viewport, viewSize: sourceSize, contentsScale: 1,
                                 backgroundColor: CGColor(red: 0, green: 0, blue: 0, alpha: 1), into: target)
    var rendered = [UInt8](repeating: 0, count: width * height * 4)
    rendered.withUnsafeMutableBytes { bytes in
        target.getBytes(bytes.baseAddress!, bytesPerRow: width * 4,
                        from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
    }
    print("\nPLAIN IMAGE 1:1 \(width)x\(height) through the image path (no tiles)")
    for row in [2, height / 2, height - 3] {
        let offset = (row * width + 2) * 4
        let got = (Int(rendered[offset + 2]), Int(rendered[offset + 1]), Int(rendered[offset]))
        let want = intensity(x: 2, y: row)
        let flipped = intensity(x: 2, y: height - 1 - row)
        let verdict = got == (Int(want.0), Int(want.1), Int(want.2)) ? "as-is"
            : (got == (Int(flipped.0), Int(flipped.1), Int(flipped.2)) ? "REVERSED" : "neither")
        print("  row \(row): got \(got) want \(want) flipped \(flipped) -> \(verdict)")
    }
}

/// The same scene through Core Graphics, whose bitmap memory layout is unambiguous (row 0 is
/// the top of the image). If Quartz says "as-is" and Metal says "REVERSED" for the identical
/// scene, the two renderers disagree and one of them is upside down — that is the question this
/// answers, without trusting my own row arithmetic.
func quartzOneToOne(width: Int, height: Int) {
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    for y in 0..<height {
        for x in 0..<width {
            let (r, g, b) = intensity(x: x, y: y)
            let offset = (y * width + x) * 4
            pixels[offset] = r; pixels[offset + 1] = g; pixels[offset + 2] = b; pixels[offset + 3] = 255
        }
    }
    guard let image = imageFrom(pixels, width: width, height: height) else { return }
    let sourceSize = CGSize(width: width, height: height)
    var viewport = ViewportState(fitScale: 1, zoomScale: 1, normalizedCenter: CGPoint(x: 0.5, y: 0.5))
    viewport.fitScale = 1
    var rendered = [UInt8](repeating: 0, count: width * height * 4)
    rendered.withUnsafeMutableBytes { bytes in
        guard let context = CGContext(data: bytes.baseAddress, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        context.interpolationQuality = .none
        context.concatenate(viewport.imageToViewTransform(sourcePixelSize: sourceSize,
                                                          viewSize: sourceSize))
        context.draw(image, in: ViewportState.centredSourceRect(
            CGRect(origin: .zero, size: sourceSize), sourcePixelSize: sourceSize))
    }
    print("\nQUARTZ 1:1 \(width)x\(height) (same transform and rects as the Metal path)")
    for row in [2, height / 2, height - 3] {
        let offset = (row * width + 2) * 4
        let got = (Int(rendered[offset]), Int(rendered[offset + 1]), Int(rendered[offset + 2]))
        let want = intensity(x: 2, y: row)
        let flipped = intensity(x: 2, y: height - 1 - row)
        let verdict = got == (Int(want.0), Int(want.1), Int(want.2)) ? "as-is"
            : (got == (Int(flipped.0), Int(flipped.1), Int(flipped.2)) ? "REVERSED" : "neither")
        print("  row \(row): got \(got) want \(want) flipped \(flipped) -> \(verdict)")
    }
}

/// Convention-free positional acceptance: render the same scene (proxy + tiles) through both
/// renderers and diff the frames. No hand-derived mapping, no assumption about which way a
/// CGContext or a CGPoint.applying runs — Quartz is the reference implementation, Metal has to
/// put the same pixels in the same places.
func metalVsQuartz(renderer: MetalImageRenderer, device: MTLDevice, tileSize: Int,
                   viewSize: CGSize, centre: CGPoint) {
    let sourceSize = CGSize(width: fixtureWidth, height: fixtureHeight)
    guard let encodingProxy = imageFrom(fixturePixels(), width: fixtureWidth, height: fixtureHeight) else { return }
    var viewport = ViewportState(fitScale: 1, zoomScale: 1, normalizedCenter: centre)
    viewport.fitScale = ViewportState.fitScale(imagePixels: sourceSize, viewPoints: viewSize)
    guard let plan = NativeTilePlanner.plan(
        sourceRect: NativeTilePlanner.visibleSourceRect(viewport: viewport, sourcePixelSize: sourceSize,
                                                        viewSize: viewSize),
        sourcePixelSize: sourceSize, tileSize: tileSize) else { return }
    final class Box: @unchecked Sendable {
        private let lock = NSLock(); private var storage: [NativeTile] = []
        func append(_ t: NativeTile) { lock.lock(); storage.append(t); lock.unlock() }
        var tiles: [NativeTile] { lock.lock(); defer { lock.unlock() }; return storage }
    }
    let box = Box()
    try? PNGNativeTileProvider().produce(plan: plan, source: fixtureURL, pageIndex: 0, gutter: 1,
                                        colorSpace: nil, shouldCancel: { false }, onTile: { box.append($0) })
    let tiles = box.tiles
    let width = Int(viewSize.width), height = Int(viewSize.height)

    // Metal
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width,
                                                              height: height, mipmapped: false)
    descriptor.usage = [.renderTarget, .shaderRead]
    descriptor.storageMode = .shared
    guard let target = device.makeTexture(descriptor: descriptor) else { return }
    _ = renderer.renderOffscreen(image: encodingProxy, nativeTiles: tiles, sourcePixelSize: sourceSize,
                                 viewport: viewport, viewSize: viewSize, contentsScale: 1,
                                 backgroundColor: CGColor(red: 0, green: 0, blue: 0, alpha: 1), into: target)
    var metal = [UInt8](repeating: 0, count: width * height * 4)
    metal.withUnsafeMutableBytes { bytes in
        target.getBytes(bytes.baseAddress!, bytesPerRow: width * 4,
                        from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
    }

    // Quartz, same scene: fill, transform, proxy, tiles.
    var quartz = [UInt8](repeating: 0, count: width * height * 4)
    quartz.withUnsafeMutableBytes { bytes in
        guard let context = CGContext(data: bytes.baseAddress, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .none
        context.concatenate(viewport.imageToViewTransform(sourcePixelSize: sourceSize, viewSize: viewSize))
        context.draw(encodingProxy, in: ViewportState.centredSourceRect(
            CGRect(origin: .zero, size: sourceSize), sourcePixelSize: sourceSize))
        for tile in tiles {
            context.draw(tile.image, in: ViewportState.centredSourceRect(tile.sourceRect,
                                                                        sourcePixelSize: sourceSize))
        }
    }

    var differing = 0
    var worst = 0
    for pixel in stride(from: 0, to: width * height * 4, by: 4) {
        let dR = abs(Int(metal[pixel + 2]) - Int(quartz[pixel]))
        let dG = abs(Int(metal[pixel + 1]) - Int(quartz[pixel + 1]))
        let dB = abs(Int(metal[pixel]) - Int(quartz[pixel + 2]))
        let delta = max(dR, dG, dB)
        if delta > 2 { differing += 1 }
        worst = max(worst, delta)
    }
    print(String(format: "  tile %d view %dx%d centre (%.2f,%.2f): tiles=%d differing=%d/%d worst=%d -> %@",
                 tileSize, width, height, centre.x, centre.y, tiles.count, differing, width * height,
                 worst, differing == 0 ? "IDENTICAL" : "MISMATCH"))
}

print("\nMETAL vs QUARTZ, same scene with tiles (Quartz is the reference)")
for tileSize in [64, 128] {
    for viewSize in [CGSize(width: 200, height: 160), CGSize(width: 120, height: 120)] {
        for centre in [CGPoint(x: 0.5, y: 0.5), CGPoint(x: 0.2, y: 0.8)] {
            metalVsQuartz(renderer: renderer, device: device, tileSize: tileSize,
                          viewSize: viewSize, centre: centre)
        }
    }
}

quartzOneToOne(width: 240, height: 230)
plainImageOneToOne(renderer: renderer, device: device, width: 240, height: 230)
plainImageOneToOne(renderer: renderer, device: device, width: 64, height: 64)
tileOneToOne(renderer: renderer, device: device, tileSize: 64)
proxyOnlyControl(renderer: renderer, device: device)
isolatedTileProbe(renderer: renderer, device: device)

for tileSize in tileSizes {
    for viewSize in viewSizes {
        for centre in [CGPoint(x: 0.5, y: 0.5), CGPoint(x: 0.25, y: 0.75)] {
            var viewport = ViewportState(fitScale: 0.5, zoomScale: 1, normalizedCenter: centre)
            viewport.fitScale = ViewportState.fitScale(imagePixels: sourceSize, viewPoints: viewSize)
            guard let plan = NativeTilePlanner.plan(
                sourceRect: NativeTilePlanner.visibleSourceRect(viewport: viewport,
                                                                sourcePixelSize: sourceSize,
                                                                viewSize: viewSize),
                sourcePixelSize: sourceSize, tileSize: tileSize) else { continue }

            final class Collector: @unchecked Sendable {
                private let lock = NSLock()
                private var storage: [NativeTile] = []
                func append(_ tile: NativeTile) { lock.lock(); storage.append(tile); lock.unlock() }
                var tiles: [NativeTile] { lock.lock(); defer { lock.unlock() }; return storage }
            }
            let collector = Collector()
            do {
                try PNGNativeTileProvider().produce(plan: plan, source: fixtureURL, pageIndex: 0,
                                                    gutter: 1, colorSpace: nil,
                                                    shouldCancel: { false },
                                                    onTile: { collector.append($0) })
            } catch {
                FileHandle.standardError.write(Data("pass failed: \(error)\n".utf8)); continue
            }
            let tiles = collector.tiles

            let side = Int(viewSize.width)
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm, width: side, height: Int(viewSize.height), mipmapped: false)
            descriptor.usage = [.renderTarget, .shaderRead]
            descriptor.storageMode = .shared
            guard let target = device.makeTexture(descriptor: descriptor) else { continue }
            let rendered = renderer.renderOffscreen(image: proxy, nativeTiles: tiles,
                                                    sourcePixelSize: sourceSize, viewport: viewport,
                                                    viewSize: viewSize, contentsScale: 1,
                                                    backgroundColor: CGColor(red: 0, green: 0, blue: 0, alpha: 1),
                                                    into: target)
            var pixels = [UInt8](repeating: 0, count: side * Int(viewSize.height) * 4)
            pixels.withUnsafeMutableBytes { bytes in
                target.getBytes(bytes.baseAddress!, bytesPerRow: side * 4,
                                from: MTLRegionMake2D(0, 0, side, Int(viewSize.height)), mipmapLevel: 0)
            }

            print("\n--- tile \(tileSize), view \(Int(viewSize.width))x\(Int(viewSize.height)), "
                  + "centre (\(centre.x), \(centre.y)), tiles \(tiles.count) ---")
            // Quad placement or tile content? For one sample, find the tile whose *quad* covers
            // the view point and read the tile image at the local offset the geometry implies.
            if let sample = tiles.first(where: { $0.sourceRect.width >= CGFloat(tileSize) }) {
                let image = sample.image
                var buffer = [UInt8](repeating: 0, count: image.width * image.height * 4)
                buffer.withUnsafeMutableBytes { bytes in
                    if let context = CGContext(data: bytes.baseAddress, width: image.width,
                                               height: image.height, bitsPerComponent: 8,
                                               bytesPerRow: image.width * 4,
                                               space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                               bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
                    }
                }
                let rect = sample.sourceRect
                let ox = Int(rect.minX), oy = Int(rect.minY)
                func tilePixel(_ lx: Int, _ ly: Int) -> (Int, Int, Int) {
                    let offset = (ly * image.width + lx) * 4
                    return (Int(buffer[offset]), Int(buffer[offset + 1]), Int(buffer[offset + 2]))
                }
                for (lx, ly) in [(4, 4), (4, Int(rect.height) / 2), (4, Int(rect.height) - 5)] {
                    let atTopLeft = tilePixel(lx, ly)
                    let wantSame = intensity(x: ox + lx, y: oy + ly)
                    let wantFlipped = intensity(x: ox + lx, y: oy + Int(rect.height) - 1 - ly)
                    print("  tile \(sample.key.x),\(sample.key.y) rect=\(rect) local(\(lx),\(ly)) "
                          + "image=\(atTopLeft) sourceRowMajor=\(wantSame) sourceRowFlipped=\(wantFlipped)")
                }
            }
            let transform = viewport.imageToViewTransform(sourcePixelSize: sourceSize, viewSize: viewSize)
            var worst = 0
            var worstAt = ""
            for row in 0..<8 {
                for column in 0..<8 {
                    let fx = (Double(column) + 0.5) / 8, fy = (Double(row) + 0.5) / 8
                    let viewPoint = CGPoint(x: fx * viewSize.width, y: fy * viewSize.height)
                    let centred = viewPoint.applying(transform.inverted())
                    let canonicalX = Int((centred.x + sourceSize.width / 2).rounded(.down))
                    let canonicalY = Int((sourceSize.height / 2 - centred.y).rounded(.down))
                    guard canonicalX >= 0, canonicalY >= 0,
                          canonicalX < fixtureWidth, canonicalY < fixtureHeight else { continue }
                    let px = Int(viewPoint.x.rounded(.down))
                    let py = Int((viewSize.height - viewPoint.y).rounded(.down))
                    guard px >= 0, py >= 0, px < side, py < Int(viewSize.height) else { continue }
                    let offset = (py * side + px) * 4
                    // bgra8Unorm: B, G, R, A
                    let gotR = Int(pixels[offset + 2]), gotG = Int(pixels[offset + 1])
                    let (wantR, wantG, wantB) = intensity(x: canonicalX, y: canonicalY)
                    // Recover the coordinate the rendered pixel came from, when it is recoverable.
                    var recovered = "flat/other"
                    if gotR < 251, gotG < 241 {
                        let candidateB = (gotR * 7 + gotG * 13) % 239
                        if abs(candidateB - Int(pixels[offset])) <= 2 || pixels[offset] == wantB {
                            recovered = "(\(gotR),\(gotG))"
                        }
                    }
                    let delta = max(abs(gotR - Int(wantR)), abs(gotG - Int(wantG)))
                    if delta > worst { worst = delta; worstAt = "view(\(px),\(py)) = canonical(\(canonicalX),\(canonicalY))" }
                    if column % 3 == 0 && row % 3 == 0 {
                        print(String(format: "  view(%3d,%3d) canonical(%3d,%3d) want(%3d,%3d,%3d) got(%3d,%3d,%3d) from=%@",
                                     px, py, canonicalX, canonicalY, Int(wantR), Int(wantG), Int(wantB),
                                     gotR, gotG, Int(pixels[offset]), recovered))
                    }
                }
            }
            print("  worst channel delta \(worst) at \(worstAt)")
        }
    }
}
