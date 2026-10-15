// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "FolioCore",
    defaultLocalization: "zh-Hans",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "FolioCore", targets: ["FolioCore"]),
        .library(name: "FolioMetadata", targets: ["FolioMetadata"]),
        .library(name: "FolioCitation", targets: ["FolioCitation"]),
        .library(name: "FolioZotero", targets: ["FolioZotero"]),
        .executable(name: "folio-seed", targets: ["FolioSeed"]),
        .library(name: "FolioTranslate", targets: ["FolioTranslate"]),
        .executable(name: "folio-apple-translate", targets: ["FolioAppleTranslate"]),
        .library(name: "FolioAgent", targets: ["FolioAgent"]),
        .executable(name: "folio-cli", targets: ["FolioCLI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.11.1"),
    ],
    targets: [
        .target(name: "FolioCore", dependencies: [.product(name: "GRDB", package: "GRDB.swift")], resources: [.process("Resources")]),
        .target(name: "FolioMetadata", dependencies: ["FolioCore"]),
        .target(name: "FolioCitation", dependencies: ["FolioCore"], resources: [.copy("Resources"), .process("Localization")]),
        .target(name: "FolioZotero", dependencies: ["FolioCore", .product(name: "GRDB", package: "GRDB.swift")]),
        // Developer tool: seeds demo / performance libraries for screenshots and measurements.
        .executableTarget(name: "FolioSeed", dependencies: ["FolioCore"]),
        .testTarget(name: "FolioCoreTests", dependencies: ["FolioCore"]),
        .testTarget(name: "FolioMetadataTests", dependencies: ["FolioMetadata"], resources: [.copy("Fixtures")]),
        .testTarget(name: "FolioCitationTests", dependencies: ["FolioCitation"]),
        .testTarget(name: "FolioZoteroTests", dependencies: ["FolioZotero"]),
        // Layout-preserving PDF translation (pdf2zh_next / BabelDOC engine management).
        .target(name: "FolioTranslate", resources: [.process("Resources")]),
        // `--clitranslator` helper that translates stdin with Apple's offline Translation framework.
        .executableTarget(name: "FolioAppleTranslate", dependencies: ["FolioTranslate"]),
        .testTarget(name: "FolioTranslateTests", dependencies: ["FolioTranslate"], resources: [.copy("Fixtures")]),
        // AI integration (MCP server, folio-cli, skill, agent configuration).
        .target(name: "FolioAgent", dependencies: ["FolioCore", "FolioMetadata", "FolioCitation", "FolioTranslate"], resources: [.process("Resources")]),
        .executableTarget(name: "FolioCLI", dependencies: ["FolioAgent"]),
        .testTarget(name: "FolioAgentTests", dependencies: ["FolioAgent"]),
    ]
)
