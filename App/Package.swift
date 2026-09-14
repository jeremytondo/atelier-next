// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "Atelier",
  platforms: [.macOS(.v26)],
  products: [
    .library(name: "SpaceControlCore", targets: ["SpaceControlCore"]),
    .library(name: "AtelierEngine", targets: ["AtelierEngine"]),
    .executable(name: "atelier-config", targets: ["AtelierConfig"]),
    .executable(name: "atelier-engine", targets: ["AtelierHelper"]),
    .executable(name: "atelier-tools", targets: ["AtelierTools"]),
  ],
  dependencies: [
    .package(url: "https://github.com/mattt/swift-toml.git", exact: "2.0.0")
  ],
  targets: [
    .target(name: "AtelierShellCore", path: "Hammerspoon/ShellCore"),
    .testTarget(name: "AtelierShellCoreTests", dependencies: ["AtelierShellCore"]),
    .target(name: "QuickAppSupport"),
    .target(name: "SpaceControlCore"),
    .target(name: "AtelierCore", dependencies: [.product(name: "TOML", package: "swift-toml")]),
    .target(
      name: "AtelierEngine",
      dependencies: ["QuickAppSupport", "SpaceControlCore", "AtelierCore"]),
    .executableTarget(name: "AtelierHelper", dependencies: ["AtelierEngine"]),
    .executableTarget(name: "AtelierConfig", dependencies: ["AtelierCore"]),
    .executableTarget(name: "AtelierTools"),
    .testTarget(name: "AtelierCoreTests", dependencies: ["AtelierCore"]),
    .testTarget(name: "QuickAppSupportTests", dependencies: ["QuickAppSupport"]),
    .testTarget(name: "SpaceControlCoreTests", dependencies: ["SpaceControlCore"]),
  ],
  swiftLanguageModes: [.v5]
)
