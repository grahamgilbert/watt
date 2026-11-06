// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "Watt", platforms: [.macOS(.v14)], targets: [
    .binaryTarget(name: "Sparkle", url: "https://github.com/sparkle-project/Sparkle/releases/download/2.10.1/Sparkle-for-Swift-Package-Manager.zip", checksum: "4c2e48a3e50ebcc2c88a58a4c7264a1a99c3c31857ce754357afb9cdb323022a"),
    .target(name: "CTelemetry", linkerSettings: [.linkedLibrary("proc"), .linkedLibrary("sqlite3")]),
    .executableTarget(name: "Watt", dependencies: ["CTelemetry", "Sparkle"], swiftSettings: [.swiftLanguageMode(.v5)], linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]),
    .testTarget(name: "WattTests", dependencies: ["Watt"])
])
