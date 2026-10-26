import CryptoKit
import Darwin
import Foundation

/// Where this instance of Umi keeps its state and listens for the CLI.
///
/// Everything an instance stores or listens on is derived from its state directory
/// ($UMI_STATE_DIR, default ~/Library/Application Support/Umi). The control socket lives
/// in the per-user temporary directory under a hash of the state directory, so its path is
/// short whatever the state directory's length (Unix socket paths are limited to 104 bytes)
/// and two instances with different state directories can never reach each other.
///
/// Keep `canonical`, `hash` and `socketPath` in sync with UmiCLI/main.swift.
enum UmiPaths {
    static let productName = "Umi"
    static let cliName = "umi"

    /// The app is hosting unit tests (Xcode, `xcodebuild test`, `zig build test`). Then it is
    /// never the user's own copy: it gets a state directory of its own, like an isolated instance,
    /// so tests never copy Tern's state, register agent plugins or touch the user's windows.
    static let isTestHost: Bool = {
        let env = ProcessInfo.processInfo.environment
        if ["XCTestConfigurationFilePath", "XCTestSessionIdentifier", "XCTestBundlePath"].contains(where: { env[$0] != nil }) {
            return true
        }
        return (env["DYLD_INSERT_LIBRARIES"] ?? "").contains("XCTest")
    }()

    /// True when the state directory was given explicitly (an isolated instance), or the app
    /// hosts unit tests.
    static let isIsolated: Bool = {
        if let dir = ProcessInfo.processInfo.environment["UMI_STATE_DIR"], !dir.isEmpty { return true }
        return isTestHost
    }()

    static let stateDirectory: String = {
        let raw: String
        if let dir = ProcessInfo.processInfo.environment["UMI_STATE_DIR"], !dir.isEmpty {
            raw = (dir as NSString).expandingTildeInPath
        } else if isTestHost {
            raw = NSTemporaryDirectory() + "umi-test-host-\(getpid())"
        } else {
            raw = NSHomeDirectory() + "/Library/Application Support/\(productName)"
        }
        // The first run after Tern: bring its windows, tabs and sessions over (a copy).
        UmiTernImport.importIfNeeded(into: raw, isolated: isIsolated)
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

    /// "<state hash>:<run id>", exported to panes as UMI_INSTANCE.
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

    static var socketPath: String { userTempDirectory + "umi-\(stateHash).sock" }

    static func path(_ name: String) -> String {
        (stateDirectory as NSString).appendingPathComponent(name)
    }

    static func directory(_ name: String) -> String {
        let dir = path(name)
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    /// The directory holding the app bundle's executables (and the `umi` CLI).
    static var executableDirectory: String {
        Bundle.main.executableURL?.deletingLastPathComponent().path
            ?? (Bundle.main.bundlePath + "/Contents/MacOS")
    }

    static var cliPath: String { executableDirectory + "/\(cliName)" }

    /// Umi's own config file: Ghostty settings that only Umi reads (Ghostty itself never
    /// sees them), loaded right after the user's Ghostty config, so it wins over it.
    /// `$XDG_CONFIG_HOME/umi/config`, by default ~/.config/umi/config.
    static var userConfigFile: String {
        let env = ProcessInfo.processInfo.environment
        let xdg = env["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? (NSHomeDirectory() + "/.config")
        return xdg + "/umi/config"
    }
}

/// One instance per state directory (P-3). The lock is held for the life of the process
/// and released by the kernel however the process ends.
enum UmiSingleInstance {
    private static var lockFD: Int32 = -1

    /// Take the instance lock or exit. Called first thing in main, before any window or
    /// socket exists, so a losing launch has nothing to clean up.
    static func acquireOrExit() {
        let path = UmiPaths.path("instance.lock")
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
            if UmiControlClient.request(method: "system.activate", timeout: 2) { break }
            usleep(200_000)
        }
        exit(0)
    }
}

/// A minimal client for the app's own socket, used by a losing launch to reach the winner.
enum UmiControlClient {
    static func request(method: String, timeout: TimeInterval) -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(UmiPaths.socketPath.utf8)
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
enum UmiEnvironment {
    /// Variables a launching process may have set that must not leak into Umi's terminals:
    /// other agents' session markers and another Umi pane's identity.
    static func scrubInherited() {
        let env = ProcessInfo.processInfo.environment
        let exact: Set<String> = [
            "CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_CODE_SSE_PORT", "CLAUDE_AGENT_SDK_VERSION",
            "UMI_PANE_ID", "UMI_INSTANCE", "UMI_TAB_ID", "UMI_WINDOW_ID",
            "TERM_SESSION_ID", "ITERM_SESSION_ID", "WEZTERM_PANE", "KITTY_WINDOW_ID",
        ]
        // TERN_: Tern's panes say who they are the same way (Umi was called Tern before 0.6.0;
        // launched from one of Tern's terminals, Umi's must not claim to be Tern's).
        let prefixes = ["CLAUDE_CODE_", "CODEX_", "TERN_"]
        // Where the user keeps Codex's configuration isn't a session marker: panes, sessions and
        // `agent plugins` all need it.
        let kept: Set<String> = ["CODEX_HOME"]
        for key in env.keys where !kept.contains(key)
            && (exact.contains(key) || prefixes.contains(where: { key.hasPrefix($0) })) {
            unsetenv(key)
        }
        // Another Ghostty-based app's resources (Tern's, Ghostty's): release builds would take
        // its shell integration and helpers instead of this bundle's. Without the variables,
        // Ghostty finds this bundle's own next to the executable.
        let bundle = Bundle.main.bundlePath + "/"
        for key in ["GHOSTTY_RESOURCES_DIR", "GHOSTTY_BIN_DIR"] {
            if let value = env[key], !value.hasPrefix(bundle) { unsetenv(key) }
        }
    }

    /// Variables every pane gets: who it is and how to reach this instance.
    static func paneVariables(paneID: UUID) -> [String: String] {
        [
            "UMI_PANE_ID": paneID.uuidString.lowercased(),
            "UMI_INSTANCE": UmiPaths.instanceID,
            "UMI_STATE_DIR": UmiPaths.stateDirectory,
            // Umi's plugins for Claude Code and Codex report through this CLI; they stay
            // silent where it isn't set (outside Umi, AG-18).
            "UMI_CLI": UmiPaths.cliPath,
        ]
    }
}
