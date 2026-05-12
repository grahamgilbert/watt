// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "WattHelperProtocol",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "WattHelperProtocol", targets: ["WattHelperProtocol"])
    ],
    targets: [
        .target(
            name: "WattHelperProtocol",
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
