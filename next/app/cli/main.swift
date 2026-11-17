// umi-next: the command line for Umi next, mirroring the `umi` commands that drive the UI
// (acceptance/CLI.md; next/PARITY.md "Track (d)"). Same flags, `--json` shapes and exit codes,
// so agents and skills move over by changing the command name.
//
// - Layout commands go to the UI's socket `<state>/ui.sock` (Sources/UmiNext/ControlServer.swift),
//   which hands them to the page (web/cli.js).
// - Session I/O (`send`, `keys`, `read`, `wait`) goes to the daemon's socket, so it works while
//   the UI is down.
// - `comments` works on the file alone, with the page's own parser (web/comments.js) run in
//   JavaScriptCore; `comments wait` needs the UI.
// - `focus-log` reads `<state>/logs/focus/` (the format Umi writes; FocusLog.swift).
//
// It never talks to Umi: its own name, its own state folder (UMI_NEXT_STATE_DIR, else the state
// folder of the app it ships in), its own sockets and UMI_NEXT_* environment.
//
// Built by next/app/build.sh with swiftc, together with app/macos/UmiCLI/focusgroups.swift.

import Darwin
import Foundation

let cliName = "umi-next"
var jsonOutput = false

// MARK: - Output

func eprint(_ text: String) { FileHandle.standardError.write((text + "\n").data(using: .utf8)!) }

func fail(_ message: String, code: Int32 = 1) -> Never {
    eprint("\(cliName): \(message)")
    exit(code)
}

func printJSON(_ value: Any) {
    guard JSONSerialization.isValidJSONObject(value),
          let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes, .prettyPrinted]),
          let text = String(data: data, encoding: .utf8) else { print("{}"); return }
    print(text)
}

let stdoutIsTTY = isatty(STDOUT_FILENO) != 0
func style(_ text: String, _ code: String) -> String { stdoutIsTTY ? "\u{1B}[\(code)m\(text)\u{1B}[0m" : text }
func dim(_ s: String) -> String { style(s, "2") }
func bold(_ s: String) -> String { style(s, "1") }

func abbreviateHome(_ path: String) -> String {
    let home = NSHomeDirectory()
    if path == home { return "~" }
    if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
    return path
}

func absolutePath(_ path: String) -> String {
    let expanded = (path as NSString).expandingTildeInPath
    if expanded.hasPrefix("/") { return URL(fileURLWithPath: expanded).standardizedFileURL.path }
    return URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(expanded).standardizedFileURL.path
}

func realPath(_ path: String) -> String {
    var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
    return realpath(path, &buffer) != nil ? String(cString: buffer) : path
}

func readStdin() -> String {
    String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
}

// MARK: - The app this CLI belongs to

/// The Info.plist of the UmiNext.app holding this binary (through a symlink such as
/// ~/.local/bin/umi-next), if it is in one.
let appInfo: [String: Any] = {
    let me = URL(fileURLWithPath: realPath(CommandLine.arguments[0].contains("/")
        ? absolutePath(CommandLine.arguments[0]) : (Bundle.main.executablePath ?? CommandLine.arguments[0])))
    let plist = me.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Info.plist")
    guard let data = try? Data(contentsOf: plist),
          let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return [:] }
    return info
}()

let env = ProcessInfo.processInfo.environment

/// `$UMI_NEXT_STATE_DIR`, else the app's own state folder (Umi-next, or Umi-next-test-NAME for a
/// `build.sh --test NAME` copy), as the app itself picks it (Paths.swift).
let stateDir: String = {
    if let d = env["UMI_NEXT_STATE_DIR"], !d.isEmpty { return d }
    let name = appInfo["UmiNextStateName"] as? String ?? "Umi-next"
    return NSHomeDirectory() + "/Library/Application Support/" + name
}()

/// The web layer the app loads (for web/comments.js).
let webDir: String? = {
    if let d = env["UMI_NEXT_WEB_DIR"], !d.isEmpty { return d }
    return (appInfo["UmiNextSourceDir"] as? String).map { $0 + "/web" }
}()

/// The session this CLI runs in (a pane's shell or agent), from the daemon's environment.
let callerSession: String? = {
    for key in ["UMI_NEXT_SESSION_ID", "UMI_NEXT_SESSION"] { if let s = env[key], !s.isEmpty { return s } }
    return nil
}()

// MARK: - Sockets ('J' frames: type byte, u32 big-endian length, JSON; next/daemon/PROTOCOL.md)

func connectSocket(_ path: String) -> Int32? {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8)
    guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { close(fd); return nil }
    withUnsafeMutableBytes(of: &addr.sun_path) { raw in raw.copyBytes(from: bytes); raw[bytes.count] = 0 }
    let rc = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    if rc != 0 { close(fd); return nil }
    var on: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    return fd
}

func writeFrame(_ fd: Int32, _ obj: [String: Any]) -> Bool {
    guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) else { return false }
    let n = UInt32(data.count)
    var out: [UInt8] = [0x4A, UInt8(n >> 24), UInt8((n >> 16) & 0xff), UInt8((n >> 8) & 0xff), UInt8(n & 0xff)]
    out.append(contentsOf: data)
    var off = 0
    while off < out.count {
        let w = out.withUnsafeBytes { write(fd, $0.baseAddress! + off, out.count - off) }
        if w < 0 && errno == EINTR { continue }
        if w <= 0 { return false }
        off += w
    }
    return true
}

/// Reads frames until a JSON one arrives (the daemon may send others first on some ops).
func readJSONFrame(_ fd: Int32) -> [String: Any]? {
    func readN(_ n: Int) -> [UInt8]? {
        var out = [UInt8](repeating: 0, count: n)
        var off = 0
        while off < n {
            let r = out.withUnsafeMutableBytes { read(fd, $0.baseAddress! + off, n - off) }
            if r < 0 && errno == EINTR { continue }
            if r <= 0 { return nil }
            off += r
        }
        return out
    }
    while true {
        guard let head = readN(5) else { return nil }
        let len = Int(head[1]) << 24 | Int(head[2]) << 16 | Int(head[3]) << 8 | Int(head[4])
        guard let body = readN(len) else { return nil }
        if head[0] == 0x4A { return (try? JSONSerialization.jsonObject(with: Data(body))) as? [String: Any] }
    }
}

var uiSocket: String { stateDir + "/ui.sock" }
var daemonSocket: String { stateDir + "/daemon.sock" }

/// One request to the UI (the page answers it). Fails with exit 1 when the UI isn't running.
@discardableResult
func ui(_ cmd: String, _ args: [String: Any] = [:]) -> Any {
    guard let fd = connectSocket(uiSocket) else {
        fail("Umi next isn't running for \(abbreviateHome(stateDir)) (no \(abbreviateHome(uiSocket)))")
    }
    defer { close(fd) }
    var caller: [String: Any] = ["argv": Array(CommandLine.arguments.dropFirst()), "cwd": FileManager.default.currentDirectoryPath]
    if let s = callerSession { caller["session"] = s }
    guard writeFrame(fd, ["cmd": cmd, "args": args, "caller": caller]), let reply = readJSONFrame(fd) else {
        fail("Umi next closed the connection without answering")
    }
    if reply["ok"] as? Bool != true { fail(reply["error"] as? String ?? "\(cmd) failed") }
    return reply["result"] ?? NSNull()
}

/// One request to the session daemon. `nil` socket: exit 1.
func daemon(_ req: [String: Any]) -> [String: Any] {
    guard let fd = connectSocket(daemonSocket) else {
        fail("the session daemon isn't running for \(abbreviateHome(stateDir)) (no \(abbreviateHome(daemonSocket)))")
    }
    defer { close(fd) }
    guard writeFrame(fd, req), let reply = readJSONFrame(fd) else { fail("the daemon closed the connection") }
    if reply["ok"] as? Bool != true { fail(reply["error"] as? String ?? "daemon request failed") }
    return reply
}

// MARK: - Arguments

struct ArgSpec {
    var valued: Set<String> = []
    var boolean: Set<String> = []
    var short: [String: String] = ["-p": "--pane", "-t": "--tab", "-e": "--enter"]
}

struct Args {
    var positional: [String] = []
    var values: [String: String] = [:]
    var flags: Set<String> = []
    /// Words after `--`: text, even if they start with dashes.
    var rest: [String]?
    func value(_ k: String) -> String? { values[k] }
    func has(_ k: String) -> Bool { flags.contains(k) }
    var words: [String] { positional + (rest ?? []) }
}

func parse(_ argv: [String], _ spec: ArgSpec) -> Args {
    var a = Args()
    var i = 0
    while i < argv.count {
        var w = argv[i]
        if w == "--" { a.rest = Array(argv[(i + 1)...]); break }
        if let long = spec.short[w] { w = long }
        if w.hasPrefix("--"), let eq = w.firstIndex(of: "="), spec.valued.contains(String(w[..<eq])) {
            a.values[String(w[..<eq])] = String(w[w.index(after: eq)...])
        } else if spec.valued.contains(w) {
            guard i + 1 < argv.count else { fail("\(w) needs a value") }
            a.values[w] = argv[i + 1]
            i += 1
        } else if spec.boolean.contains(w) {
            a.flags.insert(w)
        } else if w.hasPrefix("-") && w != "-" && w.count > 1 && !w.dropFirst().allSatisfy(\.isNumber) {
            fail("unknown option \(w)")
        } else {
            a.positional.append(w)
        }
        i += 1
    }
    return a
}

// MARK: - Times ("90s", "5m", "2h", "3d", "9am", "14:30", ISO 8601)

func parseDuration(_ s: String) -> Double? {
    let units: [Character: Double] = ["s": 1, "m": 60, "h": 3600, "d": 86400]
    var total = 0.0, num = ""
    var any = false
    for c in s {
        if c.isNumber || c == "." { num.append(c); continue }
        guard let u = units[c], let n = Double(num) else { return nil }
        total += n * u; num = ""; any = true
    }
    if !num.isEmpty { return nil }
    return any ? total : nil
}

func parseTime(_ s: String) -> Date {
    if let d = parseDuration(s) { return Date().addingTimeInterval(-d) }
    let iso = ISO8601DateFormatter()
    for opts: ISO8601DateFormatter.Options in [[.withInternetDateTime, .withFractionalSeconds], [.withInternetDateTime],
                                               [.withFullDate]] {
        iso.formatOptions = opts
        if opts == [.withFullDate] { iso.timeZone = .current }
        if let d = iso.date(from: s) { return d }
    }
    let lower = s.lowercased()
    let re = try! NSRegularExpression(pattern: #"^(\d{1,2})(?::(\d{2}))?\s*(am|pm)?$"#)
    if let m = re.firstMatch(in: lower, range: NSRange(lower.startIndex..., in: lower)) {
        func g(_ i: Int) -> String? { Range(m.range(at: i), in: lower).map { String(lower[$0]) } }
        var h = Int(g(1)!)!
        let min = g(2).flatMap(Int.init) ?? 0
        if let ap = g(3) { if h == 12 { h = 0 }; if ap == "pm" { h += 12 } } else if g(2) == nil { fail("can't read the time \"\(s)\"") }
        guard h < 24, min < 60 else { fail("can't read the time \"\(s)\"") }
        return Calendar.current.date(bySettingHour: h, minute: min, second: 0, of: Date())!
    }
    fail("can't read the time \"\(s)\" (ISO 8601, 9am, 14:30, or 90s / 5m / 2h / 3d back)")
}

// MARK: - Main

var argv = Array(CommandLine.arguments.dropFirst())
// --json anywhere before a `--`.
if let i = argv.firstIndex(where: { $0 == "--json" }), argv.firstIndex(of: "--").map({ i < $0 }) ?? true {
    jsonOutput = true
    argv.remove(at: i)
}
guard let command = argv.first else { printHelp(); exit(0) }
let rest = Array(argv.dropFirst())

switch command {
case "help", "--help", "-h": rest.contains("--json") || jsonOutput ? printHelpJSON() : printHelp()
case "ls": lsCommand(rest)
case "tab": tabCommand(rest)
case "split": splitCommand(rest)
case "pane": paneCommand(rest)
case "send": sendCommand(rest)
case "keys": keysCommand(rest)
case "read": readCommand(rest)
case "wait": waitCommand(rest)
case "sidebar": sidebarCommand(rest)
case "notify": notifyCommand(rest)
case "go": goCommand(rest)
case "shortcuts": shortcutsCommand(rest)
case "edit", "open": editCommand(rest)
case "editor": editorCommand(rest)
case "comments": commentsCommand(rest)
case "focus-log": focusLogCommand(rest)
case "info": paneCommand(["info"] + rest)
default:
    if notMirrored.contains(command) {
        fail("\(command) isn't in Umi next (next/PARITY.md, \"Not mirrored\")")
    }
    fail("unknown command \(command) (umi-next help lists them)")
}
exit(0)
