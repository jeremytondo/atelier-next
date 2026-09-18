import Foundation
import Synchronization
import os

public struct Notice: Equatable, Sendable {
  public let text: String
}

/// Brief word for the person at the keyboard: why a shortcut or leader
/// command did nothing. A success is quiet, and the `atelier` command gets
/// its answer in its reply, so these are only for the interface to show for
/// a moment. Every notice is logged as well.
public final class Notices: Sendable {
  private let listeners = Mutex<[UUID: AsyncStream<Notice>.Continuation]>([:])
  private let log = Logger(subsystem: "com.elevenideas.Atelier", category: "notices")

  init() {}

  public func changes() -> AsyncStream<Notice> {
    let (stream, continuation) = AsyncStream.makeStream(
      of: Notice.self, bufferingPolicy: .bufferingNewest(4))
    let id = UUID()
    listeners.withLock { $0[id] = continuation }
    continuation.onTermination = { [self] _ in listeners.withLock { $0[id] = nil } }
    return stream
  }

  func post(_ text: String) {
    log.notice("\(text, privacy: .public)")
    let notice = Notice(text: text)
    for listener in listeners.withLock({ Array($0.values) }) { listener.yield(notice) }
  }
}
