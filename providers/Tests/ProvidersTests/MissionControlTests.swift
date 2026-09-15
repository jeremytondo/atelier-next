import CoreGraphics
import Foundation
import SpaceControlCore
import Testing

@testable import Providers

private func desktop(_ id: UInt64, fullscreen: Bool = false) -> ManagedSpaceSnapshot {
  ManagedSpaceSnapshot(id: id, isFullscreen: fullscreen, rawType: fullscreen ? 4 : 0)
}

/// Dock's Spaces bar for one display: thumbnails 100 points wide starting at
/// x 100, expanded to 60 points tall while the pointer rests on the top edge.
private final class FakeDock {
  var time: TimeInterval = 0
  var spaces = [desktop(1), desktop(2), desktop(3)]
  var current: UInt64 = 2
  var visible = false
  var pointer = CGPoint(x: 500, y: 400)
  let bounds = CGRect(x: 0, y: 0, width: 1440, height: 900)
  var hotkeys: [UInt32] = []
  var drags: [(from: CGPoint, to: CGPoint)] = []
  var presses: [Int] = []
  var removals: [Int] = []
  var opensOnHotkey = true
  var pressCloses = true
  var dragReorders = true
  var removeDeletes = true
  let target = TargetDisplay(displayID: 1, topologyIdentifier: "A")

  var topology: [DisplaySpaceSnapshot] {
    [DisplaySpaceSnapshot(identifier: "A", currentSpaceID: current, spaces: spaces)]
  }

  private var expanded: Bool { visible && pointer.y <= bounds.minY + 1 }

  func thumbnails() -> [CGRect]? {
    guard visible else { return nil }
    return spaces.indices.map {
      CGRect(x: 100 + CGFloat($0) * 120, y: 10, width: 100, height: expanded ? 60 : 30)
    }
  }

  private func index(at point: CGPoint) -> Int? {
    thumbnails()?.firstIndex { $0.minX <= point.x && point.x <= $0.maxX }
  }

  var seams: MissionControlSeams {
    MissionControlSeams(
      topology: { self.topology },
      postSymbolicHotKey: { id in
        self.hotkeys.append(id)
        switch id {
        case SymbolicHotKey.missionControl:
          if self.visible || self.opensOnHotkey { self.visible.toggle() }
        case SymbolicHotKey.previousSpace, SymbolicHotKey.nextSpace:
          guard let index = self.spaces.firstIndex(where: { $0.id == self.current }) else {
            return false
          }
          let next = index + (id == SymbolicHotKey.nextSpace ? 1 : -1)
          if self.spaces.indices.contains(next) { self.current = self.spaces[next].id }
        default:
          return false
        }
        return true
      },
      isVisible: { self.visible },
      thumbnails: { _ in self.thumbnails() },
      press: { _, index in
        self.presses.append(index)
        guard self.pressCloses else { return true }
        self.current = self.spaces[index].id
        self.visible = false
        return true
      },
      removeDesktop: { _, index in
        self.removals.append(index)
        if self.removeDeletes { self.spaces.remove(at: index) }
        return true
      },
      displayBounds: { _ in self.bounds },
      pointer: { self.pointer },
      movePointer: { point in
        self.pointer = point
        return true
      },
      drag: { from, to in
        self.drags.append((from, to))
        if self.dragReorders, let source = self.index(at: from),
          let destination = self.index(at: to)
        {
          self.spaces.insert(self.spaces.remove(at: source), at: destination)
        }
        return true
      },
      poller: Poller(now: { self.time }, pause: { self.time += 0.05 }))
  }

  func open() throws -> MissionControl {
    let control = MissionControl(seams: seams)
    try control.open(on: target, topology: topology)
    return control
  }
}

private func message(_ body: () throws -> Void) -> String? {
  do {
    try body()
    return nil
  } catch {
    return error.localizedDescription
  }
}

@Test func openingExpandsTheBarAndResetReturnsAnUntouchedPointer() throws {
  let dock = FakeDock()
  let control = try dock.open()
  #expect(dock.hotkeys == [SymbolicHotKey.missionControl] && dock.visible)
  #expect(dock.pointer == CGPoint(x: 500, y: 1))
  #expect(dock.time >= MissionControl.presentationSettleTime + MissionControl.thumbnailSettleTime)
  control.resetPointer()
  #expect(dock.pointer == CGPoint(x: 500, y: 400))

  let moved = FakeDock()
  let movedControl = try moved.open()
  moved.pointer = CGPoint(x: 900, y: 300)
  movedControl.resetPointer()
  #expect(moved.pointer == CGPoint(x: 900, y: 300))

  let stuck = FakeDock()
  stuck.opensOnHotkey = false
  #expect(message { _ = try stuck.open() }?.contains("Could not open Mission Control") == true)
}

@Test func reorderDragsFromTheLeftEdgeAndEntersTheMovedDesktop() throws {
  let dock = FakeDock()
  let control = try dock.open()
  try control.reorderActiveDesktop(offset: 1, on: dock.target, topology: dock.topology)
  #expect(dock.spaces.map(\.id) == [1, 3, 2])
  let drag = try #require(dock.drags.first)
  #expect(drag.from == CGPoint(x: 224, y: 40) && drag.to == CGPoint(x: 436, y: 40))
  try control.enterActiveDesktop(on: dock.target, topology: dock.topology)
  #expect(dock.presses == [2] && !dock.visible && dock.current == 2)

  let left = FakeDock()
  try left.open().reorderActiveDesktop(offset: -1, on: left.target, topology: left.topology)
  #expect(left.spaces.map(\.id) == [2, 1, 3] && left.drags.first?.to.x == 104)

  let edge = FakeDock()
  edge.current = 3
  try edge.open().reorderActiveDesktop(offset: 1, on: edge.target, topology: edge.topology)
  #expect(edge.drags.isEmpty && edge.spaces.map(\.id) == [1, 2, 3])
}

@Test func reorderFailsWhenMacOSDoesNotConfirmOrMissionControlCloses() throws {
  let silent = FakeDock()
  silent.dragReorders = false
  let control = try silent.open()
  let started = silent.time
  #expect(
    message {
      try control.reorderActiveDesktop(offset: 1, on: silent.target, topology: silent.topology)
    }?.contains("did not confirm the Desktop reorder") == true)
  #expect(silent.time - started >= 3)

  let closed = FakeDock()
  let closedControl = try closed.open()
  closed.visible = false
  #expect(
    message {
      try closedControl.reorderActiveDesktop(
        offset: 1, on: closed.target, topology: closed.topology)
    }?.contains("no longer open") == true)
  #expect(closed.drags.isEmpty)
}

@Test func deleteLeavesTheActiveDesktopBeforeRemovingItsThumbnail() throws {
  let dock = FakeDock()
  try dock.open().deleteActiveDesktop(on: dock.target, topology: dock.topology)
  #expect(dock.hotkeys.contains(SymbolicHotKey.nextSpace))
  #expect(dock.removals == [1] && dock.spaces.map(\.id) == [1, 3] && dock.current == 3)

  let last = FakeDock()
  last.current = 3
  try last.open().deleteActiveDesktop(on: last.target, topology: last.topology)
  #expect(last.hotkeys.contains(SymbolicHotKey.previousSpace))
  #expect(last.removals == [2] && last.spaces.map(\.id) == [1, 2] && last.current == 2)

  // Full-screen Spaces sit between Desktops in the native order and are stepped through.
  let mixed = FakeDock()
  mixed.spaces = [desktop(1), desktop(90, fullscreen: true), desktop(2)]
  mixed.current = 1
  try mixed.open().deleteActiveDesktop(on: mixed.target, topology: mixed.topology)
  #expect(mixed.hotkeys.filter { $0 == SymbolicHotKey.nextSpace }.count == 2)
  #expect(mixed.removals == [0] && mixed.spaces.map(\.id) == [90, 2] && mixed.current == 2)
}

@Test func deleteRefusesTheFinalDesktopAndUnconfirmedRemovals() throws {
  let single = FakeDock()
  single.spaces = [desktop(1)]
  single.current = 1
  let control = try single.open()
  #expect(
    message { try control.deleteActiveDesktop(on: single.target, topology: single.topology) }?
      .contains("final Desktop") == true)
  #expect(single.removals.isEmpty)

  let stuck = FakeDock()
  stuck.removeDeletes = false
  let stuckControl = try stuck.open()
  #expect(
    message { try stuckControl.deleteActiveDesktop(on: stuck.target, topology: stuck.topology) }?
      .contains("did not confirm Desktop deletion") == true)
  #expect(stuck.removals == [1] && stuck.spaces.count == 3)
}

@Test func enteringFallsBackToTheShortcutWhenThePressDoesNotClose() throws {
  let dock = FakeDock()
  dock.pressCloses = false
  try dock.open().enterActiveDesktop(on: dock.target, topology: dock.topology)
  #expect(dock.presses == [1])
  #expect(dock.hotkeys == [SymbolicHotKey.missionControl, SymbolicHotKey.missionControl])
  #expect(!dock.visible && dock.current == 2)
}
