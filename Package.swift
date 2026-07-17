// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "FanCurve",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "FanCurveApp", targets: ["FanCurveApp"]),
        .executable(name: "FanCurveHelper", targets: ["FanCurveHelper"])
    ],
    targets: [
        .target(
            name: "StatsSMC",
            path: "Vendor/Stats/SMC",
            exclude: ["Helper", "Makefile", "main.swift"],
            sources: ["smc.swift"],
            linkerSettings: [.linkedFramework("IOKit")]
        ),
        .target(name: "FanCurveCore"),
        .executableTarget(
            name: "FanCurveApp",
            dependencies: ["FanCurveCore", "StatsSMC"]
        ),
        .executableTarget(
            name: "FanCurveHelper",
            dependencies: ["FanCurveCore", "StatsSMC"]
        ),
        .executableTarget(
            name: "FanCurveCheck",
            dependencies: ["FanCurveCore"]
        )
    ],
    swiftLanguageModes: [.v5]
)
