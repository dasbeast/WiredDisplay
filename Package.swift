// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "WiredDisplayCore",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .library(
            name: "WiredDisplayCore",
            targets: ["WiredDisplayCore"]
        ),
    ],
    targets: [
        .target(
            name: "WiredDisplayCore",
            path: "Shared/Protocol",
            sources: [
                "AudioFrameTypes.swift",
                "FrameMetadata.swift",
                "NetworkDiagnostics.swift",
                "NetworkProtocol.swift",
                "VideoFrameTypes.swift",
                "VideoPacket.swift",
            ]
        ),
        .testTarget(
            name: "WiredDisplayCoreTests",
            dependencies: ["WiredDisplayCore"],
            path: "Tests/WiredDisplayCoreTests"
        ),
    ]
)
