// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Anser",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Anser", targets: ["Anser"]),
        .library(name: "AnserCore", targets: ["AnserCore"]),
    ],
    targets: [
        // libghostty, built by scripts/build-ghostty.sh
        .binaryTarget(name: "GhosttyKit", path: "vendor/GhosttyKit.xcframework"),

        // Pure Swift logic: history, completion, parsing, config. No UI, no terminal.
        .target(
            name: "AnserCore",
            resources: [.copy("Specs")],
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),

        // The AppKit app.
        .executableTarget(
            name: "Anser",
            dependencies: ["AnserCore", "GhosttyKit"],
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
