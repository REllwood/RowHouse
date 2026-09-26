// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RowHouse",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "RowHouse", targets: ["RowHouse"]),
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
        .testTarget(name: "RowHouseFormulaTests", dependencies: ["RowHouseFormula"]),
        .testTarget(name: "RowHouseCoreTests", dependencies: ["RowHouseCore"]),
    ]
)
