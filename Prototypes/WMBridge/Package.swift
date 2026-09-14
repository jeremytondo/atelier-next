// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "WMBridgeExperiment",
  platforms: [.macOS(.v26)],
  products: [.executable(name: "wmbridge-experiment", targets: ["Experiment"]),
    .executable(name: "review-recording", targets: ["ReviewRecording"])],
  dependencies: [.package(path: "../../App")],
  targets: [
    .target(name: "NativeBridge", cSettings: [.unsafeFlags(["-fobjc-arc"])],
      linkerSettings: [.linkedFramework("AppKit")]),
    .target(name: "Trial", dependencies: [.product(name: "SpaceControlCore", package: "App")]),
    .executableTarget(name: "Experiment", dependencies: ["NativeBridge", "Trial", .product(name: "AtelierEngine", package: "App")]),
    .testTarget(name: "TrialTests", dependencies: ["Trial"]),
    .executableTarget(name: "ReviewRecording"),
  ],
  swiftLanguageModes: [.v5]
)
