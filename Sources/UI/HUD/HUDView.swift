import AtelierKit
import SwiftUI

/// What the HUD draws: a title and rows of key and label, and under the leader
/// menu a footer whose height never changes so feedback cannot move the rows.
/// System type, colors, and glass; the one thing drawn by hand is `Design`'s
/// keycaps.
struct HUDView: View {
  enum Content: Equatable {
    case empty
    case leader(LeaderState)
    case windows([AtelierKit.Window])
    case notice(String)
  }

  let content: Content

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      switch content {
      case .empty:
        EmptyView()
      case .leader(let state):
        // A submenu nobody named is titled by its key, which keeps its case.
        header(
          state.path.map { $0.isKey ? $0.label : $0.label.uppercased() }.joined(separator: " › "))
        if state.entries.isEmpty {
          Text("Nothing here").foregroundStyle(.secondary)
            .padding(.horizontal, HUDMetrics.rowPadding)
        } else {
          HUDRows(spacing: HUDMetrics.leaderRowSpacing) {
            ForEach(state.entries) { LeaderRow(entry: $0) }
          }
        }
        footer(state.feedback ?? "")
      case .windows(let windows):
        header("WINDOWS")
        HUDRows(spacing: 0) {
          ForEach(Array(windows.enumerated()), id: \.element.id) { index, window in
            WindowRow(
              // The tenth window is on the 0 key, and later ones have no key.
              keyPieces: index < 10 ? ["\((index + 1) % 10)"] : [], window: window,
              showsTitle: windows.filter { $0.app == window.app }.count > 1)
          }
        }
      case .notice(let text):
        Label(text, systemImage: "exclamationmark.circle")
          .font(.callout)
          .padding(.horizontal, HUDMetrics.rowPadding)
          .padding(.vertical, 10)
      }
    }
    .padding(.vertical, 8)
    .frame(width: HUDMetrics.width, alignment: .leading)
    .glassEffect(.regular, in: .rect(cornerRadius: 20))
    .padding(8)
  }

  private func header(_ title: String) -> some View {
    Text(title)
      .font(.caption.weight(.semibold))
      .foregroundStyle(.secondary)
      .padding(.horizontal, HUDMetrics.rowPadding)
      .padding(.bottom, 4)
      .lineLimit(1)
  }

  private func footer(_ text: String) -> some View {
    Text(text.isEmpty ? " " : text)
      .font(.caption)
      .foregroundStyle(.secondary)
      .padding(.horizontal, HUDMetrics.rowPadding)
      .padding(.top, 6)
      .lineLimit(1)
      .accessibilityHidden(text.isEmpty)
  }
}

private struct LeaderRow: View {
  let entry: LeaderEntry

  var body: some View {
    HUDRow(keyPieces: entry.keyPieces, height: HUDMetrics.leaderRowHeight) {
      Text(entry.label)
        .strikethrough(entry.unavailable != nil)
        .lineLimit(1)
      Spacer(minLength: HUDMetrics.columnGap)
      if let hintPieces = entry.hintPieces {
        Keycaps(pieces: hintPieces, style: .quiet)
      }
      if entry.isSubmenu {
        Image(systemName: "chevron.right").imageScale(.small).foregroundStyle(.secondary)
      }
    }
    .foregroundStyle(entry.unavailable == nil ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
    .accessibilityElement(children: .combine)
    .accessibilityHint(entry.unavailable ?? "")
  }
}

private struct WindowRow: View {
  let keyPieces: [String]
  let window: AtelierKit.Window
  let showsTitle: Bool

  var body: some View {
    HUDRow(
      keyPieces: keyPieces, height: HUDMetrics.windowRowHeight, isHighlighted: window.isFocused
    ) {
      VStack(alignment: .leading, spacing: 0) {
        Text(window.app).fontWeight(window.isFocused ? .semibold : .regular).lineLimit(1)
        if showsTitle {
          Text(window.title.isEmpty ? "Untitled" : window.title)
            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
      }
      Spacer(minLength: HUDMetrics.columnGap)
      if !window.isVisible {
        Image(systemName: "eye.slash").imageScale(.small).foregroundStyle(.secondary)
          .accessibilityLabel("Hidden or minimized")
      }
      if window.isFocused {
        Image(systemName: "checkmark").imageScale(.small).fontWeight(.semibold)
          .accessibilityLabel("Focused")
      }
    }
    .foregroundStyle(window.isVisible ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
    .accessibilityElement(children: .combine)
  }
}
