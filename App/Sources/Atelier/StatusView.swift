import AppKit
import ServiceManagement
import SwiftUI

/// Operational status and permission guidance. Configuration belongs to files.
struct StatusView: View {
  @ObservedObject var controller: Controller
  @ObservedObject var settings: ConfigurationStore
  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      HStack {
        Image(systemName: "rectangle.3.group.fill").font(.system(size: 28))
        VStack(alignment: .leading) {
          Text("Atelier").font(.title2.bold())
          Text(controller.state).foregroundStyle(controller.running ? .green : .secondary)
        }
        Spacer()
        Button(controller.running ? "Pause" : "Resume") {
          if controller.running { controller.pause() } else { Task { await controller.start() } }
        }.disabled(controller.state == "Starting" || controller.reloading)
      }
      if !controller.accessibility {
        Text(
          "Enable Atelier in System Settings → Privacy & Security → Accessibility, then press Resume."
        )
        Button("Open Accessibility Settings") { controller.requestAccessibility() }
      }
      if let error = controller.lastError {
        Text(error).foregroundStyle(.red).textSelection(.enabled)
      }
      if let error = controller.configurationError {
        Text("Configuration was not applied. \(error)").foregroundStyle(.red).textSelection(
          .enabled)
      }
      VStack(alignment: .leading, spacing: 8) {
        Text("Configuration").font(.headline)
        Text(settings.url.path).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
        Text("Save your edits, then reload when you’re ready.").foregroundStyle(.secondary)
        HStack {
          Button("Open Configuration") { settings.openConfiguration() }
          Button("Reload Configuration") { Task { await controller.reloadConfiguration() } }
            .disabled(controller.reloading || controller.state == "Starting")
          Button("Reference") { settings.openReference() }
        }
        if let message = settings.message, controller.configurationError == nil {
          Text(message).font(.callout).textSelection(.enabled)
        }
      }
      ForEach(settings.configuration.quickApps.filter { controller.quickErrors[$0.id] != nil }) {
        app in
        Text("\(app.configName ?? app.app): \(controller.quickErrors[app.id] ?? "")")
          .font(.callout).foregroundStyle(.red).textSelection(.enabled)
      }
      Divider()
      LabeledContent("Launch at login", value: settings.loginStatus)
      if SMAppService.mainApp.status == .requiresApproval {
        Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() }
      }
      HStack {
        Text("Groups last until Atelier quits.").font(.caption).foregroundStyle(.secondary)
        Spacer()
        Button("Export Diagnostics…") { controller.exportDiagnostics() }
      }
    }.padding(24).frame(minWidth: 640).fixedSize(horizontal: false, vertical: true)
  }
}
