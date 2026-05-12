// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "WattCore",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "WattCore", targets: [
            "WattModels",
            "WattSampling",
            "WattAnalysis",
            "WattAI",
            "WattUI"
        ])
    ],
    dependencies: [
        // gonzalezreal/textual is the successor to swift-markdown-ui. No tagged
        // releases yet, pin to a specific commit on main.
        .package(
            url: "https://github.com/gonzalezreal/textual",
            revision: "5b06b811c0f5313b6b84bbef98c635a630638c38"
        )
    ],
    targets: [
        .target(
            name: "WattSamplingC",
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("include")
            ]
        ),
        .target(
            name: "WattModels",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "WattSampling",
            dependencies: [
                "WattModels",
                "WattAnalysis",
                "WattSamplingC"
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .define("WATT_USE_PRIVATE_HID")
            ],
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("CoreFoundation")
            ]
        ),
        .target(
            name: "WattAnalysis",
            dependencies: ["WattModels"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "WattAI",
            dependencies: ["WattModels", "WattAnalysis"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "WattUI",
            dependencies: [
                "WattModels",
                "WattAnalysis",
                "WattAI",
                "WattSampling",
                .product(name: "Textual", package: "textual")
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "WattCoreTests",
            dependencies: ["WattModels", "WattAnalysis", "WattAI", "WattSampling", "WattUI"],
            resources: [.process("Snapshots"), .process("Fixtures")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
