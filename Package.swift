// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "agxntz",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.0"),
    ],
    targets: [
        .executableTarget(
            name: "agxntz",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/agxntz",
            linkerSettings: [.linkedLibrary("sqlite3")]
        )
    ]
)
