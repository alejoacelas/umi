// umi-next-daemon: owns every session's pty and screen state.
//
// One thread, one poll() loop over the listening socket, every pty master
// and every client connection. Each pty's output goes into a libghostty-vt
// terminal (the session's screen) and to the attached clients.
import Darwin
import Foundation
import UmiC

let foreground = CommandLine.arguments.contains("--foreground")

// ---- start-up: state dir, log, single instance, detach ----

try? FileManager.default.createDirectory(atPath: Paths.stateDir, withIntermediateDirectories: true)
let logFD = open(Paths.log, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o600)

func log(_ s: String) {
    let line = "\(ISO8601DateFormatter().string(from: Date())) [\(getpid())] \(s)\n"
    _ = line.withCString { write(logFD >= 0 ? logFD : 2, $0, strlen($0)) }
}

if !foreground {
    if umi_daemonize(logFD) != 0 { log("daemonize failed: \(errno)"); exit(1) }
}
umi_ignore_hup_pipe()

let lockFD = open(Paths.lock, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
if lockFD < 0 || flock(lockFD, LOCK_EX | LOCK_NB) != 0 {
    log("another daemon holds \(Paths.lock); exiting")
    exit(0)
}
ftruncate(lockFD, 0)
_ = "\(getpid())\n".withCString { write(lockFD, $0, strlen($0)) }

// Every session takes a pty master and every client a socket; the default soft limit (256) is
// reached with a few dozen panes.
let fdLimit = umi_raise_nofile()

let listenFD = socket(AF_UNIX, SOCK_STREAM, 0)
unlink(Paths.socket)
guard withUnixAddr(Paths.socket, { bind(listenFD, $0, $1) }) == 0 else {
    log("bind \(Paths.socket) failed (errno \(errno); path limit is 103 bytes)")
    exit(1)
}
chmod(Paths.socket, 0o600)
listen(listenFD, 64)
setNonBlocking(listenFD)
_ = fcntl(listenFD, F_SETFD, FD_CLOEXEC)

var sigPipe: [Int32] = [0, 0]
pipe(&sigPipe)
setNonBlocking(sigPipe[0]); setNonBlocking(sigPipe[1])
_ = fcntl(sigPipe[0], F_SETFD, FD_CLOEXEC); _ = fcntl(sigPipe[1], F_SETFD, FD_CLOEXEC)
umi_install_sigchld(sigPipe[1])

log("daemon started, socket \(Paths.socket), fd limit \(fdLimit)")

func setNonBlocking(_ fd: Int32) {
    _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
}

// ---- model ----

final class Session {
    let id: String
    var name: String
    /// Who started the session: "user" (the UI, for something Alejo did) or another starter
    /// ("cli": `umi-next-ctl new` from an agent or script). nil: not recorded (an older client).
    let by: String?
    let cwd: String
    let command: String?
    let pid: pid_t
    var master: Int32
    let term: GhosttyTerminal
    var cols: UInt16, rows: UInt16
    var clients: [Conn] = []
    var ptyPending = [UInt8]()
    var exitCode: Int32? = nil      // shell-style: code, or 128+signal
    var exitSignal: Int32? = nil
    let created = Date()

    init(id: String, name: String, by: String?, cwd: String, command: String?, pid: pid_t, master: Int32,
         cols: UInt16, rows: UInt16) {
        self.id = id; self.name = name; self.by = by; self.cwd = cwd; self.command = command
        self.pid = pid; self.master = master; self.cols = cols; self.rows = rows
        self.term = umi_vt_new(cols, rows)
    }

    var alive: Bool { exitCode == nil }

    func writePty(_ bytes: UnsafeRawBufferPointer) {
        guard master >= 0, bytes.count > 0 else { return }
        if ptyPending.isEmpty {
            let n = write(master, bytes.baseAddress!, bytes.count)
            if n == bytes.count { return }
            let off = n > 0 ? n : 0
            if n < 0 && errno != EAGAIN && errno != EINTR { return }
            ptyPending.append(contentsOf: UnsafeRawBufferPointer(rebasing: bytes[off...]))
        } else {
            ptyPending.append(contentsOf: bytes)
        }
    }

    func flushPty() {
        guard master >= 0, !ptyPending.isEmpty else { return }
        let n = ptyPending.withUnsafeBytes { write(master, $0.baseAddress!, $0.count) }
        if n > 0 { ptyPending.removeFirst(n) }
    }

    func resize(_ c: UInt16, _ r: UInt16) {
        guard c > 0, r > 0, c != cols || r != rows else { return }
        cols = c; rows = r
        umi_vt_resize(term, c, r)
        if master >= 0 { umi_set_winsize(master, c, r) }
    }

    func info() -> [String: Any] {
        var d: [String: Any] = [
            "id": id, "name": name, "cwd": cwd, "pid": Int(pid), "alive": alive,
            "clients": clients.count, "cols": Int(cols), "rows": Int(rows),
            "created": created.timeIntervalSince1970,
        ]
        d["command"] = command ?? NSNull()
        d["by"] = by ?? NSNull()
        d["exit_status"] = exitCode.map { Int($0) } ?? NSNull()
        d["exit_signal"] = exitSignal.map { Int($0) } ?? NSNull()
        var fg: Any = NSNull()
        if alive, master >= 0 {
            let pg = umi_tcgetpgrp(master)
            var buf = [CChar](repeating: 0, count: 256)
            umi_proc_name(pg > 0 ? pg : pid, &buf, 256)
            let s = String(cString: buf)
            if !s.isEmpty { fg = s }
        }
        d["foreground"] = fg
        return d
    }
}

final class Conn {
    let fd: Int32
    var reader = FrameReader()
    var out = [UInt8]()
    var outStart = 0
    weak var session: Session?
    var closeAfterFlush = false
    var dead = false

    init(fd: Int32) { self.fd = fd }

    var pendingOut: Int { out.count - outStart }

    func send(_ bytes: [UInt8]) {
        guard !dead else { return }
        if pendingOut == 0 {
            out.removeAll(keepingCapacity: true); outStart = 0
            let n = bytes.withUnsafeBytes { write(fd, $0.baseAddress!, $0.count) }
            if n == bytes.count { return }
            if n < 0 && errno != EAGAIN && errno != EINTR { dead = true; return }
            out.append(contentsOf: bytes[max(n, 0)...])
        } else {
            out.append(contentsOf: bytes)
        }
        // A client that stops reading must not grow the daemon without bound.
        if pendingOut > 64 << 20 { log("dropping slow client fd \(fd)"); dead = true }
    }

    func flush() {
        guard pendingOut > 0 else { return }
        let n = out.withUnsafeBytes { write(fd, $0.baseAddress! + outStart, pendingOut) }
        if n > 0 {
            outStart += n
            if outStart == out.count || outStart > 1 << 20 {
                out.removeFirst(outStart); outStart = 0
            }
        } else if n < 0 && errno != EAGAIN && errno != EINTR {
            dead = true
        }
    }
}

var sessions: [Session] = []
var conns: [Conn] = []
var stopping = false
/// While stopping: the process groups to SIGKILL if they outlive the SIGHUP (each session's, and
/// its terminal's foreground group, which a shell with job control gives its own), when the
/// grace ends, and the latest time to exit after the kill.
var stopGroups: Set<pid_t> = []
var stopKillAt = Date.distantFuture
var stopExitBy: Date? = nil
/// accept() ran out of file descriptors. macOS then drops the connection it was taking, so the
/// listening socket sits out of poll for a second: connections wait in the queue meanwhile and
/// get served if descriptors free up, instead of each being dropped on arrival.
var acceptPausedUntil = Date.distantPast
var acceptFullLogged = false

func findSession(_ id: Any?) -> Session? {
    guard let id = id as? String else { return nil }
    return sessions.first { $0.id == id } ?? sessions.first { $0.name == id && !$0.name.isEmpty }
}

func newID() -> String {
    while true {
        let id = String(format: "%08x", arc4random())
        if !sessions.contains(where: { $0.id == id }) { return id }
    }
}

// VT query responses (DA, DSR, …). When a client is attached its own
// terminal answers the same query, so the daemon answers only when nobody is
// attached; otherwise the program would get two answers.
let writePtyCallback: @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<UInt8>?, Int) -> Void = { ud, data, len in
    guard let ud, let data else { return }
    let s = Unmanaged<Session>.fromOpaque(ud).takeUnretainedValue()
    if s.clients.isEmpty { s.writePty(UnsafeRawBufferPointer(start: data, count: len)) }
}

// ---- sessions ----

func loginShell(_ env: [String: String]) -> String {
    if let s = env["SHELL"], !s.isEmpty { return s }
    if let pw = getpwuid(getuid()), let sh = pw.pointee.pw_shell { return String(cString: sh) }
    return "/bin/zsh"
}

func createSession(_ req: [String: Any]) throws -> Session {
    var env = (req["env"] as? [String: String]) ?? ProcessInfo.processInfo.environment
    let cwd = (req["cwd"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? (env["HOME"] ?? "/")
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: cwd, isDirectory: &isDir), isDir.boolValue else {
        throw NSError(domain: "umi", code: Int(ENOENT), userInfo: [NSLocalizedDescriptionKey: "no folder \(cwd)"])
    }
    let cmd = (req["cmd"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    let cols = UInt16(clamping: (req["cols"] as? Int) ?? 80)
    let rows = UInt16(clamping: (req["rows"] as? Int) ?? 24)
    let id = newID()
    env["TERM"] = "xterm-256color"
    env["COLORTERM"] = "truecolor"
    env["UMI_NEXT_SESSION_ID"] = id
    env["PWD"] = cwd
    let shell = loginShell(env)
    let argv: [String] = cmd.map { [shell, "-l", "-c", $0] } ?? [shell, "-l"]

    var cargv: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) } + [nil]
    var cenv: [UnsafeMutablePointer<CChar>?] = env.map { strdup("\($0.key)=\($0.value)") } + [nil]
    defer { cargv.forEach { free($0) }; cenv.forEach { free($0) } }
    var master: Int32 = -1
    let pid = umi_spawn_pty(shell, &cargv, &cenv, cwd, max(cols, 1), max(rows, 1), &master)
    guard pid > 0 else { throw NSError(domain: "umi", code: Int(errno), userInfo: [NSLocalizedDescriptionKey: "forkpty failed: \(String(cString: strerror(errno)))"]) }
    let s = Session(id: id, name: (req["name"] as? String) ?? "", by: req["by"] as? String, cwd: cwd, command: cmd, pid: pid,
                    master: master, cols: max(cols, 1), rows: max(rows, 1))
    umi_vt_set_write_pty(s.term, Unmanaged.passUnretained(s).toOpaque(), writePtyCallback)
    sessions.append(s)
    log("session \(id) pid \(pid) cwd \(cwd) cmd \(cmd ?? "<shell>") \(cols)x\(rows)")
    return s
}

var readBuf = [UInt8](repeating: 0, count: 1 << 16)

/// Read what the pty has now. Returns false when the pty is closed.
@discardableResult
func readPty(_ s: Session) -> Bool {
    guard s.master >= 0 else { return false }
    while true {
        let n = readBuf.withUnsafeMutableBytes { read(s.master, $0.baseAddress!, $0.count) }
        if n > 0 {
            readBuf.withUnsafeBytes { raw in
                let chunk = UnsafeRawBufferPointer(rebasing: raw[0..<n])
                ghostty_terminal_vt_write(s.term, chunk.bindMemory(to: UInt8.self).baseAddress, n)
                if !s.clients.isEmpty {
                    let frame = encodeFrame(.output, Array(chunk))
                    for c in s.clients { c.send(frame) }
                }
            }
            if n < readBuf.count { return true }
            continue
        }
        if n < 0 && (errno == EAGAIN || errno == EINTR) { return true }
        return false  // 0 or EIO: every slave fd is closed
    }
}

func closeMaster(_ s: Session) {
    if s.master >= 0 { close(s.master); s.master = -1 }
}

func finishSession(_ s: Session, status: Int32) {
    readPty(s)  // drain the last output before telling clients
    if WIFEXITED(status) {
        s.exitCode = WEXITSTATUS(status)
    } else if WIFSIGNALED(status) {
        s.exitSignal = WTERMSIG(status)
        s.exitCode = 128 + WTERMSIG(status)
    } else {
        s.exitCode = 255
    }
    closeMaster(s)
    log("session \(s.id) exited: code \(s.exitCode!) signal \(s.exitSignal.map { String($0) } ?? "-")")
    for c in s.clients {
        c.send(encodeFrame(.exit, be32(UInt32(bitPattern: s.exitCode!))))
        c.closeAfterFlush = true
    }
    s.clients.removeAll()
}

func reapChildren() {
    while true {
        var status: Int32 = 0
        let pid = waitpid(-1, &status, WNOHANG)
        if pid <= 0 { return }
        if let s = sessions.first(where: { $0.pid == pid && $0.alive }) {
            finishSession(s, status: status)
        }
    }
}

func WIFEXITED(_ s: Int32) -> Bool { (s & 0x7f) == 0 }
func WEXITSTATUS(_ s: Int32) -> Int32 { (s >> 8) & 0xff }
func WIFSIGNALED(_ s: Int32) -> Bool { (s & 0x7f) != 0 && (s & 0x7f) != 0x7f }
func WTERMSIG(_ s: Int32) -> Int32 { s & 0x7f }

func removeSession(_ s: Session) {
    for c in s.clients {
        c.send(encodeFrame(.exit, be32(UInt32(bitPattern: s.exitCode ?? 255))))
        c.closeAfterFlush = true
    }
    s.clients.removeAll()
    closeMaster(s)
    sessions.removeAll { $0 === s }
    // The terminal's userdata box is tiny; the terminal itself is freed here.
    ghostty_terminal_free(s.term)
    log("session \(s.id) removed")
}

// ---- requests ----

func reply(_ c: Conn, _ obj: [String: Any]) { c.send(encodeJSON(obj)) }
func fail(_ c: Conn, _ msg: String) { reply(c, ["ok": false, "error": msg]) }

func replayBytes(_ s: Session) -> [UInt8] {
    var len = 0
    guard let p = umi_vt_replay(s.term, &len) else { return [] }
    defer { free(p) }
    return Array(UnsafeBufferPointer(start: p, count: len))
}

func handleJSON(_ c: Conn, _ req: [String: Any]) {
    let op = req["op"] as? String ?? ""
    switch op {
    case "ping":
        reply(c, ["ok": true, "pid": Int(getpid()), "sessions": sessions.count, "state_dir": Paths.stateDir])
    case "new":
        do { reply(c, ["ok": true, "id": try createSession(req).id]) } catch { fail(c, "\(error.localizedDescription)") }
    case "ls":
        reply(c, ["ok": true, "sessions": sessions.map { $0.info() }])
    case "kill":
        guard let s = findSession(req["id"]) else { return fail(c, "no such session") }
        guard s.alive else { return fail(c, "session already exited") }
        guard let sig = Int32(exactly: (req["signal"] as? Int) ?? Int(SIGTERM)), sig >= 0, sig < NSIG else {
            return fail(c, "bad signal")
        }
        // The child leads its own session and process group (forkpty).
        if kill(-s.pid, sig) != 0 { kill(s.pid, sig) }
        reply(c, ["ok": true])
    case "rm":
        guard let s = findSession(req["id"]) else { return fail(c, "no such session") }
        if s.alive {
            guard (req["force"] as? Bool) == true else { return fail(c, "session is alive (kill it first, or --force)") }
            kill(-s.pid, SIGKILL); kill(s.pid, SIGKILL)
            var status: Int32 = 0
            if waitpid(s.pid, &status, 0) == s.pid { finishSession(s, status: status) }
        }
        removeSession(s)
        reply(c, ["ok": true])
    case "screen":
        guard let s = findSession(req["id"]) else { return fail(c, "no such session") }
        let format = req["format"] as? String ?? "plain"
        if format == "vt" {
            reply(c, ["ok": true, "vt": Data(replayBytes(s)).base64EncodedString()])
        } else {
            var o = vtState(s.term); o["ok"] = true
            if (req["scrollback"] as? Bool) == true { o.merge(vtHistory(s.term)) { a, _ in a } }
            reply(c, o)
        }
    case "send":
        guard let s = findSession(req["id"]) else { return fail(c, "no such session") }
        guard s.alive else { return fail(c, "session exited") }
        let data = Data(base64Encoded: req["data"] as? String ?? "") ?? Data()
        data.withUnsafeBytes { s.writePty($0) }
        reply(c, ["ok": true])
    case "attach":
        guard let s = findSession(req["id"]) else { return fail(c, "no such session") }
        reply(c, ["ok": true, "id": s.id])
        if s.alive {
            // Size first, so the replay is laid out for the client's terminal.
            s.resize(UInt16(clamping: (req["cols"] as? Int) ?? Int(s.cols)), UInt16(clamping: (req["rows"] as? Int) ?? Int(s.rows)))
        }
        c.send(encodeFrame(.output, replayBytes(s)))
        if s.alive {
            c.session = s
            s.clients.append(c)
        } else {
            c.send(encodeFrame(.exit, be32(UInt32(bitPattern: s.exitCode ?? 255))))
            c.closeAfterFlush = true
        }
    case "stop":
        let alive = sessions.filter { $0.alive }
        if !alive.isEmpty && (req["force"] as? Bool) != true {
            return fail(c, "\(alive.count) session(s) alive; use --force")
        }
        // The requester's connection stays open: it closes when the daemon exits.
        reply(c, ["ok": true])
        guard !stopping else { return }
        stopping = true
        for s in alive {
            stopGroups.insert(s.pid)
            if s.master >= 0 { let fg = umi_tcgetpgrp(s.master); if fg > 0 { stopGroups.insert(fg) } }
            kill(-s.pid, SIGHUP); kill(s.pid, SIGHUP)
        }
        stopKillAt = Date() + 2
        log("stopping: SIGHUP to \(alive.count) session(s)")
    default:
        fail(c, "unknown op '\(op)'")
    }
}

func handleFrame(_ c: Conn, _ type: Frame?, _ payload: [UInt8]) {
    switch type {
    case .json:
        guard let req = decodeJSON(payload) else { return fail(c, "bad json") }
        handleJSON(c, req)
    case .input:
        guard let s = c.session, s.alive else { return }
        payload.withUnsafeBytes { s.writePty($0) }
    case .resize:
        guard let s = c.session, s.alive, payload.count >= 4 else { return }
        s.resize(readBE16(payload[...], 0), readBE16(payload[...], 2))
    default:
        break
    }
}

func dropConn(_ c: Conn) {
    if let s = c.session { s.clients.removeAll { $0 === c } }
    close(c.fd)
    c.dead = true
    conns.removeAll { $0 === c }
}

// ---- loop ----

while true {
    let listening = Date() >= acceptPausedUntil
    var fds: [pollfd] = [pollfd(fd: listening ? listenFD : -1, events: Int16(POLLIN), revents: 0),
                         pollfd(fd: sigPipe[0], events: Int16(POLLIN), revents: 0)]
    let liveSessions = sessions.filter { $0.master >= 0 }
    for s in liveSessions {
        var ev = Int16(POLLIN)
        if !s.ptyPending.isEmpty { ev |= Int16(POLLOUT) }
        fds.append(pollfd(fd: s.master, events: ev, revents: 0))
    }
    let pollConns = conns
    for c in pollConns {
        var ev = Int16(POLLIN)
        if c.pendingOut > 0 { ev |= Int16(POLLOUT) }
        fds.append(pollfd(fd: c.fd, events: ev, revents: 0))
    }
    let rc = poll(&fds, nfds_t(fds.count), stopping ? 50 : 1000)
    if rc < 0 && errno != EINTR { log("poll failed: \(errno)"); exit(1) }

    if fds[1].revents != 0 {
        var b = [UInt8](repeating: 0, count: 64)
        while read(sigPipe[0], &b, 64) > 0 {}
    }
    reapChildren()  // also catches anything a missed SIGCHLD left

    if fds[0].revents & Int16(POLLIN) != 0 {
        while true {
            let fd = accept(listenFD, nil, nil)
            if fd < 0 {
                if errno == EMFILE || errno == ENFILE {
                    acceptPausedUntil = Date() + 1
                    if !acceptFullLogged {
                        log("out of file descriptors (limit \(fdLimit)); new connections wait")
                        acceptFullLogged = true
                    }
                }
                break
            }
            acceptFullLogged = false
            setNonBlocking(fd)
            _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
            var on: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            conns.append(Conn(fd: fd))
        }
    }

    for (i, s) in liveSessions.enumerated() {
        let re = fds[2 + i].revents
        guard re != 0, s.master >= 0 else { continue }
        if re & Int16(POLLOUT) != 0 { s.flushPty() }
        if re & Int16(POLLIN | POLLHUP | POLLERR) != 0 {
            if !readPty(s) {
                // Every slave fd closed; the process may still be running
                // (it closed its tty) — keep it listed until it is reaped.
                closeMaster(s)
            }
        }
    }

    let base = 2 + liveSessions.count
    for (i, c) in pollConns.enumerated() {
        let re = fds[base + i].revents
        if re & Int16(POLLOUT) != 0 { c.flush() }
        if re & Int16(POLLIN | POLLHUP | POLLERR) != 0 {
            var gotEOF = false
            while true {
                let n = readBuf.withUnsafeMutableBytes { read(c.fd, $0.baseAddress!, $0.count) }
                if n > 0 {
                    readBuf.withUnsafeBytes { c.reader.append(UnsafeRawBufferPointer(rebasing: $0[0..<n])) }
                    if n < readBuf.count { break }
                    continue
                }
                if n < 0 && (errno == EAGAIN || errno == EINTR) { break }
                gotEOF = true
                break
            }
            while let (type, payload) = c.reader.next() { handleFrame(c, type, payload) }
            if gotEOF { c.dead = true }
        }
    }

    for c in conns where c.dead || (c.closeAfterFlush && c.pendingOut == 0) {
        dropConn(c)
    }

    if stopping {
        let now = Date()
        if stopExitBy == nil {
            stopGroups = stopGroups.filter { kill(-$0, 0) == 0 || errno != ESRCH }
            if stopGroups.isEmpty || now >= stopKillAt {
                for pg in stopGroups { kill(-pg, SIGKILL) }
                if !stopGroups.isEmpty { log("stopping: SIGKILL to process groups \(stopGroups.sorted()) that outlived SIGHUP") }
                stopExitBy = now + 1
            }
        }
        // After the kill, a second at most for the last exits to be reaped and every reply and
        // exit frame to be written; a client that doesn't read doesn't hold the daemon up.
        if let by = stopExitBy,
           now >= by || (!sessions.contains(where: { $0.alive }) && conns.allSatisfy({ $0.pendingOut == 0 })) {
            log("daemon stopping")
            unlink(Paths.socket)
            exit(0)
        }
    }
}
