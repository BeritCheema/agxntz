// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "agxntz",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "agxntz",
            path: "Sources/agxntz",
            linkerSettings: [.linkedLibrary("sqlite3")]
        )
    ]
)
