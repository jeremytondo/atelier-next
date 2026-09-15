// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "AtelierProviders",
  // SDK floor for Xcode 26 toolchains. Atelier requires macOS 27 at runtime; the
  // Spaces provider checks the running version before creating Desktops.
  platforms: [.macOS(.v26)],
  products: [
    .executable(name: "atelier-providers", targets: ["AtelierProviders"])
  ],
  targets: [
    // Pure Space topology logic with no macOS dependencies.
    .target(name: "SpaceControlCore"),
    .testTarget(name: "SpaceControlCoreTests", dependencies: ["SpaceControlCore"]),
    // Objective-C wrapper around the private SkyLight bridge operation ABI.
    .target(name: "DesktopBridge"),
    // Every provider, the pipe protocol, and the private-API access they share.
    .target(name: "Providers", dependencies: ["SpaceControlCore", "DesktopBridge"]),
    .testTarget(name: "ProvidersTests", dependencies: ["Providers"]),
    .executableTarget(name: "AtelierProviders", dependencies: ["Providers"]),
  ],
  swiftLanguageModes: [.v5]
)
