import Darwin
import Foundation

/// The environment a managed agent runs with (MA-20, MA-23, MA-27).
///
/// It is the environment a new terminal window gives: the user's login shell, interactive,
/// started from a clean slate (never the app's own environment, which is minimal when it is
/// launched from the Dock, and never the environment of whoever ran `agent start`, which may
/// carry another agent's markers). On top of it, a managed agent gets:
/// - `TERN_STATE_DIR`, `TERN_SESSION_ID`, `TERN_INSTANCE`: how `tern` inside it reaches this
///   instance and knows `self`;
/// - the app's own `tern` first on PATH (an older `tern` elsewhere on PATH must not answer);
/// - the variables given with `agent start --env`.
enum TernAgentEnvironment {
    private static let captureQueue = DispatchQueue(label: "dev.tern.agents.login-env")
    private static var cached: (env: [String: String], at: Date, ok: Bool)?

    /// The login shell environment. Cached for a few minutes; concurrent callers share one
    /// capture. A capture blocks while the shell starts (at most ~15 s if a startup file
    /// hangs), so callers on the agent queue must not use it: see `TernAgents.launch`.
    static func login() -> (env: [String: String], ok: Bool) {
        captureQueue.sync {
            if let cached, Date().timeIntervalSince(cached.at) < 300 { return (cached.env, cached.ok) }
            let fresh = capture()
            cached = (fresh.env, Date(), fresh.ok)
            return fresh
        }
    }

    /// Warm the cache (at launch), so the first agent starts quickly.
    static func warm() {
        DispatchQueue.global(qos: .utility).async { _ = login() }
    }

    static var userShell: String {
        if let entry = getpwuid(getuid()), let raw = entry.pointee.pw_shell {
            let candidate = String(cString: raw)
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return "/bin/zsh"
    }

    private static func baseEnvironment() -> [String: String] {
        [
            "HOME": NSHomeDirectory(), "USER": NSUserName(), "LOGNAME": NSUserName(), "SHELL": userShell,
            "TERM": "xterm-256color", "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "TMPDIR": TernPaths.userTempDirectory,
        ]
    }

    private static func capture() -> (env: [String: String], ok: Bool) {
        let marker = "__TERN_LOGIN_ENV__"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: userShell)
        process.arguments = ["-l", "-i", "-c", "printf '\\n\(marker)\\n'; /usr/bin/env -0"]
        process.environment = baseEnvironment()
        process.currentDirectoryURL = URL(fileURLWithPath: NSHomeDirectory())
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return (fallback(), false) }
        let collected = TernLockedData()
        let done = DispatchSemaphore(value: 0)
        let fd = out.fileHandleForReading.fileDescriptor
        Thread.detachNewThread {
            var chunk = [UInt8](repeating: 0, count: 65536)
            while true {
                let n = read(fd, &chunk, chunk.count)
                if n < 0 && errno == EINTR { continue }
                if n <= 0 { break }
                collected.append(Data(chunk[0..<n]))
            }
            done.signal()
        }
        let timedOut = done.wait(timeout: .now() + 15) == .timedOut
        if process.isRunning { process.terminate() }
        let data = collected.data
        guard !timedOut, let range = data.range(of: Data("\n\(marker)\n".utf8)) else { return (fallback(), false) }
        var env: [String: String] = [:]
        for entry in data[range.upperBound...].split(separator: 0) {
            let text = String(decoding: entry, as: UTF8.self)
            guard let eq = text.firstIndex(of: "="), eq != text.startIndex else { continue }
            env[String(text[..<eq])] = String(text[text.index(after: eq)...])
        }
        guard env["PATH"] != nil else { return (fallback(), false) }
        for key in ["_", "SHLVL", "OLDPWD", "PWD"] { env.removeValue(forKey: key) }
        return (env, true)
    }

    /// If the login shell can't be read: what macOS's path_helper and common locations give.
    private static func fallback() -> [String: String] {
        var env = baseEnvironment()
        var path = ["/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        if let text = try? String(contentsOfFile: "/etc/paths", encoding: .utf8) {
            path = text.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        }
        let home = NSHomeDirectory()
        for extra in ["\(home)/.local/bin", "/opt/homebrew/bin", "/opt/homebrew/sbin"] where !path.contains(extra) {
            path.insert(extra, at: 0)
        }
        env["PATH"] = path.joined(separator: ":")
        return env
    }

    /// Markers of other agent processes that must never reach a managed agent (MA-20), even
    /// if something put them in the login environment.
    static func isForeignMarker(_ key: String) -> Bool {
        let exact: Set<String> = ["CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_CODE_SSE_PORT",
                                  "CLAUDE_AGENT_SDK_VERSION", "CLAUDE_CODE_SESSION_ID", "CODEX_THREAD_ID",
                                  "CODEX_SANDBOX", "CODEX_SANDBOX_NETWORK_DISABLED", "TERN_PANE_ID",
                                  "TERN_TAB_ID", "TERN_WINDOW_ID", "TERN_SESSION_ID", "TERN_INSTANCE",
                                  "TERN_STATE_DIR", "TERN_SESSION_NAME", "TERM_SESSION_ID", "ITERM_SESSION_ID",
                                  "TERN_HEADLESS", "TERN_PLUGIN_ROOT", "TERN_CLI"]
        return exact.contains(key)
    }

    /// The full environment for a session's harness process.
    static func harnessEnvironment(session: TernSessionRecord) -> (env: [String: String], flags: [String]) {
        let base = login()
        var env = base.env.filter { !isForeignMarker($0.key) }
        var flags: [String] = []
        if !base.ok { flags.append("couldn't read your login shell's environment; using a default PATH") }
        let bin = TernPaths.executableDirectory
        let path = (env["PATH"] ?? "/usr/bin:/bin").split(separator: ":").map(String.init).filter { $0 != bin }
        env["PATH"] = ([bin] + path).joined(separator: ":")
        env["TERN_STATE_DIR"] = TernPaths.stateDirectory
        env["TERN_SESSION_ID"] = session.id
        env["TERN_INSTANCE"] = TernPaths.instanceID
        env["TERN_CLI"] = TernPaths.cliPath
        // Headless, Tern reads the agent's own stream: Tern's hook plugin stays quiet here.
        env["TERN_HEADLESS"] = "1"
        env["PWD"] = session.cwd
        for (key, value) in session.env { env[key] = value }
        return (env, flags)
    }

    /// Where a harness binary is: the instance's override (tests point it at the fakes), else
    /// `claude` / `codex` on the login PATH.
    static func harnessBinary(_ kind: TernAgentKind) -> String? {
        let override = ProcessInfo.processInfo.environment[kind == .claude ? "TERN_CLAUDE_BIN" : "TERN_CODEX_BIN"]
        if let override, !override.isEmpty { return override }
        let name = kind.rawValue
        let path = login().env["PATH"] ?? ""
        for dir in path.split(separator: ":") {
            let candidate = "\(dir)/\(name)"
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    // MARK: What a worker is told about its situation (MA-27)

    static func awarenessNote(session: TernSessionRecord) -> String {
        let cli = TernPaths.cliName
        var who = "Your session: name \"\(session.name)\", id \(session.id)"
        if let parent = session.parent { who += ", started by session \(parent)" }
        who += ". Your folder: \(session.cwd)."
        return """
        You are an agent session in \(TernPaths.productName), a terminal that runs Claude Code and Codex sessions. \
        You may be running headless with nobody watching: whoever sent your instructions (often another agent) \
        reads your reply when your turn ends. The user can also open this session in a pane and talk to you there.
        - \(who) `\(cli) agent info self` shows your current name, id, parent and status.
        - When your task is done, or you're blocked, or it failed, record your verdict with \
        `\(cli) agent report done|blocked|failed "<one-line summary>"` (whoever started you can wait for it).
        - `\(cli)` is on your PATH and reaches this \(TernPaths.productName). `\(cli) agent start claude|codex "TASK"` starts \
        another session (headless, in the background), `\(cli) agent wait NAME` waits for its reply, \
        `\(cli) agent send NAME "TEXT"` steers it or gives it its next task, `\(cli) agent ls --parent self` lists \
        the sessions you started; `\(cli) agent --help` explains the rest.
        """
    }
}

/// Bytes appended by one thread and read by another.
final class TernLockedData: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()

    func append(_ chunk: Data) {
        lock.lock()
        storage.append(chunk)
        lock.unlock()
    }

    var data: Data {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
