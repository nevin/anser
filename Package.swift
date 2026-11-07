// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Anser",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Anser", targets: ["Anser"]),
        .library(name: "AnserCore", targets: ["AnserCore"]),
        // Keeps shells running while Anser quits, restarts or updates.
        .executable(name: "anser-session", targets: ["AnserSession"]),
    ],
    dependencies: [
        // Automatic updates (Help → Check for Updates).
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0"),
    ],
    targets: [
        // libghostty, built by scripts/build-ghostty.sh
        .binaryTarget(name: "GhosttyKit", path: "vendor/GhosttyKit.xcframework"),

        // Pure Swift logic: history, completion, parsing, config. No UI, no terminal.
        .target(
            name: "AnserCore",
            resources: [.copy("Specs")],
            // Swift 6: the compiler checks for data races in the core logic.
            swiftSettings: [.swiftLanguageMode(.v6)],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),

        // Starts a shell on a new pseudo-terminal (forkpty needs C).
        .target(name: "AnserPTY"),
        .executableTarget(
            name: "AnserSession",
            dependencies: ["AnserCore", "AnserPTY"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),

        // The AppKit app.
        .executableTarget(
            name: "Anser",
            dependencies: ["AnserCore", "GhosttyKit", .product(name: "Sparkle", package: "Sparkle")],
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .linkedLibrary("c++"),
                .linkedLibrary("z"),
                .linkedFramework("AppKit"),
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("CoreText"),
                .linkedFramework("Carbon"),
                .linkedFramework("IOKit"),
                .linkedFramework("UniformTypeIdentifiers"),
            ]
        ),

        .testTarget(name: "AnserCoreTests", dependencies: ["AnserCore"], swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
