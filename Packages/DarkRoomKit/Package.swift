// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "DarkRoomKit",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "ImmichAPI", targets: ["ImmichAPI"]),
        .library(name: "DarkRoomCore", targets: ["DarkRoomCore"]),
    ],
    targets: [
        .target(name: "ImmichAPI"),
        .target(name: "DarkRoomCore", dependencies: ["ImmichAPI"]),
        .testTarget(name: "ImmichAPITests", dependencies: ["ImmichAPI"]),
        .testTarget(name: "DarkRoomCoreTests", dependencies: ["DarkRoomCore"]),
        .testTarget(name: "IntegrationTests", dependencies: ["ImmichAPI", "DarkRoomCore"]),
    ]
)
