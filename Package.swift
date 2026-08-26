// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ScreamingKoda",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "KodaCore", targets: ["KodaCore"]),
        .library(name: "KodaRender", targets: ["KodaRender"]),
        .executable(name: "koda", targets: ["koda"]),
        .executable(name: "KodaApp", targets: ["KodaApp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "6.29.3"),
        .package(url: "https://github.com/scinfu/SwiftSoup.git", from: "2.13.7"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
        // Required: XCTest and Testing are absent from the Command Line Tools SDK.
        //
        // Every @Test emits "'Test' is deprecated: Swift Testing is now included in the
        // Swift 6 toolchain. Remove your 'swift-testing' package dependency". Under Xcode
        // that is true. Under Command Line Tools alone — which is what this project builds
        // with — it is not: removing this dependency fails with "missing required module
        // '_TestingInternals'". Verified 2026-08-21. The warnings are the cost of building
        // without Xcode; do not act on them.
        .package(url: "https://github.com/swiftlang/swift-testing.git", from: "0.10.0"),
    ],
    targets: [
        .target(
            name: "KodaCore",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                "SwiftSoup",
            ]
        ),
        .executableTarget(
            name: "koda",
            dependencies: [
                "KodaCore",
                "KodaRender",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(
            name: "KodaCoreTests",
            dependencies: [
                "KodaCore",
                .product(name: "Testing", package: "swift-testing"),
            ],
            resources: [.copy("Fixtures")]
        ),
        // WebKit lives here, not in KodaCore: rendering needs a UI framework and
        // a main-thread run loop, and KodaCore's defining property is that it
        // builds and tests headless. KodaCore declares the protocol; this
        // implements it; the app and CLI inject it.
        .target(
            name: "KodaRender",
            dependencies: ["KodaCore"]
        ),
        .testTarget(
            name: "KodaRenderTests",
            dependencies: [
                "KodaRender",
                .product(name: "Testing", package: "swift-testing"),
            ]
        ),
        .target(
            name: "KodaUI",
            dependencies: ["KodaCore"]
        ),
        .executableTarget(
            name: "KodaApp",
            dependencies: ["KodaUI", "KodaRender"]
        ),
        .testTarget(
            name: "KodaUITests",
            dependencies: [
                "KodaUI",
                .product(name: "Testing", package: "swift-testing"),
            ]
        ),
    ]
)
