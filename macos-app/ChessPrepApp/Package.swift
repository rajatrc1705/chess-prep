// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ChessPrepApp",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "ChessPrepApp", targets: ["ChessPrepApp"]),
    ],
    targets: [
        .executableTarget(
            name: "ChessPrepApp"
        ),
        .testTarget(
            name: "ChessPrepAppTests",
            dependencies: ["ChessPrepApp"]
        ),
    ]
)
