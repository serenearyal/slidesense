// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SlideSense",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "SlideSense", targets: ["SlideSense"])
    ],
    targets: [
        .target(
            name: "SlideSenseCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "SlideSense",
            dependencies: ["SlideSenseCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "SlideSenseCoreTests",
            dependencies: ["SlideSenseCore"],
            exclude: ["Fixtures"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
