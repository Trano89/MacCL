// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MacCL",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "MacCL",
            path: "Sources/MacCL",
            swiftSettings: [
                // Keep Swift 5 concurrency semantics: this app drives a subprocess
                // with plenty of callback plumbing; strict Swift 6 concurrency would
                // add a lot of friction for no real safety gain in a single-window app.
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
