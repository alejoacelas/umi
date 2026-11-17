import Foundation

/// The `umi-next` CLI's socket: `<state>/ui.sock` (mode 0600), framed as the daemon's `J` messages
/// (next/daemon/PROTOCOL.md): type 'J', payload length u32 big endian, a JSON object. One request
/// per connection; the reply is `{"ok": true, "result": …}` or `{"ok": false, "error": "…"}`.
///
/// The layout lives in the page, so each request goes to it as `{type: 'cli', id, req}` and its
/// answer comes back as `{type: 'cliReply', id, ok, result|error}` (web/cli.js). A request waits
/// for the page's hello for up to 5 s after a launch or reload. A reload drops the page's own
/// state: requests it was answering fail ("try again"), except waits (`comments.wait`), which are
/// sent again to the new page. `native.*` requests are answered here (the focus log's open
/// stretch).
final class ControlServer {
    typealias Reply = ([String: Any]) -> Void
    private struct Pending {
        let req: [String: Any]
        let done: Reply
        var sentTo: Int?        // the page generation it went to
        let since: Date
    }

    private var fd: Int32 = -1
    private var pending: [String: Pending] = [:]   // main thread only
    private var seq = 0
    private var generation = 0
    private var ready = false
    /// Sends a message to the page (MainWindowController.send).
    var sendToPage: (([String: Any]) -> Void)?
    /// Requests native answers itself: name → handler.
    var native: [String: ([String: Any]) -> [String: Any]] = [:]

    init() {
        let path = Paths.uiSocket
        unlink(path)
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        guard path.utf8.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            NSLog("umi-next: ui socket path too long: %@", path); return
        }
        _ = withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            path.withCString { strncpy(buf.baseAddress!.assumingMemoryBound(to: CChar.self), $0, buf.count - 1) }
        }
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard ok == 0, listen(fd, 16) == 0 else { NSLog("umi-next: ui socket failed: %s", strerror(errno)); return }
        chmod(path, 0o600)
        Thread.detachNewThread { [weak self] in self?.acceptLoop() }
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.expireUnsent() }
    }

    private func acceptLoop() {
        while true {
            let c = accept(fd, nil, nil)
            if c < 0 { if errno == EINTR { continue } else { return } }
            var on: Int32 = 1
            setsockopt(c, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            Thread.detachNewThread { [weak self] in self?.serve(c) }
        }
    }

    /// Reads one request, hands it to the main thread, writes its reply. A client that goes away
    /// (a `comments wait` killed by its timeout) cancels its request.
    private func serve(_ c: Int32) {
        defer { close(c) }
        guard let req = Self.readJSON(c) else { return }
        let sem = DispatchSemaphore(value: 0)
        var reply: [String: Any] = ["ok": false, "error": "no reply"]
        var id = ""
        DispatchQueue.main.sync {
            id = self.submit(req) { r in reply = r; sem.signal() }
        }
        // Wait for the reply, noticing a client that hung up.
        while sem.wait(timeout: .now() + 0.5) == .timedOut {
            var p = pollfd(fd: c, events: Int16(POLLIN), revents: 0)
            if poll(&p, 1, 0) > 0, p.revents & Int16(POLLHUP | POLLIN) != 0 {
                var b: UInt8 = 0
                if recv(c, &b, 1, MSG_PEEK | MSG_DONTWAIT) == 0 {
                    DispatchQueue.main.async { self.cancel(id) }
                    return
                }
            }
        }
        Self.writeJSON(c, reply)
    }

    private func submit(_ req: [String: Any], done: @escaping Reply) -> String {
        seq += 1
        let id = "c\(seq)"
        let cmd = req["cmd"] as? String ?? ""
        if cmd.hasPrefix("native."), let h = native[cmd] {
            done(h(req))
            return id
        }
        pending[id] = Pending(req: req, done: done, sentTo: nil, since: Date())
        if ready { send(id) }
        return id
    }

    private func send(_ id: String) {
        guard var p = pending[id] else { return }
        p.sentTo = generation
        pending[id] = p
        sendToPage?(["type": "cli", "id": id, "req": p.req])
    }

    private func cancel(_ id: String) {
        guard let p = pending.removeValue(forKey: id) else { return }
        if p.sentTo != nil { sendToPage?(["type": "cliCancel", "id": id]) }
    }

    /// The page said hello (a launch or a reload).
    func pageReady() {
        generation += 1
        ready = true
        for (id, p) in pending {
            if p.sentTo == nil || Self.isWait(p.req) { send(id) }
            else { pending[id] = nil; p.done(["ok": false, "error": "the web layer reloaded while answering; try again"]) }
        }
    }

    /// The page is going away (reload, crash): nothing goes to it until its next hello.
    func pageGone() { ready = false }

    func reply(_ msg: [String: Any]) {
        guard let id = msg["id"] as? String, let p = pending.removeValue(forKey: id) else { return }
        var r: [String: Any] = ["ok": msg["ok"] as? Bool ?? false]
        if let v = msg["result"] { r["result"] = v }
        if let e = msg["error"] { r["error"] = e }
        p.done(r)
    }

    private func expireUnsent() {
        for (id, p) in pending where p.sentTo == nil && Date().timeIntervalSince(p.since) > 5 {
            pending[id] = nil
            p.done(["ok": false, "error": "the web layer isn't running (see the banner in Umi next's window)"])
        }
    }

    private static func isWait(_ req: [String: Any]) -> Bool { (req["cmd"] as? String) == "comments.wait" }

    // MARK: Framing ('J', u32 big-endian length, JSON)

    static func readJSON(_ fd: Int32) -> [String: Any]? {
        func readN(_ n: Int) -> [UInt8]? {
            var out = [UInt8](repeating: 0, count: n)
            var off = 0
            while off < n {
                let r = out.withUnsafeMutableBytes { read(fd, $0.baseAddress! + off, n - off) }
                if r < 0 && errno == EINTR { continue }
                if r <= 0 { return nil }
                off += r
            }
            return out
        }
        guard let head = readN(5), head[0] == 0x4A else { return nil }
        let len = Int(head[1]) << 24 | Int(head[2]) << 16 | Int(head[3]) << 8 | Int(head[4])
        guard len < 64 << 20, let body = readN(len) else { return nil }
        return (try? JSONSerialization.jsonObject(with: Data(body))) as? [String: Any]
    }

    static func writeJSON(_ fd: Int32, _ obj: [String: Any]) {
        let data = (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])) ?? Data("{}".utf8)
        let n = UInt32(data.count)
        var out: [UInt8] = [0x4A, UInt8(n >> 24), UInt8((n >> 16) & 0xff), UInt8((n >> 8) & 0xff), UInt8(n & 0xff)]
        out.append(contentsOf: data)
        var off = 0
        while off < out.count {
            let w = out.withUnsafeBytes { write(fd, $0.baseAddress! + off, out.count - off) }
            if w < 0 && errno == EINTR { continue }
            if w <= 0 { return }
            off += w
        }
    }
}
