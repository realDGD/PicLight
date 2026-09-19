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
    /// file*, not a string literal in code, and only once per process — the cache below is what
    /// makes that true: without it every canvas paid for the Metal front end again (measured: one
    /// full test run compiled the shader 241 times, which stretched the run from 466 s to 858 s
    /// and starved the tile tests' upload deadlines into 30–80 s timeouts).
    public static func defaultLibrary(device: MTLDevice) -> MTLLibrary? {
        let key = ObjectIdentifier(device)
        libraryLock.lock()
        let cached = cachedLibraries[key]
        libraryLock.unlock()
        if let cached { return cached }

        guard let bundle = resourceBundle() else { return nil }
        let library: MTLLibrary?
        if let compiled = try? device.makeDefaultLibrary(bundle: bundle) {
            library = compiled
        } else if let source = shaderSource(bundle: bundle) {
            FileHandle.standardError.write(
                "MetalLibraryLocator: no compiled default.metallib in the resource bundle; "
                .data(using: .utf8)!)
            FileHandle.standardError.write(
                "compiling the shipped ImageShaders.metal at first use (install the Metal toolchain "
                .data(using: .utf8)!)
            FileHandle.standardError.write(
                "with `xcodebuild -downloadComponent MetalToolchain` to package a compiled library)\n"
                .data(using: .utf8)!)
            library = try? device.makeLibrary(source: source, options: nil)
        } else {
            library = nil
        }

        if let library {
            libraryLock.lock()
            cachedLibraries[key] = library
            libraryLock.unlock()
        }
        return library
    }

    /// One library per device: a `MTLLibrary` belongs to the device that made it, so two GPUs
    /// must never share one. Guarded because `defaultLibrary` is called from wherever a canvas is
    /// built, and the compile itself runs outside the lock — a rare double compile is harmless,
    /// a multi-second critical section would not be.
    private static let libraryLock = NSLock()
    nonisolated(unsafe) private static var cachedLibraries: [ObjectIdentifier: MTLLibrary] = [:]
}

/// Anchor for `Bundle(for:)`: the bundle that contains this module's code.
private final class BundleFinder {}
