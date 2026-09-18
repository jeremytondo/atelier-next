import AtelierKit
import SwiftUI

/// The configuration's problems, until they are fixed, and reload and open.
struct ConfigView: View {
  let model: ConfigModel

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      if !model.problems.isEmpty {
        Label("Configuration problems", systemImage: "exclamationmark.triangle")
          .font(.headline)
        ForEach(model.problems, id: \.self) { problem in
          Text(problem.text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
        }
      }
      HStack {
        Button("Reload Configuration") { model.reload() }
        Button("Open Configuration…") { model.open() }
      }
      if let message = model.message {
        Text(message).font(.callout).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }
}
