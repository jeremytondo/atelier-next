import SwiftUI

/// The HUD's own measurements. What another piece of UI also needs is in
/// `Design` instead.
enum HUDMetrics {
  static let width: CGFloat = 320
  /// Between the panel's edge and what a row, the header, or the footer shows.
  static let rowPadding: CGFloat = 12
  /// Between the key column, the label, and what trails it.
  static let columnGap: CGFloat = 8
  static let keyColumnMinWidth: CGFloat = 52
  /// What a line of body text with 3 points above and below came to before
  /// rows had keycaps. A cap has to fit inside it; the row never grows to
  /// fit a cap.
  static let leaderRowHeight: CGFloat = 22
  static let leaderRowSpacing: CGFloat = 4
  /// One line or two, a window row is this tall, and rows touch.
  static let windowRowHeight: CGFloat = 40
  /// A Space row is one line, and rows touch.
  static let spaceRowHeight: CGFloat = 28
}

/// The rows of one list. Every row's key column is as wide as the list's
/// widest key, and never narrower than the minimum, so labels line up.
struct HUDRows<Rows: View>: View {
  let spacing: CGFloat
  @ViewBuilder let rows: Rows
  @State private var widestKey: CGFloat = 0

  var body: some View {
    VStack(alignment: .leading, spacing: spacing) { rows }
      .environment(\.hudKeyColumnWidth, max(HUDMetrics.keyColumnMinWidth, widestKey))
      .onPreferenceChange(KeyWidth.self) { widestKey = $0 }
  }
}

/// One row of either list: the key to press in the leading column, then
/// whatever the list puts beside it, on a highlight when the row has one.
/// The list says how tall its rows are.
struct HUDRow<Content: View>: View {
  /// No pieces leaves the column empty, and labels still line up.
  let keyPieces: [String]
  let height: CGFloat
  var isHighlighted = false
  @ViewBuilder let content: Content
  @Environment(\.hudKeyColumnWidth) private var keyColumnWidth

  var body: some View {
    HStack(spacing: HUDMetrics.columnGap) {
      Keycaps(pieces: keyPieces)
        .background(
          GeometryReader { Color.clear.preference(key: KeyWidth.self, value: $0.size.width) }
        )
        .frame(minWidth: keyColumnWidth, alignment: .leading)
      content
    }
    .padding(.horizontal, HUDMetrics.rowPadding)
    .frame(height: height)
    .background(
      isHighlighted
        ? RoundedRectangle(cornerRadius: 8).fill(.selection).padding(.horizontal, 6) : nil
    )
  }
}

private struct KeyWidth: PreferenceKey {
  static let defaultValue: CGFloat = 0

  static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
    value = max(value, nextValue())
  }
}

extension EnvironmentValues {
  @Entry fileprivate var hudKeyColumnWidth = HUDMetrics.keyColumnMinWidth
}
