// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Toranja",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Toranja", path: "Sources/Toranja")
    ]
)
