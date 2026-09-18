import Foundation

/// Where the window lists are kept between runs. The file is safe to delete,
/// and a stale one only loses entries: every identity in it is checked
/// against the open windows before use.
struct WindowListFile {
  private struct Contents: Codable, Equatable {
    struct Desktop: Codable, Equatable {
      var space: UInt64
      var windows: [WindowIdentity]
    }
    var version = 1
    var desktops: [Desktop]
  }

  let url: URL
  private var written: Contents?

  init(folder: URL) {
    url = folder.appending(path: "window-lists.json")
  }

  /// Empty when there is no file or it is not one of ours.
  mutating func read() -> [UInt64: [WindowIdentity]] {
    guard let data = try? Data(contentsOf: url),
      let contents = try? JSONDecoder().decode(Contents.self, from: data), contents.version == 1
    else { return [:] }
    written = contents
    return Dictionary(contents.desktops.map { ($0.space, $0.windows) }) { first, _ in first }
  }

  /// Writes only when the lists differ from what the file holds.
  mutating func save(_ lists: [UInt64: [WindowIdentity]]) throws {
    let contents = Contents(
      desktops: lists.sorted { $0.key < $1.key }.compactMap { desktop, windows in
        let saved = windows.filter { $0.launched != nil }
        return saved.isEmpty ? nil : Contents.Desktop(space: desktop, windows: saved)
      })
    guard contents != written else { return }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try encoder.encode(contents).write(to: url, options: .atomic)
    written = contents
  }
}
