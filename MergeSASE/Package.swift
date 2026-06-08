// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MergeSASE",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "MergeSASE",
            path: "Sources",
            swiftSettings: [.enableUpcomingFeature("BareSlashRegexLiterals")]
        )
    ]
)
