// swift-tools-version: 6.2
import PackageDescription

// The companion's logic, kept out of the app target so it can be tested
// without Spotlight: the request envelope, the Hammerspoon 2 check, the
// delivery, and the reply. `App/` holds the bundle that links this library.
let package = Package(
  name: "AtelierCompanion",
  platforms: [.macOS(.v26)],
  products: [
    .library(name: "Companion", targets: ["Companion"])
  ],
  targets: [
    .target(name: "Companion"),
    .testTarget(name: "CompanionTests", dependencies: ["Companion"]),
  ],
  swiftLanguageModes: [.v5]
)
