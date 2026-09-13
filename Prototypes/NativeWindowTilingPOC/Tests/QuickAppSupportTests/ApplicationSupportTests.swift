import QuickAppSupport
import Testing

@Test @MainActor func resolvesNamesBundleIDsAndPathsToTheSameApp() throws {
  let named = try TargetApplication.resolve("Calculator")
  let suffixed = try TargetApplication.resolve("Calculator.app")
  let identified = try TargetApplication.resolve(named.bundleIdentifier)
  let path = try TargetApplication.resolve(named.url.path)
  #expect(named.bundleIdentifier == "com.apple.calculator")
  #expect([suffixed, identified, path].allSatisfy { $0.url == named.url })
}

@Test @MainActor func missingAppIsAConfigurationError() {
  #expect(throws: (any Error).self) {
    try TargetApplication.resolve("AtelierMissingApp-DF328ECB-991B-45EF-97C9-26BBB44E002C")
  }
}
