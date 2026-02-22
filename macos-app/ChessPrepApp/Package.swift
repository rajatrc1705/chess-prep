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
            name: "ChessPrepApp",
            exclude: [
                "Resources/IconBuild",
            ],
            resources: [
                .copy("Resources/AppIcon.icns"),
            ]
        ),
        .testTarget(
            name: "ChessPrepAppTests",
            dependencies: ["ChessPrepApp"]
        ),
    ]
)
