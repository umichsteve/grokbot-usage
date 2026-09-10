// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "GrokBotUsage",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "GrokBotUsage", targets: ["GrokBotUsage"])
    ],
    targets: [
        .executableTarget(
            name: "GrokBotUsage",
            path: "Sources/GrokBotUsage",
            exclude: [
                "Info.plist"
            ],
            resources: [
                .process("Resources")
            ]
        )
    ]
)
