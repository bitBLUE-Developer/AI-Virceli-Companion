// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ClaudeNativeMac",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "ClaudeNativeMac", targets: ["ClaudeNativeMac"])
    ],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.11.0")
    ],
    targets: [
        .executableTarget(
            name: "ClaudeNativeMac",
            dependencies: [
                .product(name: "SwiftTerm", package: "SwiftTerm")
            ],
            path: "Sources"
        )
    ]
)
