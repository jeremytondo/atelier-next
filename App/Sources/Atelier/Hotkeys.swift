import AppKit
import AtelierCore
import Carbon.HIToolbox

enum Command: Equatable {
  case group
  case select(Int)
  case cycle(Int)
  case desktop(Int)
  case create
  case reorder(Int)
  case delete
  case quick(UUID)
  case reload
  var isSpace: Bool {
    switch self {
    case .desktop, .create, .reorder, .delete: return true
    default: return false
    }
  }
  var name: String {
    switch self {
    case .group: return "group"
    case .select: return "select"
    case .cycle: return "cycle"
    case .desktop: return "switch"
    case .create: return "create"
    case .reorder: return "reorder"
    case .delete: return "delete"
    case .quick: return "quickApp"
    case .reload: return "reload-config"
    }
  }
}

@MainActor
final class Hotkeys {
  struct Binding {
    let shortcut: Shortcut
    let command: Command
  }
  private var handler: EventHandlerRef?
  private var references: [UInt32: EventHotKeyRef] = [:]
  private(set) var bindings: [UInt32: Binding] = [:]
  private var nextID: UInt32 = 1
  private let registration: ((UInt32, Binding) throws -> EventHotKeyRef)?
  private let release: (EventHotKeyRef) -> Void
  init(
    registration: ((UInt32, Binding) throws -> EventHotKeyRef)? = nil,
    release: @escaping (EventHotKeyRef) -> Void = { UnregisterEventHotKey($0) }
  ) {
    self.registration = registration
    self.release = release
  }
  var onCommand: ((Command) -> Void)?
  func start() throws {
    guard handler == nil else { return }
    var event = EventTypeSpec(
      eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
    let callback: EventHandlerUPP = { _, event, context in
      guard let event, let context else { return OSStatus(eventNotHandledErr) }
      var id = EventHotKeyID()
      guard
        GetEventParameter(
          event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
          MemoryLayout<EventHotKeyID>.size, nil, &id) == noErr, id.signature == 0x4154_4c52
      else { return OSStatus(eventNotHandledErr) }
      MainActor.assumeIsolated {
        let owner = Unmanaged<Hotkeys>.fromOpaque(context).takeUnretainedValue()
        if let command = owner.bindings[id.id]?.command { owner.onCommand?(command) }
      }
      return noErr
    }
    let result = InstallEventHandler(
      GetApplicationEventTarget(), callback, 1, &event, Unmanaged.passUnretained(self).toOpaque(),
      &handler)
    guard result == noErr else { throw AppError("Could not listen for shortcuts (\(result)).") }
  }
  func add(_ binding: Binding) throws {
    guard !bindings.values.contains(where: { $0.shortcut == binding.shortcut }) else {
      throw AppError("\(binding.shortcut.label) is already used by Atelier.")
    }
    if case .quick = binding.command {
      var raw: Unmanaged<CFArray>?
      if CopySymbolicHotKeys(&raw) == noErr,
        let entries = raw?.takeRetainedValue() as? [[String: Any]],
        entries.contains(where: {
          ($0[kHISymbolicHotKeyEnabled as String] as? Bool) == true
            && ($0[kHISymbolicHotKeyCode as String] as? NSNumber)?.uint32Value
              == binding.shortcut.keyCode
            && ($0[kHISymbolicHotKeyModifiers as String] as? NSNumber)?.uint32Value
              == binding.shortcut.modifiers
        })
      {
        throw AppError("\(binding.shortcut.label) is already assigned to a macOS shortcut.")
      }
    }
    let id = nextID
    nextID += 1
    try register(id, binding)
    bindings[id] = binding
  }
  /// Acquire every new shortcut before releasing any old registration. Reused
  /// shortcuts keep their registration and can change actions atomically.
  func replace(with proposed: [Binding]) throws {
    guard Set(proposed.map(\.shortcut)).count == proposed.count else {
      throw AppError("The configuration contains duplicate shortcuts.")
    }
    let previous = bindings
    var replacement: [UInt32: Binding] = [:]
    var added: [UInt32] = []
    do {
      for binding in proposed {
        if let id = previous.first(where: { $0.value.shortcut == binding.shortcut })?.key {
          replacement[id] = binding
        } else {
          try add(binding)
          let id = nextID - 1
          added.append(id)
          replacement[id] = binding
        }
      }
    } catch {
      for id in added {
        if let ref = references.removeValue(forKey: id) { release(ref) }
      }
      bindings = previous
      throw error
    }
    for id in previous.keys where replacement[id] == nil {
      if let ref = references.removeValue(forKey: id) { release(ref) }
    }
    bindings = replacement
  }
  private func register(_ id: UInt32, _ binding: Binding) throws {
    if let registration {
      references[id] = try registration(id, binding)
      return
    }
    var ref: EventHotKeyRef?
    let status = RegisterEventHotKey(
      binding.shortcut.keyCode, binding.shortcut.modifiers,
      EventHotKeyID(signature: 0x4154_4c52, id: id), GetApplicationEventTarget(), 0, &ref)
    guard status == noErr, let ref else {
      throw AppError(
        "\(binding.shortcut.label) is unavailable. Another app or macOS may be using it (\(status))."
      )
    }
    references[id] = ref
  }
  func suspendSpaces() {
    for (id, binding) in bindings where binding.command.isSpace {
      if let ref = references.removeValue(forKey: id) { release(ref) }
    }
  }
  func resumeSpaces() throws {
    for (id, binding) in bindings where binding.command.isSpace && references[id] == nil {
      try register(id, binding)
    }
  }
  func stop() {
    for ref in references.values { release(ref) }
    references.removeAll()
    bindings.removeAll()
    if let handler { RemoveEventHandler(handler) }
    handler = nil
  }
  static func defaults(_ config: AppConfiguration) throws -> [Binding] {
    try config.effectiveBindings().sorted { $0.key < $1.key }.map { name, shortcut in
      let command: Command
      switch name {
      case "reload-config": command = .reload
      case "group": command = .group
      case "cycle-previous": command = .cycle(-1)
      case "cycle-next": command = .cycle(1)
      case "desktop-create": command = .create
      case "desktop-left": command = .reorder(-1)
      case "desktop-right": command = .reorder(1)
      case "desktop-delete": command = .delete
      default:
        if name.hasPrefix("desktop-"), let n = Int(name.dropFirst(8)) {
          command = .desktop(n)
        } else if name.hasPrefix("select-"), let n = Int(name.dropFirst(7)) {
          command = .select(n)
        } else {
          throw AppError("Unknown action: \(name)")
        }
      }
      return Binding(shortcut: shortcut, command: command)
    }
  }
}
