// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ScreamingKoda",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "KodaCore", targets: ["KodaCore"]),
        .executable(name: "koda", targets: ["koda"]),
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
        .executableTarget(
            name: "koda",
            dependencies: [
                "KodaCore",
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
    ]
)
