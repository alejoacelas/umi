import Darwin
import Foundation

/// Umi was called Tern before 0.6.0. The first time Umi runs without a state directory of its
/// own, it copies what the user would miss from Tern's (`~/Library/Application Support/Tern`):
/// windows, tabs and panes (`layout.json`), the sidebar (`ui.json`), shortcuts
/// (`shortcuts.json`, `keybindings.conf`), the editor's unsaved changes (`recovery/`) and agent
/// sessions (`sessions/`). Tern's folder is only read, never changed.
///
/// Tern may still be running while Umi copies (both apps can be installed at once). Then its
/// sessions are copied as stopped: nothing in the copy is live, running or waiting to be
/// delivered, so Umi never starts a second process on a conversation Tern is driving, and never
/// sends a message Tern is already handling. The panes still show those sessions, and Take Over
/// continues one in Umi. When Tern isn't running the copy is taken as is, and Umi resumes it the
/// way Tern would have on its next launch (a session that was live comes back live).
///
/// Isolated instances (`UMI_STATE_DIR`) copy nothing unless `UMI_IMPORT_STATE_DIR` names a
/// folder to copy from (the tests' way in).
///
/// This runs while `UmiPaths.stateDirectory` is being made, so it must not use UmiPaths' state
/// directory (or anything that does): plain paths only.
enum UmiTernImport {
    /// What is copied, relative to the state directory.
    static let copied = ["layout.json", "ui.json", "shortcuts.json", "keybindings.conf", "recovery", "sessions"]

    /// Where Tern kept its state, or nil when nothing should be copied into this instance.
    static func source(isolated: Bool) -> String? {
        if let dir = ProcessInfo.processInfo.environment["UMI_IMPORT_STATE_DIR"], !dir.isEmpty {
            return (dir as NSString).expandingTildeInPath
        }
        if isolated { return nil }
        return NSHomeDirectory() + "/Library/Application Support/Tern"
    }

    /// Copy Tern's state into `dest` if `dest` doesn't exist yet. Returns true if it copied.
    @discardableResult
    static func importIfNeeded(into dest: String, isolated: Bool) -> Bool {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard let source = source(isolated: isolated),
              !fm.fileExists(atPath: dest),
              fm.fileExists(atPath: source, isDirectory: &isDir), isDir.boolValue else { return false }

        // Copy into a folder next to the destination and move it into place at the end, so an
        // interrupted copy leaves no half-made state directory behind (the next launch retries).
        let staging = dest + ".importing-\(getpid())"
        try? fm.removeItem(atPath: staging)
        do {
            try fm.createDirectory(atPath: staging, withIntermediateDirectories: true)
        } catch {
            return false
        }
        let running = isRunning(stateDirectory: source)
        var names: [String] = []
        for name in copied {
            let from = (source as NSString).appendingPathComponent(name)
            guard fm.fileExists(atPath: from) else { continue }
            do {
                try fm.copyItem(atPath: from, toPath: (staging as NSString).appendingPathComponent(name))
                names.append(name)
            } catch {
                NSLog("Umi: couldn't copy \(from) from Tern: \(error)")
            }
        }
        if running { stopSessions(in: (staging as NSString).appendingPathComponent("sessions")) }
        let note: [String: Any] = [
            "from": source,
            "at": ISO8601DateFormatter().string(from: Date()),
            "tern_running": running,
            "copied": names,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: note, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: (staging as NSString).appendingPathComponent("imported-from-tern.json")))
        }
        if rename(staging, dest) != 0 {
            // Another launch made the state directory first: keep that one.
            try? fm.removeItem(atPath: staging)
            return false
        }
        return true
    }

    /// Whether an app holds the instance lock of this state directory (Tern takes it for its
    /// whole life, exclusively, and the kernel drops it however Tern ends).
    static func isRunning(stateDirectory: String) -> Bool {
        let fd = open((stateDirectory as NSString).appendingPathComponent("instance.lock"), O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        if flock(fd, LOCK_SH | LOCK_NB) == 0 {
            flock(fd, LOCK_UN)
            return false
        }
        return errno == EWOULDBLOCK
    }

    // MARK: Sessions Tern is still running

    /// Fields of a session record that say a process runs it, or will.
    private static let runningFields = [
        "live", "livePID", "liveAttached", "goLiveWhenSettled", "pid", "queue", "cutOffAt", "cutOffReason",
    ]

    /// Make every copied session stopped: no live interface, no harness, no queue, and the
    /// messages Tern was still handling end as interrupted in the copy (Tern goes on with them).
    static func stopSessions(in root: String) {
        let fm = FileManager.default
        guard let ids = try? fm.contentsOfDirectory(atPath: root) else { return }
        for id in ids where !id.hasPrefix(".") {
            let folder = (root as NSString).appendingPathComponent(id)
            let recordPath = (folder as NSString).appendingPathComponent("session.json")
            guard let data = fm.contents(atPath: recordPath),
                  var record = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
            for field in runningFields { record.removeValue(forKey: field) }
            record["openSelfTurn"] = false

            let logPath = (folder as NSString).appendingPathComponent("log.jsonl")
            var log = fm.contents(atPath: logPath) ?? Data()
            // Tern may have been writing the last line: drop a partial one.
            if let last = log.last, last != 0x0A {
                log = log.prefix((log.lastIndex(of: 0x0A).map { $0 + 1 }) ?? 0)
            }
            var messages: [String: [String: Any]] = [:]
            var order: [String] = []
            var lastItem = 0
            for line in log.split(separator: 0x0A) where !line.isEmpty {
                guard let entry = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any] else { continue }
                if let message = entry["m"] as? [String: Any], let mid = message["id"] as? String {
                    if messages[mid] == nil { order.append(mid) }
                    messages[mid] = message
                }
                if let item = entry["i"] as? [String: Any], let iid = item["id"] as? String,
                   let n = iid.split(separator: "-").last.flatMap({ Int($0) }) {
                    lastItem = max(lastItem, n)
                }
            }
            let now = Date().timeIntervalSince1970
            var appended = Data()
            func append(_ entry: [String: Any]) {
                guard let line = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]) else { return }
                appended.append(line)
                appended.append(0x0A)
            }
            for mid in order {
                guard var message = messages[mid], let state = message["state"] as? String,
                      ["queued", "sent", "delivered"].contains(state) else { continue }
                message["state"] = "interrupted"
                message["error"] = "Tern was still handling this message when Umi copied the session"
                message["finishedAt"] = now
                message.removeValue(forKey: "cutOff")
                append(["m": message])
            }
            let next = max(record["nextItem"] as? Int ?? 1, lastItem + 1)
            append(["i": [
                "id": "\(id.prefix(8))-\(next)",
                "kind": "notice",
                "text": "Copied from Tern, which was still running this session. Take Over continues it in Umi.",
                "at": now,
            ]])
            record["nextItem"] = next + 1
            log.append(appended)
            try? log.write(to: URL(fileURLWithPath: logPath))
            chmod(logPath, 0o600)
            if let out = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]) {
                try? out.write(to: URL(fileURLWithPath: recordPath))
                chmod(recordPath, 0o600)
            }
        }
    }
}
