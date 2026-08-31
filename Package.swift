// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "Melo",
    defaultLocalization: "zh-Hans",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "Melo", targets: ["Melo"]),
        .executable(name: "MeloHardwareHelper", targets: ["MeloHardwareHelper"])
    ],
    targets: [
        .target(
            name: "SMCCore",
            path: "Sources/SMCCore",
            linkerSettings: [.linkedFramework("IOKit")]
        ),
        .target(
            name: "MeloHardwareProtocol",
            path: "Sources/MeloHardwareProtocol"
        ),
        .executableTarget(
            name: "Melo",
            dependencies: [
                "MeloHardwareProtocol",
                "SMCCore"
            ],
            path: "Sources/Melo"
        ),
        .executableTarget(
            name: "MeloHardwareHelper",
            dependencies: [
                "MeloHardwareProtocol",
                "SMCCore"
            ],
            path: "Sources/MeloHardwareHelper",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("Security")
            ]
        ),
        .testTarget(
            name: "MeloTests",
            dependencies: ["Melo", "MeloHardwareProtocol", "SMCCore"],
            path: "Tests/MeloTests"
        )
    ]
)
