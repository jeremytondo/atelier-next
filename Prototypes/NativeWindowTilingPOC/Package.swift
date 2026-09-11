// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "NativeWindowTilingPOC",
    platforms: [
        .macOS(.v15),
    ],
    products: [
        .executable(name: "native-window-tiling-poc", targets: ["NativeWindowTilingPOC"]),
        .executable(name: "desktop-groups-prototype", targets: ["DesktopGroupsPrototype"]),
    ],
    targets: [
        .target(
            name: "WindowManagementBridge",
            publicHeadersPath: "include",
            linkerSettings: [
                .linkedFramework("Foundation"),
            ]
        ),
        .target(name: "NativeMenuDispatch"),
        .target(name: "DesktopGroupsCore"),
        .executableTarget(
            name: "NativeWindowTilingPOC",
            dependencies: ["WindowManagementBridge", "NativeMenuDispatch"]
        ),
        .executableTarget(
            name: "DesktopGroupsPrototype",
            dependencies: ["DesktopGroupsCore", "NativeMenuDispatch"]
        ),
        .testTarget(
            name: "DesktopGroupsCoreTests",
            dependencies: ["DesktopGroupsCore"]
        ),
    ]
)
