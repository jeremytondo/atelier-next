import AtelierEngine
import Foundation

MainActor.assumeIsolated {
  do {
    try runAtelierEngine()
  } catch {
    fputs("Atelier engine: \(error.localizedDescription)\n", stderr)
    exit(EXIT_FAILURE)
  }
}
