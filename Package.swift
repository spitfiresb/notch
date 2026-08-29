// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Notch",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Notch",
            path: "Sources/Notch",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
        // Offscreen render harness: draws the notch in each dock / state to PNGs
        // in `.build/renders` so layout can be checked without a screen.
        .testTarget(
            name: "NotchRenderTests",
            dependencies: ["Notch"],
            path: "Tests/NotchRenderTests",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
