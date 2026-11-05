// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "Watt", platforms: [.macOS(.v14)], targets: [
    .target(name: "CTelemetry", linkerSettings: [.linkedLibrary("proc"), .linkedLibrary("sqlite3")]),
    .executableTarget(name: "Watt", dependencies: ["CTelemetry"], swiftSettings: [.swiftLanguageMode(.v5)]),
    .testTarget(name: "WattTests", dependencies: ["Watt"])
])
