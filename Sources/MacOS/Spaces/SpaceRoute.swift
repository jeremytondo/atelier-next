/// The key presses that take a display from its current Space to another.
///
/// macOS offers "Switch to Desktop N" for the first sixteen Desktops, numbered
/// across all displays in WindowServer's order and skipping full-screen and
/// Split View Spaces, and previous and next, which step through every kind of
/// Space and stop at either end. So any Space is a jump to a numbered Desktop,
/// or none, and then steps; the route with the fewest presses wins.
///
/// Each of those shortcuts can be switched off in Keyboard settings, and a
/// route is made only of the ones that are on, since pressing one that is off
/// does nothing. Many people have the numbered ones off.
///
/// Stepping acts on the display under the pointer, which need not be the one
/// with the keyboard, so with several displays only a jump alone will do.
enum SpaceRoute {
  enum Press: Equatable {
    case previous, next
    case desktop(Int)
  }

  static let lastNumberedDesktop = 16

  private struct Route {
    /// The Desktop number to jump to first and its place among the Spaces.
    var jump: (number: Int, index: Int)?
    /// Steps after that: later when positive, earlier when negative.
    var steps: Int
    var presses: Int { abs(steps) + (jump == nil ? 0 : 1) }
  }

  /// Each press with the Space it should arrive at. Empty when already there;
  /// nil when the target is unknown, no route is safe, or every route needs a
  /// shortcut that `isOn` says is switched off.
  static func plan(
    to target: UInt64, on displayID: String, in displays: [DisplaySpaces],
    isOn: (Press) -> Bool
  ) -> [(press: Press, arrivesAt: UInt64)]? {
    guard let display = displays.first(where: { $0.id == displayID }),
      let to = display.spaces.firstIndex(where: { $0.id == target }),
      let from = display.spaces.firstIndex(where: { $0.id == display.currentSpace })
    else { return nil }

    var routes: [Route] = []
    var number = 0
    for other in displays {
      for (index, space) in other.spaces.enumerated() where space.isDesktop {
        number += 1
        if other.id == displayID, number <= lastNumberedDesktop, index != from,
          isOn(.desktop(number))
        {
          routes.append(Route(jump: (number, index), steps: to - index))
        }
      }
    }
    routes.append(Route(jump: nil, steps: to - from))
    let usable = routes.filter { route in
      (displays.count == 1 || route.steps == 0)
        && (route.steps == 0 || isOn(route.steps > 0 ? .next : .previous))
    }
    guard let route = usable.min(by: { $0.presses < $1.presses }) else { return nil }

    var plan: [(Press, UInt64)] = []
    var index = from
    if let jump = route.jump {
      plan.append((.desktop(jump.number), display.spaces[jump.index].id))
      index = jump.index
    }
    while index != to {
      index += route.steps > 0 ? 1 : -1
      plan.append((route.steps > 0 ? .next : .previous, display.spaces[index].id))
    }
    return plan
  }
}
