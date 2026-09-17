import Foundation

extension DisplaySpaces {
  /// Reads the undocumented dictionaries SLSCopyManagedDisplaySpaces returns.
  /// A Desktop is type 0 with no TileLayoutManager; full-screen and Split View
  /// Spaces are type 4 and carry one.
  static func decode(_ rawDisplays: [[String: Any]]) -> [DisplaySpaces] {
    rawDisplays.compactMap { rawDisplay in
      guard let current = rawDisplay["Current Space"] as? [String: Any],
        let currentSpace = id(of: current),
        let rawSpaces = rawDisplay["Spaces"] as? [[String: Any]]
      else { return nil }
      let spaces = rawSpaces.compactMap { rawSpace in
        id(of: rawSpace).map { id in
          Space(
            id: id,
            isDesktop: (rawSpace["type"] as? NSNumber)?.intValue == 0
              && rawSpace["TileLayoutManager"] == nil)
        }
      }
      return DisplaySpaces(currentSpace: currentSpace, spaces: spaces)
    }
  }

  private static func id(of rawSpace: [String: Any]) -> UInt64? {
    ((rawSpace["ManagedSpaceID"] ?? rawSpace["id64"]) as? NSNumber)?.uint64Value
  }
}
