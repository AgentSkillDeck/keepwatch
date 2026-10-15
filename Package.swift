// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Keepwatch",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Keepwatch", targets: ["Keepwatch"]),
        .executable(name: "keepwatch-cli", targets: ["KeepwatchCLI"]),
        .library(name: "KeepwatchCore", targets: ["KeepwatchCore"]),
    ],
    targets: [
        .target(
            name: "KeepwatchCore",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("CoreMediaIO"),
            ]
        ),
        .executableTarget(
            name: "Keepwatch",
            dependencies: ["KeepwatchCore"]
        ),
        .executableTarget(
            name: "KeepwatchCLI",
            dependencies: ["KeepwatchCore"]
        ),
        .testTarget(
            name: "KeepwatchCoreTests",
            dependencies: ["KeepwatchCore"]
        ),
    ],
    swiftLanguageModes: [.v5]
)
