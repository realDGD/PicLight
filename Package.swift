// swift-tools-version: 6.0
import PackageDescription

// AppKit decides whether the app uses the macOS 26 design language — Liquid Glass on the system
// controls, which is what a slider, a popup button and an outline view are — from the SDK version
// recorded in the executable's `LC_BUILD_VERSION`. SwiftPM links with
// `--target=arm64-apple-macos14.0`, and clang then records the *deployment target* as the build SDK:
// measured on this package, the binary said `minos 14.0, sdk 14.0`, and on macOS 27 every system
// control stayed in the pre-26 compatibility look while only the explicitly created
// `NSGlassEffectView` surfaces (the dock, the drawer) showed glass. Measured with the same source
// and OS, naming the real platform version changes the controls' own metrics — `sdk 14.0` gives an
// `NSSlider` a 24 pt knob and a 28 pt fitting height, `sdk 26.0` gives it 20 pt and 16 pt.
//
// The deployment target stays 14.0: only the *build* SDK is named, so the app still launches on
// macOS 14. 26.0 is the minimum that enables the design and is never an over-claim:
// `MaterialHostView` uses `NSGlassEffectView`, which does not compile against an older SDK, so the
// build already requires a macOS 26 or later SDK, supplied by Xcode or a matching
// Command Line Tools package. Resource updates use a separate compiler workflow.
//
// Applied to the test target as well, so the tests measure the control metrics the shipped app uses.
// SwiftPM also propagates the executable target's unsafe flags to it, so this line is explicit
// rather than load-bearing — but it is the one that keeps `swift test` honest if that changes.
let liquidGlassDesignLinkerSettings: [LinkerSetting] = [
    .unsafeFlags(["-Xlinker", "-platform_version", "-Xlinker", "macos",
                  "-Xlinker", "14.0", "-Xlinker", "26.0"]),
]

let package = Package(
    name: "PicViewMac",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "PicViewMac", targets: ["PicViewMac"])],
    targets: [
        // Row-streaming PNG decoder for native-detail tiles. ImageIO has no region
        // decode (measured: a 512×512 crop of a 12000×9000 PNG costs a full decode and
        // its 0.43 GiB peak), so native pixels for part of a huge image can only come
        // from inflating the stream ourselves and keeping the rows the viewer needs.
        .target(
            name: "PicPNGStream",
            path: "PicPNGStream",
            publicHeadersPath: "include",
            linkerSettings: [.linkedLibrary("z")]
        ),
        .executableTarget(
            name: "PicViewMac",
            dependencies: ["PicPNGStream"],
            path: "PicViewMac",
            // Shipped as a *copied source file*, not `.process`ed: `.process` runs the
            // Xcode Metal toolchain at build time, and a missing toolchain then fails
            // the whole build (observed here: "cannot execute tool 'metal' due to
            // missing Metal Toolchain"). scripts/build-release.sh validates and copies
            // the precompiled default.metallib from Resources/Precompiled; source or
            // target changes require scripts/precompile-resources.py update. The copied
            // source is the development fallback. Nothing on the runtime path may use
            // the generated `Bundle.module` accessor — it traps when the bundle is
            // missing (see MetalLibraryLocator).
            resources: [.copy("Shaders/ImageShaders.metal")],
            linkerSettings: liquidGlassDesignLinkerSettings
        ),
        .testTarget(
            name: "PicViewMacTests",
            dependencies: ["PicViewMac", "PicPNGStream"],
            path: "PicViewMacTests",
            resources: [.copy("Fixtures")],
            linkerSettings: liquidGlassDesignLinkerSettings
        ),
    ]
)
