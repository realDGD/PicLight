// swift-tools-version: 6.0
import PackageDescription

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
            // missing Metal Toolchain"). scripts/build-release.sh compiles this file
            // into default.metallib inside Contents/Resources and fails the release if
            // it cannot, so a shipped app always carries a compiled library; the copied
            // source is the development fallback. Nothing on the runtime path may use
            // the generated `Bundle.module` accessor — it traps when the bundle is
            // missing (see MetalLibraryLocator).
            resources: [.copy("Shaders/ImageShaders.metal")]
        ),
        .testTarget(
            name: "PicViewMacTests",
            dependencies: ["PicViewMac", "PicPNGStream"],
            path: "PicViewMacTests",
            resources: [.copy("Fixtures")]
        ),
    ]
)
