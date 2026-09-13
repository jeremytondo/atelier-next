import AppKit
import AtelierCore

/// Opt-in local smoke-test transport. Not started in ordinary app launches.
/// Commands are a fixed allowlist; requests never evaluate code.
@MainActor
final class DiagnosticControl {
  private var timer: Timer?
  private var lastID = ""
  private var busy = false
  private let controller: Controller
  private let directory: URL
  var capture: ((Int) throws -> String)?
  init(controller: Controller) {
    self.controller = controller
    directory = controller.settings.stateDirectory.appendingPathComponent(
      "diagnostic-control", isDirectory: true)
    try? FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    if let data = try? Data(contentsOf: directory.appendingPathComponent("request.json")),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    {
      lastID = object["id"] as? String ?? ""
    }
    let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.poll() }
    }
    self.timer = timer
    RunLoop.main.add(timer, forMode: .common)
  }
  private func poll() {
    guard !busy, let data = try? Data(contentsOf: directory.appendingPathComponent("request.json")),
      data.count < 65_536,
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let id = object["id"] as? String,
      id != lastID, let command = object["command"] as? String
    else { return }
    lastID = id
    busy = true
    Task {
      defer { busy = false }
      var response: [String: Any] = ["id": id]
      do {
        var action: Command?
        switch command {
        case "status": break
        case "start": await controller.start()
        case "pause": controller.pause()
        case "reload":
          await controller.reloadConfiguration()
          if let error = controller.configurationError { throw AppError(error) }
        case "group": action = .group
        case "select": action = .select(object["number"] as? Int ?? 1)
        case "cycle": action = .cycle(object["offset"] as? Int ?? 1)
        case "switch": action = .desktop(object["number"] as? Int ?? 1)
        case "create": action = .create
        case "reorder": action = .reorder(object["offset"] as? Int ?? 1)
        case "delete": action = .delete
        case "quickApp":
          guard
            let app = controller.settings.configuration.quickApps.first(where: {
              $0.app == object["app"] as? String || $0.id.uuidString == object["app"] as? String
            })
          else { throw AppError("Unknown configured Quick App.") }
          action = .quick(app.id)
        case "capture": response["capture"] = try capture?(object["tab"] as? Int ?? 0)
        default: throw AppError("Unknown diagnostic command.")
        }
        if let action { try await controller.diagnosticPerform(action) }
        response["ok"] = true
        response["result"] = try JSONSerialization.jsonObject(with: controller.diagnosticData())
      } catch {
        response["ok"] = false
        response["error"] = error.localizedDescription
      }
      if let data = try? JSONSerialization.data(
        withJSONObject: response, options: [.prettyPrinted, .sortedKeys])
      {
        try? data.write(to: directory.appendingPathComponent("response.json"), options: .atomic)
      }
    }
  }
  func stop() {
    timer?.invalidate()
    timer = nil
  }
}
