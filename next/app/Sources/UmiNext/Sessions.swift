import Foundation

/// What the UI knows about every daemon session, sent to the web layer as `sessions`:
/// the daemon's `ls`, each session's project, and its agent's state from Umi's hook plugin.
///
/// Agent state comes from Umi's Claude Code / Codex plugin (app/macos/UmiPlugins), which calls
/// `$UMI_CLI hook EVENT`; daemon sessions point UMI_CLI at umi-next-hook, which writes
/// <state>/agents/<session>.json. "waiting" = the agent stopped and waits for Alejo (Stop,
/// Notification, PermissionRequest, StopFailure); "busy" = a turn is running; the file goes when
/// the agent's session ends. Shell sessions: "busy" while a program other than the shell runs.
final class SessionMonitor {
    private let queue = DispatchQueue(label: "umi-next.sessions")
    private var timer: DispatchSourceTimer?
    private var watcher: FileWatcher?
    private var projects: [String: String] = [:]   // folder → project (git main folder)
    /// session → last folder its pane reported (OSC 7), kept across UI restarts.
    private var pwds: [String: String]
    private let pwdFile = Paths.stateDir + "/session-folders.json"
    var onUpdate: (([[String: Any]]) -> Void)?
    /// Sessions shown in a pane (asked on the main thread each poll).
    var shownSessions: () -> Set<String> = { [] }
    private(set) var last: [[String: Any]] = []

    static var agentsDir: String { Paths.stateDir + "/agents" }

    init() {
        pwds = (try? JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: Paths.stateDir + "/session-folders.json")))) as? [String: String] ?? [:]
        try? FileManager.default.createDirectory(atPath: Self.agentsDir, withIntermediateDirectories: true)
    }

    func start() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: 1.5)
        t.setEventHandler { [weak self] in self?.poll() }
        t.resume()
        timer = t
        watcher = FileWatcher(path: Self.agentsDir) { [weak self] in self?.pollSoon() }
    }

    func pollSoon() { queue.async { [weak self] in self?.poll() } }

    func notePwd(session: String, pwd: String) {
        queue.async { [self] in
            guard pwds[session] != pwd else { return }
            pwds[session] = pwd
            if let d = try? JSONSerialization.data(withJSONObject: pwds) { try? d.write(to: URL(fileURLWithPath: pwdFile), options: .atomic) }
        }
    }

    private func poll() {
        guard let list = SessionBackend.sessions() else { return }
        let shown = DispatchQueue.main.sync { shownSessions() }
        var out: [[String: Any]] = []
        for var s in list {
            guard let id = s["id"] as? String else { continue }
            let alive = s["alive"] as? Bool ?? false
            if !alive && !shown.contains(id) {
                // Ended while no pane showed it: forget it in the daemon.
                SessionBackend.run(SessionBackend.ctlPath, ["rm", id])
                try? FileManager.default.removeItem(atPath: Self.agentsDir + "/\(id).json")
                continue
            }
            var agent = readAgent(id)
            let folder = pwds[id] ?? (agent?["cwd"] as? String) ?? (s["cwd"] as? String) ?? NSHomeDirectory()
            s["folder"] = folder
            s["project"] = project(of: folder)
            if let a = agent, a["state"] as? String == "ended" { agent = nil }
            if let agent { s["agent"] = agent }
            let shell = ((s["command"] as? String) == nil)
            let fg = s["foreground"] as? String ?? ""
            let shellBusy = shell && !fg.isEmpty && !["zsh", "-zsh", "bash", "-bash", "fish", "sh", "login"].contains(fg)
            s["state"] = agent?["state"] as? String ?? (shellBusy ? "busy" : "waiting")
            s["kind"] = (agent?["agent"] as? String) ?? (shell ? "shell" : "command")
            out.append(s)
        }
        last = out
        DispatchQueue.main.async { self.onUpdate?(out) }
    }

    private func readAgent(_ id: String) -> [String: Any]? {
        let path = Self.agentsDir + "/\(id).json"
        guard let d = FileManager.default.contents(atPath: path),
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
        let event = j["event"] as? String ?? ""
        let input = j["input"] as? [String: Any] ?? [:]
        let state: String
        switch event {
        case "Stop", "StopFailure", "Notification", "PermissionRequest", "Interrupt", "SessionStart": state = "waiting"
        case "SessionEnd": state = "ended"
        default: state = "busy"
        }
        var a: [String: Any] = ["agent": j["agent"] ?? "claude", "event": event, "state": state, "ts": j["ts"] ?? 0]
        if let c = input["cwd"] { a["cwd"] = c }
        if let t = input["transcript_path"] { a["transcript"] = t }
        if let sid = input["session_id"] { a["agentSession"] = sid }
        return a
    }

    /// The main folder of the git repository `folder` is in (worktrees count as their repository),
    /// else the folder itself.
    func project(of folder: String) -> String {
        if let p = projects[folder] { return p }
        let r = SessionBackend.run("/usr/bin/git", ["-C", folder, "rev-parse", "--path-format=absolute", "--git-common-dir"])
        var p = folder
        if r.status == 0 {
            let common = r.out.trimmingCharacters(in: .whitespacesAndNewlines)
            p = common.hasSuffix("/.git") ? String(common.dropLast(5)) : (common as NSString).deletingLastPathComponent
        }
        projects[folder] = p
        return p
    }

    /// `pastSessions` on the monitor's queue; `done` runs on the main thread.
    func past(project: String, done: @escaping ([[String: Any]]) -> Void) {
        queue.async { [self] in
            let live = Set(last.compactMap { ($0["agent"] as? [String: Any])?["agentSession"] as? String })
            let list = pastSessions(project: project, exclude: live)
            DispatchQueue.main.async { done(list) }
        }
    }

    /// Claude Code and Codex sessions that ended and can be resumed, in `project`, newest first.
    private func pastSessions(project: String, exclude: Set<String>, limit: Int = 40) -> [[String: Any]] {
        var files: [(URL, Date, String)] = []
        let fm = FileManager.default
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let claude = home.appendingPathComponent(".claude/projects")
        for dir in (try? fm.contentsOfDirectory(at: claude, includingPropertiesForKeys: nil)) ?? [] {
            for f in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] where f.pathExtension == "jsonl" {
                let m = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                files.append((f, m, "claude"))
            }
        }
        if let e = fm.enumerator(at: home.appendingPathComponent(".codex/sessions"), includingPropertiesForKeys: [.contentModificationDateKey]) {
            for case let f as URL in e where f.pathExtension == "jsonl" {
                let m = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                files.append((f, m, "codex"))
            }
        }
        files.sort { $0.1 > $1.1 }
        var out: [[String: Any]] = []
        for (f, mtime, kind) in files.prefix(400) {
            guard let h = try? FileHandle(forReadingFrom: f) else { continue }
            let data = h.readData(ofLength: 256 * 1024)
            try? h.close()
            var cwd: String?, id: String?, title: String?, prompt: String?
            for line in data.split(separator: 10) {
                guard let j = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
                if kind == "claude" {
                    if id == nil { id = j["sessionId"] as? String }
                    if cwd == nil { cwd = j["cwd"] as? String }
                    if title == nil, j["type"] as? String == "ai-title" { title = j["aiTitle"] as? String }
                    if prompt == nil, j["type"] as? String == "user", (j["isSidechain"] as? Bool) != true,
                       let c = (j["message"] as? [String: Any])?["content"] as? String { prompt = c }
                } else if j["type"] as? String == "session_meta", let p = j["payload"] as? [String: Any] {
                    id = p["id"] as? String; cwd = p["cwd"] as? String
                } else if prompt == nil, let p = j["payload"] as? [String: Any], p["type"] as? String == "user_message" {
                    prompt = p["message"] as? String
                }
                if cwd != nil && id != nil && prompt != nil && (kind == "codex" || title != nil) { break }
            }
            guard let cwd, let id, !exclude.contains(id), self.project(of: cwd) == project else { continue }
            if kind == "codex" && prompt == nil { prompt = f.deletingPathExtension().lastPathComponent }
            out.append(["kind": kind, "id": id, "cwd": cwd, "title": title ?? prompt ?? id,
                        "mtime": mtime.timeIntervalSince1970])
            if out.count >= limit { break }
        }
        return out
    }
}
