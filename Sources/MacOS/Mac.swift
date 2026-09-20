import Foundation

/// What macOS can tell Atelier and what Atelier can ask of it. `MacOS` reports
/// raw facts and carries out requests; it gives them no meaning, and a request
/// sent proves nothing. `AtelierKit` decides what facts mean and checks that
/// each request had its effect. This is the only module that touches
/// Accessibility or private macOS calls, and `LiveMac` is the only
/// implementation outside tests.
///
/// Every request that changes Spaces takes `expecting`, the Spaces the caller
/// chose its target from. The Spaces are read once more at the last moment,
/// with nothing in between that could let them change unseen, and when they
/// differ nothing is asked of macOS.
package protocol Mac: Sendable {
  var hasAccessibility: Bool { get }

  /// Asks macOS to list Atelier under Accessibility and opens that settings pane.
  func requestAccessibility()

  /// True when this app runs from an Applications folder, as an installed
  /// copy does and a build in a source checkout does not.
  var isInstalled: Bool { get }

  /// Where this app is on disk.
  var appPath: String { get }

  /// Ends this app the way its Quit does.
  func terminate()

  var loginItemStatus: LoginItemStatus { get }

  /// Asks macOS to open this app at login. Nil when macOS took the request,
  /// and otherwise why not. The caller reads `loginItemStatus` for the result.
  func registerLoginItem() -> String?

  /// Opens Login Items in System Settings.
  func openLoginItemSettings()

  /// Where the keyboard is now, read in the background from the frontmost app.
  func focus() async -> Focus

  /// One census of Spaces and windows, read in the background. Nil when
  /// WindowServer refuses the census.
  func snapshot() async -> Snapshot?

  /// Yields whenever windows, focus, or Spaces may have changed. It is a hint
  /// to take a fresh snapshot, never a fact, and some changes send none.
  func changes() -> AsyncStream<Void>

  /// Displays and their Spaces in Mission Control order, read without waiting
  /// on any app. Empty when WindowServer refuses or any part is unreadable.
  func spaces() -> [DisplaySpaces]

  /// A name for each full-screen and Split View Space, by the Space's id: its
  /// app's, or both apps' for a Split View. Read without waiting on any app.
  /// A Desktop has no entry; it goes by its number.
  func spaceNames() -> [UInt64: String]

  /// Nil when Dock would not say.
  func isMissionControlOpen() async -> Bool?

  /// Asks macOS to make `space` the current Space of `display`, the way the
  /// user would. The caller reads `spaces()` afterwards for the result.
  func switchSpace(to space: UInt64, on display: String, expecting: [DisplaySpaces]) async
    -> SpaceDispatch

  /// Asks macOS for one new Desktop, which it adds after the display's last Space.
  func createDesktop(expecting: [DisplaySpaces]) async -> DesktopCreation

  /// Moves a Space to a zero-based place among all the Spaces of its display.
  func moveSpace(
    _ id: UInt64, toIndex index: Int, onDisplay display: String, expecting: [DisplaySpaces]
  ) async -> SpaceDispatch

  /// Removes a Space. macOS moves its windows to the Space being shown.
  func destroySpace(_ id: UInt64, expecting: [DisplaySpaces]) async -> SpaceDispatch

  /// Moves a window to a Space, leaving every other. The caller confirms
  /// with `spaces(ofWindow:)`; a sent request proves nothing.
  func moveWindow(_ id: UInt32, toSpace space: UInt64, expecting: [DisplaySpaces]) async
    -> SpaceDispatch

  /// The Spaces a window belongs to now; empty when WindowServer reports none.
  func spaces(ofWindow id: UInt32) -> [UInt64]

  /// Shows a window of `app` if it is minimized or its app is hidden, and asks
  /// for it to come forward. The caller watches `focus()` for the result.
  func raise(window: UInt32, of app: Int32) async -> RaiseResult

  /// The arrangements in `app`'s Window menu, read in the background. Nil
  /// when the app does not answer; empty when its menus have none.
  func arrangements(of app: Int32) async -> [Arrangement: ArrangementItem]?

  /// Presses the arrangement's menu item in `app`, provided `window` still has
  /// the keyboard there. macOS does the arranging.
  func arrange(_ arrangement: Arrangement, in app: Int32, window: UInt32) async -> ArrangeResult

  /// Makes exactly these chords Atelier's global keyboard shortcuts, releasing
  /// any registered before. Returns why each refused chord was refused.
  func registerHotKeys(_ chords: [Chord]) async -> [Chord: String]

  /// Every press of a registered shortcut, once per press however long it is held.
  func hotKeyPresses() -> AsyncStream<Chord>

  /// macOS's own shortcuts for switching Spaces, on or off, which Atelier
  /// presses itself and so must not register.
  func spaceSwitchingChords() async -> [Chord]

  /// Opens a file in the app the user has for it. False when macOS could not.
  func open(_ file: URL) -> Bool

  /// Starts listening to the keyboard and mouse, consuming what `decide`
  /// says to, until the listener is stopped. `decide` runs at once for each
  /// event, off the main thread, and must be quick. Nil when macOS refuses.
  func listenToKeys(_ decide: @escaping @Sendable (KeyEvent) -> KeyDecision) async
    -> (any KeyListening)?

  /// The modifier keys held, whenever that changes.
  func modifierChanges() async -> AsyncStream<Chord.Modifiers>

  /// An app on disk from a name, bundle identifier, or path. Nil when none.
  func findApp(_ reference: String) -> AppReference?

  /// The process number of the app when it is running.
  func runningApp(_ app: AppReference) -> Int32?

  /// Launches the app, or reopens it when running, without activating it.
  /// The process number once macOS reports it; nil when it would not launch.
  func launch(_ app: AppReference) async -> Int32?

  /// Nil when there is no such process.
  func isAppHidden(_ pid: Int32) -> Bool?

  /// Asks macOS to hide or show every window of the app, without activating
  /// it. False when there is no such process. Asking proves nothing: the
  /// caller watches `isAppHidden`.
  func setAppHidden(_ pid: Int32, _ hidden: Bool) -> Bool

  /// The window's frame in Accessibility's coordinates: points from the
  /// top-left of the primary display, y growing downwards. Nil when the app
  /// does not answer or has no such window.
  func frame(ofWindow id: UInt32, in app: Int32) async -> CGRect?

  /// Asks the app for a frame; it may keep the window larger. False when the
  /// window cannot be found. The caller reads the frame back for the result.
  func setFrame(_ frame: CGRect, ofWindow id: UInt32, in app: Int32) async -> Bool

  /// The display's area free of the menu bar and Dock, in Accessibility's
  /// coordinates. Nil when the display is gone.
  func usableFrame(ofDisplay id: String) async -> CGRect?
}

package struct Focus: Sendable, Equatable {
  /// The frontmost app. Nil when it is Atelier itself.
  package let app: Int32?
  /// The frontmost app's focused window, which may be a panel the census
  /// leaves out. Nil when it has none, does not answer, or is Atelier itself.
  package let window: UInt32?
  /// False for a panel, sheet, or dialog, and when there is no focused window.
  package let windowIsOrdinary: Bool
  package let windowSpaces: [UInt64]
  /// The Space WindowServer treats as active.
  package let activeSpace: UInt64

  package init(
    app: Int32?, window: UInt32?, windowIsOrdinary: Bool, windowSpaces: [UInt64],
    activeSpace: UInt64
  ) {
    self.app = app
    self.window = window
    self.windowIsOrdinary = windowIsOrdinary
    self.windowSpaces = windowSpaces
    self.activeSpace = activeSpace
  }
}

package struct Snapshot: Sendable, Equatable {
  package let displays: [DisplaySpaces]
  /// Layer-0 windows of every other app on every Space, front to back.
  /// WindowServer can keep a closed window listed.
  package let windows: [WindowFacts]

  package init(displays: [DisplaySpaces], windows: [WindowFacts]) {
    self.displays = displays
    self.windows = windows
  }
}

package struct WindowFacts: Sendable, Equatable {
  /// What the window's app said about it through Accessibility.
  package enum Report: Sendable, Equatable {
    /// A document or main window rather than a panel, sheet, or dialog.
    case ordinary
    /// Listed, but a panel, sheet, dialog, or full-screen window.
    case other
    /// The app listed its windows and this was not among them. Apps leave out
    /// windows on Spaces that are not showing, so only there is this no news.
    case missing
    /// The app did not answer in time, or a Space changed while it answered.
    case unanswered
  }

  package let id: UInt32
  package let app: Int32
  /// When the app was launched, in seconds since 1970. With `app` and `id` it
  /// names one window for as long as the Mac stays up. Nil when macOS has none.
  package let appLaunched: Double?
  package let appName: String
  package let title: String
  /// Empty when WindowServer reports no membership.
  package let spaces: [UInt64]
  /// False while minimized, while its app is hidden, and on an inactive Space.
  package let isOnScreen: Bool
  package let report: Report

  package init(
    id: UInt32, app: Int32, appLaunched: Double?, appName: String, title: String,
    spaces: [UInt64], isOnScreen: Bool, report: Report
  ) {
    self.id = id
    self.app = app
    self.appLaunched = appLaunched
    self.appName = appName
    self.title = title
    self.spaces = spaces
    self.isOnScreen = isOnScreen
    self.report = report
  }
}

package struct DisplaySpaces: Sendable, Equatable {
  /// WindowServer's name for the display, stable while it stays connected.
  package let id: String
  package let currentSpace: UInt64
  /// In Mission Control order.
  package let spaces: [Space]

  package init(id: String, currentSpace: UInt64, spaces: [Space]) {
    self.id = id
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

/// What became of one request to change Spaces.
package enum SpaceDispatch: Sendable, Equatable {
  case sent
  /// The Spaces were not as expected. Nothing was asked of macOS.
  case changed
  /// macOS cannot do this. Nothing was asked of it.
  case refused(String)
  /// The request went out and failed part-way, so the outcome is unknown.
  case uncertain(String)
}

package enum DesktopCreation: Sendable, Equatable {
  case created(UInt64)
  case changed
  case refused(String)
  case uncertain(String)
}

package enum RaiseResult: Sendable, Equatable {
  case asked
  /// The app listed its windows and this one was not among them.
  case closed
  /// The app did not answer in time.
  case unanswered
}
