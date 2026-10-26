import Foundation

/// Tern's plugins for Claude Code and Codex (AG-18): hooks that tell Tern what an agent in one
/// of its panes is doing, the way Warp's plugins do. They ship in the app bundle
/// (`Contents/Resources/agent-plugins`, a marketplace for each agent) and are installed into
/// the user's Claude Code and Codex with the agents' own plugin commands, then kept at the
/// app's version. Outside Tern the hooks do nothing (`tern-hook.sh`).
///
/// - Claude Code: `claude plugin marketplace add <bundle>`, `claude plugin install tern@tern`;
///   an update is `marketplace update` + `plugin update`.
/// - Codex: `codex plugin marketplace add <bundle>`, `codex plugin add tern@tern`, then the
///   plugin's own hooks are marked trusted through Codex's app server (`hooks/list`,
///   `config/batchWrite` of `hooks.state.<key>.trusted_hash`), because Codex runs no plugin
///   hook until it's trusted. Only hooks of `tern@tern` are ever touched.
///
/// Sessions Tern shows live load the bundled copy directly (`--plugin-dir`), so they report
/// even before anything is installed.
enum TernAgentPlugins {
    static let pluginID = "tern@tern"

    static var bundledRoot: String? {
        guard let resources = Bundle.main.resourcePath else { return nil }
        let root = resources + "/agent-plugins"
        return FileManager.default.fileExists(atPath: root + "/.claude-plugin/marketplace.json") ? root : nil
    }

    static var bundledClaudePlugin: String? { bundledRoot.map { $0 + "/claude" } }

    static func bundledVersion(_ kind: TernAgentKind) -> String? {
        guard let root = bundledRoot else { return nil }
        let manifest = kind == .claude ? "/claude/.claude-plugin/plugin.json" : "/codex/.codex-plugin/plugin.json"
        guard let data = FileManager.default.contents(atPath: root + manifest),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object["version"] as? String
    }

    // MARK: Where the agents keep their configuration

    /// The environment the agents' plugin commands run with: the login shell's, plus the app's
    /// own CLAUDE_CONFIG_DIR / CODEX_HOME when set (tests point them at temporary folders).
    static func commandEnvironment() -> [String: String] {
        var env = TernAgentEnvironment.login().env.filter { !TernAgentEnvironment.isForeignMarker($0.key) }
        let own = ProcessInfo.processInfo.environment
        for key in ["CLAUDE_CONFIG_DIR", "CODEX_HOME"] { if let value = own[key], !value.isEmpty { env[key] = value } }
        return env
    }

    static func claudeConfigDir(_ env: [String: String]) -> String {
        env["CLAUDE_CONFIG_DIR"] ?? (NSHomeDirectory() + "/.claude")
    }

    static func codexHome(_ env: [String: String]) -> String {
        env["CODEX_HOME"] ?? (NSHomeDirectory() + "/.codex")
    }

    static func binary(_ kind: TernAgentKind, _ env: [String: String]) -> String? {
        let override = ProcessInfo.processInfo.environment[kind == .claude ? "TERN_PLUGIN_CLAUDE_BIN" : "TERN_PLUGIN_CODEX_BIN"]
        if let override, !override.isEmpty { return override }
        for dir in (env["PATH"] ?? "").split(separator: ":") {
            let candidate = "\(dir)/\(kind.rawValue)"
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    // MARK: Status

    struct Status {
        var agentInstalled: Bool
        var installed: Bool
        var version: String?
        var bundled: String?
        var hooksTrusted: Bool?
        var detail: String?
        /// Installed from this copy of the app (another copy, a moved app or an old build may have
        /// installed it: then it's brought over to this one).
        var fromThisApp = true
        /// Claude Code can have it installed but disabled (its settings were rewritten, or the
        /// user disabled it): then it reports nothing.
        var enabled: Bool?

        var current: Bool {
            installed && version != nil && version == bundled && hooksTrusted != false && fromThisApp && enabled != false
        }

        var json: [String: Any] {
            var out: [String: Any] = ["agent_installed": agentInstalled, "installed": installed, "current": current]
            if let version { out["version"] = version }
            if let bundled { out["bundled_version"] = bundled }
            if let hooksTrusted { out["hooks_trusted"] = hooksTrusted }
            if let enabled { out["enabled"] = enabled }
            if let detail { out["detail"] = detail }
            return out
        }
    }

    static func status(_ kind: TernAgentKind, env: [String: String]? = nil) -> Status {
        let env = env ?? commandEnvironment()
        let bundled = bundledVersion(kind)
        let agent = binary(kind, env) != nil
        switch kind {
        case .claude:
            let path = claudeConfigDir(env) + "/plugins/installed_plugins.json"
            let object = FileManager.default.contents(atPath: path).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            let entries = (object?["plugins"] as? [String: Any])?[pluginID] as? [[String: Any]] ?? []
            let version = entries.first?["version"] as? String
            var status = Status(agentInstalled: agent, installed: !entries.isEmpty, version: version, bundled: bundled, hooksTrusted: nil)
            if let root = bundledRoot { status.fromThisApp = claudeMarketplacePoints(at: root, env: env) }
            if status.installed {
                let settings = FileManager.default.contents(atPath: claudeConfigDir(env) + "/settings.json")
                    .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                status.enabled = (settings?["enabledPlugins"] as? [String: Any])?[pluginID] as? Bool ?? false
            }
            return status
        case .codex:
            let home = codexHome(env)
            let config = (try? String(contentsOfFile: home + "/config.toml", encoding: .utf8)) ?? ""
            let installed = config.contains("[plugins.\"\(pluginID)\"]")
            let cache = home + "/plugins/cache/tern/tern"
            let versions = ((try? FileManager.default.contentsOfDirectory(atPath: cache)) ?? []).sorted {
                $0.compare($1, options: .numeric) == .orderedAscending
            }
            let trusted = installed ? config.contains("[hooks.state.\"\(pluginID):") : nil
            var status = Status(agentInstalled: agent, installed: installed, version: versions.last, bundled: bundled,
                                hooksTrusted: trusted)
            if let root = bundledRoot { status.fromThisApp = codexMarketplacePoints(at: root, config: config) }
            return status
        }
    }

    // MARK: Installing

    private static let queue = DispatchQueue(label: "dev.tern.agent-plugins")

    /// Install or update both plugins (whichever agents are installed). Blocks the calling
    /// thread while the agents' commands run (seconds); never call it on the main thread.
    @discardableResult
    static func install(force: Bool = false) -> [String: Any] {
        queue.sync {
            let env = commandEnvironment()
            var out: [String: Any] = [:]
            for kind in [TernAgentKind.claude, .codex] {
                out[kind.rawValue] = installOne(kind, env: env, force: force)
            }
            log("install: \(out)")
            return out
        }
    }

    private static func installOne(_ kind: TernAgentKind, env: [String: String], force: Bool) -> [String: Any] {
        guard let root = bundledRoot else { return ["error": "this build has no plugins"] }
        guard let bin = binary(kind, env) else { return ["skipped": "\(kind.rawValue) isn't installed"] }
        let before = status(kind, env: env)
        if before.current && !force { return status(kind, env: env).json }
        var steps: [String] = []
        func run(_ args: [String]) -> Bool {
            let result = runCommand(bin, args, env: env)
            steps.append("\(kind.rawValue) \(args.joined(separator: " ")): \(result.ok ? "ok" : "failed: \(result.output.suffix(300))")")
            return result.ok
        }
        switch kind {
        case .claude:
            if !before.installed {
                if claudeMarketplaceKnown(env: env) && !claudeMarketplacePoints(at: root, env: env) {
                    _ = run(["plugin", "marketplace", "remove", "tern"])
                }
                if !claudeMarketplacePoints(at: root, env: env) { _ = run(["plugin", "marketplace", "add", root]) }
                _ = run(["plugin", "install", pluginID])
            } else {
                // Point the marketplace at this app (it may have moved), then update.
                if !claudeMarketplacePoints(at: root, env: env) {
                    _ = run(["plugin", "marketplace", "remove", "tern"])
                    _ = run(["plugin", "marketplace", "add", root])
                    _ = run(["plugin", "install", pluginID])
                } else {
                    _ = run(["plugin", "marketplace", "update", "tern"])
                    _ = run(["plugin", "update", pluginID])
                }
            }
            if status(kind, env: env).enabled == false { _ = run(["plugin", "enable", pluginID]) }
        case .codex:
            let config = (try? String(contentsOfFile: codexHome(env) + "/config.toml", encoding: .utf8)) ?? ""
            if !codexMarketplacePoints(at: root, config: config) {
                if config.contains("[marketplaces.tern]") { _ = run(["plugin", "marketplace", "remove", "tern"]) }
                _ = run(["plugin", "marketplace", "add", root])
            }
            _ = run(["plugin", "add", pluginID])
            steps.append(trustCodexHooks(bin, env: env))
        }
        var json = status(kind, env: env).json
        json["steps"] = steps
        return json
    }

    private static func claudeMarketplaceKnown(env: [String: String]) -> Bool {
        let path = claudeConfigDir(env) + "/plugins/known_marketplaces.json"
        guard let data = FileManager.default.contents(atPath: path),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return object["tern"] != nil
    }

    /// Codex records the marketplace's folder with symlinks resolved (/tmp → /private/tmp).
    private static func codexMarketplacePoints(at root: String, config: String) -> Bool {
        let resolved = (root as NSString).resolvingSymlinksInPath
        return [root, resolved, "/private" + root].contains { config.contains("source = \"\($0)\"") }
    }

    private static func claudeMarketplacePoints(at root: String, env: [String: String]) -> Bool {
        let path = claudeConfigDir(env) + "/plugins/known_marketplaces.json"
        guard let data = FileManager.default.contents(atPath: path),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entry = object["tern"] as? [String: Any],
              let source = entry["source"] as? [String: Any] else { return false }
        return (source["path"] as? String) == root
    }

    /// Mark the hooks of Tern's own Codex plugin trusted (nothing else), through a private app
    /// server: Codex skips plugin hooks until they're trusted.
    private static func trustCodexHooks(_ bin: String, env: [String: String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: bin)
        process.arguments = ["app-server", "--listen", "stdio://"]
        process.environment = env
        // Not the home folder: there Claude Code takes ~/.claude/settings.json for the folder's
        // project settings and changes it too, whatever CLAUDE_CONFIG_DIR says.
        process.currentDirectoryURL = neutralFolder
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return "codex hooks: couldn't start codex (\(error))" }
        defer {
            try? input.fileHandleForWriting.close()
            if process.isRunning { process.terminate() }
        }
        let reader = TernLineReader(output.fileHandleForReading)
        func call(_ id: Int, _ method: String, _ params: [String: Any]) -> [String: Any]? {
            guard let data = try? JSONSerialization.data(withJSONObject: ["id": id, "method": method, "params": params]) else { return nil }
            input.fileHandleForWriting.write(data + Data("\n".utf8))
            let deadline = Date().addingTimeInterval(20)
            while Date() < deadline {
                guard let line = reader.next(timeout: deadline.timeIntervalSinceNow) else { return nil }
                if let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                   (object["id"] as? NSNumber)?.intValue == id, object["method"] == nil {
                    return object
                }
            }
            return nil
        }
        guard call(1, "initialize", ["clientInfo": ["name": "tern", "title": "Tern", "version": "1"],
                                    "capabilities": ["experimentalApi": true]]) != nil else {
            return "codex hooks: the app server didn't answer"
        }
        input.fileHandleForWriting.write(Data("{\"method\":\"initialized\"}\n".utf8))
        guard let listed = call(2, "hooks/list", ["cwds": [NSHomeDirectory()]]),
              let data = (listed["result"] as? [String: Any])?["data"] as? [[String: Any]] else {
            return "codex hooks: couldn't list hooks"
        }
        var trust: [String: Any] = [:]
        for entry in data {
            for hook in entry["hooks"] as? [[String: Any]] ?? [] where hook["pluginId"] as? String == pluginID {
                guard let key = hook["key"] as? String, let hash = hook["currentHash"] as? String else { continue }
                if hook["trustStatus"] as? String != "trusted" { trust[key] = ["trusted_hash": hash] }
            }
        }
        if trust.isEmpty { return "codex hooks: already trusted" }
        let written = call(3, "config/batchWrite", ["edits": [["keyPath": "hooks.state", "mergeStrategy": "upsert", "value": trust]]])
        if written?["error"] != nil || written == nil { return "codex hooks: couldn't record trust" }
        return "codex hooks: trusted \(trust.count)"
    }

    /// Remove both plugins (`agent plugins remove`).
    static func remove() -> [String: Any] {
        queue.sync {
            let env = commandEnvironment()
            var out: [String: Any] = [:]
            if let bin = binary(.claude, env) {
                let a = runCommand(bin, ["plugin", "uninstall", pluginID], env: env)
                let b = runCommand(bin, ["plugin", "marketplace", "remove", "tern"], env: env)
                out["claude"] = ["uninstalled": a.ok, "marketplace_removed": b.ok]
            }
            if let bin = binary(.codex, env) {
                let a = runCommand(bin, ["plugin", "remove", pluginID], env: env)
                let b = runCommand(bin, ["plugin", "marketplace", "remove", "tern"], env: env)
                out["codex"] = ["uninstalled": a.ok, "marketplace_removed": b.ok]
            }
            log("remove: \(out)")
            return out
        }
    }

    /// At launch of the user's own copy (never an isolated test instance): install or update
    /// in the background, once.
    static func ensureInstalledAtLaunch() {
        guard !TernPaths.isIsolated, bundledRoot != nil else { return }
        guard ProcessInfo.processInfo.environment["TERN_NO_PLUGIN_INSTALL"] == nil else { return }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5) {
            install()
        }
    }

    // MARK: Running the agents' commands

    /// An empty folder of Tern's own to run the agents' commands in (no project settings there).
    static let neutralFolder: URL = {
        let url = URL(fileURLWithPath: TernPaths.directory("agent-commands"))
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    static func runCommand(_ bin: String, _ args: [String], env: [String: String], timeout: TimeInterval = 60)
        -> (ok: Bool, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: bin)
        process.arguments = args
        process.environment = env
        // Not the home folder: there Claude Code takes ~/.claude/settings.json for the folder's
        // project settings and changes it too, whatever CLAUDE_CONFIG_DIR says.
        process.currentDirectoryURL = neutralFolder
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return (false, "\(error)") }
        let collected = TernLockedData()
        let done = DispatchSemaphore(value: 0)
        let fd = output.fileHandleForReading.fileDescriptor
        Thread.detachNewThread {
            var chunk = [UInt8](repeating: 0, count: 16384)
            while true {
                let n = read(fd, &chunk, chunk.count)
                if n < 0 && errno == EINTR { continue }
                if n <= 0 { break }
                collected.append(Data(chunk[0..<n]))
            }
            done.signal()
        }
        if done.wait(timeout: .now() + timeout) == .timedOut, process.isRunning { process.terminate() }
        process.waitUntilExit()
        return (process.terminationStatus == 0, String(decoding: collected.data, as: UTF8.self))
    }

    private static func log(_ line: String) {
        let path = TernPaths.path("plugins.log")
        let text = "\(TernAgentTime.iso(Date())) \(line)\n"
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(Data(text.utf8))
            try? handle.close()
        } else {
            FileManager.default.createFile(atPath: path, contents: Data(text.utf8), attributes: [.posixPermissions: 0o600])
        }
    }
}

/// Lines from a pipe, with a timeout per line.
final class TernLineReader: @unchecked Sendable {
    private let handle: FileHandle
    private var buffer = Data()
    private let lock = NSCondition()
    private var lines: [Data] = []
    private var ended = false

    init(_ handle: FileHandle) {
        self.handle = handle
        Thread.detachNewThread { [self] in
            let fd = handle.fileDescriptor
            var chunk = [UInt8](repeating: 0, count: 65536)
            while true {
                let n = read(fd, &chunk, chunk.count)
                if n < 0 && errno == EINTR { continue }
                lock.lock()
                if n <= 0 {
                    ended = true
                    lock.broadcast()
                    lock.unlock()
                    return
                }
                buffer.append(contentsOf: chunk[0..<n])
                while let newline = buffer.firstIndex(of: 0x0A) {
                    lines.append(Data(buffer[buffer.startIndex..<newline]))
                    buffer.removeSubrange(buffer.startIndex...newline)
                }
                lock.broadcast()
                lock.unlock()
            }
        }
    }

    func next(timeout: TimeInterval) -> Data? {
        let deadline = Date().addingTimeInterval(max(0, timeout))
        lock.lock()
        defer { lock.unlock() }
        while lines.isEmpty && !ended {
            if !lock.wait(until: deadline) { return nil }
        }
        return lines.isEmpty ? nil : lines.removeFirst()
    }
}
