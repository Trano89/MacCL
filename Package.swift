// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ClaudeMac",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "ClaudeMac",
            path: "Sources/ClaudeMac",
            swiftSettings: [
                // Keep Swift 5 concurrency semantics: this app drives a subprocess
                // with plenty of callback plumbing; strict Swift 6 concurrency would
                // add a lot of friction for no real safety gain in a single-window app.
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
