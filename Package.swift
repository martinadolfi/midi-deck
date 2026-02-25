// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "MidiDeck",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "MidiDeck",
            path: "Sources/MidiDeck",
            linkerSettings: [
                .linkedFramework("CoreMIDI"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("AudioToolbox"),
            ]
        )
    ]
)
