// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "OpenMinisMac",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "OpenMinisMac",
            path: "Sources/OpenMinisMac"
        )
    ]
)
