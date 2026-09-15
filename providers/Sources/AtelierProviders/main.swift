import Foundation
import Providers

MainActor.assumeIsolated {
  do {
    try runProviders()
  } catch {
    fputs("atelier-providers: \(error.localizedDescription)\n", stderr)
    exit(EXIT_FAILURE)
  }
}
