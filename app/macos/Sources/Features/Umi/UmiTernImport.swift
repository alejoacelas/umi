import AppKit
import Darwin
import Foundation

/// Umi was called Tern before 0.6.0. The first time Umi runs without a state directory of its
/// own, it copies what the user would miss from Tern's (`~/Library/Application Support/Tern`):
/// windows, tabs and panes (`layout.json`), the sidebar (`ui.json`), shortcuts
/// (`shortcuts.json`, `keybindings.conf`), the editor's unsaved changes (`recovery/`) and agent
/// sessions (`sessions/`). Tern's folder is only read, never changed.
///
/// Sessions are copied stopped: nothing in the copy is live, running or waiting to be delivered,
/// and messages Tern hadn't finished end as interrupted in the copy. Copying (not moving) leaves
/// every conversation with Tern too, and Tern may be running now or start at any moment, so Umi
/// never resumes a copied session by itself: it never starts a second process on a conversation
/// Tern is driving, or sends a message again that Tern already handled. The panes show those
/// sessions as before, and Take Over continues one in Umi when the user decides to. A session that
/// can't be made stopped isn't copied at all.
///
/// Only regular files and folders are copied (never a symbolic link, so nothing in Umi's copy
/// leads back into Tern's files or anywhere else). What couldn't be copied after a few tries is
/// listed in `imported-from-tern.json` and shown in an alert at launch; to copy again, quit Umi
/// and remove its state directory.
///
/// Isolated instances (`UMI_STATE_DIR`) copy nothing unless `UMI_IMPORT_STATE_DIR` names a
/// folder to copy from (the tests' way in).
///
/// This runs while `UmiPaths.stateDirectory` is being made, so it must not use UmiPaths' state
/// directory (or anything that does): plain paths only.
enum UmiTernImport {
    /// What is copied, relative to the state directory.
    static let copied = ["layout.json", "ui.json", "shortcuts.json", "keybindings.conf", "recovery", "sessions"]

    /// What this launch's copy couldn't copy (empty when it copied everything or didn't run).
    nonisolated(unsafe) static var failures: [String] = []

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
        removeStaleStaging(next: dest)
        var names: [String] = []
        var failed: [String] = []
        var runningBefore = false
        // A running Tern rewrites files while they're copied; a failed copy is tried again.
        for attempt in 1...3 {
            try? fm.removeItem(atPath: staging)
            // Tern's folder's own permissions (it may have been made private), never looser. `stat`,
            // not `lstat`: if the folder itself is a link (moved elsewhere by the user), what counts
            // is the folder it leads to, never the link's own mode.
            var sourceStat = stat()
            let mode = stat(source, &sourceStat) == 0 ? (sourceStat.st_mode & 0o777) | 0o700 : 0o700
            guard mkdir(staging, mode) == 0 else { return false }
            chmod(staging, mode)
            runningBefore = isRunning(stateDirectory: source)
            names = []
            failed = []
            for name in copied {
                let from = (source as NSString).appendingPathComponent(name)
                var st = stat()
                guard lstat(from, &st) == 0 else {
                    // Missing is fine (Tern never wrote it); anything else (unreadable) is a failure.
                    if errno != ENOENT { failed.append(from) }
                    continue
                }
                let errors = copyTree(from, (staging as NSString).appendingPathComponent(name))
                if errors.isEmpty { names.append(name) } else { failed += errors }
            }
            if failed.isEmpty { break }
            NSLog("Umi: copying Tern's state, attempt \(attempt): couldn't copy \(failed)")
            if attempt < 3 { usleep(300_000) }
        }

        // Recorded for the note only: copied sessions are stopped whether Tern runs or not.
        let running = runningBefore || isRunning(stateDirectory: source)
        let dropped = stopSessions(in: (staging as NSString).appendingPathComponent("sessions"), ternRunning: running)
        var note: [String: Any] = [
            "from": source,
            "at": ISO8601DateFormatter().string(from: Date()),
            "tern_running": running,
            "copied": names,
        ]
        if !failed.isEmpty { note["failed"] = failed }
        if !dropped.isEmpty { note["sessions_not_copied"] = dropped }
        if let data = try? JSONSerialization.data(withJSONObject: note, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: (staging as NSString).appendingPathComponent("imported-from-tern.json")))
        }
        if rename(staging, dest) != 0 {
            // Another launch made the state directory first: keep that one.
            try? fm.removeItem(atPath: staging)
            return false
        }
        failures = failed + dropped.map { "session \($0)" }
        return true
    }

    /// Copy a file or folder: regular files and folders only (symbolic links and anything else
    /// are left out), and a file that disappears meanwhile (Tern replaces some through temporary
    /// files) is skipped. Copies are owner-writable, since stopping sessions rewrites some.
    /// Returns what couldn't be copied.
    private static func copyTree(_ from: String, _ to: String) -> [String] {
        var st = stat()
        guard lstat(from, &st) == 0 else { return errno == ENOENT ? [] : [from] }
        switch st.st_mode & S_IFMT {
        case S_IFDIR:
            guard mkdir(to, (st.st_mode & 0o777) | 0o700) == 0 else { return [from] }
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: from) else {
                return access(from, F_OK) != 0 ? [] : [from]
            }
            return names.flatMap {
                copyTree((from as NSString).appendingPathComponent($0), (to as NSString).appendingPathComponent($0))
            }
        case S_IFREG:
            guard let data = FileManager.default.contents(atPath: from) else {
                return access(from, F_OK) != 0 ? [] : [from]
            }
            let mode = Int((st.st_mode & 0o777) | 0o600)
            return FileManager.default.createFile(atPath: to, contents: data, attributes: [.posixPermissions: mode]) ? [] : [from]
        default:
            NSLog("Umi: not copying \(from) from Tern (not a file or folder)")
            return []
        }
    }

    /// Say what the first launch couldn't copy from Tern, and how to try again.
    @MainActor
    static func reportFailures() {
        guard !failures.isEmpty else { return }
        // An isolated instance (the tests) never stops on a dialog: the note and the log say it.
        guard !UmiPaths.isIsolated else {
            NSLog("Umi: couldn't copy from Tern: \(failures)")
            return
        }
        let listed = failures.prefix(8).map { "• \($0)" }.joined(separator: "\n")
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "Umi couldn't copy everything from Tern"
            alert.informativeText = """
            Tern's tabs and sessions were copied, except:
            \(listed)\(failures.count > 8 ? "\n…" : "")

            Tern's own files weren't changed. To copy again, quit Umi, remove \
            ~/Library/Application Support/Umi and open Umi.
            """
            alert.runModal()
        }
    }

    /// Staging folders of launches that died while copying (their process is gone).
    private static func removeStaleStaging(next dest: String) {
        let parent = (dest as NSString).deletingLastPathComponent
        let prefix = (dest as NSString).lastPathComponent + ".importing-"
        for name in (try? FileManager.default.contentsOfDirectory(atPath: parent)) ?? [] where name.hasPrefix(prefix) {
            guard let pid = Int32(name.dropFirst(prefix.count)), pid > 0 else { continue }
            if kill(pid, 0) != 0 && errno == ESRCH {
                try? FileManager.default.removeItem(atPath: (parent as NSString).appendingPathComponent(name))
            }
        }
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
    /// messages Tern hadn't finished end as interrupted in the copy (Tern goes on with them if it
    /// runs). A session that can't be rewritten is removed from the copy, so Umi never resumes it.
    /// Returns the ids of the sessions removed.
    static func stopSessions(in root: String, ternRunning: Bool) -> [String] {
        let fm = FileManager.default
        guard let ids = try? fm.contentsOfDirectory(atPath: root) else { return [] }
        var dropped: [String] = []
        for id in ids where !id.hasPrefix(".") {
            let folder = (root as NSString).appendingPathComponent(id)
            if !stopSession(id: id, folder: folder, ternRunning: ternRunning) {
                try? fm.removeItem(atPath: folder)
                if fm.fileExists(atPath: folder) {
                    // Couldn't remove it either: hide it from Umi (sessions starting with "." aren't loaded).
                    _ = rename(folder, (root as NSString).appendingPathComponent(".not-copied-\(id)"))
                }
                dropped.append(id)
            }
        }
        return dropped
    }

    private static func stopSession(id: String, folder: String, ternRunning: Bool) -> Bool {
        let fm = FileManager.default
        let recordPath = (folder as NSString).appendingPathComponent("session.json")
        guard let data = fm.contents(atPath: recordPath),
              var record = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return false }
        for field in runningFields { record.removeValue(forKey: field) }
        record["openSelfTurn"] = false
        // A watch would message its supervising session by itself when this one finishes, and so
        // resume a conversation Tern may be driving: watches aren't copied (`agent watch` again).
        record["watches"] = [Any]()

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
        func append(_ entry: [String: Any]) -> Bool {
            guard let line = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]) else { return false }
            appended.append(line)
            appended.append(0x0A)
            return true
        }
        for mid in order {
            guard var message = messages[mid], let state = message["state"] as? String,
                  ["queued", "sent", "delivered"].contains(state) else { continue }
            message["state"] = "interrupted"
            message["error"] = "Tern hadn't finished this message when Umi copied the session"
            message["finishedAt"] = now
            message.removeValue(forKey: "cutOff")
            guard append(["m": message]) else { return false }
        }
        let next = max(record["nextItem"] as? Int ?? 1, lastItem + 1)
        _ = append(["i": [
            "id": "\(id.prefix(8))-\(next)",
            "kind": "notice",
            "text": ternRunning
                ? "Copied from Tern, which was still running. Take Over continues this session in Umi."
                : "Copied from Tern. Take Over continues this session in Umi.",
            "at": now,
        ]])
        record["nextItem"] = next + 1
        log.append(appended)
        guard let out = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]) else { return false }
        // Whole files, replaced in one step: the log first, so a record never claims more than it.
        return replace(logPath, with: log) && replace(recordPath, with: out)
    }

    private static func replace(_ path: String, with data: Data) -> Bool {
        let tmp = path + ".stopping"
        guard FileManager.default.createFile(atPath: tmp, contents: data, attributes: [.posixPermissions: 0o600]) else {
            return false
        }
        if rename(tmp, path) != 0 {
            unlink(tmp)
            return false
        }
        return true
    }
}
