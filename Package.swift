// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PicViewMac",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "PicViewMac", targets: ["PicViewMac"])],
    targets: [
        .executableTarget(
            name: "PicViewMac",
            path: "PicViewMac"
        ),
        .testTarget(
            name: "PicViewMacTests",
            dependencies: ["PicViewMac"],
            path: "PicViewMacTests",
            resources: [.copy("Fixtures")]
        ),
    ]
)
