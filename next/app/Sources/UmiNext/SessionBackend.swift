import Foundation

/// The one place the UI meets the session daemon (next/daemon, PROTOCOL.md).
///
/// Each pane's terminal runs `umi-next-attach <id>`; `umi-next-ctl` lists, creates and ends
/// sessions and starts the daemon when needed. The three binaries ship in the app's
/// Contents/MacOS; `UMI_NEXT_DAEMON_BIN` (a folder holding them) overrides that, e.g. to use
/// next/daemon/bin from a checkout.
///
/// Debug mode only: `UMI_NEXT_PLAIN_SHELL=1` runs a plain login shell in each pane, with no
/// daemon; those shells end with the UI.
enum SessionBackend {
    struct Launch {
        let sessionID: String
        /// nil: Ghostty's default (the user's login shell), plain-shell debug mode only.
        let command: String?
        let workingDirectory: String?
    }

    static let plainShell = ProcessInfo.processInfo.environment["UMI_NEXT_PLAIN_SHELL"] == "1"
    static var mode: String { plainShell ? "plain-shell (debug)" : "daemon" }

    static let binDir: String = {
        if let d = ProcessInfo.processInfo.environment["UMI_NEXT_DAEMON_BIN"], !d.isEmpty { return d }
        return Bundle.main.executableURL!.deletingLastPathComponent().path
    }()
    static var ctlPath: String { binDir + "/umi-next-ctl" }
    static var attachPath: String { binDir + "/umi-next-attach" }

    /// Starts the daemon if it isn't running. Returns an error message on failure.
    static func startDaemon() -> String? {
        if plainShell { return nil }
        let r = run(ctlPath, ["daemon-start"])
        return r.status == 0 ? nil : "umi-next-ctl daemon-start failed: \(r.err.trimmingCharacters(in: .whitespacesAndNewlines))"
    }

    /// Every session the daemon has (`umi-next-ctl ls`), or nil when it can't be asked.
    static func sessions() -> [[String: Any]]? {
        if plainShell { return [] }
        let r = run(ctlPath, ["ls"])
        guard r.status == 0, let list = try? JSONSerialization.jsonObject(with: Data(r.out.utf8)) as? [[String: Any]] else {
            return nil
        }
        return list
    }

    /// Ids of the live sessions.
    static func liveSessionIDs() -> Set<String>? {
        sessions().map { Set($0.filter { $0["alive"] as? Bool ?? false }.compactMap { $0["id"] as? String }) }
    }

    /// The command for a pane: reattach to `existing` when it's live, else start a new session
    /// (`cmd` nil: the login shell).
    static func launch(existing: String?, live: Set<String>?, cwd: String?, name: String?, cmd: String? = nil) -> Launch {
        if plainShell {
            return Launch(sessionID: "shell-" + UUID().uuidString.prefix(8).lowercased(), command: nil, workingDirectory: cwd)
        }
        if let existing, live?.contains(existing) == true {
            return Launch(sessionID: existing, command: shellQuote([attachPath, existing]), workingDirectory: cwd)
        }
        var args = ["new", "--cwd", cwd ?? NSHomeDirectory()]
        if let name, !name.isEmpty { args += ["--name", name] }
        if let cmd { args += ["--cmd", cmd] }
        let r = run(ctlPath, args, extraEnv: shellIntegrationEnv().merging(hookEnv()) { a, _ in a })
        let id = r.out.trimmingCharacters(in: .whitespacesAndNewlines)
        guard r.status == 0, !id.isEmpty else {
            // No silent fallback: the pane shows the failure and stays open.
            let msg = "umi-next: could not create a session: \(r.err.trimmingCharacters(in: .whitespacesAndNewlines))"
            return Launch(sessionID: "failed-" + UUID().uuidString.prefix(8).lowercased(),
                          command: shellQuote(["/bin/sh", "-c", "echo \"$0\"; exec sleep 2147483647", msg]),
                          workingDirectory: cwd)
        }
        return Launch(sessionID: id, command: shellQuote([attachPath, id]), workingDirectory: cwd)
    }

    /// A pane stopped showing a session (⌘W, a session moved to another pane). The session keeps
    /// running in the daemon: ⌘W never ends a program (Alejo, 2026-11-17). Only Exit ends one.
    static func paneClosed(sessionID: String, how: String) {}

    /// The session's program ended (its pane's attach got the exit): forget it in the daemon.
    static func sessionEnded(sessionID: String) {
        guard !plainShell else { return }
        DispatchQueue.global().async { _ = run(ctlPath, ["rm", sessionID]) }
    }

    /// The palette's Exit: `umi-next-ctl kill` (TERM to its process group), then HUP and forget it
    /// if it's still there after a second.
    static func endSession(sessionID: String) {
        guard !plainShell else { return }
        DispatchQueue.global().async {
            _ = run(ctlPath, ["kill", sessionID])
            Thread.sleep(forTimeInterval: 1)
            _ = run(ctlPath, ["kill", sessionID, "--signal", "1"])
            Thread.sleep(forTimeInterval: 0.5)
            _ = run(ctlPath, ["rm", sessionID, "--force"])
        }
    }

    /// Ghostty's zsh integration for a new session (the daemon starts the shell, so Ghostty can't
    /// inject it): it reports the folder (OSC 7), titles, prompts and command ends (OSC 133) to
    /// the attached terminal, as in Umi. zsh only, like Ghostty's ZDOTDIR injection.
    static func shellIntegrationEnv() -> [String: String] {
        let env = ProcessInfo.processInfo.environment
        let shell = env["SHELL"] ?? "/bin/zsh"
        guard shell.hasSuffix("/zsh"),
              let res = Bundle.main.resourceURL?.appendingPathComponent("ghostty").path,
              FileManager.default.fileExists(atPath: res + "/shell-integration/zsh/.zshenv") else { return [:] }
        var out = [
            "GHOSTTY_RESOURCES_DIR": res,
            "ZDOTDIR": res + "/shell-integration/zsh",
            "GHOSTTY_SHELL_FEATURES": "cursor:blink,path,title,umi-blocks",
            "TERM_PROGRAM": "ghostty",
        ]
        if let z = env["ZDOTDIR"] { out["GHOSTTY_ZSH_ZDOTDIR"] = z }
        return out
    }

    /// Lets Umi's Claude Code / Codex plugin report to umi-next (see umi-next-hook): the plugin
    /// acts when UMI_CLI, UMI_STATE_DIR and UMI_PANE are set. UMI_STATE_DIR is a folder of
    /// umi-next's own, so a real `umi` run in a session never takes it for Umi's.
    static func hookEnv() -> [String: String] {
        ["UMI_CLI": (Bundle.main.resourceURL?.path ?? binDir) + "/umi-next-hook", "UMI_STATE_DIR": Paths.stateDir + "/umi-compat",
         "UMI_PANE": "umi-next", "UMI_NEXT_STATE_DIR": Paths.stateDir]
    }

    @discardableResult
    static func run(_ path: String, _ args: [String], extraEnv: [String: String] = [:]) -> (status: Int32, out: String, err: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["UMI_NEXT_STATE_DIR"] = Paths.stateDir
        env.removeValue(forKey: "UMI_NEXT_DEBUG")
        env.merge(extraEnv) { _, new in new }
        p.environment = env
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        do { try p.run() } catch { return (-1, "", "\(error)") }
        let o = out.fileHandleForReading.readDataToEndOfFile()
        let e = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: o, as: UTF8.self), String(decoding: e, as: UTF8.self))
    }

    static func shellQuote(_ args: [String]) -> String {
        args.map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }.joined(separator: " ")
    }
}
