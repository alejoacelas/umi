import Foundation

/// What the UI knows about every daemon session, sent to the web layer as `sessions`:
/// the daemon's `ls`, each session's project, and its agent's state from Umi's hook plugin.
///
/// Agent state comes from Umi's Claude Code / Codex plugin (app/macos/UmiPlugins), which calls
/// `$UMI_CLI hook EVENT`; daemon sessions point UMI_CLI at umi-next-hook, which writes
/// <state>/agents/<session>.json. "waiting" = the agent stopped and waits for Alejo (Stop,
/// Notification, PermissionRequest, StopFailure); "busy" = a turn is running. The file stays after
/// the agent exits; it goes, with the session's entry in session-folders.json, once the daemon no
/// longer lists the session. Shell sessions: "busy" while a program other than the shell runs.
final class SessionMonitor {
    private let queue = DispatchQueue(label: "umi-next.sessions")
    private let historyQueue = DispatchQueue(label: "umi-next.project-history", qos: .utility)
    private var historyCache: (date: Date, paths: [String])?
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
    let docket: Docket

    /// Sends a session to the docket (or takes it off); both on the monitor's queue.
    func setDocketed(_ sid: String, _ on: Bool, name: String? = nil) {
        queue.async { [self] in
            if on { docket.mark(sid, name: name) } else { docket.clear(sid) }
            poll()
        }
    }
    /// Whether `last` comes from the daemon yet (before the first poll it's empty, not "no sessions").
    private(set) var polled = false

    static var agentsDir: String { Paths.stateDir + "/agents" }

    init() {
        docket = Docket(queue: queue)
        pwds = (try? JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: Paths.stateDir + "/session-folders.json")))) as? [String: String] ?? [:]
        try? FileManager.default.createDirectory(atPath: Self.agentsDir, withIntermediateDirectories: true)
        docket.onChange = { [weak self] in self?.poll() }
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
            savePwds()
        }
    }

    private func savePwds() {
        if let d = try? JSONSerialization.data(withJSONObject: pwds) { try? d.write(to: URL(fileURLWithPath: pwdFile), options: .atomic) }
    }

    /// Forgets the agent files and folders of sessions the daemon no longer lists. A file younger
    /// than 60 s is kept: its session may have started after `listed` was asked for.
    private func forgetEnded(listed: Set<String>) {
        let fm = FileManager.default
        let now = Date()
        for name in (try? fm.contentsOfDirectory(atPath: Self.agentsDir)) ?? [] where name.hasSuffix(".json") && !name.hasPrefix(".") {
            let id = String(name.dropLast(5))
            guard !listed.contains(id) else { continue }
            let path = Self.agentsDir + "/" + name
            guard let m = (try? fm.attributesOfItem(atPath: path))?[.modificationDate] as? Date,
                  now.timeIntervalSince(m) > 60 else { continue }
            try? fm.removeItem(atPath: path)
        }
        // A folder is noted only for a session a pane shows, which the daemon listed first.
        let gone = pwds.keys.filter { !listed.contains($0) }
        if !gone.isEmpty {
            gone.forEach { pwds[$0] = nil }
            savePwds()
        }
    }

    private func poll() {
        guard let list = SessionBackend.sessions() else { return }
        if !SessionBackend.plainShell { forgetEnded(listed: Set(list.compactMap { $0["id"] as? String })) }
        let shown = DispatchQueue.main.sync { shownSessions() }
        var out: [[String: Any]] = []
        for var s in list {
            guard let id = s["id"] as? String else { continue }
            let alive = s["alive"] as? Bool ?? false
            let docketPending = ["pending", "running"].contains(docket.marks[id]?["state"] as? String ?? "")
            if !alive && !shown.contains(id) && !docketPending {
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
            let antigravity = Self.isAntigravity(s["command"] as? String) || Self.isAntigravity(fg)
            s["kind"] = (agent?["agent"] as? String) ?? (antigravity ? "antigravity" : (shell ? "shell" : "command"))
            out.append(s)
        }
        docket.check(out)
        for i in out.indices {
            if let id = out[i]["id"] as? String, let m = docket.marks[id] { out[i]["docket"] = m }
        }
        DispatchQueue.main.async { self.last = out; self.polled = true; self.onUpdate?(out) }
    }

    /// Antigravity has no Umi hooks; identify its executable rather than arbitrary command text.
    private static func isAntigravity(_ command: String?) -> Bool {
        guard let command else { return false }
        let text = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = text.first else { return false }
        let executable: Substring
        if first == "\"" || first == "'" {
            let rest = text.dropFirst()
            guard let end = rest.firstIndex(of: first) else { return false }
            // A quoted executable must end at the token boundary, not be part of a longer name.
            let tail = rest[rest.index(after: end)...]
            guard tail.isEmpty || tail.first!.isWhitespace else { return false }
            executable = rest[..<end]
        } else {
            executable = text.prefix { !$0.isWhitespace }
        }
        return (String(executable) as NSString).lastPathComponent == "agy"
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
        if let t = input["transcript_path"] as? String {
            a["transcript"] = t
            // The turn ended: its last reply (its status line decides Review; web/status.js).
            if event == "Stop" || event == "StopFailure", let r = lastReply(transcript: t) { a["reply"] = r }
        }
        if let sid = input["session_id"] { a["agentSession"] = sid }
        return a
    }

    private var replyCache: [String: (Date, String)] = [:]

    /// The text of the last assistant reply in a Claude Code or Codex transcript (its last 4000
    /// characters), read from the file's last 512 KB.
    func lastReply(transcript path: String) -> String? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let mtime = attrs[.modificationDate] as? Date, let size = attrs[.size] as? UInt64 else { return nil }
        if let c = replyCache[path], c.0 == mtime { return c.1 }
        guard let h = FileHandle(forReadingAtPath: path) else { return nil }
        let start = size > 512 * 1024 ? size - 512 * 1024 : 0
        try? h.seek(toOffset: start)
        let data = h.readDataToEndOfFile()
        try? h.close()
        var reply: String?
        for line in data.split(separator: 10).reversed() {
            guard let j = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
            var texts: [String] = []
            if j["type"] as? String == "assistant", let content = (j["message"] as? [String: Any])?["content"] as? [[String: Any]] {
                texts = content.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }       // Claude Code
            } else if let p = j["payload"] as? [String: Any] {
                if p["type"] as? String == "message", p["role"] as? String == "assistant", let content = p["content"] as? [[String: Any]] {
                    texts = content.compactMap { $0["text"] as? String }                                            // Codex
                } else if p["type"] as? String == "agent_message", let m = p["message"] as? String {
                    texts = [m]
                }
            } else if j["type"] as? String == "user", (j["message"] as? [String: Any])?["content"] is String {
                break // a new prompt: no reply after it
            }
            let text = texts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { reply = String(text.suffix(4000)); break }
        }
        if let reply { replyCache[path] = (mtime, reply) }
        return reply
    }

    /// `project(of:)` on the monitor's queue; `done` runs on the main thread.
    func projectAsync(_ folder: String, done: @escaping (String) -> Void) {
        queue.async { [self] in
            let p = project(of: folder)
            DispatchQueue.main.async { done(p) }
        }
    }

    /// The main folder of the git repository `folder` is in (worktrees count as their repository),
    /// else the folder itself.
    func project(of folder: String) -> String {
        if let p = projects[folder] { return p }
        let p = Self.resolveProject(folder)
        projects[folder] = p
        return p
    }

    private static func resolveProject(_ folder: String) -> String {
        let r = SessionBackend.run("/usr/bin/git", ["-C", folder, "rev-parse", "--path-format=absolute", "--git-common-dir"])
        var p = folder
        if r.status == 0 {
            let common = r.out.trimmingCharacters(in: .whitespacesAndNewlines)
            p = common.hasSuffix("/.git") ? String(common.dropLast(5)) : (common as NSString).deletingLastPathComponent
        }
        return p
    }

    /// `pastSessions` on the monitor's queue; `done` runs on the main thread.
    func past(project: String, done: @escaping ([[String: Any]]) -> Void) {
        // Read here, on the main thread, where `last` is written.
        let live = Set(last.compactMap { ($0["agent"] as? [String: Any])?["agentSession"] as? String })
        queue.async { [self] in
            let list = pastSessions(project: project, exclude: live)
            DispatchQueue.main.async { done(list) }
        }
    }

    /// Projects from agent transcripts, including sessions started outside Umi.
    func agentProjects(done: @escaping ([String]) -> Void) {
        historyQueue.async { [self] in
            if let cache = historyCache, Date().timeIntervalSince(cache.date) < 60 {
                DispatchQueue.main.async { done(cache.paths) }
                return
            }
            var seen = Set<String>()
            var folders = Set<String>()
            let list = pastSessions(project: nil, exclude: [], limit: Int.max).compactMap { row -> String? in
                guard let cwd = row["cwd"] as? String, folders.insert(cwd).inserted else { return nil }
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: cwd, isDirectory: &isDir), isDir.boolValue else { return nil }
                let path = Self.resolveProject(cwd)
                guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue,
                      seen.insert(path).inserted else { return nil }
                return path
            }
            historyCache = (Date(), list)
            DispatchQueue.main.async { done(list) }
        }
    }

    /// Codex keeps user-assigned and generated session names in an append-only index.
    private static func codexTitles(_ url: URL) -> [String: String] {
        var titles: [String: String] = [:]
        readJSONLines(url) { row in
            if let id = row["id"] as? String, let name = row["thread_name"] as? String,
               !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                titles[id] = name
            }
            return true
        }
        return titles
    }

    /// Stream complete records, including prompts after long tool/instruction preambles.
    /// Returning false stops reading immediately, so indexed titles need only session metadata.
    private static func readJSONLines(_ url: URL, visit: ([String: Any]) -> Bool) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        var pending = Data()
        while true {
            let chunk = handle.readData(ofLength: 64 * 1024)
            pending.append(chunk)
            var offset = 0
            while offset < pending.count {
                let end = pending.withUnsafeBytes { bytes -> Int? in
                    guard let start = bytes.baseAddress,
                          let newline = memchr(start.advanced(by: offset), 10, bytes.count - offset) else { return nil }
                    return start.distance(to: newline)
                }
                guard let end = end ?? (chunk.isEmpty ? pending.count : nil) else { break }
                let line = pending[offset..<end]
                offset = end == pending.count ? end : end + 1
                if let row = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any], !visit(row) { return }
            }
            if offset > 0 { pending = Data(pending.dropFirst(offset)) }
            if chunk.isEmpty { return }
        }
    }

    private static func codexSession(_ url: URL, titles: [String: String], metadataOnly: Bool) -> [String: Any]? {
        var cwd: String?, id: String?, prompt: String?
        readJSONLines(url) { row in
            guard let payload = row["payload"] as? [String: Any] else { return true }
            if row["type"] as? String == "session_meta" {
                if id == nil { id = payload["id"] as? String }
                if cwd == nil { cwd = payload["cwd"] as? String }
            } else if prompt == nil, payload["type"] as? String == "user_message" {
                prompt = payload["message"] as? String
            } else if prompt == nil, row["type"] as? String == "response_item",
                      payload["type"] as? String == "message", payload["role"] as? String == "user",
                      let content = payload["content"] as? [[String: Any]] {
                let texts = content.compactMap { item -> String? in
                    guard item["type"] as? String == "input_text", let text = item["text"] as? String else { return nil }
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    // These user-role records are harness context, not the user's request.
                    guard !trimmed.isEmpty, !trimmed.hasPrefix("# AGENTS.md instructions"),
                          !trimmed.hasPrefix("<environment_context>") else { return nil }
                    return trimmed
                }
                if !texts.isEmpty { prompt = texts.joined(separator: "\n") }
            }
            return !(cwd != nil && id != nil && (metadataOnly || titles[id!] != nil || prompt != nil))
        }
        guard let cwd, let id else { return nil }
        return ["kind": "codex", "id": id, "cwd": cwd, "title": titles[id] ?? prompt ?? id]
    }

    /// Claude Code and Codex sessions that ended and can be resumed, in `project`, newest first.
    private func pastSessions(project: String?, exclude: Set<String>, limit: Int = 40) -> [[String: Any]] {
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
        let codexTitles = project == nil ? [:] : Self.codexTitles(home.appendingPathComponent(".codex/session_index.jsonl"))
        var out: [[String: Any]] = []
        for (f, mtime, kind) in files.prefix(project == nil ? files.count : 400) {
            if kind == "codex" {
                guard var row = Self.codexSession(f, titles: codexTitles, metadataOnly: project == nil),
                      let cwd = row["cwd"] as? String, let id = row["id"] as? String,
                      !exclude.contains(id), (project == nil || self.project(of: cwd) == project) else { continue }
                row["mtime"] = mtime.timeIntervalSince1970
                out.append(row)
                if out.count >= limit { break }
                continue
            }
            guard let h = try? FileHandle(forReadingFrom: f) else { continue }
            let data = h.readData(ofLength: 256 * 1024)
            try? h.close()
            var cwd: String?, id: String?, title: String?, prompt: String?
            // Read lines only until the required metadata is found. Splitting the entire
            // 256 KB prefix first makes project discovery scan gigabytes of unused messages.
            var offset = data.startIndex
            while offset < data.endIndex {
                let end = data.withUnsafeBytes { bytes -> Int in
                    guard let start = bytes.baseAddress else { return data.endIndex }
                    guard let newline = memchr(start.advanced(by: offset), 10, bytes.count - offset) else { return data.endIndex }
                    return start.distance(to: newline)
                }
                let line = data[offset..<end]
                offset = end == data.endIndex ? end : data.index(after: end)
                guard let j = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
                if kind == "claude" {
                    if id == nil { id = j["sessionId"] as? String }
                    if cwd == nil { cwd = j["cwd"] as? String }
                    if title == nil, j["type"] as? String == "ai-title" { title = j["aiTitle"] as? String }
                    if prompt == nil, j["type"] as? String == "user", (j["isSidechain"] as? Bool) != true,
                       let c = (j["message"] as? [String: Any])?["content"] as? String { prompt = c }
                }
                if project == nil && cwd != nil && id != nil { break }
                if cwd != nil && id != nil && prompt != nil && title != nil { break }
            }
            guard let cwd, let id, !exclude.contains(id), (project == nil || self.project(of: cwd) == project) else { continue }
            out.append(["kind": kind, "id": id, "cwd": cwd, "title": title ?? prompt ?? id,
                        "mtime": mtime.timeIntervalSince1970])
            if out.count >= limit { break }
        }
        return out
    }
}
