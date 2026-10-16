// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "NaughtScribe",
    platforms: [
        .macOS(.v26)
    ],
    targets: [
        .target(
            name: "TranscriptionCore",
            path: "Sources/TranscriptionCore"
        ),
        .target(
            name: "EngineSpeechTranscriber",
            dependencies: ["TranscriptionCore"],
            path: "Sources/EngineSpeechTranscriber"
        ),
        .executableTarget(
            name: "NaughtScribe",
            dependencies: ["TranscriptionCore", "EngineSpeechTranscriber"],
            path: "Sources/NaughtScribe"
        ),
        .testTarget(
            name: "NaughtScribeTests",
            dependencies: ["NaughtScribe", "TranscriptionCore"],
            path: "Tests/NaughtScribeTests"
        )
    ]
)
