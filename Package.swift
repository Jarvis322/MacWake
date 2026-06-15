// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MacWake",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "MacWake",
            dependencies: [],
            path: "Sources"
        )
    ]
)
