// icon-probe — what artwork does the system hand out for an app bundle?
//
//   swift scripts/icon-probe.swift <pixels> <path> [<path> ...]
//
// AppKit resolves a bundle's icon through IconServices — the same lookup Finder,
// the Dock and ⌘-Tab use — so this measures the painted result rather than the
// files that were supposed to produce it. `verify-release.sh` runs it over a
// fresh copy of the built app and over a path that has no icon at all: equal
// fingerprints mean the bundle's icon never reached the system.
//
// The answer is cached per path by iconservicesd, and a path the daemon has
// already seen without an icon can keep answering with the generic placeholder
// for a long time — including across a rebuild at the same path. A copy at a
// path the daemon has never seen resolves the current bundle; that is why the
// verification copies the app instead of probing dist/ in place.
//
// One line per path, key=value, so the caller does not have to parse prose:
//   sha=<first 16 hex digits of the RGBA pixels> mean=r,g,b alpha=<coverage> rep=<largest representation> path=<path>
import AppKit
import CryptoKit

let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count >= 2, let pixels = arguments.first.flatMap({ Int($0) }), pixels >= 16 else {
    FileHandle.standardError.write("usage: swift scripts/icon-probe.swift <pixels> <path> [<path> ...]\n".data(using: .utf8)!)
    exit(2)
}

for path in arguments.dropFirst() {
    let icon = NSWorkspace.shared.icon(forFile: path)
    var pixelsBuffer = [UInt8](repeating: 0, count: pixels * pixels * 4)
    guard let context = CGContext(data: &pixelsBuffer, width: pixels, height: pixels,
                                  bitsPerComponent: 8, bytesPerRow: pixels * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        FileHandle.standardError.write("cannot create a \(pixels)x\(pixels) context\n".data(using: .utf8)!)
        exit(3)
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
    icon.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
    NSGraphicsContext.restoreGraphicsState()

    let digest = SHA256.hash(data: Data(pixelsBuffer)).map { String(format: "%02x", $0) }.joined()
    var sums = [Double](repeating: 0, count: 4)
    for index in stride(from: 0, to: pixelsBuffer.count, by: 4) {
        for channel in 0..<4 { sums[channel] += Double(pixelsBuffer[index + channel]) }
    }
    let count = Double(pixels * pixels)
    let largest = icon.representations.reduce(0) { max($0, max($1.pixelsWide, $1.pixelsHigh)) }
    print(String(format: "sha=%@ mean=%.1f,%.1f,%.1f alpha=%.3f rep=%d path=%@",
                 String(digest.prefix(16)), sums[0] / count, sums[1] / count, sums[2] / count,
                 sums[3] / count / 255.0, largest, path))
}
