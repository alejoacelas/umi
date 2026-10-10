// tern: the command line for Tern, a Ghostty-based terminal for working with coding agents.
//
// It talks to one running instance of the app over a Unix socket (JSON lines). The instance
// is the one whose state directory is $TERN_STATE_DIR (default ~/Library/Application
// Support/Tern); the socket path is derived from that directory, so a CLI pointed at one
// state directory can never reach another instance.
//
// Self-contained on purpose: `build.sh` compiles this file alone with swiftc.

import CryptoKit
import Darwin
import Foundation

let cliName = "tern"
let productName = "Tern"
let defaultFeedURL = "https://github.com/alejoacelas/tern/releases/latest/download/appcast.json"

// MARK: - Output

var jsonOutput = false

func eprint(_ text: String) {
    FileHandle.standardError.write((text + "\n").data(using: .utf8)!)
}

func fail(_ message: String, code: Int32 = 1) -> Never {
    eprint("\(cliName): \(message)")
    exit(code)
}

func printJSON(_ value: Any) {
    let options: JSONSerialization.WritingOptions = [.sortedKeys, .withoutEscapingSlashes]
    guard JSONSerialization.isValidJSONObject(value),
          let data = try? JSONSerialization.data(withJSONObject: value, options: options),
          let text = String(data: data, encoding: .utf8) else {
        print("{}")
        return
    }
    print(text)
}

let stdoutIsTTY = isatty(STDOUT_FILENO) != 0
func style(_ text: String, _ code: String) -> String { stdoutIsTTY ? "\u{1B}[\(code)m\(text)\u{1B}[0m" : text }
func dim(_ s: String) -> String { style(s, "2") }
func bold(_ s: String) -> String { style(s, "1") }

func shortID(_ value: Any?) -> String {
    guard let id = value as? String else { return "?" }
    return String(id.prefix(8))
}

func abbreviateHome(_ path: String) -> String {
    let home = NSHomeDirectory()
    if path == home { return "~" }
    if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
    return path
}

// MARK: - Paths and instance discovery

/// The state directory of the instance this CLI talks to.
func stateDirectory() -> String {
    if let dir = ProcessInfo.processInfo.environment["TERN_STATE_DIR"], !dir.isEmpty {
        return absolutePath(dir)
    }
    return NSHomeDirectory() + "/Library/Application Support/\(productName)"
}

/// The canonical form of a state directory: what both the app and the CLI hash.
func canonicalStateDirectory(_ dir: String) -> String {
    var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
    if realpath(dir, &buffer) != nil { return String(cString: buffer) }
    return URL(fileURLWithPath: dir).standardizedFileURL.path
}

func stateHash(_ dir: String) -> String {
    let digest = SHA256.hash(data: Data(canonicalStateDirectory(dir).utf8))
    return digest.map { String(format: "%02x", $0) }.joined().prefix(16).lowercased()
}

/// The per-user temporary directory (independent of $TMPDIR, so every process of the user
/// agrees on it).
func userTempDirectory() -> String {
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
}

/// The control socket of the instance with this state directory. Short whatever the
/// state directory's length (Unix socket paths are limited to 104 bytes).
func socketPath(for dir: String) -> String {
    userTempDirectory() + "tern-\(stateHash(dir)).sock"
}

func absolutePath(_ path: String, relativeTo base: String? = nil) -> String {
    let expanded = (path as NSString).expandingTildeInPath
    if expanded.hasPrefix("/") { return URL(fileURLWithPath: expanded).standardizedFileURL.path }
    let root = base ?? FileManager.default.currentDirectoryPath
    return URL(fileURLWithPath: root).appendingPathComponent(expanded).standardizedFileURL.path
}

/// The pane this CLI runs in, if it runs inside one of this instance's terminals.
///
/// TERN_INSTANCE is "<state hash>:<run id>". A pane of an instance with another state
/// directory (for example the CLI pointed elsewhere with TERN_STATE_DIR) is not a caller
/// context at all; a pane of an earlier run of the same instance is stale, and the app
/// refuses to use it as a default.
struct Caller {
    var pane: String?
    var instance: String?
    /// The managed session this CLI runs in (inside an agent): what `self` names.
    var session: String?

    static func current() -> Caller {
        let env = ProcessInfo.processInfo.environment
        guard let instance = env["TERN_INSTANCE"], !instance.isEmpty else { return Caller() }
        let hash = instance.split(separator: ":", maxSplits: 1).first.map(String.init) ?? ""
        guard hash == stateHash(stateDirectory()) else { return Caller() }
        var caller = Caller()
        if let pane = env["TERN_PANE_ID"], !pane.isEmpty { caller.pane = pane }
        if let session = env["TERN_SESSION_ID"], !session.isEmpty { caller.session = session }
        guard caller.pane != nil || caller.session != nil else { return Caller() }
        caller.instance = instance
        return caller
    }

    var json: [String: Any] {
        var out: [String: Any] = [:]
        if let pane { out["pane"] = pane }
        if let instance { out["instance"] = instance }
        if let session { out["session"] = session }
        return out
    }
}

// MARK: - Socket client

struct RPCError: Error {
    let code: String
    let message: String
}

final class Client {
    let fd: Int32
    private var buffer = Data()
    private var nextID = 1

    init?(path: String) {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            close(fd)
            return nil
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            for (i, b) in bytes.enumerated() { raw[i] = b }
            raw[bytes.count] = 0
        }
        var nosigpipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &nosigpipe, socklen_t(MemoryLayout<Int32>.size))
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            close(fd)
            return nil
        }
        self.fd = fd
    }

    deinit { close(fd) }

    func send(_ object: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes])
        data.append(0x0A)
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw RPCError(code: "io", message: "lost the connection to \(productName)")
                }
                offset += n
            }
        }
    }

    /// The next JSON line, or nil at end of stream.
    func readLine() -> [String: Any]? {
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<newline]
                buffer.removeSubrange(buffer.startIndex...newline)
                if line.isEmpty { continue }
                if let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] { return object }
                continue
            }
            var chunk = [UInt8](repeating: 0, count: 65536)
            let n = read(fd, &chunk, chunk.count)
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { return nil }
            buffer.append(contentsOf: chunk[0..<n])
        }
    }

    func call(_ method: String, _ params: [String: Any]) throws -> Any {
        let id = nextID
        nextID += 1
        try send(["id": id, "method": method, "params": params, "caller": Caller.current().json])
        while let message = readLine() {
            guard (message["id"] as? Int) == id else { continue }
            if let error = message["error"] as? [String: Any] {
                throw RPCError(code: error["code"] as? String ?? "error",
                               message: error["message"] as? String ?? "request failed")
            }
            return message["result"] ?? [String: Any]()
        }
        throw RPCError(code: "io", message: "\(productName) closed the connection")
    }
}

func connect() -> Client {
    let dir = stateDirectory()
    let path = socketPath(for: dir)
    if let client = Client(path: path) { return client }
    if ProcessInfo.processInfo.environment["TERN_STATE_DIR"] != nil {
        fail("\(productName) isn't running for state directory \(dir)")
    }
    fail("\(productName) isn't running (start the app first)")
}

@discardableResult
func call(_ method: String, _ params: [String: Any] = [:]) -> Any {
    let client = connect()
    do {
        return try client.call(method, params)
    } catch let error as RPCError {
        fail(error.message, code: error.code == "timeout" ? 124 : 1)
    } catch {
        fail("\(error)")
    }
}

func callDict(_ method: String, _ params: [String: Any] = [:]) -> [String: Any] {
    call(method, params) as? [String: Any] ?? [:]
}

// MARK: - Argument parsing

/// Parsed command arguments. Options are `--name value`, `--name=value` or boolean flags.
/// `--` ends options; what follows is kept in `rest`.
struct Args {
    var positional: [String] = []
    var values: [String: [String]] = [:]
    var flags: Set<String> = []
    var rest: [String]?

    func value(_ name: String) -> String? { values[name]?.last }
    func all(_ name: String) -> [String] { values[name] ?? [] }
    func has(_ name: String) -> Bool { flags.contains(name) }
}

struct ArgSpec {
    var valued: Set<String> = []
    var boolean: Set<String> = []
    var aliases: [String: String] = [:]
    /// Flags that may take an optional value: consumed only if the next word matches.
    var optionalValue: [String: (String) -> Bool] = [:]
}

func parse(_ argv: [String], _ spec: ArgSpec) -> Args {
    var args = Args()
    var i = 0
    while i < argv.count {
        let word = argv[i]
        if word == "--" {
            args.rest = Array(argv[(i + 1)...])
            break
        }
        if word.hasPrefix("-") && word != "-" && !isNegativeNumber(word) {
            var name = word
            var inline: String?
            if word.hasPrefix("--"), let eq = word.firstIndex(of: "=") {
                name = String(word[..<eq])
                inline = String(word[word.index(after: eq)...])
            }
            name = spec.aliases[name] ?? name
            if spec.valued.contains(name) {
                if let inline {
                    args.values[name, default: []].append(inline)
                } else {
                    guard i + 1 < argv.count else { fail("\(name) needs a value") }
                    args.values[name, default: []].append(argv[i + 1])
                    i += 1
                }
            } else if spec.boolean.contains(name) {
                args.flags.insert(name)
            } else if let accepts = spec.optionalValue[name] {
                args.flags.insert(name)
                if i + 1 < argv.count, accepts(argv[i + 1]) {
                    args.values[name, default: []].append(argv[i + 1])
                    i += 1
                }
            } else {
                fail("unknown option \(word) (see `\(cliName) help`)")
            }
        } else {
            args.positional.append(word)
        }
        i += 1
    }
    return args
}

func isNegativeNumber(_ word: String) -> Bool {
    word.count > 1 && word.hasPrefix("-") && Double(word) != nil
}

/// Text from arguments: words joined with spaces, `-` reads stdin, text after `--` is text.
func textArgument(_ args: Args, words: [String]) -> String? {
    var parts = words
    if let rest = args.rest { parts += rest }
    if parts == ["-"] { return readStdin() }
    if parts.isEmpty { return nil }
    return parts.joined(separator: " ")
}

func readStdin() -> String {
    let data = FileHandle.standardInput.readDataToEndOfFile()
    return String(decoding: data, as: UTF8.self)
}

// MARK: - Login shell environment

/// Run a command in the user's login shell, from a clean slate, the way a new terminal
/// window would. Returns stdout.
func loginShell(_ command: String, timeout: TimeInterval = 30) -> String? {
    var shell = "/bin/zsh"
    if let entry = getpwuid(getuid()), let raw = entry.pointee.pw_shell {
        let candidate = String(cString: raw)
        if FileManager.default.isExecutableFile(atPath: candidate) { shell = candidate }
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: shell)
    process.arguments = ["-l", "-i", "-c", command]
    var env: [String: String] = [
        "HOME": NSHomeDirectory(), "USER": NSUserName(), "LOGNAME": NSUserName(), "SHELL": shell,
        "TERM": "xterm-256color", "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
    ]
    if let tmp = ProcessInfo.processInfo.environment["TMPDIR"] { env["TMPDIR"] = tmp }
    process.environment = env
    let out = Pipe()
    process.standardOutput = out
    process.standardError = FileHandle.nullDevice
    process.standardInput = FileHandle.nullDevice
    do { try process.run() } catch { return nil }
    let deadline = Date().addingTimeInterval(timeout)
    // Read on another thread, so a startup script that hangs, or a child that keeps stdout
    // open, can't outlast the timeout.
    let output = OutputBuffer()
    let finished = DispatchSemaphore(value: 0)
    let fd = out.fileHandleForReading.fileDescriptor
    Thread.detachNewThread {
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = read(fd, &buffer, buffer.count)
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { break }
            output.append(Data(buffer[0..<n]))
        }
        finished.signal()
    }
    let timedOut = finished.wait(timeout: .now() + timeout) == .timedOut
    while !timedOut && process.isRunning && Date() < deadline { usleep(20_000) }
    if process.isRunning { process.terminate() }
    return String(decoding: output.contents, as: UTF8.self)
}

/// Bytes collected by one thread and read by another.
final class OutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        lock.lock()
        data.append(chunk)
        lock.unlock()
    }

    var contents: Data {
        lock.lock()
        defer { lock.unlock() }
        return data
    }
}

/// Where a program is found on the login shell's PATH.
func loginWhich(_ names: [String]) -> [String: String] {
    let marker = "__TERN_WHICH__"
    let script = names.map { "printf '\(marker)%s=%s\\n' \($0) \"$(command -v \($0) 2>/dev/null)\"" }.joined(separator: "; ")
    guard let output = loginShell(script) else { return [:] }
    var found: [String: String] = [:]
    for line in output.split(separator: "\n") {
        guard let range = line.range(of: marker) else { continue }
        let pair = line[range.upperBound...]
        guard let eq = pair.firstIndex(of: "=") else { continue }
        let name = String(pair[..<eq])
        let path = String(pair[pair.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
        if !path.isEmpty { found[name] = path }
    }
    return found
}

// MARK: - Git worktrees

@discardableResult
func git(_ args: [String], in dir: String) -> (status: Int32, out: String, err: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["-C", dir] + args
    var env = ProcessInfo.processInfo.environment
    env["GIT_TERMINAL_PROMPT"] = "0"
    process.environment = env
    let out = Pipe()
    let err = Pipe()
    process.standardOutput = out
    process.standardError = err
    process.standardInput = FileHandle.nullDevice
    do { try process.run() } catch { return (127, "", "\(error)") }
    // Read both pipes concurrently so a chatty hook can't fill one and block git.
    var errData = Data()
    let group = DispatchGroup()
    group.enter()
    DispatchQueue.global().async {
        errData = err.fileHandleForReading.readDataToEndOfFile()
        group.leave()
    }
    let outData = out.fileHandleForReading.readDataToEndOfFile()
    group.wait()
    process.waitUntilExit()
    return (process.terminationStatus, String(decoding: outData, as: UTF8.self), String(decoding: errData, as: UTF8.self))
}

struct Worktree {
    let path: String
    let branch: String?
}

func listWorktrees(in dir: String) -> [Worktree] {
    let result = git(["worktree", "list", "--porcelain"], in: dir)
    guard result.status == 0 else { return [] }
    var trees: [Worktree] = []
    var path: String?
    var branch: String?
    for line in result.out.split(separator: "\n", omittingEmptySubsequences: false) {
        if line.hasPrefix("worktree ") {
            if let path { trees.append(Worktree(path: path, branch: branch)) }
            path = String(line.dropFirst("worktree ".count))
            branch = nil
        } else if line.hasPrefix("branch ") {
            let ref = String(line.dropFirst("branch ".count))
            branch = ref.hasPrefix("refs/heads/") ? String(ref.dropFirst("refs/heads/".count)) : ref
        }
    }
    if let path { trees.append(Worktree(path: path, branch: branch)) }
    return trees
}

/// The folder for `--worktree NAME`: an existing worktree directory, a worktree with that
/// branch or folder name, or a new worktree next to the repository on a new branch NAME.
func resolveWorktree(_ name: String, base: String, baseRef: String?) -> String {
    let candidate = absolutePath(name)
    var isDir = ObjCBool(false)
    if (name.hasPrefix("/") || name.hasPrefix(".") || name.hasPrefix("~")),
       FileManager.default.fileExists(atPath: candidate, isDirectory: &isDir), isDir.boolValue {
        return candidate
    }
    let top = git(["rev-parse", "--show-toplevel"], in: base)
    guard top.status == 0 else { fail("--worktree: \(abbreviateHome(base)) isn't in a git repository") }
    let trees = listWorktrees(in: base)
    if let match = trees.first(where: { $0.branch == name })
        ?? trees.first(where: { ($0.path as NSString).lastPathComponent == name }) {
        return match.path
    }
    if FileManager.default.fileExists(atPath: candidate, isDirectory: &isDir), isDir.boolValue,
       git(["rev-parse", "--show-toplevel"], in: candidate).status == 0 {
        return candidate
    }
    guard let main = trees.first?.path ?? Optional(top.out.trimmingCharacters(in: .whitespacesAndNewlines)) else {
        fail("--worktree: can't find the repository")
    }
    let repoName = (main as NSString).lastPathComponent
    let folder = name.replacingOccurrences(of: "/", with: "-")
    let path = ((main as NSString).deletingLastPathComponent as NSString)
        .appendingPathComponent("\(repoName).worktrees/\(folder)")
    if FileManager.default.fileExists(atPath: path) {
        fail("--worktree: \(abbreviateHome(path)) already exists and isn't a worktree of this repository")
    }
    try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                             withIntermediateDirectories: true)
    let branchExists = git(["show-ref", "--verify", "--quiet", "refs/heads/\(name)"], in: base).status == 0
    var addArgs = ["worktree", "add", "--quiet"]
    if branchExists {
        addArgs += [path, name]
    } else {
        addArgs += ["-b", name, path]
        if let baseRef { addArgs.append(baseRef) }
    }
    let added = git(addArgs, in: base)
    guard added.status == 0, FileManager.default.fileExists(atPath: path) else {
        let reason = added.err.split(separator: "\n").last(where: { $0.contains("fatal") || $0.contains("error") })
            .map(String.init) ?? added.err.trimmingCharacters(in: .whitespacesAndNewlines)
        fail("--worktree: git couldn't create \(abbreviateHome(path)): \(reason)")
    }
    return path
}

/// Common creation options shared by window/tab/split and interactive agents.
///
/// `--worktree` is resolved in the repository of `--cwd`, else of the pane named with
/// `--pane` (the new pane starts from it), else of the folder the CLI runs in.
func creationParams(_ args: Args) -> [String: Any] {
    var params: [String: Any] = [:]
    var cwd: String?
    if let dir = args.value("--cwd") { cwd = absolutePath(dir) }
    if let worktree = args.value("--worktree") {
        var base = cwd ?? FileManager.default.currentDirectoryPath
        if cwd == nil, let pane = args.value("--pane") {
            let info = callDict("pane.info", ["pane": pane])
            if let paneCwd = info["cwd"] as? String, !paneCwd.isEmpty { base = paneCwd }
        }
        cwd = resolveWorktree(worktree, base: base, baseRef: args.value("--base"))
    }
    if let cwd { params["cwd"] = cwd }
    if let command = args.value("--cmd") { params["command"] = command }
    if let name = args.value("--name") { params["name"] = name }
    if args.has("--no-focus") { params["focus"] = false }
    return params
}

let creationSpec: Set<String> = ["--cwd", "--cmd", "--name", "--worktree", "--base"]

// MARK: - Human output

func printCreated(_ result: Any) {
    let dict = result as? [String: Any] ?? [:]
    if jsonOutput { printJSON(dict) } else { print(dict["pane"] as? String ?? "") }
}

func printOK(_ result: Any) {
    if jsonOutput { printJSON(result as? [String: Any] ?? ["ok": true]) }
}

func printTree(_ result: Any) {
    let tree = result as? [String: Any] ?? [:]
    if jsonOutput {
        printJSON(tree)
        return
    }
    let windows = tree["windows"] as? [[String: Any]] ?? []
    if windows.isEmpty {
        print(dim("no windows"))
        return
    }
    let currentPane = tree["current_pane"] as? String
    for window in windows {
        print("\(bold("window #\(window["index"] ?? "?")")) \(dim(shortID(window["id"])))")
        for tab in window["tabs"] as? [[String: Any]] ?? [] {
            var line = "  \((tab["selected"] as? Bool ?? false) ? "▸" : " ") tab #\(tab["index"] ?? "?") \(dim(shortID(tab["id"])))"
            line += "  \(tab["name"] as? String ?? tab["title"] as? String ?? "")"
            if tab["pinned"] as? Bool ?? false { line += "  📌" }
            if let color = tab["color"] as? String { line += "  [\(color)]" }
            print(line)
            for pane in tab["panes"] as? [[String: Any]] ?? [] {
                let here = (pane["id"] as? String) == currentPane
                var row = "      \(here ? "●" : ((pane["focused"] as? Bool ?? false) ? "○" : " ")) pane \(dim(shortID(pane["id"])))"
                if let name = pane["name"] as? String { row += "  \(bold(name))" }
                row += "  \(abbreviateHome(pane["cwd"] as? String ?? ""))"
                if pane["zoomed"] as? Bool ?? false { row += "  (zoomed)" }
                if let agent = pane["agent"] as? String {
                    row += "  [session \(shortID(agent))\((pane["showing"] as? String) == "live" ? ", live" : "")]"
                }
                print(row)
            }
        }
    }
}

// MARK: - Commands

/// The help, printed from the command table (`commands.swift`), as `help --json` is.
var help: String { renderHelp() }

func layoutCommand(_ argv: [String]) {
    guard let command = argv.first else {
        printTree(call("tree"))
        return
    }
    let rest = Array(argv.dropFirst())
    switch command {
    case "ls", "tree", "list":
        _ = parse(rest, ArgSpec())
        printTree(call("tree"))

    case "window", "windows":
        windowCommand(rest)

    case "tab", "tabs":
        tabCommand(rest)

    case "split":
        let args = parse(rest, ArgSpec(valued: creationSpec.union(["--pane", "--ratio"]),
                                       boolean: ["--no-focus"], aliases: ["-p": "--pane"]))
        guard args.positional.count <= 1 else { fail("split takes one direction: right, down, left or up") }
        var params = creationParams(args)
        params["direction"] = args.positional.first ?? "right"
        if let pane = args.value("--pane") { params["pane"] = pane }
        if let ratio = args.value("--ratio") {
            guard let value = Double(ratio), value > 0, value < 1 else { fail("--ratio must be between 0 and 1") }
            params["ratio"] = value
        }
        printCreated(call("pane.split", params))

    case "pane", "panes":
        paneCommand(rest)

    case "send", "type":
        sendCommand(rest)

    case "keys", "key":
        let args = parse(rest, ArgSpec(valued: ["--pane"], aliases: ["-p": "--pane"]))
        let keys = args.positional + (args.rest ?? [])
        guard !keys.isEmpty else { fail("keys: name at least one key (enter, esc, ctrl+c, …)") }
        var params: [String: Any] = ["keys": keys]
        if let pane = args.value("--pane") { params["pane"] = pane }
        printOK(call("pane.keys", params))

    case "read", "capture":
        let args = parse(rest, ArgSpec(valued: ["--pane", "--lines"], boolean: ["--scrollback"],
                                       aliases: ["-p": "--pane", "-n": "--lines"]))
        var params: [String: Any] = ["scrollback": args.has("--scrollback")]
        if let pane = args.value("--pane") { params["pane"] = pane }
        if let lines = args.value("--lines") {
            guard let n = Int(lines), n > 0 else { fail("--lines must be a positive number") }
            params["lines"] = n
        }
        let result = callDict("pane.read", params)
        if jsonOutput { printJSON(result) } else { print(result["text"] as? String ?? "") }

    case "wait":
        waitCommand(rest)

    case "events":
        eventsCommand(rest)

    case "notify":
        let args = parse(rest, ArgSpec(valued: ["--pane"], aliases: ["-p": "--pane"]))
        let words = args.positional + (args.rest ?? [])
        guard let title = words.first else { fail("notify: give a title") }
        var params: [String: Any] = ["title": title]
        if words.count > 1 { params["body"] = words.dropFirst().joined(separator: " ") }
        if let pane = args.value("--pane") { params["pane"] = pane }
        printOK(call("notify", params))

    case "sidebar":
        let args = parse(rest, ArgSpec(valued: ["--window"], aliases: ["-w": "--window"]))
        var params: [String: Any] = [:]
        if let window = args.value("--window") { params["window"] = window }
        let sub = args.positional.first ?? "toggle"
        switch sub {
        case "on", "show": params["visible"] = true
        case "off", "hide": params["visible"] = false
        case "toggle": params["toggle"] = true
        case "status": break
        case "tabs", "files": params["mode"] = sub
        case "width":
            // `sidebar width` says the window's width; `sidebar width N` sets it.
            if args.positional.count > 1 {
                guard let width = Double(args.positional[1]), width > 0 else { fail("sidebar width: give a width in points") }
                params["width"] = width
            }
        default: fail("sidebar: use on, off, toggle, status, tabs, files or width [N]")
        }
        let result = callDict("sidebar", params)
        if sub == "width" && !jsonOutput {
            if let width = result["width"] as? Double { print(Int(width)) }
        } else if jsonOutput || sub == "status" {
            var status: [String: Any] = ["visible": result["visible"] as? Bool ?? false, "mode": result["mode"] as? String ?? "tabs"]
            if let width = result["width"] { status["width"] = width }
            printJSON(status)
        }

    case "reopen":
        let args = parse(rest, ArgSpec(boolean: ["--list"]))
        guard args.positional.isEmpty else { fail("reopen: unexpected argument \(args.positional[0])") }
        if args.has("--list") {
            let result = callDict("reopen.list")
            if jsonOutput {
                printJSON(result)
            } else {
                let items = result["items"] as? [[String: Any]] ?? []
                if items.isEmpty { print(dim("nothing to reopen")) }
                for item in items {
                    let what = item["kind"] as? String ?? "?"
                    let title = item["title"] as? String ?? ""
                    print("\(what)\(title.isEmpty ? "" : "  \(title)")  \(dim("\(item["expires_in"] ?? "?")s left"))")
                }
            }
        } else {
            let result = callDict("reopen")
            if jsonOutput { printJSON(result) } else { print(result["pane"] as? String ?? result["window"] as? String ?? "") }
        }

    case "screenshot":
        let args = parse(rest, ArgSpec(valued: ["--window"], aliases: ["-w": "--window"]))
        guard let out = args.positional.first else { fail("screenshot: give an output file (OUT.png)") }
        var params: [String: Any] = ["path": absolutePath(out)]
        if let window = args.value("--window") { params["window"] = window }
        let result = callDict("screenshot", params)
        if jsonOutput { printJSON(result) } else { print(result["path"] as? String ?? absolutePath(out)) }

    case "jump":
        let args = parse(rest, ArgSpec())
        let back = args.positional.first == "back"
        guard args.positional.count <= 1, back || args.positional.first ?? "next" == "next" else {
            fail("jump: use `jump` (the next session that needs you) or `jump back`")
        }
        let result = callDict(back ? "jump.back" : "jump.next")
        if jsonOutput {
            printJSON(result)
        } else {
            print(result["pane"] as? String ?? result["session"] as? String ?? "")
        }

    case "shortcuts", "shortcut":
        shortcutsCommand(rest)

    case "worktree", "worktrees":
        let args = parse(rest, ArgSpec())
        guard args.positional.first ?? "ls" == "ls" || args.positional.first == "list" else {
            fail("worktree: only `worktree ls` is available")
        }
        let trees = listWorktrees(in: FileManager.default.currentDirectoryPath)
        if jsonOutput {
            printJSON(["worktrees": trees.map { ["path": $0.path, "branch": $0.branch as Any] }])
        } else if trees.isEmpty {
            fail("not in a git repository")
        } else {
            for tree in trees { print("\(abbreviateHome(tree.path))  \(dim(tree.branch ?? "(detached)"))") }
        }

    default:
        fail("unknown command `\(command)` (see `\(cliName) help`)")
    }
}

/// `shortcuts`: list, change, clear or reset keyboard shortcuts (Settings, ⌘,).
func shortcutsCommand(_ argv: [String]) {
    let args = parse(argv, ArgSpec())
    let words = args.positional
    switch words.first ?? "ls" {
    case "ls", "list":
        let result = callDict("shortcuts.list")
        if jsonOutput {
            printJSON(result)
            return
        }
        var kind = ""
        for entry in result["shortcuts"] as? [[String: Any]] ?? [] {
            let entryKind = entry["kind"] as? String ?? ""
            if entryKind != kind {
                kind = entryKind
                print(bold(kind == "tern" ? productName : "Terminal (Ghostty keybindings)"))
            }
            let display = (entry["display"] as? [String] ?? []).joined(separator: " ")
            let keys = (entry["keys"] as? [String] ?? []).joined(separator: ", ")
            let changed = entry["changed"] as? Bool ?? false
            let id = (entry["id"] as? String ?? "").padding(toLength: 34, withPad: " ", startingAt: 0)
            print("  \(id) \((display.isEmpty ? (keys.isEmpty ? "-" : keys) : display).padding(toLength: 12, withPad: " ", startingAt: 0)) \(dim(entry["title"] as? String ?? ""))\(changed ? "  (changed)" : "")")
        }
    case "set":
        guard words.count == 3 else { fail("shortcuts set ID KEYS (KEYS like cmd+shift+] or ctrl+cmd+left)") }
        let result = callDict("shortcuts.set", ["id": words[1], "keys": words[2]])
        if jsonOutput { printJSON(result) } else { for note in result["notes"] as? [String] ?? [] { print(note) } }
    case "clear":
        guard words.count == 2 else { fail("shortcuts clear ID") }
        printOK(call("shortcuts.set", ["id": words[1], "keys": ""]))
    case "reset":
        guard words.count <= 2 else { fail("shortcuts reset [ID]") }
        var params: [String: Any] = [:]
        if words.count == 2 { params["id"] = words[1] }
        printOK(call("shortcuts.reset", params))
    default:
        fail("shortcuts: use ls, set ID KEYS, clear ID or reset [ID]")
    }
}

func windowCommand(_ argv: [String]) {
    guard let sub = argv.first else { fail("window: use new, focus or close") }
    let rest = Array(argv.dropFirst())
    switch sub {
    case "new":
        let args = parse(rest, ArgSpec(valued: creationSpec, boolean: ["--no-focus"]))
        guard args.positional.isEmpty else { fail("window new: unexpected argument \(args.positional[0])") }
        printCreated(call("window.new", creationParams(args)))
    case "focus", "close":
        let args = parse(rest, ArgSpec())
        var params: [String: Any] = [:]
        if let window = args.positional.first { params["window"] = window }
        printOK(call("window.\(sub)", params))
    default:
        fail("window: unknown subcommand \(sub)")
    }
}

func tabCommand(_ argv: [String]) {
    guard let sub = argv.first else { fail("tab: use new, focus, back, next, prev, close, rename, color, pin, unpin, move or equalize") }
    let rest = Array(argv.dropFirst())
    switch sub {
    case "new":
        let args = parse(rest, ArgSpec(valued: creationSpec.union(["--window", "--pane", "--color", "--index"]),
                                       boolean: ["--no-focus"], aliases: ["-w": "--window", "-p": "--pane"]))
        var params = creationParams(args)
        if params["name"] == nil, let name = args.positional.first { params["name"] = name }
        guard args.positional.count <= 1 else { fail("tab new: unexpected argument \(args.positional[1])") }
        if let window = args.value("--window") { params["window"] = window }
        if let pane = args.value("--pane") { params["pane"] = pane }
        if let color = args.value("--color") { params["color"] = color }
        if let index = args.value("--index") {
            guard let n = Int(index) else { fail("--index must be a number") }
            params["index"] = n
        }
        printCreated(call("tab.new", params))
    case "focus", "select", "close", "equalize", "pin", "unpin":
        let args = parse(rest, ArgSpec())
        var params: [String: Any] = [:]
        if let tab = args.positional.first { params["tab"] = tab }
        let method = sub == "select" ? "focus" : sub
        printOK(call("tab.\(method)", params))
    case "back", "next", "prev", "previous":
        let args = parse(rest, ArgSpec(valued: ["--window"], aliases: ["-w": "--window"]))
        guard args.positional.isEmpty else { fail("tab \(sub) takes no tab: it goes from the selected one") }
        var params: [String: Any] = [:]
        if let window = args.value("--window") { params["window"] = window }
        let result = callDict("tab.\(sub == "previous" ? "prev" : sub)", params)
        if jsonOutput { printJSON(result) } else { print(result["tab"] as? String ?? "") }
    case "rename", "name":
        let args = parse(rest, ArgSpec())
        let words = args.positional + (args.rest ?? [])
        var params: [String: Any] = [:]
        switch words.count {
        case 1: params["name"] = words[0]
        case 2:
            params["tab"] = words[0]
            params["name"] = words[1]
        default: fail("tab rename [TAB] NAME")
        }
        printOK(call("tab.rename", params))
    case "color", "colour":
        let args = parse(rest, ArgSpec())
        var params: [String: Any] = [:]
        switch args.positional.count {
        case 1: params["color"] = args.positional[0]
        case 2:
            params["tab"] = args.positional[0]
            params["color"] = args.positional[1]
        default: fail("tab color [TAB] COLOR")
        }
        printOK(call("tab.color", params))
    case "move":
        let args = parse(rest, ArgSpec(valued: ["--window", "--index"], boolean: ["--new-window", "--no-focus", "--up", "--down"],
                                       aliases: ["-w": "--window"]))
        var params: [String: Any] = [:]
        if let tab = args.positional.first { params["tab"] = tab }
        if let window = args.value("--window") { params["window"] = window }
        if let index = args.value("--index") {
            guard let n = Int(index) else { fail("--index must be a number") }
            params["index"] = n
        }
        if args.has("--new-window") { params["new_window"] = true }
        if args.has("--no-focus") { params["focus"] = false }
        if args.has("--up") || args.has("--down") {
            guard params["window"] == nil, params["index"] == nil, params["new_window"] == nil, !(args.has("--up") && args.has("--down")) else {
                fail("tab move: --up and --down go alone (not with --window, --index or --new-window)")
            }
            params["by"] = args.has("--up") ? -1 : 1
        }
        guard params["window"] != nil || params["index"] != nil || params["new_window"] != nil || params["by"] != nil else {
            fail("tab move: give --window W, --index I, --up, --down or --new-window")
        }
        printOK(call("tab.move", params))
    default:
        fail("tab: unknown subcommand \(sub)")
    }
}

func paneCommand(_ argv: [String]) {
    guard let sub = argv.first else { fail("pane: use focus, close, info, zoom, rename, move, swap or resize") }
    let rest = Array(argv.dropFirst())
    switch sub {
    case "focus", "close", "info", "zoom":
        let args = parse(rest, ArgSpec())
        var params: [String: Any] = [:]
        if let pane = args.positional.first { params["pane"] = pane }
        let result = call("pane.\(sub)", params)
        if sub == "info" {
            let dict = result as? [String: Any] ?? [:]
            if jsonOutput {
                printJSON(dict)
            } else {
                print("pane \(dict["id"] ?? "?")")
                if let name = dict["name"] as? String { print("  name   \(name)") }
                print("  cwd    \(abbreviateHome(dict["cwd"] as? String ?? ""))")
                print("  tab    \(dict["tab"] ?? "?")")
                print("  window \(dict["window"] ?? "?")")
            }
        } else {
            printOK(result)
        }
    case "rename", "name":
        let args = parse(rest, ArgSpec())
        let words = args.positional + (args.rest ?? [])
        var params: [String: Any] = [:]
        switch words.count {
        case 1: params["name"] = words[0]
        case 2:
            params["pane"] = words[0]
            params["name"] = words[1]
        default: fail("pane rename [PANE] NAME")
        }
        printOK(call("pane.rename", params))
    case "move":
        let args = parse(rest, ArgSpec(valued: ["--to", "--dir", "--tab", "--window"],
                                       boolean: ["--new-tab", "--new-window", "--no-focus"],
                                       aliases: ["-t": "--tab", "-w": "--window"]))
        var params: [String: Any] = [:]
        if let pane = args.positional.first { params["pane"] = pane }
        if let to = args.value("--to") { params["to"] = to }
        if let dir = args.value("--dir") { params["direction"] = dir }
        if let tab = args.value("--tab") { params["tab"] = tab }
        if let window = args.value("--window") { params["window"] = window }
        if args.has("--new-tab") { params["new_tab"] = true }
        if args.has("--new-window") { params["new_window"] = true }
        if args.has("--no-focus") { params["focus"] = false }
        let targets = ["to", "tab", "new_tab", "new_window"].filter { params[$0] != nil }.count
            + (params["window"] != nil && params["new_tab"] == nil ? 1 : 0)
        guard targets == 1 else {
            fail("pane move: give one of --to PANE, --tab T, --window W, --new-tab or --new-window")
        }
        printOK(call("pane.move", params))
    case "swap":
        let args = parse(rest, ArgSpec())
        var params: [String: Any] = [:]
        switch args.positional.count {
        case 1: params["target"] = args.positional[0]
        case 2:
            params["pane"] = args.positional[0]
            params["target"] = args.positional[1]
        default: fail("pane swap [PANE] TARGET")
        }
        printOK(call("pane.swap", params))
    case "resize":
        let args = parse(rest, ArgSpec())
        let directions: Set<String> = ["up", "down", "left", "right"]
        var params: [String: Any] = [:]
        var words = args.positional
        if words.count >= 2, directions.contains(words[1]), !directions.contains(words[0]) || words.count == 3 {
            params["pane"] = words.removeFirst()
        }
        guard let direction = words.first, directions.contains(direction) else {
            fail("pane resize [PANE] up|down|left|right [AMOUNT]")
        }
        params["direction"] = direction
        if words.count > 1 {
            guard let amount = Int(words[1]), amount > 0 else { fail("pane resize: AMOUNT must be a positive number") }
            params["amount"] = amount
        }
        printOK(call("pane.resize", params))
    case "send":
        sendCommand(rest)
    case "read":
        layoutCommand(["read"] + rest)
    default:
        fail("pane: unknown subcommand \(sub)")
    }
}

func sendCommand(_ argv: [String]) {
    let args = parse(argv, ArgSpec(valued: ["--pane"], boolean: ["--enter"], aliases: ["-e": "--enter", "-p": "--pane"]))
    var text = textArgument(args, words: args.positional)
    if text == nil {
        // No text: send what is piped on stdin (never wait on a terminal).
        if isatty(STDIN_FILENO) == 0 { text = readStdin() } else { fail("send: give the text to send") }
    }
    var value = text ?? ""
    if args.has("--enter"), value.hasSuffix("\n") { value.removeLast() }
    var params: [String: Any] = ["text": value, "enter": args.has("--enter")]
    if let pane = args.value("--pane") { params["pane"] = pane }
    printOK(call("pane.send", params))
}

func waitCommand(_ argv: [String]) {
    let args = parse(argv, ArgSpec(valued: ["--pane", "--pattern", "--idle", "--timeout"],
                                   aliases: ["-p": "--pane", "-t": "--timeout"]))
    let pattern = args.value("--pattern")
    let idle = args.value("--idle").map { value -> Double in
        guard let seconds = Double(value), seconds > 0 else { fail("--idle must be a positive number of seconds") }
        return seconds
    }
    guard (pattern == nil) != (idle == nil) else { fail("wait: give --pattern RE or --idle SECS") }
    let timeout = args.value("--timeout").map { value -> Double in
        guard let seconds = Double(value), seconds >= 0 else { fail("--timeout must be a number of seconds") }
        return seconds
    }
    var regex: NSRegularExpression?
    if let pattern {
        do {
            regex = try NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])
        } catch {
            fail("--pattern: invalid regular expression")
        }
    }
    let client = connect()
    var paneParams: [String: Any] = [:]
    if let pane = args.value("--pane") { paneParams["pane"] = pane }
    // Resolve the pane once, so a pane that closes later isn't confused with another one.
    let info: [String: Any]
    do {
        info = try client.call("pane.info", paneParams) as? [String: Any] ?? [:]
    } catch let error as RPCError {
        fail(error.message)
    } catch {
        fail("\(error)")
    }
    guard let paneID = info["id"] as? String else { fail("wait: no such pane") }
    let deadline = timeout.map { Date().addingTimeInterval($0) }
    var lastText: String?
    var lastBytes: Int?
    var lastChange = Date()
    while true {
        let result: [String: Any]
        var params: [String: Any] = ["pane": paneID, "output_only": regex != nil, "recent": true]
        if let lastBytes {
            // After the first read, ask for everything written since, even what scrolled past the screen.
            params["since_bytes"] = lastBytes
        } else if regex != nil {
            // The first read covers the scrollback too: output that arrived (and scrolled away)
            // between `send` and this wait still counts.
            params["scrollback"] = true
        }
        do {
            result = try client.call("pane.read", params) as? [String: Any] ?? [:]
        } catch let error as RPCError {
            if error.code == "not_found" { fail("the pane closed while waiting") }
            fail(error.message)
        } catch {
            fail("\(error)")
        }
        let text = result["text"] as? String ?? ""
        let bytes = result["output_bytes"] as? Int
        defer { lastBytes = bytes }
        if let regex {
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            if let match = regex.firstMatch(in: text, range: range), let found = Range(match.range, in: text) {
                let matched = String(text[found])
                if jsonOutput { printJSON(["matched": matched, "pane": paneID]) } else { print(matched) }
                return
            }
        } else if let idle {
            // Idle means no output at all, not an unchanged screen (a program can keep
            // redrawing the same text).
            if let bytes, bytes != lastBytes {
                lastChange = Date()
            } else if bytes == nil, text != lastText {
                lastText = text
                lastChange = Date()
            } else if Date().timeIntervalSince(lastChange) >= idle {
                if jsonOutput { printJSON(["idle": idle, "pane": paneID]) }
                return
            }
        }
        if let deadline, Date() >= deadline {
            fail("timed out waiting for \(pattern.map { "/\($0)/" } ?? "the pane to go idle")", code: 124)
        }
        usleep(100_000)
    }
}

func eventsCommand(_ argv: [String]) {
    let args = parse(argv, ArgSpec(valued: ["--filter", "--pane"], aliases: ["-p": "--pane", "-f": "--filter"]))
    var params: [String: Any] = ["filters": args.all("--filter") + args.positional]
    if let pane = args.value("--pane") { params["pane"] = pane }
    let client = connect()
    do {
        _ = try client.call("events.subscribe", params)
    } catch let error as RPCError {
        fail(error.message)
    } catch {
        fail("\(error)")
    }
    setvbuf(stdout, nil, _IOLBF, 0)
    while let message = client.readLine() {
        guard let name = message["event"] as? String else { continue }
        printJSON(["event": name, "data": message["data"] ?? [String: Any](), "ts": message["ts"] ?? 0])
        fflush(stdout)
    }
}

// MARK: - Editor

func editCommand(_ argv: [String]) {
    let args = parse(argv, ArgSpec(valued: ["--tab", "--pane"], boolean: ["--source", "--preview"],
                                   aliases: ["-t": "--tab", "-p": "--pane"]))
    var files = args.positional + (args.rest ?? [])
    if files.isEmpty {
        if isatty(STDIN_FILENO) == 0 {
            files = readStdin().split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        }
        guard !files.isEmpty else { fail("edit: name a file") }
    }
    var params: [String: Any] = ["paths": files.map { absolutePath($0) }]
    if args.has("--source") { params["mode"] = "source" }
    if args.has("--preview") { params["mode"] = "preview" }
    if let tab = args.value("--tab") { params["tab"] = tab }
    if let pane = args.value("--pane") { params["pane"] = pane }
    let result = callDict("editor.open", params)
    if jsonOutput { printJSON(result) }
}

func editorCommand(_ argv: [String]) {
    guard let sub = argv.first else { fail("editor: use ls, close, mode or default") }
    let rest = Array(argv.dropFirst())
    let spec = ArgSpec(valued: ["--tab", "--pane"], boolean: ["--force", "--dry-run"],
                       aliases: ["-t": "--tab", "-p": "--pane"])
    let args = parse(rest, spec)
    var params: [String: Any] = [:]
    if let tab = args.value("--tab") { params["tab"] = tab }
    if let pane = args.value("--pane") { params["pane"] = pane }
    switch sub {
    case "ls", "list":
        let result = callDict("editor.list", params)
        if jsonOutput {
            printJSON(result)
        } else {
            for doc in result["documents"] as? [[String: Any]] ?? [] {
                let dirty = (doc["dirty"] as? Bool ?? false) ? " ●" : ""
                print("\(abbreviateHome(doc["path"] as? String ?? ""))  \(dim(doc["mode"] as? String ?? ""))\(dirty)")
            }
        }
    case "close":
        if let file = args.positional.first { params["path"] = absolutePath(file) }
        if args.has("--force") { params["force"] = true }
        printOK(call("editor.close", params))
    case "mode", "toggle":
        if let mode = args.positional.first {
            guard mode == "preview" || mode == "source" else { fail("editor mode: use preview or source") }
            params["mode"] = mode
        }
        let result = callDict("editor.mode", params)
        if jsonOutput { printJSON(result) }
    case "default":
        makeDefaultMarkdownApp(dryRun: args.has("--dry-run"))
    default:
        fail("editor: unknown subcommand \(sub)")
    }
}

/// The app bundle this CLI belongs to (the CLI lives in App.app/Contents/MacOS).
func ownAppBundle() -> String? {
    var size: UInt32 = 0
    _NSGetExecutablePath(nil, &size)
    var buffer = [CChar](repeating: 0, count: Int(size) + 1)
    guard _NSGetExecutablePath(&buffer, &size) == 0 else { return nil }
    let exe = canonicalStateDirectory(String(cString: buffer))
    let macos = (exe as NSString).deletingLastPathComponent
    let contents = (macos as NSString).deletingLastPathComponent
    let app = (contents as NSString).deletingLastPathComponent
    guard (macos as NSString).lastPathComponent == "MacOS", app.hasSuffix(".app") else { return nil }
    return app
}

func makeDefaultMarkdownApp(dryRun: Bool) {
    guard let app = ownAppBundle() else { fail("this \(cliName) isn't inside an app bundle") }
    if dryRun {
        print(app)
        return
    }
    guard let bundle = Bundle(path: app), let id = bundle.bundleIdentifier else { fail("can't read \(app)") }
    let url = URL(fileURLWithPath: app)
    LSRegisterURL(url as CFURL, true)
    var failures: [String] = []
    for type in ["net.daringfireball.markdown", "public.markdown"] {
        let status = LSSetDefaultRoleHandlerForContentType(type as CFString, .all, id as CFString)
        if status != noErr && type == "net.daringfireball.markdown" { failures.append("\(type) (\(status))") }
    }
    if !failures.isEmpty { fail("couldn't make \(productName) the default for \(failures.joined(separator: ", "))") }
    if jsonOutput { printJSON(["app": app, "default": true]) } else { print("\(productName) now opens Markdown files") }
}

// MARK: - Interactive agents

/// Quote a word for a POSIX shell, the way a person would type it.
func shellQuote(_ word: String) -> String {
    if word.isEmpty { return "''" }
    let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_@%+=:,./-")
    if word.unicodeScalars.allSatisfy({ safe.contains($0) }) { return word }
    return "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'"
}


// MARK: - Updates

func updateCommand(_ argv: [String]) {
    let args = parse(argv, ArgSpec(boolean: ["--check", "--status", "--now", "--force", "--later", "--skip"]))
    let modes = ["--check", "--status", "--now", "--later", "--skip"].filter { args.has($0) }
    if modes.count > 1 { fail("update: choose one of \(modes.joined(separator: ", "))") }
    if args.has("--check") || args.has("--status") || args.has("--later") || args.has("--skip") {
        let result: [String: Any]
        if args.has("--check") {
            result = callDict("update.check")
        } else if args.has("--status") {
            result = callDict("update.status")
        } else {
            result = callDict("update.answer", ["answer": args.has("--later") ? "later" : "skip"])
        }
        if jsonOutput { printJSON(result) } else { print(updateStatusLine(result)) }
        return
    }
    // --force: install now even while managed-agent turns run (they're interrupted and
    // continue after the relaunch); without it, `--now` refuses while turns run (R-10).
    let result = callDict(args.has("--now") ? "update.install_now" : "update.download", args.has("--force") ? ["force": true] : [:])
    if jsonOutput {
        printJSON(result)
    } else if let message = result["message"] as? String {
        print(message)
    }
}

/// One line on where the update stands (`update --check`, `--status`, `--later`, `--skip`).
func updateStatusLine(_ result: [String: Any]) -> String {
    let installed = result["installed"] as? String ?? "?"
    let latest = result["latest"] as? String
    var line = "installed \(installed), latest \(latest ?? "not checked yet")"
    guard let latest, result["update_available"] as? Bool ?? false else {
        return latest == nil ? line + " (`\(cliName) update --check` checks)" : line + ": up to date"
    }
    switch result["state"] as? String ?? "" {
    case "asking":
        line += ": an update is available. \(productName) is asking whether to download it (in the sidebar); "
            + "nothing is downloaded until you say yes. `\(cliName) update` says yes."
    case "later":
        let until = (result["later_until"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
        let when = until.map { DateFormatter.localizedString(from: $0, dateStyle: .short, timeStyle: .short) } ?? "later"
        line += ": an update is available; you chose Later, so \(productName) asks again after \(when). `\(cliName) update` downloads it now."
    case "skipped":
        line += ": an update is available; you skipped \(latest), so \(productName) asks again when a newer version is out. "
            + "`\(cliName) update` downloads it anyway."
    case "agreed":
        line += ": an update is available; you said yes, so it downloads at the next check (or now with `\(cliName) update`)."
    case "downloading":
        line += ": downloading \(result["downloading"] as? String ?? latest)."
    case "ready", "installing":
        let ready = result["ready"] as? String ?? latest
        line += ": \(ready) is downloaded and installs when \(productName) quits (`\(cliName) update --now` installs it now)."
    case "failed":
        line += ": the download failed (\(result["error"] as? String ?? "unknown error")); `\(cliName) update` tries again."
    default:
        line += ": an update is available (`\(cliName) update`)"
        if result["background_checks"] as? Bool == false { line += "; this copy doesn't check by itself" }
    }
    return line
}

// MARK: - Doctor

func doctor() {
    var problems = 0
    var report: [[String: Any]] = []
    func line(_ ok: Bool, _ name: String, _ detail: String, required: Bool = true) {
        if !ok && required { problems += 1 }
        report.append(["check": name, "ok": ok, "detail": detail, "required": required])
        if !jsonOutput {
            let mark = ok ? "✓" : (required ? "✗" : "!")
            print("\(mark) \(name): \(detail)")
        }
    }

    let app = ownAppBundle()
    line(app != nil, "app", app ?? "this \(cliName) isn't inside \(productName).app", required: false)

    let tools = loginWhich(["claude", "codex", "git", cliName])
    for tool in ["claude", "codex", "git"] {
        if let path = tools[tool] {
            line(true, tool, path)
        } else {
            line(false, tool, "not found on the login shell's PATH (agents and worktrees need it)")
        }
    }
    if let path = tools[cliName] {
        line(true, "\(cliName) on PATH", path, required: false)
    } else {
        line(false, "\(cliName) on PATH", "not on the login shell's PATH; add ~/.local/bin to PATH", required: false)
    }

    let dir = stateDirectory()
    if let client = Client(path: socketPath(for: dir)), let info = try? client.call("system.ping", [:]) as? [String: Any] {
        line(true, "running instance", "version \(info["version"] ?? "?"), state \(abbreviateHome(dir))", required: false)
    } else {
        line(false, "running instance", "\(productName) isn't running for \(abbreviateHome(dir))", required: false)
    }

    if jsonOutput { printJSON(["ok": problems == 0, "checks": report]) }
    exit(problems == 0 ? 0 : 1)
}

// MARK: - Main

func main() {
    var argv = Array(CommandLine.arguments.dropFirst())
    // --json anywhere before a `--` is the global JSON switch.
    let separator = argv.firstIndex(of: "--") ?? argv.count
    if let index = argv[..<separator].firstIndex(of: "--json") {
        jsonOutput = true
        argv.remove(at: index)
    }
    guard let command = argv.first else {
        print(help)
        return
    }
    let rest = Array(argv.dropFirst())
    switch command {
    case "help", "-h", "--help":
        if jsonOutput || rest.contains("--json") { printJSON(helpJSON()) } else { print(help) }
    case "version", "--version":
        let version = ownAppBundle().flatMap { Bundle(path: $0)?.infoDictionary?["CFBundleShortVersionString"] as? String }
        print("\(cliName) \(version ?? "dev")")
    case "edit", "open":
        editCommand(rest)
    case "editor":
        editorCommand(rest)
    case "claude", "codex":
        agentShortcut(command, rest)
    case "update":
        updateCommand(rest)
    case "doctor":
        doctor()
    case "agent", "agents":
        agentCommand(rest)
    case "ping":
        let result = callDict("system.ping")
        if jsonOutput { printJSON(result) } else { print("\(productName) \(result["version"] ?? "?") pid \(result["pid"] ?? "?")") }
    default:
        layoutCommand(argv)
    }
}

main()
