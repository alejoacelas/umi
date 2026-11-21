import Foundation
import JavaScriptCore

/// Snooze to docket: sessions Alejo sent to the docket (Hyper+D, `d` in the palette).
///
/// A docketed session shows in no pane, never in Review or the sidebar, and the ⌘D picker lists it
/// under "On the docket". When its turn ends (done, waiting, a dialog, its program gone: anything),
/// once per docketing, `~/.config/umi-next/docket-hook` runs if executable, with JSON on stdin:
///   {"session", "name", "cwd", "agent", "agent_session", "status": {"status","detail","line"}|null,
///    "dialog", "host"}
/// While the hook runs the mark is "running". Exit 0: the mark becomes "on" (on the docket).
/// Non-zero: "failed", and the session shows in Review with the hook's stderr. Every run is logged
/// to <state>/docket.log. Marks live in <state>/docket.json, so they survive UI restarts.
/// Everything but the hook's process runs on the session monitor's `queue`; the hook (it calls
/// `claude -p`, up to 60 s) runs on a queue of its own, so polls go on meanwhile.
final class Docket {
    private let file = Paths.stateDir + "/docket.json"
    private let log = Paths.stateDir + "/docket.log"
    static var hookPath: String { NSHomeDirectory() + "/.config/umi-next/docket-hook" }
    private(set) var marks: [String: [String: Any]]
    private var js: JSContext?
    private let queue: DispatchQueue
    private let hookQueue = DispatchQueue(label: "umi-next.docket-hook")
    /// A hook run ended and changed a mark (called on `queue`).
    var onChange: (() -> Void)?

    init(queue: DispatchQueue) {
        self.queue = queue
        marks = (try? JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: Paths.stateDir + "/docket.json")))) as? [String: [String: Any]] ?? [:]
        // A run the UI quit during never reported back: run it again.
        for (sid, m) in marks where m["state"] as? String == "running" { marks[sid]?["state"] = "pending" }
    }

    private func save() {
        if let d = try? JSONSerialization.data(withJSONObject: marks, options: [.prettyPrinted, .sortedKeys]) {
            try? d.write(to: URL(fileURLWithPath: file), options: .atomic)
        }
    }

    func mark(_ sid: String, name: String?) {
        marks[sid] = ["since": Date().timeIntervalSince1970, "state": "pending", "name": name ?? ""]
        save()
    }

    func clear(_ sid: String) {
        guard marks.removeValue(forKey: sid) != nil else { return }
        save()
    }

    /// Called each poll with the sessions as the monitor sees them: runs the hook for docketed
    /// sessions whose turn has ended, and forgets marks of sessions that are gone.
    func check(_ sessions: [[String: Any]]) {
        let byID = Dictionary(sessions.compactMap { s in (s["id"] as? String).map { ($0, s) } }, uniquingKeysWith: { a, _ in a })
        for (sid, m) in marks {
            if m["state"] as? String == "running" { continue }
            guard m["state"] as? String == "pending" else {
                if byID[sid] == nil { marks[sid] = nil; save() }   // ended and removed: nothing to keep
                continue
            }
            let s = byID[sid]
            let alive = s?["alive"] as? Bool ?? false
            // A turn ended: the session waits (whatever it says), or its program is gone.
            guard !alive || s?["state"] as? String == "waiting" else { continue }
            // Claude's Stop hook can fire before the reply reaches the transcript: give a fresh
            // Stop up to 5 s for its reply (and status line) to appear.
            if alive, let a = s?["agent"] as? [String: Any], a["event"] as? String == "Stop",
               parseStatus(a["reply"] as? String) == nil,
               Date().timeIntervalSince1970 - (a["ts"] as? Double ?? 0) < 5 { continue }
            runHook(sid, s ?? [:], mark: m)
        }
    }

    private func runHook(_ sid: String, _ s: [String: Any], mark m: [String: Any]) {
        let agent = s["agent"] as? [String: Any]
        let event = agent?["event"] as? String ?? ""
        let reply = agent?["reply"] as? String
        let name = (m["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? (s["name"] as? String) ?? sid
        let payload: [String: Any] = [
            "session": sid, "name": name,
            "cwd": s["folder"] as? String ?? NSHomeDirectory(),
            "agent": agent?["agent"] as? String ?? (s["kind"] as? String ?? "shell"),
            "agent_session": agent?["agentSession"] ?? NSNull(),
            "status": parseStatus(reply) ?? NSNull(),
            "dialog": event == "PermissionRequest" || event == "Notification",
            "host": Self.shortHost,
        ]
        var entry: [String: Any] = ["ts": Date().timeIntervalSince1970, "session": sid, "payload": payload]
        var next = m
        let hook = Self.hookPath
        guard FileManager.default.isExecutableFile(atPath: hook) else {
            entry["exit"] = NSNull()
            entry["note"] = "no executable \(hook)"
            next["state"] = "failed"
            next["error"] = "no docket hook (\(hook) missing or not executable)"
            finish(sid, next, entry)
            return
        }
        marks[sid]?["state"] = "running"
        save()
        let stdin = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
        hookQueue.async { [self] in
            let r = Self.run(hook, stdin: stdin)
            queue.async { [self] in
                var entry = entry, next = next
                entry["exit"] = r.status
                entry["stderr"] = r.err
                entry["stdout"] = r.out
                if r.status == 0 {
                    next["state"] = "on"
                } else {
                    next["state"] = "failed"
                    next["error"] = r.err.isEmpty ? "docket-hook exited with \(r.status)" : r.err.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                // Taken off the docket, or docketed again, while the hook ran: that mark stands.
                let current = marks[sid]
                guard current?["state"] as? String == "running", current?["since"] as? Double == m["since"] as? Double else {
                    entry["note"] = "mark changed while the hook ran; result not applied"
                    writeLog(entry)
                    return
                }
                finish(sid, next, entry)
                onChange?()
            }
        }
    }

    private func finish(_ sid: String, _ next: [String: Any], _ entry: [String: Any]) {
        var next = next
        next["ranAt"] = Date().timeIntervalSince1970
        marks[sid] = next
        save()
        writeLog(entry)
    }

    private func writeLog(_ entry: [String: Any]) {
        if let line = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]),
           let h = FileHandle(forWritingAtPath: log) ?? { FileManager.default.createFile(atPath: log, contents: nil); return FileHandle(forWritingAtPath: log) }() {
            h.seekToEndOfFile()
            h.write(line + Data([10]))
            try? h.close()
        }
    }

    /// web/status.js's parseStatus, run as is (one parser for the UI and the hook):
    /// {"status": "done" | "done, pending verification" | "waiting on you" | "in progress" | other, "detail", "line"}.
    func parseStatus(_ reply: String?) -> [String: Any]? {
        guard let reply else { return nil }
        if js == nil, let src = try? String(contentsOfFile: Paths.webDir + "/status.js", encoding: .utf8) {
            let c = JSContext()!
            c.evaluateScript(src)
            js = c
        }
        guard let fn = js?.objectForKeyedSubscript("Umi")?.objectForKeyedSubscript("status")?.objectForKeyedSubscript("parseStatus"),
              let r = fn.call(withArguments: [reply]), !r.isNull, !r.isUndefined,
              let d = r.toDictionary() as? [String: Any] else { return nil }
        let names = ["done": "done", "pending": "done, pending verification", "waiting": "waiting on you", "progress": "in progress"]
        let kind = d["kind"] as? String ?? ""
        return ["status": names[kind] ?? (d["detail"] as? String ?? kind), "detail": d["detail"] ?? "", "line": d["line"] ?? ""]
    }

    static let shortHost: String = {
        var buf = [CChar](repeating: 0, count: 256)
        gethostname(&buf, buf.count)
        return String(cString: buf).components(separatedBy: ".").first ?? ""
    }()

    static func run(_ path: String, stdin: Data) -> (status: Int32, out: String, err: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        let i = Pipe(), o = Pipe(), e = Pipe()
        p.standardInput = i; p.standardOutput = o; p.standardError = e
        do { try p.run() } catch { return (-1, "", "\(error)") }
        i.fileHandleForWriting.write(stdin)
        try? i.fileHandleForWriting.close()
        let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 60, execute: killer)
        let out = o.fileHandleForReading.readDataToEndOfFile()
        let err = e.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        killer.cancel()
        return (p.terminationStatus, String(decoding: out, as: UTF8.self), String(decoding: err, as: UTF8.self))
    }
}
