import AtelierKit
import Observation

/// The configuration as the menu bar shows it: its problems, kept current for
/// as long as the app runs so the menu-bar icon can say when there are any,
/// and the two things a person does about them.
@MainActor @Observable
final class ConfigModel {
  private(set) var problems: [Problem] = []
  /// What the last reload or open said, for a moment.
  private(set) var message: String?

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
    problems = await atelier.config.problems()
    changed()
  }

  func reload() {
    Task {
      do {
        let result = try await atelier.config.reload()
        message = result.outcome == .changed ? "Reloaded." : "Reloaded; nothing had changed."
      } catch let error as AtelierError {
        message = error.message
      } catch {
        message = String(describing: error)
      }
      expire(message)
    }
  }

  /// Removes the message after a few seconds, unless a newer one replaced it.
  private func expire(_ shown: String?) {
    Task {
      try? await Task.sleep(for: .seconds(4))
      if message == shown { message = nil }
    }
  }

  func open() {
    Task {
      do {
        _ = try await atelier.config.open()
        message = nil
      } catch let error as AtelierError {
        message = error.message
      } catch {
        message = String(describing: error)
      }
      expire(message)
    }
  }
}
