import Foundation
import JavaScriptCore

/// Snooze to docket: sessions Alejo sent to the docket (Hyper+D, `d` in the palette).
///
/// A docketed session shows in no pane, never in Review or the sidebar, and the ⌘D picker lists it
/// under "On the docket". When its turn ends (done, waiting, a dialog, its program gone: anything),
/// once per docketing, `~/.config/umi-next/docket-hook` runs if executable, with JSON on stdin:
///   {"session", "name", "cwd", "agent", "agent_session", "status": {"status","detail","line"}|null,
///    "dialog", "host"}
/// Exit 0: the mark becomes "on" (on the docket). Non-zero: "failed", and the session shows in Review
/// with the hook's stderr. Every run is logged to <state>/docket.log. Marks live in
/// <state>/docket.json, so they survive UI restarts. Runs on the session monitor's queue.
final class Docket {
    private let file = Paths.stateDir + "/docket.json"
    private let log = Paths.stateDir + "/docket.log"
    static var hookPath: String { NSHomeDirectory() + "/.config/umi-next/docket-hook" }
    private(set) var marks: [String: [String: Any]]
    private var js: JSContext?

    init() {
        marks = (try? JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: Paths.stateDir + "/docket.json")))) as? [String: [String: Any]] ?? [:]
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
            guard m["state"] as? String == "pending" else {
                if byID[sid] == nil { marks[sid] = nil; save() }   // ended and removed: nothing to keep
                continue
            }
            let s = byID[sid]
            let alive = s?["alive"] as? Bool ?? false
            // A turn ended: the session waits (whatever it says), or its program is gone.
            guard !alive || s?["state"] as? String == "waiting" else { continue }
            runHook(sid, s ?? [:], mark: m)
        }
    }

    private func runHook(_ sid: String, _ s: [String: Any], mark m: [String: Any]) {
        let agent = s["agent"] as? [String: Any]
        let event = agent?["event"] as? String ?? ""
        let reply = agent?["reply"] as? String
        let name = (m["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? (s["name"] as? String) ?? sid
        var payload: [String: Any] = [
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
        if FileManager.default.isExecutableFile(atPath: hook) {
            let r = Self.run(hook, stdin: (try? JSONSerialization.data(withJSONObject: payload)) ?? Data())
            entry["exit"] = r.status
            entry["stderr"] = r.err
            entry["stdout"] = r.out
            if r.status == 0 {
                next["state"] = "on"
            } else {
                next["state"] = "failed"
                next["error"] = r.err.isEmpty ? "docket-hook exited with \(r.status)" : r.err.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        } else {
            entry["exit"] = NSNull()
            entry["note"] = "no executable \(hook)"
            next["state"] = "failed"
            next["error"] = "no docket hook (\(hook) missing or not executable)"
        }
        payload.removeAll()
        next["ranAt"] = Date().timeIntervalSince1970
        marks[sid] = next
        save()
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
