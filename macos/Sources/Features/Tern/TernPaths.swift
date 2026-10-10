import CryptoKit
import Darwin
import Foundation

/// Where this instance of Tern keeps its state and listens for the CLI.
///
/// Everything an instance stores or listens on is derived from its state directory
/// ($TERN_STATE_DIR, default ~/Library/Application Support/Tern). The control socket lives
/// in the per-user temporary directory under a hash of the state directory, so its path is
/// short whatever the state directory's length (Unix socket paths are limited to 104 bytes)
/// and two instances with different state directories can never reach each other.
///
/// Keep `canonical`, `hash` and `socketPath` in sync with TernCLI/main.swift.
enum TernPaths {
    static let productName = "Tern"
    static let cliName = "tern"

    /// True when the state directory was given explicitly (an isolated instance).
    static let isIsolated: Bool = {
        guard let dir = ProcessInfo.processInfo.environment["TERN_STATE_DIR"] else { return false }
        return !dir.isEmpty
    }()

    static let stateDirectory: String = {
        let raw: String
        if let dir = ProcessInfo.processInfo.environment["TERN_STATE_DIR"], !dir.isEmpty {
            raw = (dir as NSString).expandingTildeInPath
        } else {
            raw = NSHomeDirectory() + "/Library/Application Support/\(productName)"
        }
        try? FileManager.default.createDirectory(atPath: raw, withIntermediateDirectories: true)
        return canonical(raw)
    }()

    static func canonical(_ dir: String) -> String {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
        if realpath(dir, &buffer) != nil { return String(cString: buffer) }
        return URL(fileURLWithPath: dir).standardizedFileURL.path
    }

    static let stateHash: String = {
        let digest = SHA256.hash(data: Data(stateDirectory.utf8))
        return String(digest.map { String(format: "%02x", $0) }.joined().prefix(16))
    }()

    /// A new id for every run of the app. Pane environments carry it, so a CLI run from a
    /// terminal that outlived an earlier run can be told apart (R-7).
    static let runID: String = UUID().uuidString.lowercased()

    /// "<state hash>:<run id>", exported to panes as TERN_INSTANCE.
    static var instanceID: String { "\(stateHash):\(runID)" }

    static let userTempDirectory: String = {
        let size = confstr(_CS_DARWIN_USER_TEMP_DIR, nil, 0)
        if size > 0 {
            var buffer = [CChar](repeating: 0, count: size)
            if confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, size) > 0 {
                var path = String(cString: buffer)
                if !path.hasSuffix("/") { path += "/" }
                return path
            }
        }
        return "/tmp/"
    }()

    static var socketPath: String { userTempDirectory + "tern-\(stateHash).sock" }

    static func path(_ name: String) -> String {
        (stateDirectory as NSString).appendingPathComponent(name)
    }

    static func directory(_ name: String) -> String {
        let dir = path(name)
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    /// The directory holding the app bundle's executables (and the `tern` CLI).
    static var executableDirectory: String {
        Bundle.main.executableURL?.deletingLastPathComponent().path
            ?? (Bundle.main.bundlePath + "/Contents/MacOS")
    }

    static var cliPath: String { executableDirectory + "/\(cliName)" }
}

/// One instance per state directory (P-3). The lock is held for the life of the process
/// and released by the kernel however the process ends.
enum TernSingleInstance {
    private static var lockFD: Int32 = -1

    /// Take the instance lock or exit. Called first thing in main, before any window or
    /// socket exists, so a losing launch has nothing to clean up.
    static func acquireOrExit() {
        let path = TernPaths.path("instance.lock")
        let fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return }
        if flock(fd, LOCK_EX | LOCK_NB) == 0 {
            lockFD = fd
            let pid = "\(getpid())\n"
            ftruncate(fd, 0)
            _ = pid.withCString { write(fd, $0, strlen($0)) }
            return
        }
        close(fd)
        // Another process owns this state directory. Ask it to show itself (best effort,
        // it may still be starting) and leave.
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if TernControlClient.request(method: "system.activate", timeout: 2) { break }
            usleep(200_000)
        }
        exit(0)
    }
}

/// A minimal client for the app's own socket, used by a losing launch to reach the winner.
enum TernControlClient {
    static func request(method: String, timeout: TimeInterval) -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(TernPaths.socketPath.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { return false }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            for (i, b) in bytes.enumerated() { raw[i] = b }
            raw[bytes.count] = 0
        }
        var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var nosigpipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &nosigpipe, socklen_t(MemoryLayout<Int32>.size))
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { return false }
        let line = "{\"id\":1,\"method\":\"\(method)\",\"params\":{}}\n"
        let sent = line.withCString { write(fd, $0, strlen($0)) }
        guard sent > 0 else { return false }
        var buffer = [UInt8](repeating: 0, count: 4096)
        return read(fd, &buffer, buffer.count) > 0
    }
}

/// The environment the app hands to its terminals.
enum TernEnvironment {
    /// Variables a launching process may have set that must not leak into Tern's terminals:
    /// other agents' session markers and another Tern pane's identity.
    static func scrubInherited() {
        let env = ProcessInfo.processInfo.environment
        let exact: Set<String> = [
            "CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_CODE_SSE_PORT", "CLAUDE_AGENT_SDK_VERSION",
            "TERN_PANE_ID", "TERN_INSTANCE", "TERN_TAB_ID", "TERN_WINDOW_ID",
            "TERM_SESSION_ID", "ITERM_SESSION_ID", "WEZTERM_PANE", "KITTY_WINDOW_ID",
        ]
        let prefixes = ["CLAUDE_CODE_", "CODEX_"]
        // Where the user keeps Codex's configuration isn't a session marker: panes, sessions and
        // `agent plugins` all need it.
        let kept: Set<String> = ["CODEX_HOME"]
        for key in env.keys where !kept.contains(key)
            && (exact.contains(key) || prefixes.contains(where: { key.hasPrefix($0) })) {
            unsetenv(key)
        }
    }

    /// Variables every pane gets: who it is and how to reach this instance.
    static func paneVariables(paneID: UUID) -> [String: String] {
        [
            "TERN_PANE_ID": paneID.uuidString.lowercased(),
            "TERN_INSTANCE": TernPaths.instanceID,
            "TERN_STATE_DIR": TernPaths.stateDirectory,
            // Tern's plugins for Claude Code and Codex report through this CLI; they stay
            // silent where it isn't set (outside Tern, AG-18).
            "TERN_CLI": TernPaths.cliPath,
        ]
    }
}
