import Foundation

public struct ManagedSpaceSnapshot: Equatable, Sendable {
  public let id: UInt64
  public let isFullscreen: Bool
  /// Preserve the native type for callers that require positive type-0 evidence.
  public let rawType: UInt64?

  public init(id: UInt64, isFullscreen: Bool, rawType: UInt64? = nil) {
    self.id = id
    self.isFullscreen = isFullscreen
    self.rawType = rawType
  }
}

public struct DisplaySpaceSnapshot: Equatable, Sendable {
  public let identifier: String
  public let currentSpaceID: UInt64
  public let spaces: [ManagedSpaceSnapshot]

  public init(identifier: String, currentSpaceID: UInt64, spaces: [ManagedSpaceSnapshot]) {
    self.identifier = identifier
    self.currentSpaceID = currentSpaceID
    self.spaces = spaces
  }

  public var regularDesktops: [ManagedSpaceSnapshot] {
    spaces.filter { !$0.isFullscreen }
  }
}

public enum SpaceTopology {
  /// Converts the undocumented dictionaries returned by
  /// SLSCopyManagedDisplaySpaces into this deliberately small model. A
  /// TileLayoutManager marks a full-screen/tiled Space.
  public static func decode(_ rawDisplays: [[String: Any]]) -> [DisplaySpaceSnapshot] {
    rawDisplays.compactMap { rawDisplay in
      guard let identifier = rawDisplay["Display Identifier"] as? String,
        let current = rawDisplay["Current Space"] as? [String: Any],
        let currentID = integer(current["ManagedSpaceID"] ?? current["id64"]),
        let rawSpaces = rawDisplay["Spaces"] as? [[String: Any]]
      else {
        return nil
      }

      let spaces = rawSpaces.compactMap { rawSpace -> ManagedSpaceSnapshot? in
        guard let id = integer(rawSpace["ManagedSpaceID"] ?? rawSpace["id64"]) else {
          return nil
        }
        let explicitFullscreen = integer(rawSpace["type"]) == 4
        return ManagedSpaceSnapshot(
          id: id,
          isFullscreen: explicitFullscreen || rawSpace["TileLayoutManager"] != nil,
          rawType: integer(rawSpace["type"])
        )
      }
      guard !spaces.isEmpty else { return nil }
      return DisplaySpaceSnapshot(
        identifier: identifier,
        currentSpaceID: currentID,
        spaces: spaces
      )
    }
  }

  public static func desktop(
    number: Int,
    on displayIdentifier: String,
    displays: [DisplaySpaceSnapshot]
  ) -> ManagedSpaceSnapshot? {
    guard number > 0,
      let display = displays.first(where: { $0.identifier == displayIdentifier }),
      display.regularDesktops.indices.contains(number - 1)
    else {
      return nil
    }
    return display.regularDesktops[number - 1]
  }

  /// macOS's symbolic "Switch to Desktop N" actions number regular
  /// Desktops across displays in the raw WindowServer display order.
  public static func globalDesktopNumber(
    for spaceID: UInt64,
    displays: [DisplaySpaceSnapshot]
  ) -> Int? {
    var number = 0
    for display in displays {
      for space in display.spaces {
        guard !space.isFullscreen else {
          if space.id == spaceID { return nil }
          continue
        }
        number += 1
        if space.id == spaceID { return number }
      }
    }
    return nil
  }

  private static func integer(_ value: Any?) -> UInt64? {
    switch value {
    case let value as NSNumber: value.uint64Value
    case let value as UInt64: value
    case let value as Int where value >= 0: UInt64(value)
    default: nil
    }
  }
}
