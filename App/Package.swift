// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "Atelier",
  // SDK floor for Xcode 26 toolchains. Atelier requires macOS 27 at launch through
  // LSMinimumSystemVersion and in the engine before creating Desktops.
  platforms: [.macOS(.v26)],
  products: [
    .executable(name: "atelier-engine", targets: ["AtelierHelper"]),
    .executable(name: "atelier-tools", targets: ["AtelierTools"]),
  ],
  targets: [
    // Pure logic shared with the menu-bar app shell.
    .target(name: "AtelierShellCore", path: "Hammerspoon/ShellCore"),
    .testTarget(name: "AtelierShellCoreTests", dependencies: ["AtelierShellCore"]),
    // Pure Space topology logic with no macOS dependencies.
    .target(name: "SpaceControlCore"),
    .testTarget(name: "SpaceControlCoreTests", dependencies: ["SpaceControlCore"]),
    // Objective-C wrapper around the private SkyLight bridge operation ABI.
    .target(name: "DesktopBridge"),
    // Everything the native helper process does: protocol, Spaces, Mission
    // Control, Quick Apps, and the private-API access they share.
    .target(name: "AtelierEngine", dependencies: ["SpaceControlCore", "DesktopBridge"]),
    .testTarget(name: "AtelierEngineTests", dependencies: ["AtelierEngine"]),
    .executableTarget(name: "AtelierHelper", dependencies: ["AtelierEngine"]),
    .executableTarget(name: "AtelierTools"),
  ],
  swiftLanguageModes: [.v5]
)
