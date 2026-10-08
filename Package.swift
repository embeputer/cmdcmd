// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "cmdcmd",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "cmdcmd",
            path: "Sources/cmdcmd"
        )
    ]
)
