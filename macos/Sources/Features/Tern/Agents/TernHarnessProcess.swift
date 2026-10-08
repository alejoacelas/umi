import Darwin
import Foundation

/// One harness process (`claude -p …` or `codex app-server`), spoken to over pipes.
///
/// - It runs as the leader of a new session and process group (so it and its children can be
///   signalled together and never get the app's terminal signals), with no file descriptor
///   of the app's other than its three pipes (POSIX_SPAWN_CLOEXEC_DEFAULT: an inherited
///   instance lock or socket would outlive the app).
/// - stdout is read on its own thread and split into lines; each line goes to `onLine` in
///   order. stderr is drained (a chatty harness never blocks) and its tail kept for errors.
/// - `onEnd` runs once, after the process has exited and stdout has been read to its end
///   (or a second after the exit, if a leftover child keeps the pipe open), so every line
///   the harness wrote is seen before its end.
final class TernHarnessProcess: @unchecked Sendable {
    let pid: pid_t
    let startedAt = Date()
    private let stdinFD: Int32
    private let stdoutFD: Int32
    private let stderrFD: Int32
    private let writeLock = NSLock()
    private var stdinClosed = false

    private let stateLock = NSLock()
    private var exitStatus: Int32?
    private var stdoutDone = false
    private var endReported = false
    private var stderrTail = Data()
    private var exitSource: DispatchSourceProcess?

    /// Called on the reader thread for every stdout line (without the newline).
    private let onLine: (Data) -> Void
    /// Called once on `queue` when the process is gone: (exit status, stderr tail).
    private let onEnd: (Int32, String) -> Void
    private let queue: DispatchQueue

    struct SpawnError: Error, CustomStringConvertible {
        let description: String
    }

    init(executable: String, arguments: [String], environment: [String: String], cwd: String,
         queue: DispatchQueue, onLine: @escaping (Data) -> Void, onEnd: @escaping (Int32, String) -> Void) throws {
        self.queue = queue
        self.onLine = onLine
        self.onEnd = onEnd

        var inPipe: [Int32] = [-1, -1]
        var outPipe: [Int32] = [-1, -1]
        var errPipe: [Int32] = [-1, -1]
        guard pipe(&inPipe) == 0, pipe(&outPipe) == 0, pipe(&errPipe) == 0 else {
            throw SpawnError(description: "couldn't create pipes (errno \(errno))")
        }
        // Our ends never leak into other children.
        for fd in [inPipe[1], outPipe[0], errPipe[0]] { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, inPipe[0], 0)
        posix_spawn_file_actions_adddup2(&actions, outPipe[1], 1)
        posix_spawn_file_actions_adddup2(&actions, errPipe[1], 2)
        posix_spawn_file_actions_addchdir_np(&actions, cwd)

        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        // POSIX_SPAWN_SETSID (0x0400) | POSIX_SPAWN_CLOEXEC_DEFAULT (0x4000) | SETSIGDEF | SETSIGMASK
        let flags = Int16(0x0400 | 0x4000 | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK)
        posix_spawnattr_setflags(&attr, flags)
        var defaults = sigset_t()
        sigfillset(&defaults)
        posix_spawnattr_setsigdefault(&attr, &defaults)
        var mask = sigset_t()
        sigemptyset(&mask)
        posix_spawnattr_setsigmask(&attr, &mask)

        let argv = [executable] + arguments
        let envp = environment.map { "\($0.key)=\($0.value)" }
        var cArgs = argv.map { strdup($0) } + [nil]
        var cEnv = envp.map { strdup($0) } + [nil]
        defer {
            for p in cArgs { free(p) }
            for p in cEnv { free(p) }
        }
        var child: pid_t = 0
        let rc = posix_spawn(&child, executable, &actions, &attr, &cArgs, &cEnv)
        close(inPipe[0])
        close(outPipe[1])
        close(errPipe[1])
        guard rc == 0 else {
            close(inPipe[1])
            close(outPipe[0])
            close(errPipe[0])
            throw SpawnError(description: "couldn't start \(executable): \(String(cString: strerror(rc)))")
        }
        pid = child
        stdinFD = inPipe[1]
        stdoutFD = outPipe[0]
        stderrFD = errPipe[0]
        // Writing to a harness that died must fail, not kill the app.
        _ = fcntl(stdinFD, F_SETNOSIGPIPE, 1)

        startReaders()
        watchExit()
    }

    // MARK: Writing

    /// Write one line (a newline is added). False if the harness can't take input any more.
    /// `TERN_AGENT_TRACE=<folder>` (on the app): every line to and from harnesses is appended
    /// to `<folder>/<pid>.jsonl`, for debugging a protocol exchange.
    private static let traceFolder = ProcessInfo.processInfo.environment["TERN_AGENT_TRACE"].flatMap { $0.isEmpty ? nil : $0 }
    private lazy var traceFD: Int32 = {
        guard let folder = Self.traceFolder else { return -1 }
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        return open("\(folder)/\(pid).jsonl", O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o600)
    }()
    private let traceLock = NSLock()

    func trace(_ direction: String, _ line: Data) {
        guard Self.traceFolder != nil else { return }
        traceLock.lock()
        defer { traceLock.unlock() }
        guard traceFD >= 0 else { return }
        var record = Data("{\"t\":\(Date().timeIntervalSince1970),\"k\":\"\(direction)\",\"m\":".utf8)
        record.append(line.prefix(64 * 1024))
        record.append(contentsOf: Array("}\n".utf8))
        record.withUnsafeBytes { _ = Darwin.write(traceFD, $0.baseAddress!, $0.count) }
    }

    @discardableResult
    func writeLine(_ data: Data) -> Bool {
        trace("in", data)
        writeLock.lock()
        defer { writeLock.unlock() }
        guard !stdinClosed else { return false }
        var bytes = data
        bytes.append(0x0A)
        return bytes.withUnsafeBytes { raw -> Bool in
            var offset = 0
            while offset < raw.count {
                let n = Darwin.write(stdinFD, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if n < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                offset += n
            }
            return true
        }
    }

    func writeJSON(_ object: [String: Any]) -> Bool {
        guard let data = try? JSONSerialization.data(withJSONObject: TernJSON.sanitize(object),
                                                     options: [.withoutEscapingSlashes]) else { return false }
        return writeLine(data)
    }

    func closeStdin() {
        writeLock.lock()
        defer { writeLock.unlock() }
        guard !stdinClosed else { return }
        stdinClosed = true
        close(stdinFD)
    }

    var hasExited: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return exitStatus != nil
    }

    var stderrText: String {
        stateLock.lock()
        defer { stateLock.unlock() }
        return String(decoding: stderrTail, as: UTF8.self)
    }

    func signalGroup(_ signal: Int32) {
        kill(-pid, signal)
        kill(pid, signal)
    }

    // MARK: Reading

    private func startReaders() {
        let out = stdoutFD
        let thread = Thread { [weak self] in
            var buffer = Data()
            var chunk = [UInt8](repeating: 0, count: 256 * 1024)
            while true {
                let n = Darwin.read(out, &chunk, chunk.count)
                if n < 0 && errno == EINTR { continue }
                if n <= 0 { break }
                buffer.append(contentsOf: chunk[0..<n])
                var start = buffer.startIndex
                while let newline = buffer[start...].firstIndex(of: 0x0A) {
                    let line = buffer[start..<newline]
                    if !line.isEmpty {
                        self?.trace("out", Data(line))
                        self?.onLine(Data(line))
                    }
                    start = buffer.index(after: newline)
                }
                if start != buffer.startIndex { buffer.removeSubrange(buffer.startIndex..<start) }
            }
            if !buffer.isEmpty { self?.onLine(buffer) }
            close(out)
            self?.stdoutFinished()
        }
        thread.name = "tern harness stdout"
        thread.stackSize = 1 << 20
        thread.start()

        let err = stderrFD
        let errThread = Thread { [weak self] in
            var chunk = [UInt8](repeating: 0, count: 64 * 1024)
            while true {
                let n = Darwin.read(err, &chunk, chunk.count)
                if n < 0 && errno == EINTR { continue }
                if n <= 0 { break }
                self?.appendStderr(Data(chunk[0..<n]))
            }
            close(err)
        }
        errThread.name = "tern harness stderr"
        errThread.start()
    }

    private func appendStderr(_ data: Data) {
        stateLock.lock()
        stderrTail.append(data)
        if stderrTail.count > 32 * 1024 { stderrTail = stderrTail.suffix(16 * 1024) }
        stateLock.unlock()
    }

    private func stdoutFinished() {
        stateLock.lock()
        stdoutDone = true
        stateLock.unlock()
        reportEndIfReady(force: false)
    }

    // MARK: Exit

    private func watchExit() {
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
        source.setEventHandler { [weak self] in self?.reap() }
        exitSource = source
        source.resume()
        // It may already have exited before the source was armed.
        queue.async { [weak self] in self?.reap() }
    }

    private func reap() {
        var status: Int32 = 0
        let rc = waitpid(pid, &status, WNOHANG)
        guard rc == pid else { return }
        stateLock.lock()
        exitStatus = status
        stateLock.unlock()
        exitSource?.cancel()
        exitSource = nil
        reportEndIfReady(force: false)
        // A leftover child holding stdout open must not keep the end from being noticed.
        queue.asyncAfter(deadline: .now() + 1.0) { [weak self] in self?.reportEndIfReady(force: true) }
    }

    private func reportEndIfReady(force: Bool) {
        stateLock.lock()
        guard !endReported, let status = exitStatus, stdoutDone || force else {
            stateLock.unlock()
            return
        }
        endReported = true
        let tail = String(decoding: stderrTail, as: UTF8.self)
        stateLock.unlock()
        writeLock.lock()
        if !stdinClosed {
            stdinClosed = true
            close(stdinFD)
        }
        writeLock.unlock()
        queue.async { [onEnd] in onEnd(status, tail) }
    }

    /// A readable description of a wait status.
    static func describe(_ status: Int32) -> String {
        let signal = status & 0x7f
        if signal == 0 { return "exited with code \((status >> 8) & 0xff)" }
        if signal == 0x7f { return "stopped" }
        let name = String(cString: strsignal(signal))
        return "was killed by signal \(signal) (\(name))"
    }

    static func exitCode(_ status: Int32) -> Int32? {
        (status & 0x7f) == 0 ? (status >> 8) & 0xff : nil
    }
}
