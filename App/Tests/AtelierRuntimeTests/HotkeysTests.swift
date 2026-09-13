import AtelierCore
import Carbon.HIToolbox
import XCTest

@testable import Atelier

final class HotkeysTests: XCTestCase {
  func testFailedReplacementReleasesOnlyNewRegistrationsAndKeepsOldActions() async throws {
    try await MainActor.run {
      var live: Set<UInt32> = []
      let denied = try Shortcut("ctrl-option-cmd-f19")
      let keys = Hotkeys(
        registration: { id, binding in
          if binding.shortcut == denied { throw AppError("Reserved by another application.") }
          live.insert(id)
          return EventHotKeyRef(bitPattern: Int(id))!
        }, release: { live.remove(UInt32(Int(bitPattern: $0))) })
      let original = Hotkeys.Binding(shortcut: try Shortcut("ctrl-option-cmd-r"), command: .reload)
      try keys.add(original)
      let initialIDs = live
      XCTAssertThrowsError(
        try keys.replace(with: [
          .init(shortcut: try Shortcut("ctrl-option-cmd-f18"), command: .group),
          .init(shortcut: denied, command: .cycle(1)),
        ]))
      XCTAssertEqual(live, initialIDs)
      XCTAssertEqual(keys.bindings.values.first?.shortcut, original.shortcut)
      XCTAssertEqual(keys.bindings.values.first?.command, .reload)
      keys.stop()
      XCTAssertTrue(live.isEmpty)
    }
  }
  func testShortcutCanChangeActionWithoutReleasingItsRegistration() async throws {
    try await MainActor.run {
      var registrations = 0
      var releases = 0
      let keys = Hotkeys(
        registration: { id, _ in
          registrations += 1
          return EventHotKeyRef(bitPattern: Int(id))!
        }, release: { _ in releases += 1 })
      let shortcut = try Shortcut("ctrl-option-cmd-r")
      try keys.add(.init(shortcut: shortcut, command: .reload))
      try keys.replace(with: [.init(shortcut: shortcut, command: .group)])
      XCTAssertEqual(registrations, 1)
      XCTAssertEqual(releases, 0)
      XCTAssertEqual(keys.bindings.values.first?.command, .group)
      keys.stop()
    }
  }
}
