// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "PS2HDDManager",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "PS2HDDManager",
            path: "Sources/PS2HDDManager"
        )
    ]
)
