import AtelierKit
import SwiftUI

/// What the HUD draws: a title, rows of key and label, and a footer whose
/// height never changes so feedback cannot move the rows. System type,
/// colors, and glass; nothing drawn by hand.
struct HUDView: View {
  enum Content: Equatable {
    case empty
    case leader(LeaderState)
    case windows([AtelierKit.Window])
    case notice(String)
  }

  let content: Content

  static let width: CGFloat = 320

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
          Text("Nothing here").foregroundStyle(.secondary).padding(.horizontal, 12)
        }
        ForEach(state.entries) { LeaderRow(entry: $0) }
        footer(state.feedback ?? "")
      case .windows(let windows):
        header("WINDOWS")
        ForEach(Array(windows.enumerated()), id: \.element.id) { index, window in
          WindowRow(
            number: index < 10 ? "\((index + 1) % 10)" : "", window: window,
            showsTitle: windows.filter { $0.app == window.app }.count > 1)
        }
        footer("Release to hide")
      case .notice(let text):
        Label(text, systemImage: "exclamationmark.circle")
          .font(.callout)
          .padding(.horizontal, 12)
          .padding(.vertical, 10)
      }
    }
    .padding(.vertical, 8)
    .frame(width: Self.width, alignment: .leading)
    .glassEffect(.regular, in: .rect(cornerRadius: 20))
    .padding(8)
  }

  private func header(_ title: String) -> some View {
    Text(title)
      .font(.caption.weight(.semibold))
      .foregroundStyle(.secondary)
      .padding(.horizontal, 12)
      .padding(.bottom, 4)
      .lineLimit(1)
  }

  private func footer(_ text: String) -> some View {
    Text(text.isEmpty ? " " : text)
      .font(.caption)
      .foregroundStyle(.secondary)
      .padding(.horizontal, 12)
      .padding(.top, 6)
      .lineLimit(1)
      .accessibilityHidden(text.isEmpty)
  }
}

private struct LeaderRow: View {
  let entry: LeaderEntry

  var body: some View {
    HStack(spacing: 8) {
      Text(entry.key)
        .font(.body.weight(.semibold).monospacedDigit())
        .frame(width: 44, alignment: .leading)
      Text(entry.label)
        .strikethrough(entry.unavailable != nil)
        .lineLimit(1)
      Spacer(minLength: 8)
      if let hint = entry.hint {
        Text(hint).font(.callout).foregroundStyle(.tertiary).lineLimit(1)
      }
      if entry.isSubmenu {
        Image(systemName: "chevron.right").imageScale(.small).foregroundStyle(.secondary)
      }
    }
    .foregroundStyle(entry.unavailable == nil ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
    .padding(.horizontal, 12)
    .padding(.vertical, 3)
    .accessibilityElement(children: .combine)
    .accessibilityHint(entry.unavailable ?? "")
  }
}

private struct WindowRow: View {
  let number: String
  let window: AtelierKit.Window
  let showsTitle: Bool

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Text(number)
        .font(.body.weight(.semibold).monospacedDigit())
        .frame(width: 24, alignment: .leading)
      VStack(alignment: .leading, spacing: 0) {
        Text(window.app).fontWeight(window.isFocused ? .semibold : .regular).lineLimit(1)
        if showsTitle {
          Text(window.title.isEmpty ? "Untitled" : window.title)
            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
      }
      Spacer(minLength: 8)
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
    .padding(.horizontal, 12)
    .padding(.vertical, 3)
    .background(
      window.isFocused
        ? RoundedRectangle(cornerRadius: 8).fill(.selection).padding(.horizontal, 6) : nil
    )
    .accessibilityElement(children: .combine)
  }
}
