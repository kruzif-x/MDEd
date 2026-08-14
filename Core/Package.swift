// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MDEdCore",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .library(
            name: "MDEdCore",
            targets: ["MDEdCore"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-markdown.git", from: "0.8.0")
    ],
    targets: [
        .target(
            name: "MDEdCore",
            dependencies: [
                .product(name: "Markdown", package: "swift-markdown")
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .testTarget(
            name: "MDEdCoreTests",
            dependencies: ["MDEdCore"],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        )
    ]
)
