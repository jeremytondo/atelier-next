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
        .executable(name: "space-control-prototype", targets: ["SpaceControlPrototype"]),
        .executable(name: "scratchpad-prototype", targets: ["ScratchpadPrototype"]),
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
        .target(name: "SpaceControlCore"),
        .executableTarget(
            name: "NativeWindowTilingPOC",
            dependencies: ["WindowManagementBridge", "NativeMenuDispatch"]
        ),
        .executableTarget(
            name: "DesktopGroupsPrototype",
            dependencies: ["DesktopGroupsCore", "NativeMenuDispatch"]
        ),
        .executableTarget(
            name: "SpaceControlPrototype",
            dependencies: ["SpaceControlCore"]
        ),
        .executableTarget(
            name: "ScratchpadPrototype",
            dependencies: ["NativeMenuDispatch"]
        ),
        .testTarget(
            name: "DesktopGroupsCoreTests",
            dependencies: ["DesktopGroupsCore"]
        ),
        .testTarget(
            name: "SpaceControlCoreTests",
            dependencies: ["SpaceControlCore"]
        ),
    ]
)
