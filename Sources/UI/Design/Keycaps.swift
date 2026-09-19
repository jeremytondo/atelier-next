import SwiftUI

/// A key to press, drawn as keycaps: one bordered cap for each piece, in
/// order, on one line. The pieces come from AtelierKit, which knows where a
/// key divides; nothing here takes a string apart. Every cap Atelier shows is
/// drawn here, at one size.
///
/// A cap takes its color from the foreground style around it, so a row that
/// dims itself dims its caps too.
struct Keycaps: View {
  enum Style {
    /// A key that acts where it is shown.
    case standard
    /// A key mentioned beside another, which must not compete with it.
    case quiet
  }

  let pieces: [String]
  var style = Style.standard

  private static let height: CGFloat = 20
  private static let textPadding: CGFloat = 5
  private static let cornerRadius: CGFloat = 5
  private static let borderWidth: CGFloat = 1
  private static let gap: CGFloat = 3
  /// Slightly smaller than body text.
  private static let font = Font.callout.weight(.medium)

  var body: some View {
    HStack(spacing: Self.gap) {
      ForEach(Array(pieces.enumerated()), id: \.offset) { piece in
        Text(piece.element)
          .font(Self.font)
          // A single character gets a square cap; a named key such as `Space`
          // gets a wider one and stays whole.
          .padding(.horizontal, piece.element.count == 1 ? 0 : Self.textPadding)
          .frame(minWidth: Self.height, minHeight: Self.height, maxHeight: Self.height)
          .background(.foreground.opacity(0.06), in: .rect(cornerRadius: Self.cornerRadius))
          .overlay(
            RoundedRectangle(cornerRadius: Self.cornerRadius)
              .strokeBorder(.foreground.opacity(0.18), lineWidth: Self.borderWidth))
      }
    }
    .opacity(style == .quiet ? 0.4 : 1)
    // Never wrapped, squeezed, or cut short; what is beside it gives way.
    .fixedSize()
    // Read as the key is written, `⇧←`, not cap by cap.
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(pieces.joined())
    .accessibilityHidden(pieces.isEmpty)
  }
}
