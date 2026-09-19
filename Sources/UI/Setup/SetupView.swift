import AtelierKit
import SwiftUI

/// The setup page: one section each for Accessibility, opening at login, the
/// keys, and the configuration, each saying how things stand and offering
/// what can be done about it. System type and colors; the one thing drawn by
/// hand is `Design`'s keycaps.
struct SetupView: View {
  enum Action {
    case openAccessibilitySettings, openLoginSettings, addLoginItem
    case openConfiguration, reloadConfiguration
  }

  let model: SetupModel
  let act: (Action) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Section(title: "Accessibility", isGood: model.hasAccessibility) {
        Text(
          model.hasAccessibility
            ? "Atelier can see and arrange other apps' windows."
            : "Atelier needs the Accessibility permission to see and arrange other apps' windows. Switch Atelier on in Accessibility settings, then come back here."
        )
      } actions: {
        if !model.hasAccessibility {
          Button("Open Accessibility Settings…") { act(.openAccessibilitySettings) }
        }
      }
      if let login = model.login {
        Section(
          // An item the user removed is their choice: neither good nor a problem.
          title: "Open at Login",
          isGood: login.needsAttention ? false : login.kind == .enabled ? true : nil
        ) {
          Text(
            [
              login.summary, login.advice,
              "macOS Login Items decides this; Atelier asks only once, when the installed app first opens.",
            ].compactMap(\.self).joined(separator: " "))
        } actions: {
          Button("Open Login Items Settings…") { act(.openLoginSettings) }
          if login.kind == .notRegistered, model.canAddLoginItem {
            Button("Add Atelier to Login Items") { act(.addLoginItem) }
          }
        }
      }
      Section(title: "Keys", isGood: nil, plainSymbol: "keyboard") {
        keys
      } actions: {
      }
      Section(
        title: "Configuration", isGood: model.rejection == nil && model.problems.isEmpty
      ) {
        Text(configuration)
      } actions: {
        Button("Open Configuration") { act(.openConfiguration) }
        Button("Reload") { act(.reloadConfiguration) }
      }
    }
    .padding(20)
    .frame(width: 460, alignment: .leading)
  }

  /// Each key as caps beside what it does, the caps in a column of their own.
  private var keys: some View {
    VStack(alignment: .leading, spacing: 6) {
      if model.leaderKeyPieces == nil {
        Text("The leader menu has no key; set one under [leader] in the configuration.")
      }
      Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 6) {
        if let leaderKeyPieces = model.leaderKeyPieces {
          GridRow {
            Keycaps(pieces: leaderKeyPieces).foregroundStyle(.primary)
            Text("opens the leader menu in the corner of the screen.")
          }
        }
        GridRow {
          Keycaps(pieces: model.windowListModifierPieces).foregroundStyle(.primary)
          Text("held, shows this Desktop's numbered windows.")
        }
        if let spaceListModifierPieces = model.spaceListModifierPieces {
          GridRow {
            Keycaps(pieces: spaceListModifierPieces).foregroundStyle(.primary)
            Text("held, shows this display's numbered Spaces.")
          }
        }
      }
      Text("The atelier config show command lists every key.")
    }
  }

  private var configuration: String {
    let file = model.configurationFile ?? "The configuration file"
    let problems = model.problems.map { "• \($0.text)" }
    guard let rejection = model.rejection else {
      return
        ([
          problems.isEmpty
            ? "\(file) overrides the built-in keys. Edits apply when you reload."
            : "\(file) has problems. Each setting listed is left out until it is fixed and reloaded."
        ] + problems).joined(separator: "\n")
    }
    // A refused file changes nothing, so what was in effect still is, with
    // whatever problems it had.
    return
      ([
        "\(file) could not be read, so none of it applies and what was in effect stays. Fix it and reload.",
        "• \(rejection.text)",
      ] + (problems.isEmpty ? [] : ["Still left out of what is in effect:"] + problems))
      .joined(separator: "\n")
  }
}

private struct Section<Detail: View, Actions: View>: View {
  let title: String
  /// Nil for a section that only informs, which then shows `plainSymbol`.
  let isGood: Bool?
  var plainSymbol = "minus.circle"
  @ViewBuilder let detail: Detail
  @ViewBuilder let actions: Actions

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 10) {
      switch isGood {
      case true?:
        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
          .accessibilityLabel("Fine")
      case false?:
        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
          .accessibilityLabel("Needs attention")
      case nil:
        Image(systemName: plainSymbol).foregroundStyle(.secondary).accessibilityHidden(true)
      }
      VStack(alignment: .leading, spacing: 6) {
        Text(title).font(.headline)
        detail.foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        HStack { actions }
      }
    }
    .accessibilityElement(children: .contain)
  }
}
