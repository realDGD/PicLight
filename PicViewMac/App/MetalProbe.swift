import Foundation
import Metal
import CoreGraphics

// Deliberately no AppKit: the probe runs headless from a shell with no window server
// session, so it uses CGColor rather than NSColor.

/// Headless check that the *packaged* app can reach its Metal resources, and that a
/// missing resource bundle degrades to the Quartz fallback instead of crashing.
///
/// `scripts/verify-release.sh` runs the packaged binary with `PICLIGHT_METAL_PROBE=1`
/// and reads the single line it prints, so the release check exercises the real
/// bundle layout rather than a build-directory approximation.
public enum MetalProbe {
    public static var isRequested: Bool {
        ProcessInfo.processInfo.environment["PICLIGHT_METAL_PROBE"] != nil
    }

    /// Exit status: 0 when the probe reached a definite answer (Metal ready *or* an
    /// unavailable/fallback state), 1 when Metal claimed to be available and then
    /// failed — the only situation a release must treat as broken.
    @discardableResult
    public static func run() -> Int32 {
        guard let device = MTLCreateSystemDefaultDevice() else {
            print("metal=unavailable reason=no-device fallback=quartz")
            return 0
        }
        guard let renderer = MetalImageRenderer(device: device) else {
            // A missing resource bundle is a supported state (Quartz draws the bounded
            // bitmap), not a crash and not a failed release by itself; the release
            // script separately requires the compiled library to be packaged.
            let bundleFound = MetalLibraryLocator.resourceBundle() != nil
            print("metal=unavailable reason=no-library bundle=\(bundleFound) fallback=quartz")
            return 0
        }

        // Prove a pipeline really exists: upload a bitmap and render one frame.
        guard let context = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let image = context.makeImage() else {
            print("metal=failed reason=bitmap")
            return 1
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                                                                 width: 8, height: 8, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        guard let target = device.makeTexture(descriptor: descriptor) else {
            print("metal=failed reason=texture")
            return 1
        }
        var viewport = ViewportState()
        viewport.zoomScale = 1
        let rendered = renderer.renderOffscreen(image: image, sourcePixelSize: CGSize(width: 8, height: 8),
                                               viewport: viewport, viewSize: CGSize(width: 8, height: 8),
                                               contentsScale: 1, backgroundColor: CGColor(gray: 0, alpha: 0),
                                               into: target)
        guard rendered, renderer.hasMipmaps else {
            print("metal=failed reason=\(rendered ? "mipmaps" : "render")")
            return 1
        }
        print("metal=ok pipeline=created mipmaps=yes device=\(device.name)")
        return 0
    }
}
