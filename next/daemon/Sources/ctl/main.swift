// umi-next-ctl: manage the daemon's sessions. See PROTOCOL.md.
import Darwin
import Foundation
import UmiC

let usage = """
usage: umi-next-ctl <command>
  new [--cwd DIR] [--cmd CMD] [--cols N --rows N] [--name NAME] [--by WHO] [--env KEY=VALUE]...
                           start a session, print its id (WHO: who started it, default cli;
                           the UI passes user). The session gets a fixed set of this
                           environment's variables (HOME, PATH, SHELL, LANG, ...), not all of
                           it; --env adds one more, and can be repeated.
  ls                       sessions as JSON
  kill <id> [--signal N]   signal the session's process group (default TERM)
  rm <id> [--force]        forget an exited session (--force kills a live one)
  screen <id> [--json|--vt] [--scrollback]   current screen (plain text; --json adds cursor
                           and modes; --scrollback puts the scrollback above it, `history` in JSON)
  send <id> <text>         type text into the session
  ping                     daemon pid and session count (fails if not running)
  daemon-start             start the daemon if it isn't running
  daemon-stop [--force]    stop the daemon (refuses while sessions are alive)
  render --cols N --rows N [--json] [--scrollback]   feed stdin into a fresh terminal, print its screen
                           (--replay: also through the attach replay, both as JSON)
State dir: $UMI_NEXT_STATE_DIR or ~/Library/Application Support/Umi-next
"""

var args = Array(CommandLine.arguments.dropFirst())
guard let cmd = args.first else { eprint(usage); exit(2) }
args.removeFirst()

func flag(_ name: String) -> Bool {
    if let i = args.firstIndex(of: name) { args.remove(at: i); return true }
    return false
}
func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    let v = args[i + 1]
    args.removeSubrange(i...(i + 1))
    return v
}
func die(_ s: String, _ code: Int32 = 1) -> Never { eprint("umi-next-ctl: \(s)"); exit(code) }

func request(_ req: [String: Any], fd givenFD: Int32? = nil) -> [String: Any] {
    let fd = givenFD ?? connectDaemon()
    if fd < 0 { die("daemon not running (\(Paths.socket))", 3) }
    writeAll(fd, encodeJSON(req))
    var r = FrameReader()
    guard let (t, p) = readFrame(fd, &r), t == .json, let resp = decodeJSON(p) else { die("no reply from daemon") }
    if givenFD == nil { close(fd) }
    if resp["ok"] as? Bool != true { die(resp["error"] as? String ?? "request failed") }
    return resp
}

func printJSON(_ obj: Any) {
    let data = try! JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
    print(String(data: data, encoding: .utf8)!)
}

/// Start the daemon (next to this binary) unless one answers; wait for its socket.
func ensureDaemon() {
    let fd = connectDaemon()
    if fd >= 0 { close(fd); return }
    try? FileManager.default.createDirectory(atPath: Paths.stateDir, withIntermediateDirectories: true)
    if Paths.socket.utf8.count >= 104 { die("socket path too long (max 103 bytes): \(Paths.socket)") }
    let me = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    let daemon = me.deletingLastPathComponent().appendingPathComponent("umi-next-daemon").path
    var pid: pid_t = 0
    let argv: [UnsafeMutablePointer<CChar>?] = [strdup(daemon), nil]
    // The daemon detaches itself (fork, setsid); the spawned process exits at once.
    let rc = posix_spawn(&pid, daemon, nil, nil, argv, environ)
    if rc != 0 { die("cannot start \(daemon): \(String(cString: strerror(rc)))") }
    var status: Int32 = 0
    waitpid(pid, &status, 0)
    for _ in 0..<200 {
        let fd = connectDaemon()
        if fd >= 0 { close(fd); return }
        usleep(25_000)
    }
    die("daemon did not start; see \(Paths.log)")
}

func parseSize(_ s: String?) -> Int? { s.flatMap { Int($0) } }

/// The variables a new session takes from this environment. Everything else stays behind: this
/// environment is whatever launched UmiNext (or ran this command), and an agent's tool shell
/// carries settings meant for the agent alone. Codex runs its commands with NO_COLOR=1, PAGER=cat
/// and LC_ALL=C.UTF-8, so when Codex reinstalled UmiNext every new pane's Claude came up without
/// colours; Claude's CLAUDE_CODE_CHILD_SESSION marker made new sessions save no transcript. The
/// session's login shell sets up the rest from the user's profile.
let sessionVariables: Set<String> = [
    "HOME", "USER", "LOGNAME", "SHELL", "PATH", "TMPDIR", "LANG", "SSH_AUTH_SOCK",
    "__CF_USER_TEXT_ENCODING", "__CFBundleIdentifier",
    // Where the agents keep their configuration, and Claude's credential for sessions over SSH.
    "CODEX_HOME", "CLAUDE_CONFIG_DIR", "CLAUDE_CODE_OAUTH_TOKEN",
    // Which UmiNext the session belongs to.
    "UMI_NEXT_STATE_DIR",
]

/// `--env KEY=VALUE`, as often as given: variables the caller wants in the session by name.
func envOptions() -> [String: String] {
    var out: [String: String] = [:]
    while let pair = option("--env") {
        guard let eq = pair.firstIndex(of: "="), eq != pair.startIndex else { die("--env takes KEY=VALUE, got \(pair)", 2) }
        out[String(pair[..<eq])] = String(pair[pair.index(after: eq)...])
    }
    return out
}

switch cmd {
case "new":
    let sessionEnv = ProcessInfo.processInfo.environment.filter { sessionVariables.contains($0.key) }
        .merging(envOptions()) { _, given in given }
    var req: [String: Any] = ["op": "new", "env": sessionEnv]
    req["cwd"] = option("--cwd") ?? FileManager.default.currentDirectoryPath
    if let c = option("--cmd") { req["cmd"] = c }
    if let c = parseSize(option("--cols")) { req["cols"] = c }
    if let r = parseSize(option("--rows")) { req["rows"] = r }
    if let n = option("--name") { req["name"] = n }
    req["by"] = option("--by") ?? "cli"
    if !args.isEmpty { die("unexpected arguments: \(args)") }
    ensureDaemon()
    print(request(req)["id"] as! String)
case "ls":
    printJSON(request(["op": "ls"])["sessions"] ?? [])
case "kill":
    let signalArg = option("--signal")
    guard let id = args.first else { die("kill <id>") }
    var req: [String: Any] = ["op": "kill", "id": id]
    if let s = signalArg {
        guard let n = Int(s) else { die("--signal takes a number") }
        req["signal"] = n
    }
    _ = request(req)
case "rm":
    let force = flag("--force")
    guard let id = args.first else { die("rm <id>") }
    _ = request(["op": "rm", "id": id, "force": force])
case "screen":
    let json = flag("--json"), vt = flag("--vt"), scrollback = flag("--scrollback")
    guard let id = args.first else { die("screen <id>") }
    let r = request(["op": "screen", "id": id, "format": vt ? "vt" : "plain", "scrollback": scrollback])
    if vt {
        FileHandle.standardOutput.write(Data(base64Encoded: r["vt"] as? String ?? "") ?? Data())
    } else if json {
        var o = r; o.removeValue(forKey: "ok")
        printJSON(o)
    } else {
        FileHandle.standardOutput.write(((r["history"] as? String ?? "") + (r["text"] as? String ?? "")).data(using: .utf8)!)
    }
case "send":
    guard args.count == 2 else { die("send <id> <text>") }
    _ = request(["op": "send", "id": args[0], "data": Data(args[1].utf8).base64EncodedString()])
case "ping":
    printJSON(request(["op": "ping"]))
case "daemon-start":
    ensureDaemon()
    printJSON(request(["op": "ping"]))
case "daemon-stop":
    let force = flag("--force")
    let fd = connectDaemon()
    if fd < 0 { exit(0) }
    _ = request(["op": "stop", "force": force], fd: fd)
    // Wait until the daemon has gone.
    var b: UInt8 = 0
    while read(fd, &b, 1) > 0 {}
    close(fd)
    var gone = false
    for _ in 0..<100 {
        let probe = connectDaemon()
        if probe < 0 { gone = true; break }
        close(probe)
        usleep(20_000)
    }
    if !gone { die("the daemon is still running") }
case "render":
    let json = flag("--json"), replay = flag("--replay")
    guard let c = parseSize(option("--cols")), let r = parseSize(option("--rows")) else { die("render --cols N --rows N") }
    let t = umi_vt_new(UInt16(c), UInt16(r))!
    let input = FileHandle.standardInput.readDataToEndOfFile()
    input.withUnsafeBytes { ghostty_terminal_vt_write(t, $0.bindMemory(to: UInt8.self).baseAddress, $0.count) }
    if replay {
        // Debug: reproduce this terminal through the attach replay and show both.
        var n = 0
        let p = umi_vt_replay(t, &n)
        let t2 = umi_vt_new(UInt16(c), UInt16(r))!
        ghostty_terminal_vt_write(t2, p, n)
        free(p)
        var a = vtState(t), b = vtState(t2)
        a.merge(vtHistory(t)) { x, _ in x }; b.merge(vtHistory(t2)) { x, _ in x }
        printJSON(["original": a, "replayed": b])
        exit(0)
    }
    var st = vtState(t)
    if flag("--scrollback") { st.merge(vtHistory(t)) { a, _ in a } }
    if json { printJSON(st) } else { FileHandle.standardOutput.write((st["text"] as! String).data(using: .utf8)!) }
case "-h", "--help", "help":
    print(usage)
default:
    eprint(usage); exit(2)
}
