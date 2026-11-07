import Darwin
import Foundation

/// The command of an agent the user typed in a pane (`claude --dangerously-skip-permissions
/// --model opus`), read from its process, so it comes back as typed after a quit, a crash or an
/// update: Umi types it again in the pane, resuming the conversation its hooks reported
/// (design/primitives.md, "Agent hook plugin").
///
/// What picks a conversation (`--resume`, `--continue`, `--session-id`, `--fork-session`,
/// Codex's `resume`), one-offs (`--print`, `--worktree`, `--bg`), Umi's own plugin and the first
/// prompt are left out: the restart resumes its own conversation.
enum UmiTypedCommand {
    struct Flags: Equatable {
        var model: String?
        var effort: String?
        var permissionMode: String?
        var fullAccess = false
        var profile: String?
        var args: [String] = []
    }

    /// The typed command: the agent's process, its program as the shell was given it, and the
    /// arguments after it. `pid` is the process that ran the agent's hook: the agent itself, or a shell it ran the
    /// hook in.
    static func command(pid: Int32, kind: UmiAgentKind) -> (pid: Int32, program: String, args: [String])? {
        var candidate = pid
        for _ in 0..<3 {
            if let argv = UmiProcess.arguments(candidate),
               let index = argv.prefix(3).firstIndex(where: { isProgram($0, kind) }) {
                return (candidate, argv[index], Array(argv[(index + 1)...]))
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

    /// When a process started.
    static func startTime(_ pid: Int32) -> Date? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(info.pbi_start_tvsec) + TimeInterval(info.pbi_start_tvusec) / 1_000_000)
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

    /// A one-off run (`claude -p`), not an interface in the pane: its hooks don't make the pane's
    /// agent.
    static func isOneOff(_ args: [String], kind: UmiAgentKind) -> Bool {
        guard kind == .claude else { return args.first == "exec" || args.first == "e" }
        return args.prefix { $0 != "--" }.contains { $0 == "-p" || $0 == "--print" }
    }

    /// The command line that brings the agent back on conversation `session` (nil: a fresh one,
    /// when it never had a prompt), with the flags it was typed with. A `.js` program (`node
    /// …/cli.js`) is typed by its agent's name.
    static func restartCommand(program: String, args: [String], kind: UmiAgentKind, session: String?) -> [String] {
        let name = program.hasSuffix(".js") ? kind.rawValue : program
        switch kind {
        case .claude:
            let flags = claude(args)
            var out = [name]
            if let model = flags.model { out += ["--model", model] }
            if let effort = flags.effort { out += ["--effort", effort] }
            if flags.fullAccess {
                out.append("--dangerously-skip-permissions")
            } else if let mode = flags.permissionMode {
                out += ["--permission-mode", mode]
            }
            out += flags.args
            if let session { out += ["--resume", session] }
            return out
        case .codex:
            var out = [name]
            if let session { out += ["resume", session] }
            return out + codexKept(args)
        }
    }

    /// Codex's options as typed, for a restart: every option and its value, without the
    /// subcommand and its words (`resume ID`, `--last`), the first prompt, images and `--remote`.
    static func codexKept(_ args: [String]) -> [String] {
        let valued: Set<String> = ["-m", "--model", "-a", "--ask-for-approval", "-p", "--profile", "-c", "--config",
                                   "-s", "--sandbox", "-C", "--cd", "--add-dir", "--local-provider", "--enable", "--disable"]
        let dropped: Set<String> = ["-i", "--image", "--remote"]
        var out: [String] = []
        var i = 0
        while i < args.count {
            let arg = args[i]
            if arg == "--" { break }
            let name = arg.hasPrefix("--") ? String(arg.split(separator: "=", maxSplits: 1)[0]) : arg
            let inline = arg.hasPrefix("--") && arg.contains("=")
            if dropped.contains(name) {
                if !inline { i += 1 }
            } else if valued.contains(name) {
                if inline {
                    out.append(arg)
                } else if i + 1 < args.count {
                    out += [arg, args[i + 1]]
                    i += 1
                }
            } else if arg == "--last" || arg == "--all" {
                // `resume --last`: the restart names its thread.
            } else if arg.hasPrefix("-") {
                out.append(arg)
            }
            // Anything else is the subcommand, its thread or the first prompt.
            i += 1
        }
        return out
    }

    // Claude Code 2.1's options (`claude --help`, and options it takes without listing them,
    // seen in recordings): which take a value, which take several (until the next option) and
    // which may take one. An option it doesn't know is kept as a switch, and a word after it is
    // left out: running a first prompt again would be worse than a flag missing its value.
    private static let claudeValue: Set<String> = [
        "--agent", "--agents", "--append-system-prompt", "--append-system-prompt-file", "--autocompact",
        "--debug-file", "--environment", "--fallback-model", "--input-format", "--json-schema", "--max-budget-usd",
        "--max-thinking-tokens", "--max-turns", "-n", "--name", "--output-format", "--permission-prompt-tool",
        "--permission-prompts", "--plugin-url", "--remote-control-session-name-prefix", "--resume-session-at",
        "--setting-sources", "--settings", "--system-prompt", "--system-prompt-file", "--system-prompt-snapshot",
        "--task-budget", "--thinking", "--thinking-display",
    ]
    private static let claudeValues: Set<String> = [
        "--add-dir", "--allowedTools", "--allowed-tools", "--betas", "--channels", "--disallowedTools",
        "--disallowed-tools", "--file", "--mcp-config", "--tools",
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
            // Everything after `--` is the first prompt.
            if args[i] == "--" { break }
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
            if args[i] == "--" { break }
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
