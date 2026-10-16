// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "NaughtScribe",
    platforms: [
        .macOS(.v26)
    ],
    targets: [
        .executableTarget(
            name: "NaughtScribe",
            path: "Sources/NaughtScribe"
        )
    ]
)
