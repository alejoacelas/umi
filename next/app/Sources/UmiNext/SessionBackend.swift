import Foundation

/// The one place the UI meets the session daemon (branch `next-daemon`).
///
/// Each pane's terminal runs `launch(...).command`. With `UMI_NEXT_ATTACH` set to the path of
/// `umi-next-attach`, panes are daemon sessions: `umi-next-ctl` (next to it, or
/// `UMI_NEXT_CTL`) lists and creates them, and the terminal runs `umi-next-attach <id>`, so
/// killing the UI leaves the session running. Without it, a pane runs a plain login shell
/// (Ghostty's default) under a made-up id; such a session ends with the UI, so on relaunch
/// every pane gets a fresh shell.
enum SessionBackend {
    struct Launch {
        let sessionID: String
        /// nil: Ghostty's default (the user's login shell).
        let command: String?
        let workingDirectory: String?
    }

    static var attachPath: String? {
        guard let p = ProcessInfo.processInfo.environment["UMI_NEXT_ATTACH"], !p.isEmpty else { return nil }
        return p
    }

    static var ctlPath: String? {
        if let p = ProcessInfo.processInfo.environment["UMI_NEXT_CTL"], !p.isEmpty { return p }
        guard let attach = attachPath else { return nil }
        return (attach as NSString).deletingLastPathComponent + "/umi-next-ctl"
    }

    static var mode: String { attachPath == nil ? "shell" : "daemon" }

    /// The ids of the sessions the daemon has, or nil without a daemon (shell mode).
    static func liveSessionIDs() -> Set<String>? {
        guard attachPath != nil, let ctl = ctlPath else { return nil }
        guard let out = run(ctl, ["ls"]),
              let json = try? JSONSerialization.jsonObject(with: Data(out.utf8)) else {
            NSLog("umi-next: `umi-next-ctl ls` failed; every pane gets a new session")
            return []
        }
        // Accept a list of sessions ([{"id": …}] or ["id", …]) or {"sessions": [...]}.
        let list = (json as? [Any]) ?? ((json as? [String: Any])?["sessions"] as? [Any]) ?? []
        return Set(list.compactMap { ($0 as? String) ?? (($0 as? [String: Any])?["id"] as? String) })
    }

    /// The command for a pane: reattach to `existing` when it's in `live`, else a new session.
    static func launch(existing: String?, live: Set<String>?, cwd: String?, name: String?) -> Launch {
        guard let attach = attachPath, let ctl = ctlPath else {
            return Launch(sessionID: "shell-" + UUID().uuidString.prefix(8).lowercased(), command: nil, workingDirectory: cwd)
        }
        if let existing, live?.contains(existing) == true {
            return Launch(sessionID: existing, command: shellQuote([attach, existing]), workingDirectory: cwd)
        }
        var args = ["new"]
        if let cwd { args += ["--cwd", cwd] }
        if let name { args += ["--name", name] }
        guard let id = run(ctl, args)?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty else {
            // No silent fallback: the pane shows the failure and stays open.
            let msg = "umi-next: could not create a session (umi-next-ctl new failed)"
            return Launch(sessionID: "failed-" + UUID().uuidString.prefix(8).lowercased(),
                          command: shellQuote(["/bin/sh", "-c", "echo \"$0\"; exec sleep 2147483647", msg]),
                          workingDirectory: cwd)
        }
        return Launch(sessionID: id, command: shellQuote([attach, id]), workingDirectory: cwd)
    }

    /// A pane stopped showing a session: `how` is "detach" (the session keeps running: agents,
    /// a pane switched to another session) or "close" (the user closed it: end the session).
    /// The daemon's CLI has no documented way to end a session yet, so for now both only detach
    /// (the attach process ends with the terminal). In shell mode the shell ends either way.
    static func paneClosed(sessionID: String, how: String) {}

    private static func run(_ path: String, _ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    private static func shellQuote(_ args: [String]) -> String {
        args.map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }.joined(separator: " ")
    }
}
