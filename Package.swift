// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "AnyConnectClient",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "VPNCore", targets: ["VPNCore"]),
        .library(name: "OpenConnectRuntime", targets: ["OpenConnectRuntime"]),
        .library(name: "AnyConnectClientSupport", targets: ["AnyConnectClientSupport"]),
        .executable(name: "AnyConnectClientApp", targets: ["AnyConnectClientApp"]),
        .executable(name: "AnyConnectCredentialTool", targets: ["AnyConnectCredentialTool"])
    ],
    targets: [
        .target(
            name: "VPNCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "OpenConnectRuntime",
            dependencies: ["VPNCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "AnyConnectClientSupport",
            dependencies: ["VPNCore"],
            swiftSettings: [.swiftLanguageMode(.v6)],
            linkerSettings: [
                .linkedFramework("LocalAuthentication"),
                .linkedFramework("Security")
            ]
        ),
        .executableTarget(
            name: "AnyConnectClientApp",
            dependencies: ["AnyConnectClientSupport", "OpenConnectRuntime", "VPNCore"],
            path: "Apps/AnyConnectClient",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "AnyConnectCredentialTool",
            dependencies: ["AnyConnectClientSupport", "OpenConnectRuntime"],
            path: "Tools/AnyConnectCredentialTool",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "VPNCoreTests",
            dependencies: ["VPNCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "OpenConnectRuntimeTests",
            dependencies: ["OpenConnectRuntime", "VPNCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "AnyConnectClientSupportTests",
            dependencies: ["AnyConnectClientSupport", "VPNCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
