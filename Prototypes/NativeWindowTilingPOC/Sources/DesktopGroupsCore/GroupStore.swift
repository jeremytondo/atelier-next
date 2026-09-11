import Foundation

public struct GroupKey: Hashable, Sendable, CustomStringConvertible {
    public let spaceID: UInt64
    public let displayID: String

    public init(spaceID: UInt64, displayID: String) {
        self.spaceID = spaceID
        self.displayID = displayID
    }

    public var description: String {
        "space=\(spaceID) display=\(displayID)"
    }
}

public struct WindowKey: Hashable, Sendable, CustomStringConvertible {
    public let processID: Int32
    public let windowID: UInt32

    public init(processID: Int32, windowID: UInt32) {
        self.processID = processID
        self.windowID = windowID
    }

    public var description: String {
        "pid=\(processID) window=\(windowID)"
    }
}

public enum FillResult: Equatable, Sendable {
    case notAttempted
    case deferred
    case succeeded
    case unavailable(String)
    case failed(String)

    /// Whether activating this member should enforce Fill. A successful member
    /// only needs another dispatch after its frame changes; unavailable and
    /// failed commands wait for an explicit forced repair instead of being
    /// retried on every selection.
    public func shouldAttemptFill(
        force: Bool,
        recordedFrameMatchesCurrent: Bool?
    ) -> Bool {
        if force { return true }

        switch self {
        case .notAttempted, .deferred:
            return true
        case .succeeded:
            return recordedFrameMatchesCurrent != true
        case .unavailable, .failed:
            return false
        }
    }
}

public struct GroupMember: Equatable, Sendable {
    public let key: WindowKey
    public var lastFillResult: FillResult

    public init(key: WindowKey, lastFillResult: FillResult = .notAttempted) {
        self.key = key
        self.lastFillResult = lastFillResult
    }
}

public struct WindowGroup: Equatable, Sendable {
    public let key: GroupKey
    public fileprivate(set) var members: [GroupMember]
    public fileprivate(set) var activeIndex: Int?

    public var activeMember: GroupMember? {
        guard let activeIndex, members.indices.contains(activeIndex) else { return nil }
        return members[activeIndex]
    }
}

/// Session-only ordered state. Runtime window discovery remains outside this
/// type so compaction and Hyprland-style member indexing are deterministic and
/// unit testable without Accessibility or WindowServer access.
public struct GroupStore: Sendable {
    public private(set) var groups: [GroupKey: WindowGroup] = [:]

    public init() {}

    @discardableResult
    public mutating func createOrRepair(
        key: GroupKey,
        focused: WindowKey,
        eligibleFrontToBack: [WindowKey]
    ) -> WindowGroup {
        let candidates = unique(eligibleFrontToBack.filter { $0 != focused })

        if var group = groups[key] {
            let eligible = Set(candidates + [focused])
            let activeKey = group.activeMember?.key
            group.members.removeAll { !eligible.contains($0.key) }

            let existing = Set(group.members.map(\.key))
            for candidate in candidates + [focused] where !existing.contains(candidate) {
                group.members.append(GroupMember(key: candidate, lastFillResult: .deferred))
            }

            group.activeIndex = index(of: focused, in: group.members)
                ?? activeKey.flatMap { index(of: $0, in: group.members) }
            groups[key] = group
            return group
        }

        let memberKeys = [focused] + candidates
        let members = memberKeys.enumerated().map { index, member in
            GroupMember(key: member, lastFillResult: index == 0 ? .notAttempted : .deferred)
        }
        let group = WindowGroup(
            key: key,
            members: members,
            activeIndex: 0
        )
        groups[key] = group
        return group
    }

    @discardableResult
    public mutating func reconcile(
        key: GroupKey,
        eligibleFrontToBack: [WindowKey]
    ) -> WindowGroup? {
        guard var group = groups[key] else { return nil }
        let candidates = unique(eligibleFrontToBack)
        let eligible = Set(candidates)
        let activeKey = group.activeMember?.key

        group.members.removeAll { !eligible.contains($0.key) }
        var existing = Set(group.members.map(\.key))
        for candidate in candidates where existing.insert(candidate).inserted {
            group.members.append(GroupMember(key: candidate, lastFillResult: .deferred))
        }

        group.activeIndex = activeKey.flatMap { index(of: $0, in: group.members) }
        groups[key] = group
        return group
    }

    @discardableResult
    public mutating func activate(_ member: WindowKey, in key: GroupKey) -> Int? {
        guard var group = groups[key], let memberIndex = index(of: member, in: group.members) else {
            return nil
        }
        group.activeIndex = memberIndex
        groups[key] = group
        return memberIndex
    }

    @discardableResult
    public mutating func select(index: Int, in key: GroupKey) -> GroupMember? {
        guard var group = groups[key], group.members.indices.contains(index) else { return nil }
        group.activeIndex = index
        groups[key] = group
        return group.members[index]
    }

    @discardableResult
    public mutating func select(offset: Int, in key: GroupKey) -> GroupMember? {
        guard var group = groups[key], !group.members.isEmpty else { return nil }
        let current = group.activeIndex ?? 0
        let count = group.members.count
        let destination = ((current + offset) % count + count) % count
        group.activeIndex = destination
        groups[key] = group
        return group.members[destination]
    }

    public mutating func recordFill(
        _ result: FillResult,
        for member: WindowKey,
        in key: GroupKey
    ) {
        guard var group = groups[key], let memberIndex = index(of: member, in: group.members) else {
            return
        }
        group.members[memberIndex].lastFillResult = result
        groups[key] = group
    }

    private func index(of member: WindowKey, in members: [GroupMember]) -> Int? {
        members.firstIndex { $0.key == member }
    }

    private func unique(_ keys: [WindowKey]) -> [WindowKey] {
        var seen: Set<WindowKey> = []
        return keys.filter { seen.insert($0).inserted }
    }
}
