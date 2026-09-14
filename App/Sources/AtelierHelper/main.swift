import AtelierEngine
import Foundation

// The isolated bundle probe exercises real HS2 process I/O against a stub
// instead of the engine, so it never needs permissions or mutates macOS.
if Array(CommandLine.arguments.dropFirst()) == ["--self-test-helper"],
  ProcessInfo.processInfo.environment["ATELIER_CONFIG_DIR"] != nil
{
  HelperProtocol.runSelfTest()
}

MainActor.assumeIsolated {
  do {
    try runAtelierEngine()
  } catch {
    fputs("Atelier engine: \(error.localizedDescription)\n", stderr)
    exit(EXIT_FAILURE)
  }
}
