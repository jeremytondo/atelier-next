import AppKit
import AtelierKit
import SwiftUI

/// The HUD: one panel in the bottom-right of the display with the keyboard,
/// showing whichever of these is wanted, in this order: the leader menu
/// while it is open, the current Desktop's window list while its modifiers
/// are held, and a notice for a moment after a shortcut failed. Everything
/// it shows comes from AtelierKit's queries and events.
@MainActor
public final class HUD {
  private let atelier: Atelier
  private let panel: HUDPanel
  private var leader: LeaderState?
  private var isHeld = false
  private var windows: (list: [AtelierKit.Window], display: String)?
  private var notice: String?
  private var noticeTimer: Task<Void, Never>?
  private var following: Task<Void, Never>?
  /// Counts the window-list reads, so a slow one never overwrites a newer one.
  private var refreshes = 0

  public init(atelier: Atelier) {
    self.atelier = atelier
    panel = HUDPanel(content: HUDView(content: .empty))
    Task { [weak self] in
      for await _ in await atelier.leader.changes() {
        guard let self else { return }
        leader = await atelier.leader.state()
        render()
      }
    }
    Task { [weak self] in
      for await held in await atelier.windows.held() {
        guard let self else { return }
        isHeld = held
        if held { follow() } else { stopFollowing() }
        render()
      }
    }
    Task { [weak self] in
      for await notice in atelier.notices.changes() {
        self?.show(notice: notice.text)
      }
    }
  }

  /// Keeps the list current while the modifiers are held.
  private func follow() {
    following?.cancel()
    following = Task { [weak self] in
      guard let self else { return }
      // Subscribed first, so a change during the first read is not missed.
      let changes = await atelier.windows.changes()
      await refreshWindows()
      for await _ in changes {
        guard !Task.isCancelled else { return }
        await refreshWindows()
      }
    }
  }

  private func stopFollowing() {
    following?.cancel()
    following = nil
    refreshes += 1
    windows = nil
  }

  private func refreshWindows() async {
    refreshes += 1
    let refresh = refreshes
    let list = try? await atelier.windows.list()
    guard refresh == refreshes else { return }
    if case .desktop(let windows, let display) = list {
      self.windows = (windows, display)
    } else {
      windows = nil
    }
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
    } else if isHeld, let windows, !windows.list.isEmpty {
      content = .windows(windows.list)
      display = windows.display
    } else if let notice, leader == nil {
      content = .notice(notice)
      display = nil
    } else {
      panel.hide()
      return
    }
    guard let screen = display.flatMap(NSScreen.named) ?? NSScreen.main ?? NSScreen.screens.first
    else {
      panel.hide()
      return
    }
    panel.show(HUDView(content: content), on: screen)
  }
}
