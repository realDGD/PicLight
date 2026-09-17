#!/usr/bin/env swift
// Generates deterministic, self-owned fixtures for the PicViewMac test suite.
// WebP files are produced by the webp tools (cwebp / img2webp) because ImageIO
// can decode but not encode WebP on this platform.
//
// Usage: swift scripts/make-fixtures.swift <output-directory>

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import AppKit

let outputDirectory = URL(fileURLWithPath: CommandLine.arguments.count > 1
                          ? CommandLine.arguments[1]
                          : "PicViewMacTests/Fixtures")
try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

func makeImage(width: Int, height: Int, colorSpace: CGColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!,
               paint: (CGContext, Int, Int) -> Void = { context, w, h in
                   context.setFillColor(CGColor(red: 0.85, green: 0.2, blue: 0.25, alpha: 1))
                   context.fill(CGRect(x: 0, y: 0, width: w / 2, height: h))
                   context.setFillColor(CGColor(red: 0.15, green: 0.35, blue: 0.8, alpha: 1))
                   context.fill(CGRect(x: w / 2, y: 0, width: w - w / 2, height: h))
               }) -> CGImage {
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                            bytesPerRow: 0, space: colorSpace,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    paint(context, width, height)
    return context.makeImage()!
}

func write(_ image: CGImage, to name: String, type: UTType,
           properties: [CFString: Any] = [:]) {
    let url = outputDirectory.appendingPathComponent(name)
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL,
                                                            type.identifier as CFString, 1, nil) else {
        print("skip (no encoder): \(name)")
        return
    }
    CGImageDestinationAddImage(destination, image, properties as CFDictionary)
    print(CGImageDestinationFinalize(destination) ? "wrote \(name)" : "FAILED \(name)")
}

func writeMulti(_ images: [CGImage], to name: String, type: UTType,
                propertiesPerFrame: [[CFString: Any]] = [],
                containerProperties: [CFString: Any] = [:]) {
    let url = outputDirectory.appendingPathComponent(name)
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL,
                                                            type.identifier as CFString,
                                                            images.count, nil) else {
        print("skip (no encoder): \(name)")
        return
    }
    // Loop count belongs to the container, not to individual frames.
    if !containerProperties.isEmpty {
        CGImageDestinationSetProperties(destination, containerProperties as CFDictionary)
    }
    for (index, image) in images.enumerated() {
        let properties = index < propertiesPerFrame.count ? propertiesPerFrame[index] : [:]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
    }
    print(CGImageDestinationFinalize(destination) ? "wrote \(name)" : "FAILED \(name)")
}

// Static formats
write(makeImage(width: 64, height: 48), to: "static.png", type: .png)
write(makeImage(width: 40, height: 20), to: "static.bmp", type: .bmp)
write(makeImage(width: 24, height: 24), to: "static.gif", type: .gif)
write(makeImage(width: 96, height: 64), to: "static.jpg", type: .jpeg,
      properties: [kCGImageDestinationLossyCompressionQuality: 0.9])

// JPEG that stores EXIF orientation 6 (rotate 90° clockwise) without rewriting pixels.
write(makeImage(width: 40, height: 20), to: "oriented-6.jpg", type: .jpeg, properties: [
    kCGImagePropertyOrientation: 6,
    kCGImageDestinationLossyCompressionQuality: 0.9,
])

// Display P3 / ICC profile image to prove color-managed handling.
let p3 = CGColorSpace(name: CGColorSpace.displayP3)!
write(makeImage(width: 48, height: 32, colorSpace: p3), to: "display-p3.png", type: .png)

// ICO with two embedded sizes so representation selection can be exercised.
writeMulti([makeImage(width: 16, height: 16), makeImage(width: 32, height: 32)],
           to: "multi.ico", type: .ico)

// Animated GIF: three frames, uneven delays, infinite loop.
let frameColors: [(CGFloat, CGFloat, CGFloat)] = [(0.9, 0.2, 0.2), (0.2, 0.8, 0.3), (0.2, 0.3, 0.9)]
let gifFrames = frameColors.map { color in
    makeImage(width: 32, height: 32) { context, width, height in
        context.setFillColor(CGColor(red: color.0, green: color.1, blue: color.2, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    }
}

// Animated GIF: three frames, uneven delays, infinite loop (Netscape loop count 0).
var gifProperties: [[CFString: Any]] = []
for delay in [0.1, 0.2, 0.3] {
    gifProperties.append([
        kCGImagePropertyGIFDictionary: [
            kCGImagePropertyGIFDelayTime: delay,
            kCGImagePropertyGIFUnclampedDelayTime: delay,
        ],
    ])
}
writeMulti(gifFrames, to: "animated-infinite.gif", type: .gif, propertiesPerFrame: gifProperties,
           containerProperties: [
               kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0],
           ])

// Animated GIF that stops after two plays.
var finiteGifProperties: [[CFString: Any]] = []
for delay in [0.05, 0.05, 0.05] {
    finiteGifProperties.append([
        kCGImagePropertyGIFDictionary: [
            kCGImagePropertyGIFDelayTime: delay,
            kCGImagePropertyGIFUnclampedDelayTime: delay,
        ],
    ])
}
writeMulti(gifFrames, to: "animated-twice.gif", type: .gif, propertiesPerFrame: finiteGifProperties,
           containerProperties: [
               kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 2],
           ])

// Single-page TIFF, so page count 1 is covered explicitly.
write(makeImage(width: 36, height: 24), to: "single.tiff", type: .tiff)

// Multi-page TIFF: three pages of different sizes.
writeMulti([makeImage(width: 40, height: 30), makeImage(width: 30, height: 40), makeImage(width: 50, height: 20)],
           to: "multipage.tiff", type: .tiff)

// Truncated JPEG: a real JPEG whose body is cut short, so the decoder sees a
// plausible header with incomplete data.
write(makeImage(width: 128, height: 96), to: "full.jpg", type: .jpeg,
      properties: [kCGImageDestinationLossyCompressionQuality: 0.9])
let fullJPEG = try Data(contentsOf: outputDirectory.appendingPathComponent("full.jpg"))
let truncated = fullJPEG.prefix(fullJPEG.count * 2 / 5)
try Data(truncated).write(to: outputDirectory.appendingPathComponent("truncated.jpg"))
print("wrote truncated.jpg (\(truncated.count) of \(fullJPEG.count) bytes)")

// Corrupt file: valid extension, unusable body.
let corrupt = outputDirectory.appendingPathComponent("corrupt.png")
try Data("this is not a png".utf8).write(to: corrupt)
print("wrote corrupt.png")

// Non-image file used to prove the eligibility filter rejects it.
try Data("%PDF-1.4 not an image".utf8).write(to: outputDirectory.appendingPathComponent("not-an-image.pdf"))
print("wrote not-an-image.pdf")

// WebP through the webp tools, since ImageIO cannot encode WebP here.
func run(_ tool: String, _ arguments: [String]) -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/\(tool)")
    process.arguments = arguments
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    do {
        try process.run()
    } catch {
        print("skip (\(tool) unavailable)")
        return -1
    }
    process.waitUntilExit()
    return process.terminationStatus
}

let pngSource = outputDirectory.appendingPathComponent("static.png").path
let lossless = run("cwebp", ["-quiet", "-lossless", pngSource,
                             "-o", outputDirectory.appendingPathComponent("static.webp").path])
print(lossless == 0 ? "wrote static.webp" : "FAILED static.webp")

let lossy = run("cwebp", ["-quiet", "-q", "80", pngSource,
                          "-o", outputDirectory.appendingPathComponent("lossy.webp").path])
print(lossy == 0 ? "wrote lossy.webp" : "FAILED lossy.webp")

// Animated WebP from three frames with distinct durations and infinite loop.
let frameNames = ["frame0.png", "frame1.png", "frame2.png"]
for (index, image) in gifFrames.enumerated() {
    write(image, to: frameNames[index], type: .png)
}
let animated = run("img2webp", ["-loop", "0", "-d", "100", outputDirectory.appendingPathComponent(frameNames[0]).path,
                                "-d", "200", outputDirectory.appendingPathComponent(frameNames[1]).path,
                                "-d", "300", outputDirectory.appendingPathComponent(frameNames[2]).path,
                                "-o", outputDirectory.appendingPathComponent("animated.webp").path])
print(animated == 0 ? "wrote animated.webp" : "FAILED animated.webp")

// Animated WebP that plays a finite number of times.
let finiteWebP = run("img2webp", ["-loop", "2", "-d", "60", outputDirectory.appendingPathComponent(frameNames[0]).path,
                                  "-d", "60", outputDirectory.appendingPathComponent(frameNames[1]).path,
                                  "-o", outputDirectory.appendingPathComponent("animated-twice.webp").path])
print(finiteWebP == 0 ? "wrote animated-twice.webp" : "FAILED animated-twice.webp")
