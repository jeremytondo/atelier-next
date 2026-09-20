import Foundation

extension DisplaySpaces {
  /// Reads the undocumented dictionaries SLSCopyManagedDisplaySpaces returns.
  /// A Desktop is type 0 with no TileLayoutManager; full-screen and Split View
  /// Spaces are type 4 and carry one.
  ///
  /// Empty unless every display and Space could be read: places in the list
  /// are what Desktops are moved by, so a list with a gap is worse than none.
  static func decode(_ rawDisplays: [[String: Any]]) -> [DisplaySpaces] {
    var displays: [DisplaySpaces] = []
    for rawDisplay in rawDisplays {
      guard let display = rawDisplay["Display Identifier"] as? String,
        let current = rawDisplay["Current Space"] as? [String: Any],
        let currentSpace = id(of: current),
        let rawSpaces = rawDisplay["Spaces"] as? [[String: Any]]
      else { return [] }
      var spaces: [Space] = []
      for rawSpace in rawSpaces {
        guard let id = id(of: rawSpace), let type = (rawSpace["type"] as? NSNumber)?.intValue
        else { return [] }
        spaces.append(Space(id: id, isDesktop: type == 0 && rawSpace["TileLayoutManager"] == nil))
      }
      guard spaces.contains(where: { $0.id == currentSpace }) else { return [] }
      displays.append(DisplaySpaces(id: display, currentSpace: currentSpace, spaces: spaces))
    }
    let ids = displays.flatMap(\.spaces).map(\.id)
    return Set(ids).count == ids.count ? displays : []
  }

  /// A name for each full-screen and Split View Space: its app's, and the two
  /// of a Split View joined as Dock joins them. A Desktop has no entry, and
  /// neither has a Space none of whose apps could be named.
  ///
  /// Mission Control shows the window's title instead, and these dictionaries
  /// carry it, with the app's name, but only for a process allowed to record
  /// the screen. Atelier never asks for that, so it goes by the tile's process,
  /// which is always there, and everyone sees the same names.
  static func names(_ rawDisplays: [[String: Any]], appName: (pid_t) -> String?)
    -> [UInt64: String]
  {
    var names: [UInt64: String] = [:]
    for rawDisplay in rawDisplays {
      for rawSpace in rawDisplay["Spaces"] as? [[String: Any]] ?? [] {
        guard let id = id(of: rawSpace),
          let layout = rawSpace["TileLayoutManager"] as? [String: Any],
          let tiles = layout["TileSpaces"] as? [[String: Any]]
        else { continue }
        let apps = tiles.compactMap { tile in
          (tile["pid"] as? NSNumber).flatMap { pid_t(exactly: $0.int64Value) }.flatMap(appName)
        }
        if !apps.isEmpty { names[id] = apps.joined(separator: " & ") }
      }
    }
    return names
  }

  static func id(of rawSpace: [String: Any]) -> UInt64? {
    ((rawSpace["ManagedSpaceID"] ?? rawSpace["id64"]) as? NSNumber)?.uint64Value
  }
}
