// swift-tools-version: 5.7
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "Channels",
    platforms: [
        .iOS(.v13),
        .macOS(.v11),
    ],
    products: [
        .library(
            name: "Channels",
            targets: ["Channels"]),
    ],
    dependencies: [
        .package(url: "https://github.com/daltoniam/Starscream", from: "4.0.4"),
        // PieRTC — programmable WebRTC over v4. Prebuilt WebRTC XCFramework for
        // Apple platforms (the classic GoogleWebRTC pod is unmaintained).
        .package(url: "https://github.com/stasel/WebRTC.git", from: "120.0.0"),
    ],
    targets: [
        .target(
            name: "Channels",
            dependencies: [
                "Starscream",
                .product(name: "WebRTC", package: "WebRTC"),
            ],
            path: "Sources"
        ),
        .testTarget(
            name: "ChannelsTests",
            dependencies: ["Channels"]),
    ]
)
