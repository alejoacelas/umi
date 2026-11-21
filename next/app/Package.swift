// swift-tools-version:5.9
import PackageDescription

// Built by build.sh, which puts GhosttyKit.xcframework in vendor/ and wraps the binary in UmiNext.app.
let package = Package(
    name: "UmiNext",
    platforms: [.macOS(.v14)],
    targets: [
        .binaryTarget(name: "GhosttyKit", path: "vendor/GhosttyKit.xcframework"),
        .executableTarget(
            name: "UmiNext",
            dependencies: ["GhosttyKit"],
            path: "Sources/UmiNext",
            exclude: ["Ghostty/README.md"],
            linkerSettings: [
                .linkedLibrary("c++"),
                .linkedFramework("AppKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("CoreText"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("Metal"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("IOSurface"),
                .linkedFramework("WebKit"),
                .linkedFramework("UniformTypeIdentifiers"),
            ]
        ),
    ]
)
