// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "DiskSpace",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "DiskSpace", targets: ["DiskSpace"])
    ],
    targets: [
        .executableTarget(
            name: "DiskSpace",
            path: "DiskSpace",
            exclude: ["DiskSpace.entitlements"]
        )
    ]
)
