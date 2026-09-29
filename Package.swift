// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Elstar",
    platforms: [.iOS(.v18), .macOS(.v14)],
    products: [
        .library(name: "Elstar", targets: ["Elstar"]),
    ],
    targets: [
        .target(
            name: "Elstar",
            path: "Sources/Elstar",
            swiftSettings: [.define("DEBUG", .when(configuration: .debug))]
        ),
        .testTarget(
            name: "ElstarTests",
            dependencies: ["Elstar"],
            path: "Tests/ElstarTests",
            swiftSettings: [.define("DEBUG", .when(configuration: .debug))]
        ),
    ]
)
