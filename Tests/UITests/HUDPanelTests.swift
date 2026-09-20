import AppKit
import Testing

@testable import UI

@MainActor
private final class Window: HUDWindow {
  var contentView: NSView?
  var frame = NSRect.zero
  let windowNumber: Int
  var isVisible = false
  var isOnActiveSpace = true
  var orders = 0
  var closes = 0

  init(_ number: Int) { windowNumber = number }

  func setFrame(_ frame: NSRect, display: Bool) { self.frame = frame }

  func orderFrontRegardless() {
    orders += 1
    isVisible = true
  }

  func orderOut(_ sender: Any?) { isVisible = false }

  func close() {
    closes += 1
    isVisible = false
  }
}

@MainActor
@Suite struct HUDPanelTests {
  private let screen = NSRect(x: 0, y: 0, width: 1440, height: 900)
  private let content = HUDView(content: .notice("Test notice"))

  @Test func healthyWindowIsReusedAcrossUpdatesAndPresentations() {
    let window = Window(1)
    var creations = 0
    let hud = HUDPanel(content: content) {
      creations += 1
      return window
    }
    hud.show(content, in: screen)
    hud.show(content, in: screen)
    hud.spacesChanged()
    #expect(creations == 1)
    #expect(window.orders == 1)
    hud.hide()
    hud.show(content, in: screen)
    #expect(creations == 1)
    #expect(window.orders == 2)
    #expect(window.closes == 0)
  }

  @Test func strandedWindowIsReplacedWithItsContentAndFrame() {
    let original = Window(1)
    let replacement = Window(2)
    var creations = 0
    let hud = HUDPanel(content: content) {
      creations += 1
      return creations == 1 ? original : replacement
    }
    let hosting = original.contentView
    original.isOnActiveSpace = false
    hud.show(content, in: screen)
    #expect(creations == 2)
    #expect(original.closes == 1)
    #expect(original.contentView == nil)
    #expect(!original.isVisible)
    #expect(replacement.isVisible)
    #expect(replacement.contentView === hosting)
    #expect(replacement.frame == original.frame)
    #expect(replacement.frame.maxX == screen.maxX - 20)
    #expect(replacement.frame.minY == screen.minY + 20)
    hud.hide()
    #expect(!replacement.isVisible)
  }

  @Test func spaceChangeRepairsAnAlreadyShowingWindow() {
    let original = Window(1)
    let replacement = Window(2)
    var creations = 0
    let hud = HUDPanel(content: content) {
      creations += 1
      return creations == 1 ? original : replacement
    }
    hud.show(content, in: screen)
    original.isOnActiveSpace = false
    hud.spacesChanged()
    #expect(creations == 2)
    #expect(original.closes == 1)
    #expect(replacement.isVisible)
  }

  @Test func hiddenWindowDoesNotReappearOnSpaceChanges() {
    let window = Window(1)
    var creations = 0
    let hud = HUDPanel(content: content) {
      creations += 1
      return window
    }
    hud.spacesChanged()
    #expect(window.orders == 0)
    hud.show(content, in: screen)
    hud.hide()
    window.isOnActiveSpace = false
    hud.spacesChanged()
    #expect(!window.isVisible)
    #expect(creations == 1)
    #expect(window.orders == 1)
  }

  @Test func failedRecoveryIsBoundedUntilDismissed() {
    var windows: [Window] = []
    let hud = HUDPanel(content: content) {
      let window = Window(windows.count + 1)
      window.isOnActiveSpace = false
      windows.append(window)
      return window
    }
    hud.show(content, in: screen)
    #expect(windows.count == 2)
    // Neither content updates nor further notifications start a retry loop.
    hud.show(content, in: screen)
    hud.spacesChanged()
    hud.spacesChanged()
    #expect(windows.count == 2)
    hud.hide()
    hud.show(content, in: screen)
    #expect(windows.count == 3)
    #expect(windows[1].closes == 1)
  }
}
