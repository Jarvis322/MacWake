// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MacWake",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.0.0"),
        .package(url: "https://github.com/TelemetryDeck/SwiftSDK", from: "2.0.0")
    ],
    targets: [
        .target(
            name: "MacWakeShared",
            path: "Shared"
        ),
        .executableTarget(
            name: "MacWake",
            dependencies: [
                "MacWakeShared",
                .product(name: "Sparkle", package: "Sparkle"),
                .product(name: "TelemetryDeck", package: "SwiftSDK")
            ],
            path: "Sources"
        ),
        .executableTarget(
            name: "MacWakeHelper",
            dependencies: [
                "MacWakeShared"
            ],
            path: "Helper"
        ),
        .executableTarget(
            name: "MacWakeCLI",
            dependencies: [
                "MacWakeShared"
            ],
            path: "CLI"
        ),
        .executableTarget(
            name: "MacWakeWidget",
            path: "Widget"
        )
    ]
)
