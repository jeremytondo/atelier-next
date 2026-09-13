import XCTest

@testable import AtelierCore

final class BehaviorTests: XCTestCase {
  private func window(_ id: UInt32, pid: Int32 = 10, space: String = "a") -> WindowRecord {
    WindowRecord(id: id, pid: pid, space: space, frame: WindowFrame(x: 10, y: 10, w: 800, h: 600))
  }
  private func snapshot(_ windows: [WindowRecord], focused: UInt32 = 2, current: String = "a")
    -> Snapshot
  {
    Snapshot(
      focused: focused, targetDisplay: "screen",
      displays: [
        DisplayRecord(
          id: "screen", current: current, spaces: [SpaceRecord(id: "a"), SpaceRecord(id: "b")])
      ], windows: windows)
  }
  func testGroupsPreserveOrderAppendArrivalsAndDropDepartures() throws {
    var store = GroupStore()
    let group = try store.group(snapshot([window(1), window(2), window(3)]))
    XCTAssertEqual(group.members.map(\.id), [2, 1, 3])
    store.reconcile(snapshot([window(4), window(3), window(2)]))
    XCTAssertEqual(store.current(snapshot([]))?.members.map(\.id), [2, 3, 4])
    store.reorder(group.key, member: window(4).key, offset: -1)
    store.reconcile(snapshot([window(2), window(3), window(4)]))
    XCTAssertEqual(store.current(snapshot([]))?.members.map(\.id), [2, 4, 3])
  }
  func testInactiveDesktopObservationsDoNotEraseMembers() throws {
    var store = GroupStore()
    let group = try store.group(snapshot([window(1), window(2)]))
    store.reconcile(snapshot([], current: "b"))
    XCTAssertEqual(store.groups[group.key]?.members.count, 2)
    var removed = snapshot([])
    removed.displays[0].spaces = [SpaceRecord(id: "b")]
    removed.displays[0].current = "b"
    store.reconcile(removed)
    XCTAssertTrue(store.groups.isEmpty)
  }
  func testWindowIdentityIncludesProcessAndFullscreenCannotGroup() throws {
    var store = GroupStore()
    _ = try store.group(snapshot([window(1), window(2)]))
    store.reconcile(snapshot([window(1, pid: 20), window(2)]))
    XCTAssertEqual(
      store.current(snapshot([]))?.members.map(\.key), [window(2).key, window(1, pid: 20).key])
    var full = snapshot([window(1)])
    full.displays[0].spaces[0].fullscreen = true
    XCTAssertThrowsError(try store.group(full))
  }
  func testQuickAppsAreExcludedBeforeReconciliation() throws {
    var s = snapshot([window(1), window(2)])
    s.windows[0].bundleID = "calculator"
    s.exclude(["calculator"])
    var store = GroupStore()
    XCTAssertEqual(try store.group(s).members.map(\.id), [2])
  }
  func testOperationGateRejectsOverlapAndIgnoresStaleCompletion() {
    var gate = OperationGate()
    let old = gate.begin("create")!
    XCTAssertNil(gate.begin("delete"))
    gate.invalidate()
    let new = gate.begin("quick")!
    gate.end(old)
    XCTAssertEqual(gate.active, "quick")
    gate.end(new)
    XCTAssertNil(gate.active)
  }
  func testFillWaitsForAnimationAndQuietAccessibilityEvents() {
    let initial = WindowFrame(x: 30, y: 30, w: 800, h: 600)
    let final = WindowFrame(x: 0, y: 0, w: 1400, h: 1000)
    var settle = FillSettlement(frame: initial, now: 0)
    XCTAssertFalse(settle.sample(initial, eventAt: 0, now: 0.1))
    XCTAssertFalse(settle.sample(final, eventAt: 0.2, now: 0.2))
    XCTAssertFalse(settle.sample(final, eventAt: 0.29, now: 0.3))
    XCTAssertFalse(settle.sample(final, eventAt: 0.29, now: 0.35))
    XCTAssertTrue(settle.sample(final, eventAt: 0.29, now: 0.41))
    var unchanged = FillSettlement(frame: initial, now: 1)
    XCTAssertFalse(unchanged.sample(initial, eventAt: 0, now: 1.2))
    XCTAssertTrue(unchanged.sample(initial, eventAt: 0, now: 1.31))
  }
  func testImportPreservesConfiguredShortcutAndSizeWithoutExecutingCode() throws {
    let source = """
      // Prototype config
      module.exports = [
        {app: 'Calculator', shortcut: 'cmd-shift-c'},
        // optional app
        {app: "com.example.app", shortcut: 'ctrl-option-left-bracket', size: {width: 900, height: 650}},
      ];
      """
    let imported = try QuickAppImporter.parse(source)
    XCTAssertEqual(imported.count, 2)
    XCTAssertEqual(imported[0].shortcut, try Shortcut("command-shift-c"))
    XCTAssertEqual(imported[1].size, QuickApp.Size(width: 900, height: 650))
    XCTAssertThrowsError(try QuickAppImporter.parse("module.exports = require('secrets');"))
    XCTAssertThrowsError(
      try QuickAppImporter.parse(
        "module.exports = [{ app: (() => 'Calculator')(), shortcut: 'cmd-c' }];"))
    XCTAssertThrowsError(try QuickAppImporter.parse("run(); module.exports = [];"))
  }
  func testConfigurationRejectsInvalidValuesAndRoundTrips() throws {
    var config = AppConfiguration()
    config.quickApps = [QuickApp(app: "Calculator", shortcut: try Shortcut("cmd-shift-c"))]
    let decoded = try JSONDecoder().decode(
      AppConfiguration.self, from: JSONEncoder().encode(config))
    XCTAssertEqual(decoded, config)
    config.quickApps[0].size = .init(width: -1, height: 300)
    XCTAssertThrowsError(try config.validate())
    XCTAssertThrowsError(try Shortcut("ctrl-ctrl-c"))
    XCTAssertThrowsError(try Shortcut("c"))
    config.schemaVersion = 99
    XCTAssertThrowsError(try config.validate())
  }
  func testShortcutRecoveryPreservesUserChangesAndIgnoresEarlierBoots() {
    let record = ShortcutRecoveryRecord(
      id: 118, key: 18, flags: 0, bootTime: 100, persistedEnabled: false)
    XCTAssertTrue(record.shouldRestore(key: 18, flags: 0, bootTime: 100.1, persistedEnabled: false))
    XCTAssertFalse(record.shouldRestore(key: 18, flags: 0, bootTime: 100, persistedEnabled: true))
    XCTAssertFalse(record.shouldRestore(key: 19, flags: 0, bootTime: 100, persistedEnabled: false))
    XCTAssertFalse(record.shouldRestore(key: 18, flags: 0, bootTime: 200, persistedEnabled: false))
  }
}
