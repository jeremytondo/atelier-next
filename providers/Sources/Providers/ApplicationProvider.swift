// Fills the gaps in `hs.application`: resolve a name, path, or bundle ID to
// the app on disk, and launch or reopen it without activation. The pinned HS2
// only exposes an activating launch, which would switch Desktops before a Quick
// App's membership is established.
import AppKit
import Foundation

@MainActor
final class ApplicationProvider {
  private let poller = Poller.live(interval: 0.02)

  lazy var commands: [String: PipeProtocol.Handler] = [
    "resolve": PipeProtocol.handler { (request: ApplicationRequest) in
      let target = try TargetApplication.resolve(request.app)
      return ApplicationResponse(
        bundleID: target.bundleIdentifier, name: target.name, path: target.url.path)
    },
    "launch": PipeProtocol.handler { (request: LaunchRequest) in
      LaunchResponse(pid: try self.launch(TargetApplication.resolve(request.path)))
    },
  ]

  /// Returns once macOS reports the process, without taking focus or
  /// switching to a Desktop the app was last seen on.
  private func launch(_ target: TargetApplication) throws -> pid_t {
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = false
    var outcome: Result<pid_t, Error>?
    NSWorkspace.shared.openApplication(at: target.url, configuration: configuration) { app, error in
      DispatchQueue.main.async {
        if let app {
          outcome = .success(app.processIdentifier)
        } else {
          outcome = .failure(error ?? ProviderError("Could not launch \(target.name)"))
        }
      }
    }
    guard poller.wait(10, until: { outcome != nil }), let outcome else {
      throw ProviderError("Could not launch \(target.name)")
    }
    return try outcome.get()
  }
}
