// swift-tools-version: 5.9
import PackageDescription
import Foundation

// The App Store build sets MACWAKE_APPSTORE=1 (see AppStore/build-appstore.sh). In that
// mode we drop the Sparkle and TelemetryDeck dependencies entirely, so neither library's
// code is linked into the sandboxed binary — App Store's automated scanner flags a
// third-party library's symbols whether or not they're actually called at runtime.
let isAppStore = ProcessInfo.processInfo.environment["MACWAKE_APPSTORE"] == "1"

let packageDeps: [Package.Dependency] = isAppStore ? [] : [
    .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.0.0"),
    .package(url: "https://github.com/TelemetryDeck/SwiftSDK", from: "2.0.0"),
]

let macwakeDeps: [Target.Dependency] = isAppStore
    ? ["MacWakeShared"]
    : [
        "MacWakeShared",
        .product(name: "Sparkle", package: "Sparkle"),
        .product(name: "TelemetryDeck", package: "SwiftSDK"),
      ]

let package = Package(
    name: "MacWake",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: packageDeps,
    targets: [
        .target(
            name: "MacWakeShared",
            path: "Shared"
        ),
        .executableTarget(
            name: "MacWake",
            dependencies: macwakeDeps,
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
            path: "Widget",
            // App extensions must use NSExtensionMain as their Mach-O entry point (App
            // Store validation 90898). swift build's default executable entry is _main;
            // override it for the widget appex.
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-e", "-Xlinker", "_NSExtensionMain"])
            ]
        )
    ]
)
