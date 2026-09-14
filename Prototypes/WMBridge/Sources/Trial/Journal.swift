// One create attempt per private run directory, including after a crash. A
// dispatched or uncertain mutation is never made eligible for replay by a read.
import Darwin
import Foundation

public final class Journal {
  public let directory: URL
  public init(path: String, create: Bool) throws {
    guard path.hasPrefix("/"), !path.contains("/../") else { throw TrialError("An absolute private run directory is required") }
    directory = URL(fileURLWithPath: path).standardizedFileURL
    if create, mkdir(directory.path, 0o700) != 0 { throw TrialError("Run directory must be new; never replay an existing attempt") }
    var info = stat()
    guard lstat(directory.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
      info.st_uid == getuid(), info.st_mode & 0o077 == 0 else { throw TrialError("Run directory must be owned by this user with mode 0700") }
  }

  public func write(_ name: String, _ value: [String: Any]) throws {
    let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
    let path = directory.appendingPathComponent(name).path
    let descriptor = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
    guard descriptor >= 0 else { throw TrialError("Evidence already exists or cannot be created: \(name)") }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    try handle.write(contentsOf: data)
    try handle.synchronize()
    try handle.close()
  }

  public func read(_ name: String) throws -> [String: Any] {
    let descriptor = open(directory.appendingPathComponent(name).path, O_RDONLY | O_NOFOLLOW)
    guard descriptor >= 0 else { throw TrialError("Missing evidence: \(name)") }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    guard let data = try handle.readToEnd(),
      let value = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { throw TrialError("Invalid evidence: \(name)") }
    return value
  }
}
