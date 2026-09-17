import XCTest
import AppKit
import CoreGraphics
@testable import PicViewMac

/// Geometry invariants for a render bitmap that is *not* the source size.
///
/// These are the tests that fail if anything derives viewport geometry from
/// `bitmap.width/height` instead of `ImageDescriptor.displayPixelSize`: a bounded
/// proxy is smaller than the source it stands for, and the whole point of the
/// large-image design is that the two are allowed to differ.
@MainActor
final class LargeImageGeometryTests: XCTestCase {

    /// A 3:2 source whose bitmap is 1200× smaller — the ratio is what matters, so
    /// the test stays cheap instead of allocating a real 8192-long-edge bitmap.
    private func portraitSourceCanvas(
        bitmapSize: CGSize = CGSize(width: 40, height: 27),
        viewSize: CGSize = CGSize(width: 1600, height: 1000)
    ) throws -> (canvas: ImageCanvasView, descriptor: ImageDescriptor, bitmap: CGImage) {
        let bitmap = try Self.solidBitmap(size: bitmapSize)
        let descriptor = ImageDescriptor(
            sourceURL: URL(fileURLWithPath: "/tmp/source.png"),
            pixelSize: CGSize(width: 48000, height: 32000)
        )
        let canvas = ImageCanvasView(frame: NSRect(origin: .zero, size: viewSize))
        canvas.renderImage = RenderImage(bitmap: bitmap, descriptor: descriptor)
        return (canvas, descriptor, bitmap)
    }

    private static func solidBitmap(size: CGSize) throws -> CGImage {
        let width = Int(size.width), height = Int(size.height)
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try XCTUnwrap(context.makeImage())
    }

    /// Fraction of the view covered by anything the canvas drew.
    private func renderedCoverage(of canvas: ImageCanvasView) -> Double {
        let width = Int(canvas.bounds.width), height = Int(canvas.bounds.height)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return 0 }
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

    // MARK: - Source geometry is authoritative

    func testImagePixelSizeComesFromTheDescriptorNotTheBitmap() throws {
        let (canvas, _, bitmap) = try portraitSourceCanvas()
        XCTAssertEqual(canvas.imagePixelSize, CGSize(width: 48000, height: 32000))
        XCTAssertNotEqual(canvas.imagePixelSize, CGSize(width: bitmap.width, height: bitmap.height),
                          "geometry must not be read from the decoded bitmap")
        XCTAssertEqual(canvas.image?.width, bitmap.width, "the bitmap itself is still what gets drawn")
    }

    func testFitUsesSourceDimensions() throws {
        let (canvas, _, _) = try portraitSourceCanvas()
        canvas.setZoomToFit()
        let expected = min(canvas.bounds.width / 48000, canvas.bounds.height / 32000)
        XCTAssertEqual(canvas.viewport.zoomScale, expected, accuracy: 1e-9)
        XCTAssertEqual(canvas.viewport.normalizedCenter.x, 0.5, accuracy: 1e-9)
        XCTAssertEqual(canvas.viewport.normalizedCenter.y, 0.5, accuracy: 1e-9)
    }

    func testFitWidthUsesSourceDimensions() throws {
        let (canvas, _, _) = try portraitSourceCanvas()
        canvas.setZoomToFitWidth()
        XCTAssertEqual(canvas.viewport.zoomScale, canvas.bounds.width / 48000, accuracy: 1e-9)
    }

    func testActualPixelsMeansOneSourcePixelPerBackingPixel() throws {
        let (canvas, _, _) = try portraitSourceCanvas()
        canvas.setZoomToActualPixels()                       // backingScale is 2 without a window
        XCTAssertEqual(canvas.viewport.zoomScale, 0.5, accuracy: 1e-9)
        let displayedWidthInBackingPixels = 48000 * canvas.viewport.zoomScale * canvas.backingScale
        XCTAssertEqual(displayedWidthInBackingPixels, 48000, accuracy: 0.5,
                       "100% must still mean one source pixel per physical display pixel")
    }

    func testDoubleFitIsTwiceTheSourceBasedFit() throws {
        let (canvas, _, _) = try portraitSourceCanvas()
        canvas.setZoomToFit()
        let fit = canvas.viewport.zoomScale
        canvas.toggleFitAndDoubleFit()
        XCTAssertEqual(canvas.viewport.zoomScale, fit * 2, accuracy: 1e-9)
        canvas.toggleFitAndDoubleFit()
        XCTAssertEqual(canvas.viewport.zoomScale, fit, accuracy: 1e-9)
    }

    /// The decisive test for the drawn rectangle.
    ///
    /// Fit is not discriminating — a fit calculation scales *whatever* size it is
    /// given to fill the view, so both rectangles would cover the view. A fixed zoom
    /// is: at 100 % (0.5 on a 2x display) the 48000x32000 source covers the whole
    /// view, while a 40x27 bitmap mistakenly drawn at its own size would cover
    /// ~0.0002 of it. The control canvas below proves the metric can see that.
    func testDrawnRectangleFollowsTheSourceSizeAtAFixedZoom() throws {
        let (canvas, _, bitmap) = try portraitSourceCanvas()
        canvas.setZoomToActualPixels()                       // zoom 0.5, independent of the image size
        XCTAssertGreaterThan(renderedCoverage(of: canvas), 0.5,
                             "a 48000-wide source at 100% covers the view; a 40-px bitmap drawn at its own "
                             + "size would cover almost nothing")

        let control = ImageCanvasView(frame: NSRect(x: 0, y: 0, width: 1600, height: 1000))
        control.renderImage = RenderImage(nativeBitmap: bitmap)      // same pixels, source == bitmap
        control.setZoomToActualPixels()
        XCTAssertLessThan(renderedCoverage(of: control), 0.01,
                          "same bitmap, source 40x27: now it really is a few points across, which is what the "
                          + "proxy case would have measured had the draw rect followed the bitmap")
    }

    func testProxyAndNativeBitmapProduceIdenticalGeometry() throws {
        let (proxyCanvas, descriptor, _) = try portraitSourceCanvas(bitmapSize: CGSize(width: 40, height: 27))
        let nativeCanvas = ImageCanvasView(frame: NSRect(x: 0, y: 0, width: 1600, height: 1000))
        nativeCanvas.renderImage = RenderImage(bitmap: try Self.solidBitmap(size: CGSize(width: 82, height: 54)),
                                              descriptor: descriptor)
        proxyCanvas.setZoomToFit()
        nativeCanvas.setZoomToFit()
        XCTAssertEqual(proxyCanvas.imagePixelSize, nativeCanvas.imagePixelSize)
        XCTAssertEqual(proxyCanvas.viewport.zoomScale, nativeCanvas.viewport.zoomScale, accuracy: 1e-12)
        XCTAssertEqual(proxyCanvas.viewport.visibleNormalizedRect(imagePixels: proxyCanvas.imagePixelSize,
                                                                  viewPoints: proxyCanvas.bounds.size),
                       nativeCanvas.viewport.visibleNormalizedRect(imagePixels: nativeCanvas.imagePixelSize,
                                                                   viewPoints: nativeCanvas.bounds.size))
    }

    // MARK: - Rotation, mirror, pan

    func testRotationFitsTheSwappedSourceSize() throws {
        let (canvas, _, _) = try portraitSourceCanvas()
        canvas.setZoomToFit()
        canvas.rotateClockwise()
        let expected = min(canvas.bounds.width / 32000, canvas.bounds.height / 48000)
        XCTAssertEqual(canvas.viewport.fitScale, expected, accuracy: 1e-9,
                       "a quarter turn displays 32000x48000 even though the source is 48000x32000")
        XCTAssertEqual(canvas.viewport.normalizedQuarterTurns, 1)
        canvas.rotateCounterClockwise()
        XCTAssertEqual(canvas.viewport.normalizedQuarterTurns, 0)
        XCTAssertEqual(canvas.viewport.fitScale, min(canvas.bounds.width / 48000, canvas.bounds.height / 32000),
                       accuracy: 1e-9)
    }

    func testMirrorDoesNotChangeGeometry() throws {
        let (canvas, _, _) = try portraitSourceCanvas()
        canvas.setZoomToFit()
        let before = (canvas.imagePixelSize, canvas.viewport.fitScale, canvas.viewport.visibleNormalizedRect(
            imagePixels: canvas.imagePixelSize, viewPoints: canvas.bounds.size))
        canvas.toggleMirror()
        XCTAssertTrue(canvas.viewport.mirroredHorizontally)
        XCTAssertEqual(canvas.imagePixelSize, before.0)
        XCTAssertEqual(canvas.viewport.fitScale, before.1, accuracy: 1e-12)
        XCTAssertEqual(canvas.viewport.visibleNormalizedRect(imagePixels: canvas.imagePixelSize,
                                                             viewPoints: canvas.bounds.size), before.2,
                       "mirroring is view-only and must not move the viewport")
    }

    func testPanClampUsesSourceGeometry() throws {
        let (canvas, _, _) = try portraitSourceCanvas()
        canvas.setZoomToFit()
        // At fit the 3:2 source is height-limited, so the horizontal axis must stay
        // centred and the vertical axis clamps to the image bounds.
        var viewport = canvas.viewport
        viewport.pan(byViewDelta: CGSize(width: 5000, height: 5000),
                     imagePixels: canvas.imagePixelSize, viewPoints: canvas.bounds.size)
        XCTAssertEqual(viewport.normalizedCenter.x, 0.5, accuracy: 1e-6,
                       "an image narrower than the view is centred horizontally")
        XCTAssertEqual(viewport.normalizedCenter.y, 0.5, accuracy: 1e-6,
                       "an image exactly as tall as the view cannot pan vertically")

        // Zoomed in, the horizontal axis becomes pannable and clamps against the
        // width that the *source* implies.
        viewport.zoom(to: viewport.fitScale * 2, around: CGPoint(x: 800, y: 500),
                      viewPoints: canvas.bounds.size, imagePixels: canvas.imagePixelSize,
                      minScale: 0.01, maxScale: 100)
        let halfVisible = (canvas.bounds.width / 2) / (48000 * viewport.zoomScale)
        viewport.pan(byViewDelta: CGSize(width: -100000, height: 0),
                     imagePixels: canvas.imagePixelSize, viewPoints: canvas.bounds.size)
        XCTAssertEqual(viewport.normalizedCenter.x, 1 - halfVisible, accuracy: 1e-6)
    }

    func testVisibleRectUsesSourceGeometry() throws {
        let (canvas, _, _) = try portraitSourceCanvas()
        canvas.setZoomToFit()
        let rect = canvas.viewport.visibleNormalizedRect(imagePixels: canvas.imagePixelSize,
                                                         viewPoints: canvas.bounds.size)
        let zoom = canvas.viewport.zoomScale
        XCTAssertEqual(rect.width, min(1, canvas.bounds.width / (48000 * zoom)), accuracy: 1e-9)
        XCTAssertEqual(rect.height, min(1, canvas.bounds.height / (32000 * zoom)), accuracy: 1e-9)
    }

    // MARK: - Empty state

    func testNoImageMeansZeroGeometry() throws {
        let canvas = ImageCanvasView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        XCTAssertNil(canvas.renderImage)
        XCTAssertNil(canvas.image)
        XCTAssertEqual(canvas.imagePixelSize, .zero)
        canvas.refit()
        canvas.setZoomToFit()
        XCTAssertEqual(canvas.viewport.zoomScale, 1, "no image: the viewport is left alone")
    }
}
