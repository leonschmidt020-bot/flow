// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Flow",
    platforms: [.macOS("26.0")],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.17.4"),
    ],
    targets: [
        .executableTarget(
            name: "Flow",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")],
            path: "Sources/Flow",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
