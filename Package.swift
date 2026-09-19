// swift-tools-version: 6.2
import PackageDescription

// Each layer knows only the one below it: `UI`, then `AtelierKit`, then
// `MacOS`. `DesktopBridge` is the one piece of Objective-C, which only `MacOS`
// uses. `Client` is what the `atelier` command and the app's server agree on,
// so the command never links the app's behavior. `App/` holds the bundle that
// links `UI` and `AtelierKit`.
let package = Package(
  name: "Atelier",
  platforms: [.macOS(.v26)],
  products: [
    .library(name: "UI", targets: ["UI"]),
    .library(name: "AtelierKit", targets: ["AtelierKit"]),
    .executable(name: "atelier", targets: ["CLI"]),
  ],
  dependencies: [
    .package(url: "https://github.com/apple/swift-argument-parser", from: "1.6.0"),
    .package(url: "https://github.com/dduan/TOMLDecoder", from: "0.4.5"),
  ],
  targets: [
    .target(name: "UI", dependencies: ["AtelierKit"]),
    .target(
      name: "AtelierKit",
      dependencies: [
        "MacOS", "Client", .product(name: "TOMLDecoder", package: "TOMLDecoder"),
      ]),
    .target(name: "MacOS", dependencies: ["DesktopBridge"]),
    .target(name: "DesktopBridge"),
    .target(name: "Client"),
    .executableTarget(
      name: "CLI",
      dependencies: [
        "Client",
        .product(name: "ArgumentParser", package: "swift-argument-parser"),
      ]),
    .testTarget(name: "AtelierKitTests", dependencies: ["AtelierKit"]),
    .testTarget(name: "UITests", dependencies: ["UI"]),
    .testTarget(name: "MacOSTests", dependencies: ["MacOS"]),
    .testTarget(name: "CLITests", dependencies: ["CLI"]),
  ],
  swiftLanguageModes: [.v6]
)
