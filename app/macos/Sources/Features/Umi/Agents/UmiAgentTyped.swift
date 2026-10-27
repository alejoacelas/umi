import Darwin
import Foundation

/// The flags of an agent the user typed in a pane (`claude --dangerously-skip-permissions
/// --model opus`), read from its process, so the session comes back as typed: after a quit,
/// a crash or an update its interface returns with them, and a message resumes it headless
/// with them (AG-7, AG-10, AG-18).
///
/// The model, effort and permissions become the session's own settings; other flags are kept
/// as its harness arguments. What picks a conversation (`--resume`, `--continue`,
/// `--session-id`, `--fork-session`), one-offs (`--print`, `--worktree`, `--bg`), Umi's own
/// plugin and the first prompt are left out: the session resumes its own conversation.
enum UmiTypedCommand {
    struct Flags: Equatable {
        var model: String?
        var effort: String?
        var permissionMode: String?
        var fullAccess = false
        var profile: String?
        var args: [String] = []
    }

    /// The typed command's arguments after the agent's program. `pid` is the process that ran
    /// the agent's hook: the agent itself, or a shell it ran the hook in.
    static func arguments(pid: Int32, kind: UmiAgentKind) -> [String]? {
        var candidate = pid
        for _ in 0..<3 {
            if let argv = UmiProcess.arguments(candidate),
               let index = argv.prefix(3).firstIndex(where: { isProgram($0, kind) }) {
                return Array(argv[(index + 1)...])
            }
            guard let parent = parentPID(candidate), parent > 1 else { return nil }
            candidate = parent
        }
        return nil
    }

    /// `claude`, `codex`, or a program or script named for them (`/opt/…/claude-code/cli.js`).
    static func isProgram(_ arg: String, _ kind: UmiAgentKind) -> Bool {
        guard !arg.isEmpty, !arg.contains(where: \.isWhitespace) else { return false }
        let url = URL(fileURLWithPath: arg)
        let stem = url.deletingPathExtension().lastPathComponent.lowercased()
        let name = kind.rawValue
        if stem == name || stem.hasSuffix("_" + name) || stem.hasSuffix("-" + name) { return true }
        return url.pathExtension == "js" && url.deletingLastPathComponent().lastPathComponent.lowercased().contains(name)
    }

    private static func parentPID(_ pid: Int32) -> Int32? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return Int32(info.pbi_ppid)
    }

    static func flags(_ args: [String], kind: UmiAgentKind) -> Flags {
        kind == .claude ? claude(args) : codex(args)
    }

    // Claude Code 2.1's options (`claude --help`): which take a value, which take several
    // (until the next option) and which may take one.
    private static let claudeValue: Set<String> = [
        "--agent", "--agents", "--append-system-prompt", "--append-system-prompt-file", "--autocompact",
        "--debug-file", "--environment", "--fallback-model", "--input-format", "--json-schema", "--max-budget-usd",
        "--max-turns", "-n", "--name", "--output-format", "--permission-prompt-tool", "--permission-prompts",
        "--plugin-url", "--remote-control-session-name-prefix", "--setting-sources", "--settings",
        "--system-prompt", "--system-prompt-file", "--system-prompt-snapshot",
    ]
    private static let claudeValues: Set<String> = [
        "--add-dir", "--allowedTools", "--allowed-tools", "--betas", "--disallowedTools", "--disallowed-tools",
        "--file", "--mcp-config", "--tools",
    ]
    private static let claudeOptionalValue: Set<String> = ["-d", "--debug", "--prompt-suggestions"]

    static func claude(_ args: [String]) -> Flags {
        var flags = Flags()
        var i = 0
        while i < args.count {
            var arg = args[i]
            var inline: String?
            if arg.hasPrefix("--"), let eq = arg.firstIndex(of: "=") {
                inline = String(arg[arg.index(after: eq)...])
                arg = String(arg[..<eq])
            }
            func value() -> String? {
                if let inline { return inline }
                guard i + 1 < args.count else { return nil }
                i += 1
                return args[i]
            }
            func optionalValue() -> String? {
                if let inline { return inline }
                guard i + 1 < args.count, !args[i + 1].hasPrefix("-") else { return nil }
                i += 1
                return args[i]
            }
            func values() -> [String] {
                var out = inline.map { [$0] } ?? []
                while i + 1 < args.count, !args[i + 1].hasPrefix("-") {
                    i += 1
                    out.append(args[i])
                }
                return out
            }
            switch arg {
            case "--model": flags.model = value()
            case "--effort": flags.effort = value()
            case "--dangerously-skip-permissions": flags.fullAccess = true
            case "--permission-mode":
                let mode = value()
                if mode == "bypassPermissions" { flags.fullAccess = true } else { flags.permissionMode = mode }
            case "--plugin-dir":
                // Umi's own plugin (and Tern's) is added by Umi where it's needed.
                if let dir = value(), !dir.contains("/Contents/Resources/agent-plugins/") { flags.args += ["--plugin-dir", dir] }
            case "--session-id": _ = value()
            case "-r", "--resume", "--from-pr", "--teleport", "--cloud", "--remote-control", "-w", "--worktree":
                _ = optionalValue()
            case "-c", "--continue", "--fork-session", "-p", "--print", "--bg", "--background", "--tmux",
                 "-h", "--help", "-v", "--version":
                break
            default:
                if claudeValues.contains(arg) {
                    let given = values()
                    if !given.isEmpty { flags.args += [arg] + given }
                } else if claudeValue.contains(arg) {
                    if let v = value() { flags.args += [arg, v] }
                } else if claudeOptionalValue.contains(arg) {
                    flags.args.append(arg)
                    if let v = optionalValue() { flags.args.append(v) }
                } else if arg.hasPrefix("-") {
                    flags.args.append(args[i])
                }
                // Anything else is the first prompt: not run again.
            }
            i += 1
        }
        return flags
    }

    /// Codex's interface flags that mean something to Umi's own Codex server (the session runs
    /// there, its interface attaches to it): the model, effort, approvals and full access, the
    /// profile. Others (`-c` overrides, `--cd`, the prompt) stay with that one interface.
    static func codex(_ args: [String]) -> Flags {
        var flags = Flags()
        var i = 0
        while i < args.count {
            var arg = args[i]
            var inline: String?
            if arg.hasPrefix("--"), let eq = arg.firstIndex(of: "=") {
                inline = String(arg[arg.index(after: eq)...])
                arg = String(arg[..<eq])
            }
            func value() -> String? {
                if let inline { return inline }
                guard i + 1 < args.count else { return nil }
                i += 1
                return args[i]
            }
            switch arg {
            case "-m", "--model": flags.model = value()
            case "-a", "--ask-for-approval": flags.permissionMode = value()
            case "-p", "--profile": flags.profile = value()
            case "--dangerously-bypass-approvals-and-sandbox", "--yolo": flags.fullAccess = true
            case "-c", "--config":
                if let pair = value(), pair.hasPrefix("model_reasoning_effort=") {
                    flags.effort = String(pair.dropFirst("model_reasoning_effort=".count)).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                }
            case "-s", "--sandbox", "-C", "--cd", "-i", "--image", "--add-dir", "--remote", "--local-provider":
                _ = value()
            default:
                break
            }
            i += 1
        }
        return flags
    }
}

extension UmiAgentSession {
    /// A `claude`/`codex` the user typed in a pane (a new one, or `--resume` of a session Umi
    /// knows): its flags become the session's settings (UmiTypedCommand). An interface Umi
    /// started itself (`agent attach`, which names the session in its environment) runs with the
    /// session's settings already. Nothing changes when its process can't be read.
    func adoptTypedFlags(pid: Int32) {
        guard record.liveAttached != true,
              UmiProcessTree.environment(pid)?["UMI_SESSION_ID"] != record.id,
              let args = UmiTypedCommand.arguments(pid: pid, kind: record.kind) else { return }
        // Only an interactive interface: never a one-off Claude run (`-p`; Codex's `-p` is a profile).
        if record.kind == .claude && (args.contains("-p") || args.contains("--print")) { return }
        let flags = UmiTypedCommand.flags(args, kind: record.kind)
        record.model = flags.model
        record.effort = flags.effort
        record.permissionMode = flags.permissionMode
        record.fullAccess = flags.fullAccess
        if record.kind == .codex {
            record.profile = flags.profile
        } else {
            record.harnessArgs = flags.args
        }
        saveRecord()
    }
}
