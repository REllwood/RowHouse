// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RowHouse",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "RowHouse", targets: ["RowHouse"]),
        .executable(name: "rowhouse-mcp", targets: ["rowhouse-mcp"]),
        .library(name: "RowHouseCore", targets: ["RowHouseCore"]),
    ],
    targets: [
        .target(name: "RowHouseFormula"),
        .target(
            name: "RowHouseCore",
            dependencies: ["RowHouseFormula"]
        ),
        .executableTarget(
            name: "RowHouse",
            dependencies: ["RowHouseCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(
            name: "RowHouseMCPKit",
            dependencies: ["RowHouseCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "rowhouse-mcp",
            dependencies: ["RowHouseMCPKit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(name: "RowHouseFormulaTests", dependencies: ["RowHouseFormula"]),
        .testTarget(name: "RowHouseCoreTests", dependencies: ["RowHouseCore"]),
        .testTarget(name: "RowHouseMCPKitTests", dependencies: ["RowHouseMCPKit", "RowHouseCore"]),
    ]
)
