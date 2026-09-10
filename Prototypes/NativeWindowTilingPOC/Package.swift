// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "NativeWindowTilingPOC",
    platforms: [
        .macOS(.v15),
    ],
    products: [
        .executable(name: "native-window-tiling-poc", targets: ["NativeWindowTilingPOC"]),
    ],
    targets: [
        .target(
            name: "WindowManagementBridge",
            publicHeadersPath: "include",
            linkerSettings: [
                .linkedFramework("Foundation"),
            ]
        ),
        .executableTarget(
            name: "NativeWindowTilingPOC",
            dependencies: ["WindowManagementBridge"]
        ),
    ]
)
