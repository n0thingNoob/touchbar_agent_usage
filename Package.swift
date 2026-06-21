// swift-tools-version: 5.7

import PackageDescription

let package = Package(
    name: "CodexQuotaBar",
    platforms: [
        .macOS(.v12)
    ],
    products: [
        .executable(name: "CodexQuotaBar", targets: ["CodexQuotaBar"])
    ],
    targets: [
        .target(
            name: "TouchBarPrivateSupport",
            path: "Sources/TouchBarPrivateSupport",
            publicHeadersPath: "."
        ),
        .executableTarget(
            name: "CodexQuotaBar",
            dependencies: ["TouchBarPrivateSupport"],
            path: "Sources/CodexQuotaBar"
        )
    ]
)
