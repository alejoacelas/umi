// umi hook / umi plugins: Umi's plugins for Claude Code and Codex (CLI.md, "Agent hooks").

import Darwin
import Foundation

/// `hook EVENT --agent claude|codex [--pid PID]`, run by Umi's plugin inside Claude Code or Codex
/// with the hook's input on stdin. The app writes `agent.*` on the pane the agent runs in (the
/// caller's pane). It prints nothing and exits 0 whatever happens, and never makes the agent wait
/// long (SPEC AG-18).
func hookCommand(_ argv: [String]) -> Never {
    let args = parse(argv, ArgSpec(valued: ["--agent", "--pid"]))
    guard let event = args.positional.first else { exit(0) }
    var input = Data()
    var chunk = [UInt8](repeating: 0, count: 65536)
    while input.count < 8 * 1024 * 1024 {
        let n = read(STDIN_FILENO, &chunk, chunk.count)
        if n < 0 && errno == EINTR { continue }
        if n <= 0 { break }
        input.append(contentsOf: chunk[0..<n])
    }
    var params: [String: Any] = ["event": event, "agent": args.value("--agent") ?? "claude"]
    if let pid = args.value("--pid").flatMap({ Int($0) }) { params["pid"] = pid }
    if let object = try? JSONSerialization.jsonObject(with: input) as? [String: Any] {
        // Tool output can be large and isn't needed: only what the status needs goes.
        var payload = object
        payload.removeValue(forKey: "tool_response")
        payload.removeValue(forKey: "tool_input")
        params["payload"] = payload
    }
    guard let client = Client(path: socketPath(for: stateDirectory())) else { exit(0) }
    var timeout = timeval(tv_sec: 3, tv_usec: 0)
    setsockopt(client.fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    setsockopt(client.fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    _ = try? client.call("hook", params)
    exit(0)
}

/// `plugins [status|install [--force]|remove]`.
func pluginsCommand(_ argv: [String]) {
    let args = parse(argv, ArgSpec(boolean: ["--force"]))
    let action = args.positional.first ?? "status"
    guard ["status", "install", "remove"].contains(action) else { fail("plugins [status|install [--force]|remove]") }
    var params: [String: Any] = ["action": action]
    if args.has("--force") { params["force"] = true }
    let result = callDict("plugins", params)
    if jsonOutput {
        printJSON(result)
        return
    }
    for kind in ["claude", "codex"] {
        guard let info = result[kind] as? [String: Any] else { continue }
        let name = kind == "claude" ? "Claude Code" : "Codex"
        if let skipped = info["skipped"] as? String {
            print("\(name): \(skipped)")
            continue
        }
        if let error = info["error"] as? String {
            print("\(name): \(error)")
            continue
        }
        let installed = info["installed"] as? Bool ?? false
        var line = "\(name): " + (installed ? "Umi's plugin \(info["version"] as? String ?? "?") installed" : "Umi's plugin not installed")
        if installed, info["enabled"] as? Bool == false {
            line += " but disabled (`\(cliName) plugins install` enables it)"
        } else if let bundled = info["bundled_version"] as? String, installed, info["current"] as? Bool != true {
            line += " (this app has \(bundled); `\(cliName) plugins install` updates it)"
        }
        if info["hooks_trusted"] as? Bool == false { line += ", its hooks not trusted yet" }
        if info["agent_installed"] as? Bool == false { line += " (\(kind) isn't installed)" }
        print(line)
        for step in info["steps"] as? [String] ?? [] { print(dim("  \(step)")) }
    }
    if action == "status", !(result["claude"].flatMap { ($0 as? [String: Any])?["installed"] as? Bool } ?? false) {
        print(dim("They report what claude and codex run in \(productName)'s panes are doing; outside \(productName) they do nothing."))
    }
}
