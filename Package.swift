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
        .target(
            name: "EngineSFSpeech",
            dependencies: ["TranscriptionCore"],
            path: "Sources/EngineSFSpeech"
        ),
        .executableTarget(
            name: "NaughtScribe",
            dependencies: ["TranscriptionCore", "EngineSpeechTranscriber", "EngineSFSpeech"],
            path: "Sources/NaughtScribe"
        ),
        .testTarget(
            name: "NaughtScribeTests",
            dependencies: ["NaughtScribe", "TranscriptionCore", "EngineSFSpeech"],
            path: "Tests/NaughtScribeTests"
        )
    ]
)
