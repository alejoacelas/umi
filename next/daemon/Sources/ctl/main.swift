// umi-next-ctl: manage the daemon's sessions. See PROTOCOL.md.
import Darwin
import Foundation
import UmiC

let usage = """
usage: umi-next-ctl <command>
  new [--cwd DIR] [--cmd CMD] [--cols N --rows N] [--name NAME] [--by WHO]   start a session, print its id
                           (WHO: who started it, default cli; the UI passes user)
  ls                       sessions as JSON
  kill <id> [--signal N]   signal the session's process group (default TERM)
  rm <id> [--force]        forget an exited session (--force kills a live one)
  screen <id> [--json|--vt] current screen (plain text; --json adds cursor and modes)
  send <id> <text>         type text into the session
  ping                     daemon pid and session count (fails if not running)
  daemon-start             start the daemon if it isn't running
  daemon-stop [--force]    stop the daemon (refuses while sessions are alive)
  render --cols N --rows N [--json]   feed stdin into a fresh terminal, print its screen
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

switch cmd {
case "new":
    var req: [String: Any] = ["op": "new", "env": ProcessInfo.processInfo.environment]
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
    guard let id = args.first else { die("kill <id>") }
    var req: [String: Any] = ["op": "kill", "id": id]
    if let s = option("--signal") {
        guard let n = Int(s) else { die("--signal takes a number") }
        req["signal"] = n
    }
    _ = request(req)
case "rm":
    let force = flag("--force")
    guard let id = args.first else { die("rm <id>") }
    _ = request(["op": "rm", "id": id, "force": force])
case "screen":
    let json = flag("--json"), vt = flag("--vt")
    guard let id = args.first else { die("screen <id>") }
    let r = request(["op": "screen", "id": id, "format": vt ? "vt" : "plain"])
    if vt {
        FileHandle.standardOutput.write(Data(base64Encoded: r["vt"] as? String ?? "") ?? Data())
    } else if json {
        var o = r; o.removeValue(forKey: "ok")
        printJSON(o)
    } else {
        FileHandle.standardOutput.write((r["text"] as? String ?? "").data(using: .utf8)!)
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
    for _ in 0..<100 { if connectDaemon() < 0 { break }; usleep(20_000) }
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
        printJSON(["original": vtState(t), "replayed": vtState(t2)])
        exit(0)
    }
    let st = vtState(t)
    if json { printJSON(st) } else { FileHandle.standardOutput.write((st["text"] as! String).data(using: .utf8)!) }
case "-h", "--help", "help":
    print(usage)
default:
    eprint(usage); exit(2)
}
