// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "NotchPal",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "NotchPal", targets: ["NotchPal"]),
        .executable(name: "notchpal-report", targets: ["NotchPalReport"]),
        .library(name: "NotchPalCore", targets: ["NotchPalCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/MrKai77/DynamicNotchKit", from: "1.1.0"),
    ],
    targets: [
        // Pure-Foundation core, shared by the app and the hook reporter.
        // Deliberately free of SwiftUI/AppKit so `notchpal-report` stays tiny and fast to launch.
        .target(name: "NotchPalCore"),
        .executableTarget(name: "NotchPalReport", dependencies: ["NotchPalCore"]),
        .executableTarget(
            name: "NotchPal",
            dependencies: [
                "NotchPalCore",
                .product(name: "DynamicNotchKit", package: "DynamicNotchKit"),
            ]
        ),
        .testTarget(name: "NotchPalCoreTests", dependencies: ["NotchPalCore"]),
    ]
)
