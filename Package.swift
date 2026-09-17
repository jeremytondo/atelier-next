// swift-tools-version: 6.2
import PackageDescription

// Each layer knows only the one below it: `UI`, then `AtelierKit`, then
// `MacOS`. `Client` is what the `atelier` command and the app's server agree
// on, so the command never links the app's behavior. `App/` holds the bundle
// that links `UI` and `AtelierKit`.
let package = Package(
  name: "Atelier",
  platforms: [.macOS(.v26)],
  products: [
    .library(name: "UI", targets: ["UI"]),
    .library(name: "AtelierKit", targets: ["AtelierKit"]),
    .executable(name: "atelier", targets: ["CLI"]),
  ],
  dependencies: [
    .package(url: "https://github.com/apple/swift-argument-parser", from: "1.6.0")
  ],
  targets: [
    .target(name: "UI", dependencies: ["AtelierKit"]),
    .target(name: "AtelierKit", dependencies: ["MacOS", "Client"]),
    .target(name: "MacOS"),
    .target(name: "Client"),
    .executableTarget(
      name: "CLI",
      dependencies: [
        "Client",
        .product(name: "ArgumentParser", package: "swift-argument-parser"),
      ]),
    .testTarget(name: "AtelierKitTests", dependencies: ["AtelierKit"]),
    .testTarget(name: "MacOSTests", dependencies: ["MacOS"]),
  ],
  swiftLanguageModes: [.v6]
)
