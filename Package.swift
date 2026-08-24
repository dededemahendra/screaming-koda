// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ScreamingKoda",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "KodaCore", targets: ["KodaCore"]),
        .library(name: "KodaUI", targets: ["KodaUI"]),
        .executable(name: "koda", targets: ["koda"]),
        .executable(name: "KodaApp", targets: ["KodaApp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "6.29.3"),
        .package(url: "https://github.com/scinfu/SwiftSoup.git", from: "2.13.7"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
        // Required: XCTest and Testing are absent from the Command Line Tools SDK.
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
        // Observable models for the app. Imports Observation but never AppKit or
        // SwiftUI, so everything that matters stays testable under Command Line
        // Tools, where there is no UI test harness.
        .target(
            name: "KodaUI",
            dependencies: ["KodaCore"]
        ),
        .executableTarget(
            name: "KodaApp",
            dependencies: ["KodaUI"]
        ),
        .executableTarget(
            name: "koda",
            dependencies: [
                "KodaCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(
            name: "KodaUITests",
            dependencies: [
                "KodaUI",
                "KodaCore",
                .product(name: "Testing", package: "swift-testing"),
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
    ]
)
