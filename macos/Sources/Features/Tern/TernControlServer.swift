import Darwin
import Foundation
import OSLog

/// Errors returned to the CLI. `code` is machine-readable, `message` is for people.
struct TernError: Error {
    let code: String
    let message: String

    static func badRequest(_ message: String) -> TernError { .init(code: "bad_request", message: message) }
    static func notFound(_ message: String) -> TernError { .init(code: "not_found", message: message) }
    static func ambiguous(_ message: String) -> TernError { .init(code: "ambiguous", message: message) }
    static func failed(_ message: String) -> TernError { .init(code: "failed", message: message) }
    static func timeout(_ message: String) -> TernError { .init(code: "timeout", message: message) }
}

/// The control socket: JSON lines over a Unix socket in the per-user temporary directory.
///
/// Requests are `{"id", "method", "params", "caller"}`; responses are `{"id", "result"}` or
/// `{"id", "error": {"code", "message"}}`. After `events.subscribe` a connection also gets
/// `{"event", "data", "ts"}` lines.
///
/// Sockets are non-blocking and every connection has its own outgoing buffer, so a client
/// that stops reading can never stall the app: it is disconnected once its buffer passes a
/// limit (T-4, R-6).
final class TernControlServer: @unchecked Sendable {
    static let shared = TernControlServer()
    static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "dev.tern.app", category: "control")

    private var listenFD: Int32 = -1
    private let acceptQueue = DispatchQueue(label: "dev.tern.control.accept")
    private var acceptSource: DispatchSourceRead?
    private let lock = NSLock()
    private var connections: [ObjectIdentifier: TernConnection] = [:]

    private(set) var isRunning = false

    func start() {
        guard !isRunning else { return }
        let path = TernPaths.socketPath
        unlink(path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            Self.logger.error("control socket: socket() failed errno=\(errno)")
            return
        }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            Self.logger.error("control socket path is too long: \(path, privacy: .public)")
            close(fd)
            return
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            for (i, b) in bytes.enumerated() { raw[i] = b }
            raw[bytes.count] = 0
        }
        let oldMask = umask(0o077)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        umask(oldMask)
        guard bound == 0, listen(fd, 128) == 0 else {
            Self.logger.error("control socket: bind/listen failed errno=\(errno)")
            close(fd)
            return
        }
        chmod(path, 0o600)
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        listenFD = fd

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: acceptQueue)
        source.setEventHandler { [weak self] in self?.acceptPending() }
        source.setCancelHandler { close(fd) }
        source.resume()
        acceptSource = source
        isRunning = true

        // Tell people (and tests) where we are.
        let info: [String: Any] = [
            "pid": Int(getpid()),
            "socket": path,
            "instance": TernPaths.instanceID,
            "state_dir": TernPaths.stateDirectory,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: info, options: [.sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: TernPaths.path("instance.json")), options: .atomic)
        }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        acceptSource?.cancel()
        acceptSource = nil
        unlink(TernPaths.socketPath)
        lock.lock()
        let all = Array(connections.values)
        connections.removeAll()
        lock.unlock()
        for connection in all { connection.close() }
    }

    private func acceptPending() {
        while true {
            let client = accept(listenFD, nil, nil)
            if client < 0 { return }
            // Only this user's processes may talk to us (the socket is 0600, but be sure).
            var uid: uid_t = 0
            var gid: gid_t = 0
            if getpeereid(client, &uid, &gid) != 0 || uid != getuid() {
                close(client)
                continue
            }
            let connection = TernConnection(fd: client, server: self)
            lock.lock()
            connections[ObjectIdentifier(connection)] = connection
            lock.unlock()
            connection.start()
        }
    }

    fileprivate func remove(_ connection: TernConnection) {
        lock.lock()
        connections.removeValue(forKey: ObjectIdentifier(connection))
        lock.unlock()
        Task { @MainActor in TernEvents.shared.removeSubscriber(connection) }
    }
}

/// One client of the control socket.
final class TernConnection: @unchecked Sendable {
    private let fd: Int32
    private weak var server: TernControlServer?
    private let queue: DispatchQueue
    private var readSource: DispatchSourceRead?
    private var writeSource: DispatchSourceWrite?
    private var writeSourceActive = false
    private var inBuffer = Data()
    private var outBuffer = Data()
    private var closed = false

    /// Clients that fall this far behind are disconnected (only touched on `queue`).
    private var outgoingLimit = 512 * 1024 * 1024

    /// Lower the backlog limit (event subscribers).
    func setOutgoingLimit(_ limit: Int) {
        queue.async { [weak self] in self?.outgoingLimit = limit }
    }

    init(fd: Int32, server: TernControlServer) {
        self.fd = fd
        self.server = server
        self.queue = DispatchQueue(label: "dev.tern.control.connection")
    }

    func start() {
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        var nosigpipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &nosigpipe, socklen_t(MemoryLayout<Int32>.size))

        let fd = self.fd
        let read = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        read.setEventHandler { [weak self] in self?.readAvailable() }
        readSource = read
        let write = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: queue)
        write.setEventHandler { [weak self] in self?.flush() }
        writeSource = write
        // Both sources share the descriptor; it's closed once both are gone.
        let group = DispatchGroup()
        group.enter()
        group.enter()
        read.setCancelHandler { group.leave() }
        write.setCancelHandler { group.leave() }
        group.notify(queue: queue) { Darwin.close(fd) }
        read.resume()
    }

    // MARK: Reading

    private func readAvailable() {
        var chunk = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = Darwin.read(fd, &chunk, chunk.count)
            if n > 0 {
                inBuffer.append(contentsOf: chunk[0..<n])
                continue
            }
            if n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) { break }
            if n < 0 && errno == EINTR { continue }
            // EOF or error.
            processLines()
            closeOnQueue()
            return
        }
        processLines()
    }

    /// How much of `inBuffer` is known to hold no newline: a long request arriving in many reads
    /// is scanned once, not again from its start after every read.
    private var scanned = 0

    /// The next complete line (without its newline), if one has arrived.
    private func nextLine() -> Data? {
        let start = scanned
        let offset: Int? = inBuffer.withUnsafeBytes { raw in
            guard raw.count > start, let base = raw.baseAddress,
                  let hit = memchr(base + start, 0x0A, raw.count - start) else { return nil }
            return base.distance(to: UnsafeRawPointer(hit))
        }
        guard let offset else {
            scanned = inBuffer.count
            return nil
        }
        let line = Data(inBuffer.prefix(offset))
        inBuffer.removeFirst(offset + 1)
        scanned = 0
        return line
    }

    private func processLines() {
        while let line = nextLine() {
            guard !line.isEmpty else { continue }
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                sendRaw(["id": NSNull(), "error": ["code": "bad_request", "message": "invalid JSON"]])
                continue
            }
            let id = object["id"] ?? NSNull()
            let method = object["method"] as? String ?? ""
            let params = object["params"] as? [String: Any] ?? [:]
            let caller = object["caller"] as? [String: Any] ?? [:]
            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    let result = try await TernRPC.handle(
                        method: method,
                        params: TernParams(params),
                        caller: TernCaller(caller),
                        connection: self)
                    self.sendRaw(["id": id, "result": result ?? [String: Any]()])
                } catch let error as TernError {
                    self.sendRaw(["id": id, "error": ["code": error.code, "message": error.message]])
                } catch {
                    self.sendRaw(["id": id, "error": ["code": "failed", "message": "\(error)"]])
                }
            }
        }
    }

    // MARK: Writing

    /// Queue a JSON object for sending. Safe from any thread; never blocks.
    func sendRaw(_ object: [String: Any]) {
        let sanitized = TernJSON.sanitize(object)
        guard var data = try? JSONSerialization.data(withJSONObject: sanitized, options: [.withoutEscapingSlashes]) else {
            return
        }
        data.append(0x0A)
        queue.async { [weak self] in
            guard let self, !self.closed else { return }
            self.outBuffer.append(data)
            if self.outBuffer.count > self.outgoingLimit {
                // A consumer that stopped reading: let it go rather than hold on.
                self.closeOnQueue()
                return
            }
            self.flush()
        }
    }

    private func flush() {
        guard !closed else { return }
        while !outBuffer.isEmpty {
            let n = outBuffer.withUnsafeBytes { raw in
                Darwin.write(fd, raw.baseAddress!, raw.count)
            }
            if n > 0 {
                outBuffer.removeSubrange(0..<n)
                continue
            }
            if n < 0 && errno == EINTR { continue }
            if n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                if !writeSourceActive {
                    writeSourceActive = true
                    writeSource?.resume()
                }
                return
            }
            closeOnQueue()
            return
        }
        if writeSourceActive {
            writeSourceActive = false
            writeSource?.suspend()
        }
    }

    func close() {
        queue.async { [weak self] in self?.closeOnQueue() }
    }

    private func closeOnQueue() {
        guard !closed else { return }
        closed = true
        readSource?.cancel()
        // A suspended source must be resumed before it can be cancelled.
        if !writeSourceActive { writeSource?.resume() }
        writeSource?.cancel()
        readSource = nil
        writeSource = nil
        outBuffer.removeAll()
        server?.remove(self)
    }

    var isClosed: Bool { queue.sync { closed } }
}

/// Request parameters with typed accessors.
struct TernParams {
    let raw: [String: Any]

    init(_ raw: [String: Any]) { self.raw = raw }

    func string(_ key: String) -> String? {
        if let s = raw[key] as? String { return s }
        if let n = raw[key] as? NSNumber, !(raw[key] is Bool) { return n.stringValue }
        return nil
    }

    func bool(_ key: String) -> Bool? {
        if let b = raw[key] as? Bool { return b }
        if let n = raw[key] as? NSNumber { return n.boolValue }
        return nil
    }

    func int(_ key: String) -> Int? {
        if let n = raw[key] as? NSNumber { return n.intValue }
        if let s = raw[key] as? String { return Int(s) }
        return nil
    }

    func double(_ key: String) -> Double? {
        if let n = raw[key] as? NSNumber { return n.doubleValue }
        if let s = raw[key] as? String { return Double(s) }
        return nil
    }

    func strings(_ key: String) -> [String]? {
        if let a = raw[key] as? [String] { return a }
        if let s = raw[key] as? String { return [s] }
        return nil
    }

    func has(_ key: String) -> Bool { raw[key] != nil && !(raw[key] is NSNull) }
}

/// Who sent a request: the pane the CLI runs in (if any) and that pane's instance.
struct TernCaller {
    let pane: String?
    let instance: String?
    /// The managed session the CLI runs in (TERN_SESSION_ID), if any: what `self` names and
    /// the parent of sessions it starts (MA-12).
    let session: String?

    init(pane: String?, instance: String?, session: String?) {
        self.pane = pane
        self.instance = instance
        self.session = session
    }

    init(_ raw: [String: Any]) {
        pane = (raw["pane"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        instance = (raw["instance"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        session = (raw["session"] as? String).flatMap { $0.isEmpty ? nil : $0.lowercased() }
    }

    /// A pane id from a terminal of an earlier run of this instance.
    var isStale: Bool {
        guard pane != nil else { return false }
        return instance != TernPaths.instanceID
    }
}

enum TernJSON {
    /// Make a value safe for JSONSerialization: drop nils, stringify the unknown.
    static func sanitize(_ value: Any) -> Any {
        switch value {
        case let dict as [String: Any]:
            var out: [String: Any] = [:]
            for (key, element) in dict {
                if case Optional<Any>.none = element as Any? { continue }
                if let optional = element as? OptionalProtocol, optional.isNil { continue }
                out[key] = sanitize(element)
            }
            return out
        case let array as [Any]:
            return array.map(sanitize)
        case is String, is NSNumber, is NSNull, is Bool, is Int, is Double:
            return value
        case let optional as OptionalProtocol:
            return optional.isNil ? NSNull() : sanitize(optional.unwrapped)
        default:
            return "\(value)"
        }
    }
}

protocol OptionalProtocol {
    var isNil: Bool { get }
    var unwrapped: Any { get }
}

extension Optional: OptionalProtocol {
    var isNil: Bool { self == nil }
    var unwrapped: Any {
        switch self {
        case .some(let value): return value
        case .none: return NSNull()
        }
    }
}
