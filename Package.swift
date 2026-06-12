// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "CodexBeacon",
    platforms: [
        .macOS(.v12)
    ],
    products: [
        .executable(name: "CodexBeacon", targets: ["CodexBeacon"])
    ],
    targets: [
        .executableTarget(
            name: "CodexBeacon",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Network")
            ]
        )
    ]
)
