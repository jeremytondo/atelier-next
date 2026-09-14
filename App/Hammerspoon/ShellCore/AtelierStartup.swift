// Startup authorization is independent of JS lifetime. Only the startup flow
// warns about competitors; reloads and permission help cannot start it twice.
struct AtelierStartup {
    enum Phase: Equatable { case idle, onboarding, conflict, ready, quitting }
    private(set) var phase = Phase.idle
    private var warn = false

    mutating func begin(completed: Bool, runningCompetitor: Bool, suppressWarning: Bool) {
        guard phase == .idle else { return }
        warn = runningCompetitor && !suppressWarning
        phase = completed ? (warn ? .conflict : .ready) : .onboarding
    }

    mutating func completeOnboarding() {
        guard phase == .onboarding else { return }
        phase = warn ? .conflict : .ready
    }

    mutating func resolveConflict(continueAnyway: Bool) {
        guard phase == .conflict else { return }
        phase = continueAnyway ? .ready : .quitting
    }
}
