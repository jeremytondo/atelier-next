import Foundation

/// WindowServer's representative window for a full-screen or Split View
/// Space. A Split View target must belong to a tile of that same Space; no
/// app-name or window-title guessing is allowed.
struct FullScreenWindow: Sendable, Equatable {
  let id: UInt32
  let app: pid_t

  static func read(space: UInt64, on display: String, from raw: [[String: Any]])
    -> FullScreenWindow?
  {
    guard let screen = raw.first(where: { $0["Display Identifier"] as? String == display }),
      let spaces = screen["Spaces"] as? [[String: Any]],
      let target = spaces.first(where: { DisplaySpaces.id(of: $0) == space }),
      (target["type"] as? NSNumber)?.intValue == 4,
      let window = owner(target),
      let layout = target["TileLayoutManager"] as? [String: Any],
      let tiles = layout["TileSpaces"] as? [[String: Any]],
      tiles.contains(where: {
        owner($0) == window
          && ($0["ManagedSpaceID"] as? NSNumber)?.uint64Value == space
          && ($0["TileWindowID"] as? NSNumber)?.uint64Value == UInt64(window.id)
      })
    else { return nil }
    return window
  }

  private static func owner(_ raw: [String: Any]) -> FullScreenWindow? {
    guard let id = raw["fs_wid"] as? NSNumber,
      let window = UInt32(exactly: id.int64Value), window != 0,
      let pid = raw["pid"] as? NSNumber,
      let app = pid_t(exactly: pid.int64Value), app > 0
    else { return nil }
    return FullScreenWindow(id: window, app: app)
  }
}
