import Foundation

/// Title records live among ordinary messages in Claude's transcripts. Codex keeps all its
/// names in one append-only index. The session monitor owns these cursors on its serial queue.
final class SessionTitles {
    private struct Cursor<Value> {
        let empty: Value
        var value: Value
        var inode: ino_t?
        var size: off_t = 0
        var offset: UInt64 = 0
        var modified = timespec()
        init(_ value: Value) { empty = value; self.value = value }

        mutating func update(_ url: URL, consume: (Data, inout Value) -> Void) {
            guard let file = try? FileHandle(forReadingFrom: url) else {
                self = Cursor(empty)
                return
            }
            defer { try? file.close() }
            var st = stat()
            guard fstat(file.fileDescriptor, &st) == 0 else { return }
            let sameTime = modified.tv_sec == st.st_mtimespec.tv_sec && modified.tv_nsec == st.st_mtimespec.tv_nsec
            if inode == st.st_ino, size == st.st_size, sameTime { return }
            if inode != st.st_ino || st.st_size <= size {
                value = empty
                offset = 0
            }
            do {
                try file.seek(toOffset: offset)
                var pending = Data()
                while let chunk = try file.read(upToCount: 64 * 1024), !chunk.isEmpty {
                    var start = chunk.startIndex
                    while let end = chunk[start...].firstIndex(of: 10) {
                        if pending.isEmpty { consume(chunk[start..<end], &value) }
                        else {
                            pending.append(chunk[start..<end])
                            consume(pending, &value)
                            pending.removeAll(keepingCapacity: true)
                        }
                        start = end + 1
                    }
                    pending.append(chunk[start...])
                }
                // Accept a valid last record without a newline, but reread it on append. A
                // writer may have paused in the middle of a JSON payload when we reached EOF.
                if !pending.isEmpty { consume(pending, &value) }
                offset = try file.offset() - UInt64(pending.count)
                inode = st.st_ino
                size = st.st_size
                modified = st.st_mtimespec
            } catch {
                self = Cursor(empty)
            }
        }
    }

    private static func configFolder(_ variable: String, default name: String) -> URL {
        if let path = ProcessInfo.processInfo.environment[variable], !path.isEmpty {
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(name)
    }

    static let claudeProjects: [URL] = {
        let primary = configFolder("CLAUDE_CONFIG_DIR", default: ".claude")
        var homes = [primary]
        if ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"]?.isEmpty != false {
            let second = configFolder("CLAUDE_ROTATE_SECOND_DIR", default: ".claude-second")
            if second != primary { homes.append(second) }
        }
        return homes.map { $0.appendingPathComponent("projects") }
    }()
    static let codexHome = configFolder("CODEX_HOME", default: ".codex")
    /// A shell inside a pane can select its own profile after Umi starts. Its hook reports the
    /// rollout under that profile's sessions tree, alongside session_index.jsonl.
    static func codexHome(forTranscript path: String?) -> URL {
        guard let path, path.hasPrefix("/") else { return codexHome }
        var folder = URL(fileURLWithPath: path).deletingLastPathComponent()
        while folder.path != "/" && !folder.path.isEmpty {
            if folder.lastPathComponent == "sessions" || folder.lastPathComponent == "archived_sessions" {
                return folder.deletingLastPathComponent()
            }
            folder.deleteLastPathComponent()
        }
        return codexHome
    }

    private var indices: [URL: Cursor<[String: String]>] = [:]

    func codex(home: URL = SessionTitles.codexHome) -> [String: String] {
        let file = home.appendingPathComponent("session_index.jsonl")
        indices[file, default: Cursor([:])].update(file) { line, titles in
            guard let row = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let id = row["id"] as? String, let name = row["thread_name"] as? String else { return }
            titles[id] = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : name
        }
        return indices[file]?.value ?? [:]
    }

    private struct ClaudeTitle {
        var custom: String?
        var generated: String?
    }
    private var transcripts: [URL: Cursor<ClaudeTitle>] = [:]
    private static let customKey = Data("\"customTitle\"".utf8)
    private static let generatedKey = Data("\"aiTitle\"".utf8)

    func claude(_ transcript: URL, session: String, live: Bool = false) -> String? {
        transcripts[transcript, default: Cursor(ClaudeTitle())].update(transcript) { line, title in
            guard line.range(of: Self.customKey) != nil || line.range(of: Self.generatedKey) != nil,
                  let row = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  row["sessionId"] as? String == session else { return }
            switch row["type"] as? String {
            case "custom-title": title.custom = (row["customTitle"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            case "ai-title": title.generated = (row["aiTitle"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            default: break
            }
        }
        let title = transcripts[transcript]?.value
        if let custom = title?.custom { return custom }
        if live, let userName = liveClaudeName(session: session, transcript: transcript) { return userName }
        return title?.generated
    }

    // Claude registers --name before the first turn writes a transcript. Registry entries
    // without nameSource=user can be background worker labels rather than conversation names.
    private var registryFiles: [String: URL] = [:]
    private func liveClaudeName(session: String, transcript: URL) -> String? {
        let projects = transcript.deletingLastPathComponent().deletingLastPathComponent()
        guard projects.lastPathComponent == "projects" else { return nil }
        let dir = projects.deletingLastPathComponent().appendingPathComponent("sessions")
        func record(_ file: URL) -> [String: Any]? {
            guard let pid = Int32(file.deletingPathExtension().lastPathComponent), pid > 0,
                  kill(pid, 0) == 0, let data = try? Data(contentsOf: file),
                  let row = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  row["sessionId"] as? String == session, row["pid"] as? Int32 == pid else { return nil }
            return row
        }
        func userName(_ row: [String: Any]) -> String? {
            guard row["nameSource"] as? String == "user", let name = row["name"] as? String, !name.isEmpty else { return nil }
            return name
        }
        if let file = registryFiles[session], let row = record(file) { return userName(row) }
        for file in (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] where file.pathExtension == "json" {
            if let row = record(file) { registryFiles[session] = file; return userName(row) }
        }
        return nil
    }
}
