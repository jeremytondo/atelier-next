import MacOS
import Testing

@testable import AtelierKit

/// macOS's own window arrangements, reached through the Window menu.
@Suite struct ArrangementTests {
  private let mac = FakeMac(focusedWindow: 1, windows: [window(1), window(2)])

  init() {
    mac.change {
      $0.windowMenus[1] = [
        .fill: ArrangementItem(isEnabled: true, shortcut: Chord([.function, .control], "f")),
        .center: ArrangementItem(isEnabled: false),
      ]
    }
  }

  @Test func listsEveryArrangementWithWhetherItCanRun() async throws {
    let arrangements = try await Atelier(mac).windows.arrangements()
    #expect(arrangements.map(\.id) == Arrangement.allCases.map(\.rawValue))
    #expect(
      arrangements[0]
        == ArrangementInfo(id: "fill", label: "Fill", unavailable: nil, shortcut: "fn⌃F"))
    #expect(arrangements[1].unavailable == "Center is unavailable for the focused window.")
    #expect(arrangements[2].unavailable == "Left is not in the app's Window menu.")
    #expect(arrangements[2].shortcut == nil)
  }

  @Test func arrangingPressesTheMenuItem() async throws {
    #expect(try await Atelier(mac).windows.arrange(.fill) == .changed)
    #expect(mac.requests == ["arrange fill"])
  }

  @Test func whatTheMenuDoesNotOfferIsAFailure() async throws {
    let atelier = Atelier(mac)
    await #expect(throws: AtelierError.failed("Center is unavailable for the focused window.")) {
      try await atelier.windows.arrange(.center)
    }
    await #expect(throws: AtelierError.failed("Left is not in the Window menu of App 1.")) {
      try await atelier.windows.arrange(.left)
    }
    #expect(mac.requests.isEmpty)
  }

  @Test func aWindowThatLostTheKeyboardIsNotArranged() async throws {
    mac.change { state in
      state.afterSnapshot = { $0.focusedWindow = 2 }
    }
    await #expect(
      throws: AtelierError.targetChanged("The focused window changed, so Fill was not applied.")
    ) {
      try await Atelier(mac).windows.arrange(.fill)
    }
  }

  @Test func withoutAFocusedWindowThereIsNothingToArrange() async throws {
    mac.change { $0.focusedWindow = nil }
    let atelier = Atelier(mac)
    await #expect(throws: AtelierError.failed("No window has the keyboard.")) {
      try await atelier.windows.arrange(.fill)
    }
    #expect(
      try await atelier.windows.arrangements().allSatisfy {
        $0.unavailable == "No app is frontmost."
      })
  }

  @Test func aFrozenAppIsReported() async throws {
    mac.change { $0.frozenApps = [1] }
    let atelier = Atelier(mac)
    await #expect(throws: AtelierError.failed("App 1 is not responding.")) {
      try await atelier.windows.arrange(.fill)
    }
    #expect(
      try await atelier.windows.arrangements().allSatisfy {
        $0.unavailable == "The app did not describe its menus."
      })
  }

  @Test func needsAccessibility() async {
    mac.change { $0.hasAccessibility = false }
    await #expect(throws: AtelierError.accessibilityRequired) {
      try await Atelier(mac).windows.arrangements()
    }
  }
}
