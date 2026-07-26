// swift-tools-version: 6.1

import PackageDescription

var targets: [Target] = [
    .target(
        name: "StatsSMC",
        path: "Vendor/Stats/SMC",
        exclude: ["Helper", "Makefile", "main.swift"],
        sources: ["smc.swift"],
        linkerSettings: [.linkedFramework("IOKit")]
    ),
    .target(name: "FanCurveCore"),
    .target(
        name: "FanCurveUI",
        dependencies: ["FanCurveCore"]
    ),
    .executableTarget(
        name: "FanCurveApp",
        dependencies: ["FanCurveCore", "FanCurveUI", "StatsSMC"]
    ),
    .executableTarget(
        name: "FanCurveHelper",
        dependencies: ["FanCurveCore", "StatsSMC"]
    ),
    .executableTarget(
        name: "FanCurveProbe",
        dependencies: ["FanCurveCore", "StatsSMC"]
    ),
    .executableTarget(
        name: "FanCurveCheck",
        dependencies: ["FanCurveCore"]
    )
]

#if os(macOS)
targets.append(.executableTarget(name: "FanCurveAppCheck", dependencies: ["FanCurveUI"]))
#endif

let package = Package(
    name: "FanCurve",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "FanCurveApp", targets: ["FanCurveApp"]),
        .executable(name: "FanCurveHelper", targets: ["FanCurveHelper"]),
        .executable(name: "FanCurveProbe", targets: ["FanCurveProbe"])
    ],
    targets: targets,
    swiftLanguageModes: [.v5]
)
