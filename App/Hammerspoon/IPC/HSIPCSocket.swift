// Local IPC discovery for an ordinary application (no launchd Mach service).
// Both targets compile this source. A private user directory scopes the socket;
// kernel peer audit tokens authenticate both ends with HS2's signing requirement.
// Each connection owns one serial queue, bounded newline-delimited JSON buffers,
// and its descriptor until dispatch-source cancellation completes.
import Foundation
import CryptoKit
import Security

private nonisolated struct HSIPCMessage: Codable, Sendable {
    var kind: String
    var id: String = UUID().uuidString
    var code: String = ""
    var result: String = ""
    var isError: Bool = false
    var level: Int = Int.max
    var logLevel: String = ""
}

nonisolated enum HSIPCSocket {
    static let limit = 4 * 1024 * 1024
    static func error(_ detail: String) -> NSError {
        NSError(domain: "HSIPC", code: Int(errno), userInfo: [NSLocalizedDescriptionKey: detail])
    }
    static func path(_ service: String) throws -> String {
        let scope = service + (ProcessInfo.processInfo.environment["ATELIER_CONFIG_DIR"] ?? "")
        let hash = SHA256.hash(data: Data(scope.utf8)).prefix(10).map { ($0 < 16 ? "0" : "") + String($0, radix: 16) }.joined()
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ipc-\(getuid())-\(hash)")
        if unsafe mkdir(directory.path, 0o700) != 0 && errno != EEXIST { throw error("Cannot create IPC directory") }
        var info = stat()
        guard unsafe lstat(directory.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == getuid(), info.st_mode & 0o077 == 0 else { throw error("Unsafe IPC directory") }
        return directory.appendingPathComponent("socket").path
    }
    static func address<T>(_ path: String, _ body: (UnsafePointer<sockaddr>, socklen_t) throws -> T) throws -> T {
        var address = sockaddr_un()
        let bytes = Array(path.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw error("IPC path is too long") }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        unsafe withUnsafeMutableBytes(of: &address.sun_path) { unsafe $0.copyBytes(from: bytes) }
        return try unsafe withUnsafePointer(to: &address) {
            try unsafe $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { try unsafe body($0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
    }
    static func configure(_ fd: Int32) {
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        var yes: Int32 = 1
        _ = unsafe setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout.size(ofValue: yes)))
    }
    static func authenticate(_ fd: Int32, requirement: String?) -> Bool {
        var uid: uid_t = 0, gid: gid_t = 0
        guard unsafe getpeereid(fd, &uid, &gid) == 0, uid == getuid() else { return false }
        #if DEBUG
        if requirement == nil { return true }
        #endif
        guard let requirement else { return false }
        var token = audit_token_t(), length = socklen_t(MemoryLayout<audit_token_t>.size)
        guard unsafe getsockopt(fd, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &length) == 0 else { return false }
        let data = unsafe withUnsafeBytes(of: &token) { unsafe Data($0) }
        var code: SecCode?, rule: SecRequirement?
        guard unsafe SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributeAudit: data] as CFDictionary, [], &code) == errSecSuccess,
              let code, unsafe SecRequirementCreateWithString(requirement as CFString, [], &rule) == errSecSuccess,
              let rule else { return false }
        return SecCodeCheckValidity(code, [], rule) == errSecSuccess
    }
}

nonisolated protocol HSIPCSocketListenerDelegate: AnyObject {
    func listener(_ listener: HSIPCSocketListener, shouldAcceptNewConnection connection: HSIPCSocketConnection) -> Bool
}

nonisolated final class HSIPCSocketListener: @unchecked Sendable {
    weak var delegate: (any HSIPCSocketListenerDelegate)?
    private let name: String
    private var requirement: String?
    private var source: (any DispatchSourceRead)?
    private var cancellation: DispatchGroup?
    init(serviceName: String) { name = serviceName }
    func setConnectionCodeSigningRequirement(_ value: String) { requirement = value }
    func resume() throws {
        let path = try HSIPCSocket.path(name)
        let lock = unsafe Darwin.open(path + ".lock", O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard lock >= 0 else { throw HSIPCSocket.error("Cannot open IPC lock") }
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { close(lock); throw HSIPCSocket.error("IPC is already running") }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { close(lock); throw HSIPCSocket.error("Cannot create IPC socket") }
        do {
            // The held lock and private directory make stale-file cleanup safe.
            _ = unsafe unlink(path)
            HSIPCSocket.configure(fd)
            guard try unsafe HSIPCSocket.address(path, { unsafe Darwin.bind(fd, $0, $1) }) == 0,
                  Darwin.listen(fd, 16) == 0 else { throw HSIPCSocket.error("Cannot listen for IPC") }
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: DispatchQueue(label: name))
            source.setEventHandler { [weak self] in
                guard let self else { return }
                while true {
                    let peer = accept(fd, nil, nil)
                    guard peer >= 0 else { break }
                    HSIPCSocket.configure(peer)
                    guard HSIPCSocket.authenticate(peer, requirement: self.requirement) else { close(peer); continue }
                    let connection = HSIPCSocketConnection(descriptor: peer)
                    if self.delegate?.listener(self, shouldAcceptNewConnection: connection) != true { connection.invalidate() }
                }
            }
            let cancellation = DispatchGroup()
            cancellation.enter()
            source.setCancelHandler { close(fd); _ = unsafe unlink(path); close(lock); cancellation.leave() }
            self.cancellation = cancellation; self.source = source
            source.resume()
        } catch { close(fd); _ = unsafe unlink(path); close(lock); throw error }
    }
    func invalidate() {
        source?.cancel(); source = nil
        // Release the listening socket/lock before a reload starts its successor.
        cancellation?.wait(); cancellation = nil
    }
    deinit { source?.cancel() }
}

nonisolated final class HSIPCSocketConnection: NSObject, @unchecked Sendable {
    var exportedObject: AnyObject?
    var invalidationHandler: (@Sendable () -> Void)?
    var interruptionHandler: (@Sendable () -> Void)?
    private let queue = DispatchQueue(label: "hs.ipc.connection")
    private let fd: Int32
    private var readSource: (any DispatchSourceRead)?
    private var writeSource: (any DispatchSourceWrite)?
    private var incoming = Data(), outgoing = Data()
    private var closed = false
    private var replies: [String: Reply] = [:]
    private struct Reply: @unchecked Sendable {
        let callback: (HSIPCMessage?, Error?) -> Void
    }
    fileprivate init(descriptor: Int32) { fd = descriptor; super.init() }
    convenience init(serviceName: String, requirement: String?) throws {
        let path = try HSIPCSocket.path(serviceName)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw HSIPCSocket.error("Cannot create IPC connection") }
        do {
            HSIPCSocket.configure(fd)
            let result = try unsafe HSIPCSocket.address(path) { unsafe Darwin.connect(fd, $0, $1) }
            if result != 0 {
                guard errno == EINPROGRESS else { throw HSIPCSocket.error("IPC is not running") }
                var pollFD = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                guard unsafe poll(&pollFD, 1, 5000) > 0 else { throw HSIPCSocket.error("IPC connection timed out") }
            }
            guard HSIPCSocket.authenticate(fd, requirement: requirement) else { throw HSIPCSocket.error("IPC peer authentication failed") }
            self.init(descriptor: fd)
        } catch { close(fd); throw error }
    }
    func resume() {
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.read() }
        source.setCancelHandler { [fd] in close(fd) }
        readSource = source
        source.resume()
    }
    func invalidate() { queue.async { self.finish(notify: false) } }
    private func finish(notify: Bool = true) {
        guard !closed else { return }
        closed = true
        writeSource?.cancel(); writeSource = nil
        _ = Darwin.shutdown(fd, SHUT_RDWR)
        if let readSource { readSource.cancel() } else { close(fd) }
        readSource = nil
        let pending = replies.values; replies.removeAll()
        for reply in pending { reply.callback(nil, HSIPCSocket.error("IPC connection closed")) }
        if notify { invalidationHandler?() }
        exportedObject = nil
    }
    private func read() {
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while !closed {
            let count = unsafe recv(fd, &buffer, buffer.count, 0)
            if count < 0 { if errno != EAGAIN && errno != EINTR { finish() }; return }
            if count == 0 { finish(); return }
            incoming.append(contentsOf: buffer.prefix(count))
            guard incoming.count <= HSIPCSocket.limit else { finish(); return }
            while let end = incoming.firstIndex(of: 10) {
                guard let message = try? JSONDecoder().decode(HSIPCMessage.self, from: incoming.prefix(upTo: end)) else { finish(); return }
                incoming.removeSubrange(...end)
                receive(message)
            }
        }
    }
    private func receive(_ message: HSIPCMessage) {
        switch message.kind {
        case "reply": replies.removeValue(forKey: message.id)?.callback(message, nil)
        case "hello":
            (exportedObject as? HSIPCServerProtocol)?.hello(minLogLevel: message.level) { [weak self] result in
                self?.send(HSIPCMessage(kind: "reply", id: message.id, result: result))
            }
        case "evaluate":
            (exportedObject as? HSIPCServerProtocol)?.evaluate(id: message.id, code: message.code) { [weak self] result, isError in
                self?.send(HSIPCMessage(kind: "reply", id: message.id, result: result, isError: isError))
            }
        case "log": (exportedObject as? HSIPCClientProtocol)?.logEntry(level: message.logLevel, message: message.result)
        default: finish()
        }
    }
    fileprivate func request(_ message: HSIPCMessage, reply: @escaping (HSIPCMessage?, Error?) -> Void) {
        let box = Reply(callback: reply)
        queue.async {
            guard !self.closed else { box.callback(nil, HSIPCSocket.error("IPC connection closed")); return }
            self.replies[message.id] = box
            self.enqueue(message)
        }
    }
    fileprivate func send(_ message: HSIPCMessage) { queue.async { self.enqueue(message) } }
    private func enqueue(_ message: HSIPCMessage) {
        guard !closed, let data = try? JSONEncoder().encode(message) else { return }
        guard outgoing.count + data.count + 1 <= HSIPCSocket.limit else { finish(); return }
        outgoing.append(data); outgoing.append(10)
        flush()
    }
    private func flush() {
        while !closed && !outgoing.isEmpty {
            let count = unsafe outgoing.withUnsafeBytes { unsafe Darwin.send(fd, $0.baseAddress, $0.count, 0) }
            if count < 0 {
                if errno == EINTR { continue }
                guard errno == EAGAIN else { finish(); return }
                if writeSource == nil {
                    let source = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: queue)
                    source.setEventHandler { [weak self] in self?.flush() }
                    writeSource = source; source.resume()
                }
                return
            }
            guard count > 0 else { finish(); return }
            outgoing.removeFirst(count)
        }
        writeSource?.cancel(); writeSource = nil
    }
    var remoteObjectProxy: Any { HSIPCSocketProxy(connection: self, errorHandler: { _ in }) }
    func remoteObjectProxyWithErrorHandler(_ handler: @escaping (Error) -> Void) -> Any {
        HSIPCSocketProxy(connection: self, errorHandler: handler)
    }
    deinit { readSource?.cancel(); writeSource?.cancel() }
}

private nonisolated final class HSIPCSocketProxy: NSObject, HSIPCServerProtocol, HSIPCClientProtocol {
    private let connection: HSIPCSocketConnection
    private let errorHandler: (Error) -> Void
    init(connection: HSIPCSocketConnection, errorHandler: @escaping (Error) -> Void) {
        self.connection = connection; self.errorHandler = errorHandler
    }
    func hello(minLogLevel: Int, withReply reply: @escaping (String) -> Void) {
        connection.request(HSIPCMessage(kind: "hello", level: minLogLevel)) { [errorHandler] message, error in
            if let message { reply(message.result) } else if let error { errorHandler(error) }
        }
    }
    func evaluate(id: String, code: String, withReply reply: @escaping (String, Bool) -> Void) {
        connection.request(HSIPCMessage(kind: "evaluate", id: id, code: code)) { [errorHandler] message, error in
            if let message { reply(message.result, message.isError) } else if let error { errorHandler(error) }
        }
    }
    func logEntry(level: String, message: String) {
        connection.send(HSIPCMessage(kind: "log", result: message, logLevel: level))
    }
}
