import AtelierKit

/// The configuration's problems, kept current for as long as the app runs so
/// the menu-bar icon can say when there are any.
@MainActor
final class ConfigModel {
  private(set) var problems: [Problem] = []

  private let atelier: Atelier
  private let changed: @MainActor () -> Void

  init(atelier: Atelier, changed: @escaping @MainActor () -> Void) {
    self.atelier = atelier
    self.changed = changed
    Task {
      // Subscribed first, so a change during the first refresh is not missed.
      let changes = await atelier.config.changes()
      await refresh()
      for await _ in changes { await refresh() }
    }
  }

  private func refresh() async {
    let current = await atelier.config.problems()
    guard current != problems else { return }
    problems = current
    changed()
  }
}
