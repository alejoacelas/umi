import Darwin
import Foundation

/// The user's login shell environment, as a new terminal window gives it: interactive, started
/// from a clean slate (never the app's own environment, which is minimal when it is launched
/// from the Dock). The agent plugins' installer and the sidebar's `gh` lookups run with it.
enum UmiAgentEnvironment {
    private static let captureQueue = DispatchQueue(label: "dev.umi.agents.login-env")
    private static var cached: (env: [String: String], at: Date, ok: Bool)?

    /// The login shell environment. Cached for a few minutes; concurrent callers share one
    /// capture. A capture blocks while the shell starts (at most ~15 s if a startup file
    /// hangs), so the main thread must not wait on it.
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
            "TMPDIR": UmiPaths.userTempDirectory,
        ]
    }

    private static func capture() -> (env: [String: String], ok: Bool) {
        let marker = "__UMI_LOGIN_ENV__"
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
        let collected = UmiLockedData()
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

    /// Markers of agent processes and Umi panes that must never reach the agents' own plugin
    /// commands, even if something put them in the login environment.
    static func isForeignMarker(_ key: String) -> Bool {
        let exact: Set<String> = ["CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_CODE_SSE_PORT",
                                  "CLAUDE_AGENT_SDK_VERSION", "CLAUDE_CODE_SESSION_ID", "CODEX_THREAD_ID",
                                  "CODEX_SANDBOX", "CODEX_SANDBOX_NETWORK_DISABLED", "UMI_PANE", "UMI_PANE_ID",
                                  "UMI_TAB", "UMI_WINDOW", "UMI_CAUSE", "UMI_TAB_ID", "UMI_WINDOW_ID", "UMI_SESSION_ID", "UMI_INSTANCE",
                                  "UMI_STATE_DIR", "UMI_SESSION_NAME", "TERM_SESSION_ID", "ITERM_SESSION_ID",
                                  "UMI_HEADLESS", "UMI_PLUGIN_ROOT", "UMI_CLI"]
        return exact.contains(key)
    }
}

/// Bytes appended by one thread and read by another.
final class UmiLockedData: @unchecked Sendable {
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
