import Foundation
import Metal

/// Finds the compiled Metal library without ever trapping.
///
/// `Bundle.module` — the accessor SwiftPM generates for a target with resources —
/// calls `fatalError` when the resource bundle is absent, which would make a missing
/// shader a launch crash instead of a Quartz fallback. This locator mirrors the same
/// search order and returns `nil` instead.
public enum MetalLibraryLocator {

    /// Bundle name SwiftPM generates for this target: `<Package>_<Target>`.
    static let resourceBundleName = "PicViewMac_PicViewMac"

    /// Where a resource bundle may live, in the order SwiftPM's own accessor uses,
    /// plus the executable's directory (a bare `swift run` binary has no .app).
    static func candidateURLs() -> [URL] {
        var urls: [URL] = []
        #if DEBUG
        // The development/test override SwiftPM itself honours.
        if let override = ProcessInfo.processInfo.environment["PACKAGE_RESOURCE_BUNDLE_PATH"]
            ?? ProcessInfo.processInfo.environment["PACKAGE_RESOURCE_BUNDLE_URL"] {
            urls.append(URL(fileURLWithPath: override))
        }
        #endif
        if let resource = Bundle.main.resourceURL { urls.append(resource) }
        urls.append(Bundle(for: BundleFinder.self).bundleURL)
        if let resource = Bundle(for: BundleFinder.self).resourceURL { urls.append(resource) }
        urls.append(Bundle.main.bundleURL)
        // `swift run` / xctest: the bundle sits next to the binary.
        if let executable = Bundle.main.executableURL?.deletingLastPathComponent() {
            urls.append(executable)
        }
        for bundle in Bundle.allBundles + Bundle.allFrameworks {
            urls.append(bundle.bundleURL)
            if let resource = bundle.resourceURL { urls.append(resource) }
        }
        return urls
    }

    /// The resource bundle, or nil. `candidates` is injectable so a test can prove the
    /// missing-bundle path returns nil rather than trapping.
    public static func resourceBundle(candidates: [URL]? = nil) -> Bundle? {
        for directory in candidates ?? candidateURLs() {
            let url = directory.appendingPathComponent("\(resourceBundleName).bundle")
            if let bundle = Bundle(url: url) { return bundle }
        }
        return nil
    }

    /// The shader source shipped inside the resource bundle, used only when no
    /// compiled library is present.
    static func shaderSource(bundle: Bundle) -> String? {
        guard let url = bundle.url(forResource: "ImageShaders", withExtension: "metal") else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    /// The Metal library, or nil when neither a compiled library nor a shader source
    /// can be loaded — which is the signal for the canvas to keep using Quartz.
    ///
    /// A release build always carries `default.metallib` (scripts/build-release.sh
    /// refuses to package without it), so the source path only runs in development on
    /// a machine without the Xcode Metal toolchain. It compiles the *shipped .metal
    /// file*, not a string literal in code, and only once per process.
    public static func defaultLibrary(device: MTLDevice) -> MTLLibrary? {
        guard let bundle = resourceBundle() else { return nil }
        if let compiled = try? device.makeDefaultLibrary(bundle: bundle) { return compiled }
        guard let source = shaderSource(bundle: bundle) else { return nil }
        FileHandle.standardError.write(
            "MetalLibraryLocator: no compiled default.metallib in the resource bundle; "
            .data(using: .utf8)!)
        FileHandle.standardError.write(
            "compiling the shipped ImageShaders.metal at first use (install the Metal toolchain "
            .data(using: .utf8)!)
        FileHandle.standardError.write(
            "with `xcodebuild -downloadComponent MetalToolchain` to package a compiled library)\n"
            .data(using: .utf8)!)
        return try? device.makeLibrary(source: source, options: nil)
    }
}

/// Anchor for `Bundle(for:)`: the bundle that contains this module's code.
private final class BundleFinder {}
