import XCTest
import MachO
@testable import PicViewMac

/// The app must be *linked* as built against the macOS 26 SDK, or AppKit never leaves the pre-26
/// compatibility look: the toolbar's size slider, the sort popup button and the folder outline view
/// all render with the old design, no matter how new the running OS is. Only the surfaces the app
/// creates itself (`NSGlassEffectView`, in `MaterialHostView`) show glass — which is exactly the
/// "the dock is glass but the slider is not" report this guards against.
///
/// AppKit reads the SDK version from the executable's `LC_BUILD_VERSION` load command. SwiftPM links
/// with `--target=arm64-apple-macos14.0`, and clang then records the *deployment target* as the build
/// SDK, so without the setting in `Package.swift` this reads 14. Measured with the same source and
/// OS: `sdk 14.0` gives an `NSSlider` a 24 pt knob and a 28 pt fitting height, `sdk 26.0` gives it
/// 20 pt and 16 pt — the design language really does follow this number.
///
/// The bundle is read from disk rather than from `_dyld_get_image_header(0)`: tests run inside the
/// system's `xctest` tool, whose own image is built with a current SDK, so asking the *running* image
/// answers a question about the runner instead of about the code under test.
@MainActor
final class LiquidGlassDesignTests: XCTestCase {

    /// The `minos` and `sdk` fields of the Mach-O's `LC_BUILD_VERSION`, as `major.minor`.
    private func buildVersion(of executable: URL) throws -> (minos: String, sdk: String) {
        let data = try Data(contentsOf: executable)
        let parsed: (String, String)? = data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return nil }
            let magic = base.load(as: UInt32.self)
            guard magic == UInt32(MH_MAGIC_64) || magic == UInt32(MH_MAGIC) else { return nil }
            let is64 = magic == UInt32(MH_MAGIC_64)
            let headerSize = is64 ? MemoryLayout<mach_header_64>.size
                                  : MemoryLayout<mach_header>.size
            let commandCount = Int(base.load(fromByteOffset: 16, as: UInt32.self))
            var cursor = base.advanced(by: headerSize)
            for _ in 0..<commandCount {
                let command = cursor.load(fromByteOffset: 0, as: UInt32.self)
                let size = Int(cursor.load(fromByteOffset: 4, as: UInt32.self))
                guard size > 0 else { return nil }
                if command == UInt32(LC_BUILD_VERSION) {
                    // build_version_command: cmd, cmdsize, platform, minos, sdk, ntools.
                    func text(_ value: UInt32) -> String {
                        "\((value >> 16) & 0xffff).\((value >> 8) & 0xff)"
                    }
                    return (text(cursor.load(fromByteOffset: 12, as: UInt32.self)),
                            text(cursor.load(fromByteOffset: 16, as: UInt32.self)))
                }
                cursor = cursor.advanced(by: size)
            }
            return nil
        }
        return try XCTUnwrap(parsed, "the executable must carry LC_BUILD_VERSION")
    }

    private func testBundleExecutable() throws -> URL {
        let bundle = Bundle(for: LiquidGlassDesignTests.self)
        return try XCTUnwrap(bundle.executableURL,
                             "the test bundle must have an executable to inspect")
    }

    /// The design-language opt-in. Fails if `Package.swift`'s linker setting is dropped, or if a
    /// build tool starts recording the deployment target as the SDK again.
    func testTheBinaryIsLinkedAgainstTheMacOS26SDKOrLater() throws {
        let version = try buildVersion(of: try testBundleExecutable())
        let major = Int(version.sdk.split(separator: ".").first ?? "") ?? 0
        XCTAssertGreaterThanOrEqual(
            major, 26,
            "the binary records build SDK \(version.sdk); AppKit keeps system controls in the "
            + "pre-26 compatibility look below 26, so the toolbar slider gets no Liquid Glass")
    }

    /// The reason the SDK version cannot simply be raised: the app still ships for macOS 14.
    func testTheDeploymentTargetStaysAtMacOS14() throws {
        let version = try buildVersion(of: try testBundleExecutable())
        XCTAssertEqual(version.minos, "14.0",
                       "the deployment target must stay 14.0; only the build SDK is named as 26")
    }
}
