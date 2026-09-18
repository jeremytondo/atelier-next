import MacOS

/// One of macOS's own window arrangements as it stands for the focused window.
public struct ArrangementInfo: Equatable, Identifiable, Sendable {
  /// The name `windows arrange` takes, such as `top-left`.
  public let id: String
  public let label: String
  /// Nil when the arrangement can run now; otherwise why it cannot.
  public let unavailable: String?
  /// macOS's own shortcut for it, when its menu says.
  public let shortcut: String?
}

extension Windows {
  /// `windows.arrangements`: every arrangement macOS offers, with whether the
  /// frontmost app's Window menu enables it for the focused window right now.
  package func arrangements() async throws(AtelierError) -> [ArrangementInfo] {
    try await workspace.arrangements()
  }

  /// `windows.arrange`: presses the arrangement in the frontmost app's Window
  /// menu, so macOS chooses the windows and the layout.
  package func arrange(_ arrangement: Arrangement) async throws(AtelierError) -> Outcome {
    try await workspace.arrange(arrangement)
  }
}

extension Workspace {
  func arrangements() async throws(AtelierError) -> [ArrangementInfo] {
    guard mac.hasAccessibility else { throw .accessibilityRequired }
    let focus = await mac.focus()
    var items: [Arrangement: ArrangementItem]?
    if let app = focus.app { items = await mac.arrangements(of: app) }
    return Arrangement.allCases.map { arrangement in
      let item = items?[arrangement]
      let unavailable: String? =
        if focus.app == nil {
          "No app is frontmost."
        } else if items == nil {
          "The app did not describe its menus."
        } else if item == nil {
          "\(arrangement.label) is not in the app's Window menu."
        } else if focus.window == nil {
          "No window has the keyboard."
        } else if item?.isEnabled != true {
          "\(arrangement.label) is unavailable for the focused window."
        } else {
          nil
        }
      return ArrangementInfo(
        id: arrangement.rawValue, label: arrangement.label, unavailable: unavailable,
        shortcut: item?.shortcut.map(KeyGrammar.describe))
    }
  }

  func arrange(_ arrangement: Arrangement) async throws(AtelierError) -> Outcome {
    try await run { observation async throws(AtelierError) in
      guard let app = observation.focus.app, let window = observation.focus.window else {
        throw .failed("No window has the keyboard.")
      }
      let name = observation.snapshot.windows.first { $0.app == app }?.appName ?? "The app"
      switch await mac.arrange(arrangement, in: app, window: window) {
      case .pressed: return .changed
      case .missing: throw .failed("\(arrangement.label) is not in the Window menu of \(name).")
      case .disabled: throw .failed("\(arrangement.label) is unavailable for the focused window.")
      case .windowChanged:
        throw .targetChanged("The focused window changed, so \(arrangement.label) was not applied.")
      case .unanswered: throw .failed("\(name) is not responding.")
      }
    }
  }
}
