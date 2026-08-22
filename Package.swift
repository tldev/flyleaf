// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Flyleaf",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Flyleaf",
            path: "Sources/Flyleaf"
        ),
        .testTarget(
            name: "FlyleafTests",
            dependencies: ["Flyleaf"],
            path: "Tests/FlyleafTests"
        )
    ]
)
