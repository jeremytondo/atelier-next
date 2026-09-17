import Foundation

/// What macOS can tell Atelier. `MacOS` reports raw facts and gives them no
/// meaning; `AtelierKit` decides what they mean. This is the only module that
/// touches Accessibility or private macOS calls, and `LiveMac` is the only
/// implementation outside tests.
package protocol Mac: Sendable {
  var hasAccessibility: Bool { get }

  /// Asks macOS to list Atelier under Accessibility and opens that settings pane.
  func requestAccessibility()

  /// Where the keyboard is now, read in the background from the frontmost app.
  /// Atelier's interface reads it before appearing, since appearing moves it.
  func focus() async -> Focus

  /// One census of Spaces and windows, read in the background. Nil when
  /// WindowServer refuses the census.
  func snapshot() async -> Snapshot?
}

package struct Focus: Sendable, Equatable {
  /// The frontmost app's focused window, which may be a panel the census
  /// leaves out. Nil when it has none, does not answer, or is Atelier itself.
  package let window: UInt32?
  package let windowSpaces: [UInt64]
  /// The Space WindowServer treats as active.
  package let activeSpace: UInt64

  package init(window: UInt32?, windowSpaces: [UInt64], activeSpace: UInt64) {
    self.window = window
    self.windowSpaces = windowSpaces
    self.activeSpace = activeSpace
  }
}

package struct Snapshot: Sendable, Equatable {
  package let displays: [DisplaySpaces]
  /// Layer-0 windows of every other app on every Space, front to back.
  package let windows: [WindowFacts]

  package init(displays: [DisplaySpaces], windows: [WindowFacts]) {
    self.displays = displays
    self.windows = windows
  }
}

package struct WindowFacts: Sendable, Equatable {
  package let id: UInt32
  package let app: String
  package let title: String
  package let spaces: [UInt64]
  /// False while minimized, while its app is hidden, and on an inactive Space.
  package let isOnScreen: Bool
  /// Accessibility confirmed a document or main window rather than a panel,
  /// sheet, or dialog. False when the app did not answer in time.
  package let isOrdinary: Bool

  package init(
    id: UInt32, app: String, title: String, spaces: [UInt64], isOnScreen: Bool, isOrdinary: Bool
  ) {
    self.id = id
    self.app = app
    self.title = title
    self.spaces = spaces
    self.isOnScreen = isOnScreen
    self.isOrdinary = isOrdinary
  }
}

package struct DisplaySpaces: Sendable, Equatable {
  package let currentSpace: UInt64
  package let spaces: [Space]

  package init(currentSpace: UInt64, spaces: [Space]) {
    self.currentSpace = currentSpace
    self.spaces = spaces
  }
}

package struct Space: Sendable, Equatable {
  package let id: UInt64
  /// False for a full-screen or Split View Space; WindowServer files both
  /// under one type.
  package let isDesktop: Bool

  package init(id: UInt64, isDesktop: Bool) {
    self.id = id
    self.isDesktop = isDesktop
  }
}
