// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "FolioCore",
    defaultLocalization: "zh-Hans",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "FolioCore", targets: ["FolioCore"]),
        .library(name: "FolioMetadata", targets: ["FolioMetadata"]),
        .library(name: "FolioCitation", targets: ["FolioCitation"]),
        .library(name: "FolioZotero", targets: ["FolioZotero"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.11.1"),
    ],
    targets: [
        .target(name: "FolioCore", dependencies: [.product(name: "GRDB", package: "GRDB.swift")]),
        .target(name: "FolioMetadata", dependencies: ["FolioCore"]),
        .target(name: "FolioCitation", dependencies: ["FolioCore"], resources: [.copy("Resources")]),
        .target(name: "FolioZotero", dependencies: ["FolioCore", .product(name: "GRDB", package: "GRDB.swift")]),
        .testTarget(name: "FolioCoreTests", dependencies: ["FolioCore"]),
        .testTarget(name: "FolioMetadataTests", dependencies: ["FolioMetadata"], resources: [.copy("Fixtures")]),
        .testTarget(name: "FolioCitationTests", dependencies: ["FolioCitation"]),
        .testTarget(name: "FolioZoteroTests", dependencies: ["FolioZotero"]),
    ]
)
