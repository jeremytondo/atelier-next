import AppKit
import AtelierKit
import SwiftUI
import os

/// The HUD: one panel in the bottom-right of the display with the keyboard,
/// showing whichever of these is wanted, in this order: the leader menu
/// while it is open, the current Desktop's window list while its modifiers
/// are held, the list of Spaces while its own are, and a notice for a moment
/// after a shortcut failed. Everything it shows comes from AtelierKit's
/// queries and events; when the list of Spaces appears and what dismisses it
/// is `SpaceListAppearance`.
@MainActor
public final class HUD {
  private let atelier: Atelier
  private let panel: HUDPanel
  private var leader: LeaderState?
  private var windowsHeld = false
  private let windows: Following<(list: [AtelierKit.Window], display: String)>
  private var spaceList = SpaceListAppearance()
  private var spaceListDelay: Task<Void, Never>?
  private let spaces: Following<SpaceList>
  private var notice: String?
  private var noticeTimer: Task<Void, Never>?
  private let log = Logger(subsystem: "com.elevenideas.Atelier", category: "hud")

  public init(atelier: Atelier) {
    self.atelier = atelier
    panel = HUDPanel(content: HUDView(content: .empty))
    windows = Following(
      changes: { await atelier.windows.changes() },
      read: {
        guard case .desktop(let list, let display) = try? await atelier.windows.list() else {
          return nil
        }
        return (list, display)
      })
    spaces = Following(
      changes: { await atelier.spaces.changes() }, read: { try? await atelier.spaces.list() })
    windows.onChange = { [weak self] in
      self?.log.info(
        "windows read: \(self?.windows.value.map { "\($0.list.count) windows" } ?? "nothing", privacy: .public)"
      )
      self?.render()
    }
    spaces.onChange = { [weak self] in
      self?.log.info(
        "spaces read: \(self?.spaces.value.map { "\($0.spaces.count) Spaces" } ?? "nothing", privacy: .public)"
      )
      self?.render()
    }
    Task { [weak self] in
      for await _ in await atelier.leader.changes() {
        guard let self else { return }
        leader = await atelier.leader.state()
        log.info(
          "leader: \(self.leader == nil ? "closed" : self.leader!.isShown ? "shown" : "open, hidden", privacy: .public)"
        )
        spaceListChanged()
      }
    }
    Task { [weak self] in
      for await holds in atelier.holds.changes() {
        guard let self else { return }
        log.info(
          "holds: windows \(holds.windows), spaces \(String(describing: holds.spaces), privacy: .public)"
        )
        windowsHeld = holds.windows
        if windowsHeld { windows.start() } else { windows.stop() }
        spaceList.keys(holds.spaces)
        spaceListChanged()
      }
    }
    Task { [weak self] in
      for await _ in await atelier.spaces.selections() {
        self?.log.info("selection")
        self?.spaceList.dismiss()
        self?.spaceListChanged()
      }
    }
    Task { [weak self] in
      for await _ in await atelier.spaces.changes() {
        guard let self else { return }
        panel.spacesChanged()
      }
    }
    Task { [weak self] in
      for await notice in atelier.notices.changes() {
        self?.show(notice: notice.text)
      }
    }
  }

  /// Something happened that the list of Spaces goes by. The open leader
  /// dismisses the list, whichever of the two came first. The delay is timed
  /// and the Spaces are read only while they are needed.
  private func spaceListChanged() {
    if leader != nil { spaceList.dismiss() }
    if case .waiting(let delay) = spaceList.phase {
      if spaceListDelay == nil {
        spaceListDelay = Task { [weak self] in
          try? await Task.sleep(for: delay)
          guard !Task.isCancelled, let self else { return }
          spaceListDelay = nil
          spaceList.delayPassed()
          spaceListChanged()
        }
      }
    } else {
      spaceListDelay?.cancel()
      spaceListDelay = nil
    }
    if spaceList.phase == .shown { spaces.start() } else { spaces.stop() }
    log.info("space list: \(String(describing: self.spaceList.phase), privacy: .public)")
    render()
  }

  private func show(notice text: String) {
    noticeTimer?.cancel()
    notice = text
    render()
    noticeTimer = Task { [weak self] in
      try? await Task.sleep(for: .seconds(3))
      guard !Task.isCancelled else { return }
      self?.notice = nil
      self?.render()
    }
  }

  private func render() {
    let content: HUDView.Content
    let display: String?
    if let leader, leader.isShown {
      content = .leader(leader)
      display = leader.display
    } else if windowsHeld, let windows = windows.value, !windows.list.isEmpty {
      content = .windows(windows.list)
      display = windows.display
    } else if spaceList.phase == .shown, let spaces = spaces.value {
      content = .spaces(spaces.spaces)
      display = spaces.display
    } else if let notice, leader == nil {
      content = .notice(notice)
      display = nil
    } else {
      log.info("render: nothing")
      panel.hide()
      return
    }
    log.info("render: \(content.kind, privacy: .public)")
    guard let screen = display.flatMap(NSScreen.named) ?? NSScreen.main ?? NSScreen.screens.first
    else {
      panel.hide()
      return
    }
    panel.show(HUDView(content: content), on: screen)
  }
}

extension HUDView.Content {
  /// For the log: which kind is shown, and nothing of what it holds.
  fileprivate var kind: String {
    switch self {
    case .empty: "empty"
    case .leader: "leader"
    case .windows: "windows"
    case .spaces: "spaces"
    case .notice: "notice"
    }
  }
}
