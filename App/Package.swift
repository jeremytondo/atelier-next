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
    .target(name: "AtelierShellCore", path: "Hammerspoon/ShellCore"),
    .testTarget(name: "AtelierShellCoreTests", dependencies: ["AtelierShellCore"]),
    .target(name: "QuickAppSupport"),
    .target(name: "SpaceControlCore"),
    .target(name: "DesktopBridge"),
    .target(
      name: "AtelierEngine",
      dependencies: ["QuickAppSupport", "SpaceControlCore", "DesktopBridge"]),
    .executableTarget(name: "AtelierHelper", dependencies: ["AtelierEngine"]),
    .executableTarget(name: "AtelierTools"),
    .testTarget(name: "AtelierEngineTests", dependencies: ["AtelierEngine"]),
    .testTarget(name: "QuickAppSupportTests", dependencies: ["QuickAppSupport"]),
    .testTarget(name: "SpaceControlCoreTests", dependencies: ["SpaceControlCore"]),
  ],
  swiftLanguageModes: [.v5]
)
