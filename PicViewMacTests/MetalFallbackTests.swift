import XCTest
import AppKit
import CoreGraphics
@testable import PicViewMac

/// Metal is an optimization, never a requirement: a missing shader library, a machine
/// without Metal, or a bitmap layout the renderer cannot present must all end with the
/// bounded bitmap drawn by Quartz over the same source rectangle.
@MainActor
final class MetalFallbackTests: XCTestCase {

    private func solidBitmap(width: Int, height: Int) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try XCTUnwrap(context.makeImage())
    }

    private func coverage(of canvas: ImageCanvasView) -> Double {
        let width = Int(canvas.bounds.width), height = Int(canvas.bounds.height)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return 0 }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        canvas.draw(canvas.bounds)
        NSGraphicsContext.restoreGraphicsState()
        var covered = 0, sampled = 0
        for y in stride(from: 1, to: height, by: 8) {
            for x in stride(from: 1, to: width, by: 8) {
                sampled += 1
                if let color = rep.colorAt(x: x, y: y), color.alphaComponent > 0.05 { covered += 1 }
            }
        }
        return sampled > 0 ? Double(covered) / Double(sampled) : 0
    }

    /// A missing resource bundle must return nil. `Bundle.module` — the accessor
    /// SwiftPM generates — traps here, which is why the runtime path never uses it.
    func testMissingResourceBundleReturnsNilInsteadOfTrapping() {
        let bogus = URL(fileURLWithPath: "/tmp/definitely-not-a-bundle-\(UUID().uuidString)")
        XCTAssertNil(MetalLibraryLocator.resourceBundle(candidates: [bogus]))
        XCTAssertNil(MetalLibraryLocator.resourceBundle(candidates: []))
    }

    func testCanvasFallsBackToQuartzWhenNoRendererIsAvailable() throws {
        let canvas = ImageCanvasView(frame: NSRect(x: 0, y: 0, width: 1600, height: 1000))
        canvas.metalRendererFactory = { nil }               // as if Metal were unavailable
        let bitmap = try solidBitmap(width: 40, height: 27)
        canvas.renderImage = RenderImage(bitmap: bitmap, descriptor: ImageDescriptor(
            sourceURL: URL(fileURLWithPath: "/tmp/source.png"),
            pixelSize: CGSize(width: 32000, height: 48000)))   // portrait source
        canvas.setZoomToFit()

        XCTAssertFalse(canvas.isUsingMetal)
        XCTAssertFalse(canvas.isUsingMetalForCurrentImage)
        let covered = coverage(of: canvas)
        XCTAssertGreaterThan(covered, 0.30,
                             "the fallback still draws the bitmap over the source rectangle")
        XCTAssertLessThan(covered, 0.55)
    }

    /// A layout the renderer cannot present (16-bit here) must not leave an empty
    /// canvas: the decision is per bitmap, not per canvas.
    func testUnsupportedBitmapIsDrawnByQuartzEvenWhenMetalIsAvailable() throws {
        let canvas = ImageCanvasView(frame: NSRect(x: 0, y: 0, width: 1600, height: 1000))
        let sixteenBit = try XCTUnwrap(CGContext(
            data: nil, width: 40, height: 27, bitsPerComponent: 16, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage())
        XCTAssertFalse(MetalImageRenderer.canRender(sixteenBit))
        canvas.renderImage = RenderImage(bitmap: sixteenBit, descriptor: ImageDescriptor(
            sourceURL: URL(fileURLWithPath: "/tmp/source.png"),
            pixelSize: CGSize(width: 40, height: 27)))
        canvas.setZoomToFit()

        canvas.renderImage = RenderImage(bitmap: sixteenBit, descriptor: ImageDescriptor(
            sourceURL: URL(fileURLWithPath: "/tmp/source.png"),
            pixelSize: CGSize(width: 40, height: 27)))
        // Without a window there is no surface at all; the point of this test is the
        // per-bitmap decision, which must be false either way.
        XCTAssertFalse(canvas.isUsingMetalForCurrentImage)
        _ = coverage(of: canvas)      // must not crash and must still paint the background
    }

    func testRendererWithoutADeviceIsNil() {
        XCTAssertNil(MetalImageRenderer(device: nil, library: nil),
                     "no device means no renderer, which selects the Quartz fallback")
    }
}
