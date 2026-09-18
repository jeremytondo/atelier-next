import AppKit
import AtelierKit

/// Gives everything Atelier shows the configured theme: the menu, the HUD,
/// and its windows all take the app's appearance. Light and dark are forced;
/// with neither, macOS's own appearance applies and is followed as it
/// changes. Either way macOS still picks the variant for Increase Contrast
/// and Reduce Transparency.
@MainActor
public enum Appearance {
  /// Applies the theme in effect now and after every change to the configuration.
  public static func follow(_ atelier: Atelier) {
    Task {
      // Subscribed first, so a reload during the first read is not missed.
      let changes = await atelier.config.changes()
      await apply(atelier.config.theme())
      for await _ in changes { await apply(atelier.config.theme()) }
    }
  }

  private static func apply(_ theme: Theme) {
    NSApp.appearance =
      switch theme {
      case .light: NSAppearance(named: .aqua)
      case .dark: NSAppearance(named: .darkAqua)
      case .system: nil
      }
  }
}
