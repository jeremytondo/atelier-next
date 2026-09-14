import Foundation
import SpaceControlCore
import Testing
@testable import Trial

private func space(_ id: UInt64, _ type: UInt64 = 0) -> ManagedSpaceSnapshot {
  ManagedSpaceSnapshot(id: id, isFullscreen: type == 4, rawType: type)
}
private func display(_ spaces: [ManagedSpaceSnapshot], _ name: String = "A", current: UInt64 = 1) -> DisplaySpaceSnapshot {
  DisplaySpaceSnapshot(identifier: name, currentSpaceID: current, spaces: spaces)
}

@Test func automaticSelectionRequiresTheSameUnambiguousDisplayAsExplicitSelection() throws {
  let one = [display([space(1)])]
  #expect(try Creation.targetDisplay(requested: nil, screenCount: 1, census: one) == "A")
  #expect(try Creation.targetDisplay(requested: "A", screenCount: 1, census: one) == "A")
  for (requested, screens, census) in [
    (nil, 0, one), (nil, 2, one), (nil, 1, []),
    (nil, 1, one + [display([space(10)], "B", current: 10)]), ("B", 1, one),
  ] as [(String?, Int, [DisplaySpaceSnapshot])] {
    #expect(throws: TrialError.self) { try Creation.targetDisplay(requested: requested, screenCount: screens, census: census) }
  }
}

@Test func refreshRequiresCompletedQuietCallbacksAndFreshState() {
  var readiness = DisplayRefreshReadiness()
  #expect(!readiness.isReady(at: 10, stateMatches: true))
  readiness.record(display: 27, beginning: true, at: 10)
  readiness.record(display: 3, beginning: true, at: 10)
  readiness.record(display: 27, beginning: false, at: 10.01)
  #expect(!readiness.isReady(at: 11, stateMatches: true)) // other display is still pending
  readiness.record(display: 3, beginning: false, at: 11)
  #expect(!readiness.isReady(at: 11.02, stateMatches: true))
  #expect(!readiness.isReady(at: 11.1, stateMatches: false)) // counts/modes still disagree
  #expect(readiness.isReady(at: 11.1, stateMatches: true))
  readiness.record(display: 27, beginning: true, at: 11.11) // release starts a second batch
  #expect(!readiness.isReady(at: 12, stateMatches: true))
  readiness.record(display: 27, beginning: false, at: 12)
  #expect(!readiness.isReady(at: 12.01, stateMatches: true))
  #expect(readiness.isReady(at: 12.1, stateMatches: true))
}

@Test func creationRequiresAnExactInactiveTypeZeroAddition() {
  let original = [display([space(1), space(90, 4), space(2)])]
  let cases: [(String, UInt64, String, [DisplaySpaceSnapshot], Observation)] = [
    ("delayed census", 3, "A", original, .pending),
    ("ordinary", 3, "A", [display([space(1), space(90, 4), space(2), space(3)])], .verified),
    ("wrong ID", 7, "A", [display([space(1), space(90, 4), space(2), space(3)])], .rejected("Ambiguous addition or wrong returned ID")),
    ("ambiguous", 3, "A", [display([space(1), space(90, 4), space(2), space(3), space(4)])], .rejected("Ambiguous addition or wrong returned ID")),
    ("unknown type", 3, "A", [display([space(1), space(90, 4), space(2), space(3, 2)])], .rejected("Created Space is not a managed type-0 Desktop")),
    ("fullscreen", 3, "A", [display([space(1), space(90, 4), space(2), space(3, 4)])], .rejected("Created Space is not a managed type-0 Desktop")),
    ("missing type", 3, "A", [display([space(1), space(90, 4), space(2), ManagedSpaceSnapshot(id: 3, isFullscreen: false)])], .rejected("Created Space is not a managed type-0 Desktop")),
    ("activation", 3, "A", [display([space(1), space(90, 4), space(2), space(3)], current: 3)], .rejected("Creation changed the active Space or raced with native input")),
    ("native reorder", 3, "A", [display([space(2), space(1), space(90, 4), space(3)])], .rejected("Existing Space order, type, or display membership changed")),
    ("native deletion", 3, "A", [display([space(1), space(90, 4), space(3)])], .rejected("Existing Space order, type, or display membership changed")),
    ("existing ID", 1, "A", original, .rejected("Returned ID existed before the request")),
    ("capacity/nil ID", 0, "A", original, .rejected("No returned ID; mutation outcome is uncertain")),
    ("display disconnected", 3, "A", [], .rejected("Target display absent or display configuration changed")),
  ]
  for (name, id, target, after, expected) in cases {
    #expect(Creation.observe(id: id, display: target, before: original, after: after) == expected, "\(name)")
  }
}

@Test func multipleDisplaysRequireCorrectPlacementAndNoChangesElsewhere() {
  let before = [display([space(1)]), display([space(10)], "B", current: 10)]
  let after = [display([space(1)]), display([space(10), space(11)], "B", current: 10)]
  #expect(Creation.observe(id: 11, display: "B", before: before, after: after) == .verified)
  #expect(Creation.observe(id: 11, display: "A", before: before, after: after) == .rejected("Created on the wrong display"))
  let ambiguous = [display([space(1), space(2)]), display([space(10), space(11)], "B", current: 10)]
  #expect(Creation.observe(id: 11, display: "B", before: before, after: ambiguous) == .rejected("Ambiguous addition or wrong returned ID"))
}

@Test func strictDecoderRejectsPartialAndMalformedEvidence() throws {
  func raw(_ spaces: [[String: Any]]) -> [[String: Any]] {
    [["Display Identifier": "A", "Current Space": ["id64": 1], "Spaces": spaces]]
  }
  #expect(try Creation.decode(raw([["id64": 1, "type": 0]]))[0].spaces[0].rawType == 0)
  for invalid in [
    [["id64": 1]], [["id64": 1, "type": true]], [["id64": 1.5, "type": 0]],
    [["id64": -1, "type": 0]], [["id64": 1, "type": 0], ["id64": 1, "type": 0]],
    [["id64": 1, "ManagedSpaceID": 2, "type": 0]], [["id64": 2, "type": 0]],
  ] as [[[String: Any]]] {
    #expect(throws: TrialError.self) { try Creation.decode(raw(invalid)) }
  }
}

@Test func intentSurvivesRestartAndCannotBeReplayed() throws {
  let parent = FileManager.default.temporaryDirectory.appendingPathComponent("ate-40-test-\(UUID())")
  try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
  defer { try? FileManager.default.removeItem(at: parent) }
  let path = parent.appendingPathComponent("run").path
  let first = try Journal(path: path, create: true)
  try first.write("intent.json", ["mayApplyAfterInterruption": true])
  #expect(throws: TrialError.self) { try Journal(path: path, create: true) }
  let resumed = try Journal(path: path, create: false)
  #expect(try resumed.read("intent.json")["mayApplyAfterInterruption"] as? Bool == true)
  #expect(throws: TrialError.self) { try resumed.write("intent.json", [:]) }
  try resumed.write("dispatch.json", ["createdID": "18446744073709551614"])
  #expect(try resumed.read("dispatch.json")["createdID"] as? String == "18446744073709551614")
}

@Test func cleanupRejectsExclusiveMinimizedUnknownAndChangedOccupants() {
  let before: [String: [NSNumber]] = ["42": [1]]
  let identity: [String: [String: Any]] = ["42": ["pid": 10]]
  #expect(Cleanup.retainsBaseline(window: ["id": 42, "pid": 10, "spaces": [1, 3]], ownedID: 3,
    baselineMemberships: before, baselineWindows: identity))
  for window in [
    ["id": 42, "pid": 10, "spaces": [3], "minimized": true],
    ["id": 43, "pid": 10, "spaces": [1, 3]],
    ["id": 42, "pid": 11, "spaces": [1, 3]],
    ["id": 42, "pid": 10, "spaces": [2, 3]],
    ["id": 42, "pid": 10],
  ] as [[String: Any]] {
    #expect(!Cleanup.retainsBaseline(window: window, ownedID: 3,
      baselineMemberships: before, baselineWindows: identity))
  }
}
