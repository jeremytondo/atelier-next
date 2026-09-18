import MacOS

/// One window for as long as the Mac stays up: window and process numbers
/// come round again, but not together with the moment the process launched.
struct WindowIdentity: Hashable, Codable, Sendable {
  var app: Int32
  var id: UInt32
  /// Nil when macOS has no launch time for the app. Such a window is listed
  /// but never saved, since a later one could not be told from it.
  var launched: Double?

  init(_ window: WindowFacts) {
    app = window.app
    id = window.id
    launched = window.appLaunched
  }
}

public enum WindowMove: Hashable, Sendable {
  /// So many slots later, or earlier when negative.
  case by(Int)
  /// To this one-based slot.
  case toSlot(Int)
}

/// Every Desktop's windows in the order their numbers follow. Membership
/// follows macOS: a window is listed on every Desktop it belongs to, and each
/// list keeps its own order. Full-screen and Split View Spaces have no list.
///
/// A list starts with the focused window, then the visible ones front to
/// back, then the rest. After that only arrivals, which append, and closures
/// and departures, which close ranks, change it. Absence of evidence changes
/// nothing: a window stays while WindowServer lists it, unless its app says
/// it is gone or WindowServer places it elsewhere.
struct WindowLists: Equatable, Sendable {
  private(set) var byDesktop: [UInt64: [WindowIdentity]] = [:]

  mutating func reconcile(with snapshot: Snapshot, focused: UInt32?) {
    let open = Self.openWindows(in: snapshot)
    let census = Dictionary(open.map { (WindowIdentity($0), $0) }) { first, _ in first }
    // Apps describe only windows on shown Spaces, so a window already listed
    // anywhere is taken as ordinary wherever it turns up next.
    let known = Set(byDesktop.values.joined())
    let desktops = snapshot.displays.flatMap(\.spaces).filter(\.isDesktop).map(\.id)

    for desktop in desktops {
      let here = open.filter {
        $0.spaces.contains(desktop)
          && ($0.report == .ordinary || known.contains(WindowIdentity($0)))
      }
      guard var list = byDesktop[desktop] else {
        let rank = { (window: WindowFacts) in
          window.id == focused ? 0 : window.isOnScreen ? 1 : 2
        }
        // The sort is stable, so front-to-back order survives within each rank.
        byDesktop[desktop] = here.sorted { rank($0) < rank($1) }.map(WindowIdentity.init)
        continue
      }
      // Unknown membership is not a departure.
      list.removeAll { window in
        guard let facts = census[window] else { return true }
        return !facts.spaces.isEmpty && !facts.spaces.contains(desktop)
      }
      list += here.map(WindowIdentity.init).filter { !list.contains($0) }
      byDesktop[desktop] = list
    }
    byDesktop = byDesktop.filter { desktops.contains($0.key) && !$0.value.isEmpty }
  }

  /// WindowServer can keep a closed window listed. Its app leaving it out is
  /// proof only where the app would have listed it: on a Space being shown.
  private static func openWindows(in snapshot: Snapshot) -> [WindowFacts] {
    let shown = Set(snapshot.displays.map(\.currentSpace))
    return snapshot.windows.filter {
      !($0.report == .missing && !$0.isOnScreen && !shown.isDisjoint(with: $0.spaces))
    }
  }

  /// Starts from lists saved by an earlier run. Space numbers come round
  /// again after a restart, so a saved list is believed only when one of its
  /// windows is still open and still on that Desktop. Windows that have
  /// closed are dropped, not waited for.
  mutating func restore(
    _ saved: [UInt64: [WindowIdentity]], with snapshot: Snapshot, focused: UInt32?
  ) {
    let census = Dictionary(Self.openWindows(in: snapshot).map { (WindowIdentity($0), $0) }) {
      first, _ in first
    }
    byDesktop = saved.compactMapValues { windows in
      var seen = Set<WindowIdentity>()
      let open = windows.filter { census[$0] != nil && seen.insert($0).inserted }
      return open.isEmpty ? nil : open
    }.filter { desktop, windows in
      windows.contains { census[$0]?.spaces.contains(desktop) == true }
    }
    reconcile(with: snapshot, focused: focused)
  }

  /// False when nothing moved: the window is not listed there, or is already
  /// in the slot the move comes to once held within the list.
  mutating func move(_ window: WindowIdentity, on desktop: UInt64, _ move: WindowMove) -> Bool {
    guard var list = byDesktop[desktop], let from = list.firstIndex(of: window) else {
      return false
    }
    // Held within the list before any arithmetic, so no number is too large.
    let last = list.count - 1
    let to =
      switch move {
      case .by(let offset): from + min(max(offset, -from), last - from)
      case .toSlot(let slot): min(max(slot, 1), list.count) - 1
      }
    guard to != from else { return false }
    list.insert(list.remove(at: from), at: to)
    byDesktop[desktop] = list
    return true
  }

  mutating func forget(desktop: UInt64) {
    byDesktop[desktop] = nil
  }
}
