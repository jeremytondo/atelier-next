import AppKit
import AtelierKit
import SwiftUI

struct WindowListView: View {
  let model: WindowListModel
  let config: ConfigModel

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      content.frame(maxWidth: .infinity, alignment: .leading)
      Divider()
      ConfigView(model: config)
      Divider()
      HStack {
        Button("Refresh") { Task { await model.refresh() } }
        Spacer()
        Button("Quit Atelier") { NSApp.terminate(nil) }
      }
    }
    .padding()
    .frame(width: 360)
  }

  @ViewBuilder private var content: some View {
    switch model.state {
    case .loading:
      ProgressView()
    case .loaded(.desktop(let windows, _)) where windows.isEmpty:
      Text("No windows on this Desktop.").foregroundStyle(.secondary)
    case .loaded(.desktop(let windows, _)):
      VStack(alignment: .leading, spacing: 6) {
        Text("Current Desktop").font(.headline)
        ForEach(windows) { WindowRow(window: $0) }
      }
    case .loaded(.notDesktop):
      Text(WindowList.notDesktopMessage).foregroundStyle(.secondary)
    case .needsAccessibility:
      VStack(alignment: .leading, spacing: 8) {
        Label("Accessibility permission needed", systemImage: "exclamationmark.triangle")
          .font(.headline)
        Text(
          "Atelier reads other apps' windows through Accessibility. Turn Atelier on in "
            + "System Settings, then choose Refresh."
        )
        .fixedSize(horizontal: false, vertical: true)
        Button("Open Accessibility Settings…") { model.requestAccessibility() }
      }
    case .failed(let message):
      Text(message).foregroundStyle(.secondary)
    }
  }
}

private struct WindowRow: View {
  let window: AtelierKit.Window

  var body: some View {
    HStack(spacing: 6) {
      Image(systemName: window.isFocused ? "circle.fill" : "circle")
        .imageScale(.small)
        .foregroundStyle(window.isFocused ? Color.accentColor : .secondary)
      Text(window.app).fontWeight(.medium)
      Text(window.title).foregroundStyle(.secondary).lineLimit(1)
    }
    .opacity(window.isVisible ? 1 : 0.5)
    .help(window.isVisible ? "" : "Minimized or hidden")
  }
}
