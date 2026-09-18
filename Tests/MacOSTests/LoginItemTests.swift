import Foundation
import Testing

@testable import MacOS

@Suite struct LoginItemTests {
  private let applications = [
    URL(filePath: "/Applications"), URL(filePath: "/Users/someone/Applications"),
  ]

  @Test(arguments: [
    ("/Applications/Atelier.app", true),
    ("/Users/someone/Applications/Atelier.app", true),
    ("/Applications/Utilities/Atelier.app", true),
    // A build in a source checkout, and a folder that only starts the same.
    ("/Users/someone/Projects/atelier/.build/xcode/Build/Products/Debug/Atelier.app", false),
    ("/Applications Old/Atelier.app", false),
    ("/Applications", false),
  ])
  func onlyAnAppInAnApplicationsFolderIsInstalled(path: String, expected: Bool) {
    #expect(
      LoginItem.isInstalled(bundle: URL(filePath: path), applications: applications) == expected)
  }
}
