import AppKit
import CryptoKit
import Foundation

/// File and search services for the web layer (web/fs.js is the page's side).
///
/// The page posts `{type: "request", id, op, args}`; each request gets exactly one
/// `{type: "reply", id, ok, result | error: {code, message}}`. Long-running requests (watch,
/// search) also push `{type: "event", id, data}` until they end or are cancelled with
/// `{op: "cancel", args: {target: id}}`. Paths arrive absolute (fs.js resolves relative ones).
/// Work runs off the main thread; `send` is called on the main thread.
final class WebServices {
    private let send: ([String: Any]) -> Void
    private let work = DispatchQueue(label: "umi-next.services", qos: .userInitiated, attributes: .concurrent)
    // Main thread only.
    private var watches: [String: PathWatch] = [:]
    private var searches: [String: Search] = [:]

    /// Shows a context menu at a point of the web view (CSS px) and gives the chosen item's index,
    /// or nil (MainWindow sets it: the menu needs the view).
    var popUpMenu: ((_ items: [[String: Any]], _ x: Double, _ y: Double) -> Int?)?

    init(send: @escaping ([String: Any]) -> Void) { self.send = send }

    struct Failure: Error { let code: String; let message: String }

    /// Ends every watch and search (the page reloaded, so nobody listens to them).
    func reset() {
        watches.values.forEach { $0.stop() }
        watches = [:]
        searches.values.forEach { $0.cancel() }
        searches = [:]
    }

    func handle(_ msg: [String: Any]) {
        guard let id = msg["id"] as? String, let op = msg["op"] as? String else { return }
        let args = msg["args"] as? [String: Any] ?? [:]
        switch op {
        case "readFile": async(id) { try Self.readFile(args) }
        case "writeFile": async(id) { try Self.writeFile(args) }
        case "listDir": async(id) { try Self.listDir(args) }
        case "listFiles": async(id) { try Self.listFiles(args) }
        case "watch": startWatch(id, args)
        case "search": startSearch(id, args)
        case "gitRoot": async(id) { let r: Any = try Self.gitRoot(Self.path(args)) ?? NSNull(); return ["root": r] }
        case "gitHead": async(id) { try Self.gitHead(args) }
        case "gitStatus": async(id) { try Self.gitStatus(args) }
        case "trash": async(id) { try Self.trash(args) }
        case "rename": async(id) { try Self.renameItem(args) }
        case "reveal": reply(id, Result { try Self.reveal(args) })
        case "openDefault": reply(id, Result { try Self.openDefault(args) })
        case "clipboard": reply(id, Result { try Self.clipboard(args) })
        case "sendText": async(id) { try Self.sendText(args) }
        case "readData": async(id) { try Self.readData(args) }
        case "openURL": reply(id, Result { try Self.openURL(args) })
        case "menu":
            let items = args["items"] as? [[String: Any]] ?? []
            // Popped up after this message is handled: the menu runs its own event loop.
            DispatchQueue.main.async { [self] in
                let chosen = popUpMenu?(items, args["x"] as? Double ?? 0, args["y"] as? Double ?? 0)
                reply(id, .success(["index": chosen.map { $0 as Any } ?? NSNull()]))
            }
        case "cancel":
            let target = args["target"] as? String ?? ""
            if let w = watches.removeValue(forKey: target) {
                w.stop()
                reply(target, .success(["cancelled": true]))
            }
            searches[target]?.cancel()
            reply(id, .success(["ok": true]))
        default:
            reply(id, .failure(Failure(code: "unknownOp", message: "no service \(op)")))
        }
    }

    private func async(_ id: String, _ body: @escaping () throws -> Any) {
        work.async {
            let r: Result<Any, Error>
            do { r = .success(try body()) } catch { r = .failure(error) }
            DispatchQueue.main.async { self.reply(id, r) }
        }
    }

    private func reply(_ id: String, _ r: Result<Any, Error>) {
        switch r {
        case .success(let v): send(["type": "reply", "id": id, "ok": true, "result": v])
        case .failure(let e as Failure): send(["type": "reply", "id": id, "ok": false, "error": ["code": e.code, "message": e.message]])
        case .failure(let e as NSError):
            let code = e.domain == NSCocoaErrorDomain && [NSFileReadNoSuchFileError, NSFileNoSuchFileError].contains(e.code) ? "notFound" : "io"
            send(["type": "reply", "id": id, "ok": false, "error": ["code": code, "message": e.localizedDescription]])
        }
    }

    // MARK: Files

    static func path(_ args: [String: Any], _ key: String = "path") throws -> String {
        guard let p = args[key] as? String, p.hasPrefix("/") else {
            throw Failure(code: "badPath", message: "\(key) must be an absolute path")
        }
        return (p as NSString).standardizingPath
    }

    /// A file's version: a hash of its bytes, so a write can tell whether the file changed since it was read.
    static func version(_ data: Data) -> String {
        "sha256:" + SHA256.hash(data: data).prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    static let maxRead = 32 << 20

    static func readFile(_ args: [String: Any]) throws -> Any {
        let p = try path(args)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: p, isDirectory: &isDir) else { throw Failure(code: "notFound", message: "no file \(p)") }
        if isDir.boolValue { throw Failure(code: "isDir", message: "\(p) is a folder") }
        let attrs = try FileManager.default.attributesOfItem(atPath: p)
        let size = (attrs[.size] as? NSNumber)?.intValue ?? 0
        if size > maxRead { throw Failure(code: "tooLarge", message: "\(p) is \(size) bytes (limit \(maxRead))") }
        let data = try Data(contentsOf: URL(fileURLWithPath: p))
        guard let text = String(data: data, encoding: .utf8) else { throw Failure(code: "binary", message: "\(p) is not UTF-8 text") }
        return ["path": p, "text": text, "version": version(data), "size": data.count,
                "mtime": ((attrs[.modificationDate] as? Date) ?? Date()).timeIntervalSince1970 * 1000]
    }

    /// Writes atomically (a temporary file in the same folder, renamed over the target, keeping the
    /// target's permissions; a symlink's target is written, the link stays). With `version` given,
    /// the write happens only if the file is still at that version (null: only if it doesn't exist).
    static func writeFile(_ args: [String: Any]) throws -> Any {
        let given = try path(args)
        guard let text = args["text"] as? String else { throw Failure(code: "badArgs", message: "text missing") }
        let p = (given as NSString).resolvingSymlinksInPath
        let fm = FileManager.default
        let exists = fm.fileExists(atPath: p)
        if args.keys.contains("version") {
            let want = args["version"] as? String
            let current = exists ? (try? Data(contentsOf: URL(fileURLWithPath: p))).map(version) : nil
            if want != current {
                throw Failure(code: "conflict", message: current == nil ? "\(given) no longer exists" : want == nil ? "\(given) already exists" : "\(given) changed since it was read (now \(current!))")
            }
        }
        let dir = (p as NSString).deletingLastPathComponent
        if args["createDirs"] as? Bool == true { try fm.createDirectory(atPath: dir, withIntermediateDirectories: true) }
        let data = Data(text.utf8)
        let tmp = dir + "/.\((p as NSString).lastPathComponent).umi-next-\(UUID().uuidString.prefix(8))"
        guard fm.createFile(atPath: tmp, contents: data) else { throw Failure(code: "io", message: "can't write in \(dir)") }
        if exists, let perms = try? fm.attributesOfItem(atPath: p)[.posixPermissions] {
            try? fm.setAttributes([.posixPermissions: perms], ofItemAtPath: tmp)
        }
        guard rename(tmp, p) == 0 else {
            let err = String(cString: strerror(errno))
            unlink(tmp)
            throw Failure(code: "io", message: "can't replace \(given): \(err)")
        }
        return ["path": given, "version": version(data), "size": data.count]
    }

    /// One folder's entries, folders first. Dotfiles only with `hidden`; files git ignores are
    /// marked `ignored` and left out unless `ignored` is true. `.git` itself is always left out.
    static func listDir(_ args: [String: Any]) throws -> Any {
        let dir = try path(args)
        let showHidden = args["hidden"] as? Bool ?? false
        let showIgnored = args["ignored"] as? Bool ?? false
        let fm = FileManager.default
        let names = try fm.contentsOfDirectory(atPath: dir).filter { $0 != ".git" && $0 != ".DS_Store" }
        let ignored = gitIgnored(names, in: dir)
        var entries: [[String: Any]] = []
        for name in names {
            let hidden = name.hasPrefix(".")
            if hidden && !showHidden { continue }
            let isIgnored = ignored.contains(name)
            if isIgnored && !showIgnored { continue }
            let full = dir + "/" + name
            guard let attrs = try? fm.attributesOfItem(atPath: full) else { continue }
            let isLink = attrs[.type] as? FileAttributeType == .typeSymbolicLink
            var isDir: ObjCBool = false
            fm.fileExists(atPath: full, isDirectory: &isDir)
            var e: [String: Any] = ["name": name, "path": full, "kind": isDir.boolValue ? "dir" : "file",
                                    "size": (attrs[.size] as? NSNumber)?.intValue ?? 0,
                                    "mtime": ((attrs[.modificationDate] as? Date) ?? Date()).timeIntervalSince1970 * 1000,
                                    "hidden": hidden, "ignored": isIgnored]
            if isLink { e["link"] = true }
            entries.append(e)
        }
        entries.sort { a, b in
            let da = a["kind"] as! String == "dir", db = b["kind"] as! String == "dir"
            if da != db { return da }
            return (a["name"] as! String).localizedStandardCompare(b["name"] as! String) == .orderedAscending
        }
        return ["dir": dir, "entries": entries, "git": gitRoot(dir) != nil]
    }

    static func gitRoot(_ dir: String) -> String? {
        let r = run("/usr/bin/git", ["-C", dir, "rev-parse", "--show-toplevel"])
        guard r.status == 0, let s = String(data: r.out, encoding: .utf8) else { return nil }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    /// The file as of the last commit (the editor's gutter marks): `{text}`, or `{text: null}` when
    /// git doesn't track it (or it isn't in a repository), as Umi's `UmiGitDiff.headText`.
    static func gitHead(_ args: [String: Any]) throws -> Any {
        let p = try path(args)
        let url = URL(fileURLWithPath: p)
        let r = run("/usr/bin/git", ["-C", url.deletingLastPathComponent().path, "show", "HEAD:./\(url.lastPathComponent)"])
        guard r.status == 0 else { return ["path": p, "text": NSNull()] }
        return ["path": p, "text": String(data: r.out, encoding: .utf8) ?? String(decoding: r.out, as: UTF8.self)]
    }

    /// The tracked files with changes against HEAD (staged or not), relative to the repository's
    /// top folder, as Umi's quick open reads them (`git status --porcelain -z --untracked-files=no`).
    /// `{root: null, changed: []}` outside a repository.
    static func gitStatus(_ args: [String: Any]) throws -> Any {
        let p = try path(args)
        guard let top = gitRoot(p) else { return ["root": NSNull(), "changed": [String]()] }
        let r = run("/usr/bin/git", ["-C", top, "status", "--porcelain", "-z", "--untracked-files=no"])
        var changed: [String] = []
        var entries = r.outString.split(separator: "\0").map(String.init)[...]
        while let e = entries.popFirst() {
            guard e.count > 3 else { continue }
            changed.append(String(e.dropFirst(3)))
            // A rename or copy is followed by its old path, which is no file any more.
            if e.first == "R" || e.first == "C" { _ = entries.popFirst() }
        }
        return ["root": top, "changed": changed]
    }

    /// The names in `dir` git ignores (empty outside a repository).
    static func gitIgnored(_ names: [String], in dir: String) -> Set<String> {
        guard !names.isEmpty, gitRoot(dir) != nil else { return [] }
        let input = names.joined(separator: "\0") + "\0"
        let r = run("/usr/bin/git", ["-C", dir, "check-ignore", "-z", "--stdin"], input: Data(input.utf8))
        guard let s = String(data: r.out, encoding: .utf8) else { return [] }
        return Set(s.split(separator: "\0").map(String.init))
    }

    /// Every file under `root` for quick open: in a repository, what git tracks plus untracked files
    /// it doesn't ignore; elsewhere a walk that skips dot folders. Paths are relative to `root`.
    static func listFiles(_ args: [String: Any]) throws -> Any {
        let root = try path(args, "root")
        let limit = args["limit"] as? Int ?? 100_000
        if gitRoot(root) != nil {
            let r = run("/usr/bin/git", ["-C", root, "ls-files", "-co", "--exclude-standard", "-z"])
            if r.status == 0, let s = String(data: r.out, encoding: .utf8) {
                // Deleted-but-tracked files are listed too; keep only what exists.
                var files = s.split(separator: "\0").map(String.init)
                let dropped = Set(run("/usr/bin/git", ["-C", root, "ls-files", "-d", "-z"]).outString.split(separator: "\0").map(String.init))
                if !dropped.isEmpty { files.removeAll { dropped.contains($0) } }
                let truncated = files.count > limit
                return ["root": root, "files": Array(files.prefix(limit)), "source": "git", "truncated": truncated]
            }
        }
        var files: [String] = []
        let skip: Set<String> = ["node_modules", ".build", "build", "DerivedData", "__pycache__"]
        guard let walker = FileManager.default.enumerator(at: URL(fileURLWithPath: root), includingPropertiesForKeys: [.isDirectoryKey],
                                                          options: [.skipsHiddenFiles, .skipsPackageDescendants]) else {
            throw Failure(code: "notFound", message: "can't read \(root)")
        }
        var truncated = false
        let prefix = URL(fileURLWithPath: root).standardizedFileURL.path.count + 1
        for case let url as URL in walker {
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDir { if skip.contains(url.lastPathComponent) { walker.skipDescendants() }; continue }
            if files.count >= limit { truncated = true; break }
            files.append(String(url.standardizedFileURL.path.dropFirst(prefix)))
        }
        return ["root": root, "files": files, "source": "walk", "truncated": truncated]
    }

    struct RunResult { let status: Int32; let out: Data; var outString: String { String(data: out, encoding: .utf8) ?? "" } }

    static func run(_ exe: String, _ args: [String], input: Data? = nil) -> RunResult {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        let out = Pipe(), inp = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = input == nil ? FileHandle.nullDevice : inp
        do { try p.run() } catch { return RunResult(status: -1, out: Data()) }
        if let input {
            DispatchQueue.global().async { inp.fileHandleForWriting.write(input); try? inp.fileHandleForWriting.close() }
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return RunResult(status: p.terminationStatus, out: data)
    }

    // MARK: Explorer actions

    /// Moves to the Trash (never deletes for good).
    static func trash(_ args: [String: Any]) throws -> Any {
        let p = try path(args)
        guard FileManager.default.fileExists(atPath: p) else { throw Failure(code: "notFound", message: "no file \(p)") }
        var out: NSURL?
        try FileManager.default.trashItem(at: URL(fileURLWithPath: p), resultingItemURL: &out)
        return ["path": p, "trashed": out?.path ?? ""]
    }

    /// Renames or moves `path` to `to`; refused when something is already at `to`.
    static func renameItem(_ args: [String: Any]) throws -> Any {
        let from = try path(args), to = try path(args, "to")
        let fm = FileManager.default
        guard fm.fileExists(atPath: from) else { throw Failure(code: "notFound", message: "no file \(from)") }
        // A change of case only ("a" → "A") is the same file on macOS's file system.
        if fm.fileExists(atPath: to), from.lowercased() != to.lowercased() {
            throw Failure(code: "exists", message: "\((to as NSString).lastPathComponent) is already there")
        }
        try fm.moveItem(atPath: from, toPath: to)
        return ["path": to]
    }

    static func reveal(_ args: [String: Any]) throws -> Any {
        let p = try path(args)
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p)])
        return ["ok": true]
    }

    /// Opens with the file's default app. UMI_NEXT_TEST_OPEN_LOG (tests) appends the path to that
    /// file instead, so no app opens on the test Mac.
    static func openDefault(_ args: [String: Any]) throws -> Any {
        let p = try path(args)
        if let log = Paths.env["UMI_NEXT_TEST_OPEN_LOG"], !log.isEmpty {
            if !FileManager.default.fileExists(atPath: log) { FileManager.default.createFile(atPath: log, contents: nil) }
            if let h = FileHandle(forWritingAtPath: log) { h.seekToEndOfFile(); h.write(Data((p + "\n").utf8)); try? h.close() }
            return ["ok": true, "logged": true]
        }
        guard NSWorkspace.shared.open(URL(fileURLWithPath: p)) else { throw Failure(code: "io", message: "can't open \(p)") }
        return ["ok": true]
    }

    /// A file's bytes as base64 with a media type from its extension (images in the Markdown
    /// preview: the page may only load files from web/ itself). Up to 16 MB.
    static func readData(_ args: [String: Any]) throws -> Any {
        let p = try path(args)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: p, isDirectory: &isDir) else { throw Failure(code: "notFound", message: "no file \(p)") }
        if isDir.boolValue { throw Failure(code: "isDir", message: "\(p) is a folder") }
        let size = ((try? FileManager.default.attributesOfItem(atPath: p))?[.size] as? NSNumber)?.intValue ?? 0
        if size > 16 << 20 { throw Failure(code: "tooLarge", message: "\(p) is \(size) bytes (limit \(16 << 20))") }
        let data = try Data(contentsOf: URL(fileURLWithPath: p))
        let types = ["png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "gif": "image/gif", "webp": "image/webp",
                     "svg": "image/svg+xml", "bmp": "image/bmp", "ico": "image/x-icon", "avif": "image/avif",
                     "heic": "image/heic", "tif": "image/tiff", "tiff": "image/tiff", "pdf": "application/pdf"]
        let mime = types[(p as NSString).pathExtension.lowercased()] ?? "application/octet-stream"
        return ["path": p, "mime": mime, "base64": data.base64EncodedString(), "size": data.count]
    }

    /// Opens a web or mail link in the default app (links in the Markdown preview).
    /// UMI_NEXT_TEST_OPEN_LOG (tests) appends it to that file instead.
    static func openURL(_ args: [String: Any]) throws -> Any {
        guard let s = args["url"] as? String, let url = URL(string: s), let scheme = url.scheme?.lowercased(),
              ["http", "https", "mailto"].contains(scheme) else {
            throw Failure(code: "badArgs", message: "url must be http, https or mailto")
        }
        if let log = Paths.env["UMI_NEXT_TEST_OPEN_LOG"], !log.isEmpty {
            if !FileManager.default.fileExists(atPath: log) { FileManager.default.createFile(atPath: log, contents: nil) }
            if let h = FileHandle(forWritingAtPath: log) { h.seekToEndOfFile(); h.write(Data((s + "\n").utf8)); try? h.close() }
            return ["ok": true, "logged": true]
        }
        guard NSWorkspace.shared.open(url) else { throw Failure(code: "io", message: "can't open \(s)") }
        return ["ok": true]
    }

    /// {text}: puts it on the clipboard. Without text: gives the clipboard's text.
    static func clipboard(_ args: [String: Any]) throws -> Any {
        let pb = NSPasteboard.general
        if let text = args["text"] as? String {
            pb.clearContents()
            pb.setString(text, forType: .string)
            return ["ok": true]
        }
        return ["text": pb.string(forType: .string) ?? ""]
    }

    /// {session, text}: types the text into a daemon session's terminal (umi-next-ctl send).
    static func sendText(_ args: [String: Any]) throws -> Any {
        guard let sid = args["session"] as? String, !sid.isEmpty, let text = args["text"] as? String else {
            throw Failure(code: "badArgs", message: "session and text needed")
        }
        guard !SessionBackend.plainShell else { throw Failure(code: "noDaemon", message: "sessions aren't in the daemon (plain-shell mode)") }
        let r = SessionBackend.run(SessionBackend.ctlPath, ["send", sid, text])
        guard r.status == 0 else { throw Failure(code: "io", message: r.err.isEmpty ? "send failed" : r.err) }
        return ["ok": true]
    }

    // MARK: Watch

    private func startWatch(_ id: String, _ args: [String: Any]) {
        let p: String
        do { p = try Self.path(args) } catch { return reply(id, .failure(error)) }
        guard FileManager.default.fileExists(atPath: p) else { return reply(id, .failure(Failure(code: "notFound", message: "no file \(p)"))) }
        // The reply comes when the watch ends (cancel or reload); events come meanwhile.
        watches[id] = PathWatch(path: p) { [weak self] changes in
            self?.send(["type": "event", "id": id, "data": ["changes": changes]])
        }
    }

    // MARK: Search

    static let rgPath: String? = {
        var dirs = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]
        dirs += (Paths.env["PATH"] ?? "").split(separator: ":").map(String.init)
        return dirs.map { $0 + "/rg" }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }()

    private func startSearch(_ id: String, _ args: [String: Any]) {
        let root: String
        do { root = try Self.path(args, "root") } catch { return reply(id, .failure(error)) }
        guard let query = args["query"] as? String, !query.isEmpty else { return reply(id, .failure(Failure(code: "badArgs", message: "query missing"))) }
        guard let rg = Self.rgPath else { return reply(id, .failure(Failure(code: "noRipgrep", message: "ripgrep (rg) isn't installed; install it with `brew install ripgrep`"))) }
        var a = ["--json", "--max-columns", "2000"]
        if args["regex"] as? Bool != true { a.append("--fixed-strings") }
        // Perl-style regexes (\d, \b, lookarounds), as Umi's `git grep -P`.
        else if args["pcre2"] as? Bool == true { a.append("--pcre2") }
        a.append(args["caseSensitive"] as? Bool == true ? "--case-sensitive" : "--ignore-case")
        if args["wholeWord"] as? Bool == true { a.append("--word-regexp") }
        if args["hidden"] as? Bool == true { a.append("--hidden") }
        if args["ignored"] as? Bool == true { a.append("--no-ignore") }
        for g in args["glob"] as? [String] ?? [] { a += ["--glob", g] }
        a += ["--", query, "."]
        let s = Search(rg: rg, args: a, root: root, maxResults: args["maxResults"] as? Int ?? 5000,
                       onBatch: { [weak self] batch in self?.send(["type": "event", "id": id, "data": ["matches": batch]]) },
                       onDone: { [weak self] summary, error in
                           guard let self, self.searches.removeValue(forKey: id) != nil else { return }
                           if let error { self.reply(id, .failure(Failure(code: "searchFailed", message: error))) } else { self.reply(id, .success(summary)) }
                       })
        searches[id] = s
        s.start()
    }
}

/// One `rg --json` run: matches are sent in batches (at most every 50 ms), then a summary.
final class Search {
    private let process = Process()
    private let root: String
    private let maxResults: Int
    private let onBatch: ([[String: Any]]) -> Void
    private let onDone: ([String: Any], String?) -> Void
    private var batch: [[String: Any]] = []
    private var count = 0, files = Set<String>()
    private var truncated = false, cancelled = false
    private var lastFlush = Date.distantPast
    private let lock = NSLock()

    init(rg: String, args: [String], root: String, maxResults: Int,
         onBatch: @escaping ([[String: Any]]) -> Void, onDone: @escaping ([String: Any], String?) -> Void) {
        self.root = root
        self.maxResults = maxResults
        self.onBatch = onBatch
        self.onDone = onDone
        process.executableURL = URL(fileURLWithPath: rg)
        process.arguments = args
        process.currentDirectoryURL = URL(fileURLWithPath: root)
    }

    func start() {
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return onDone([:], "can't start rg: \(error.localizedDescription)") }
        let t0 = Date()
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            var buffer = Data()
            let fh = out.fileHandleForReading
            while true {
                let chunk = fh.availableData
                if chunk.isEmpty { break }
                buffer.append(chunk)
                while let nl = buffer.firstIndex(of: 10) {
                    let line = buffer.subdata(in: buffer.startIndex..<nl)
                    buffer.removeSubrange(buffer.startIndex...nl)
                    if !parse(line) { process.terminate(); break }
                }
                if Date().timeIntervalSince(lastFlush) > 0.05 { flush() }
            }
            process.waitUntilExit()
            let errText = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            flush()
            lock.lock(); let wasCancelled = cancelled; lock.unlock()
            // rg exits 1 when nothing matched, 2 on errors (also when some files couldn't be read).
            let status = process.terminationStatus
            let failed = !wasCancelled && !truncated && status == 2 && count == 0
            let summary: [String: Any] = ["count": count, "files": files.count, "truncated": truncated,
                                          "cancelled": wasCancelled, "ms": Int(Date().timeIntervalSince(t0) * 1000)]
            DispatchQueue.main.async { self.onDone(summary, failed ? errText.trimmingCharacters(in: .whitespacesAndNewlines) : nil) }
        }
    }

    func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
        if process.isRunning { process.terminate() }
    }

    /// Returns false once enough matches arrived.
    private func parse(_ line: Data) -> Bool {
        if truncated { return false }
        guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              obj["type"] as? String == "match", let d = obj["data"] as? [String: Any],
              let rel = Self.text(d["path"]), let lineBytes = Self.bytes(d["lines"]) else { return true }
        var text = String(decoding: lineBytes, as: UTF8.self)
        if text.hasSuffix("\n") { text.removeLast() }
        if text.hasSuffix("\r") { text.removeLast() }
        // rg gives byte offsets; the page wants UTF-16 offsets (JS string indexes).
        var ranges: [[Int]] = []
        for sm in d["submatches"] as? [[String: Any]] ?? [] {
            guard let s = sm["start"] as? Int, let e = sm["end"] as? Int, s <= e, e <= lineBytes.count else { continue }
            let a = String(decoding: lineBytes.prefix(s), as: UTF8.self).utf16.count
            let b = String(decoding: lineBytes.prefix(e), as: UTF8.self).utf16.count
            ranges.append([a, b])
        }
        let path = rel.hasPrefix("./") ? String(rel.dropFirst(2)) : rel
        files.insert(path)
        batch.append(["path": path, "line": d["line_number"] as? Int ?? 0, "text": String(text.prefix(2000)), "ranges": ranges])
        count += 1
        if count >= maxResults { truncated = true; return false }
        return true
    }

    private func flush() {
        lastFlush = Date()
        guard !batch.isEmpty else { return }
        let b = batch
        batch = []
        lock.lock(); let c = cancelled; lock.unlock()
        if !c { DispatchQueue.main.async { self.onBatch(b) } }
    }

    /// rg's {text} or {bytes: base64} values.
    private static func text(_ v: Any?) -> String? {
        guard let d = v as? [String: Any] else { return nil }
        if let t = d["text"] as? String { return t }
        if let b = d["bytes"] as? String, let data = Data(base64Encoded: b) { return String(decoding: data, as: UTF8.self) }
        return nil
    }

    private static func bytes(_ v: Any?) -> Data? {
        guard let d = v as? [String: Any] else { return nil }
        if let t = d["text"] as? String { return Data(t.utf8) }
        if let b = d["bytes"] as? String { return Data(base64Encoded: b) }
        return nil
    }
}

/// FSEvents on a file or folder (a folder recursively), coalesced over 50 ms, delivered on main.
/// A file is watched through its folder, keeping only its own events. Changes inside `.git` are
/// dropped unless the watched path is inside `.git`.
final class PathWatch {
    private var stream: FSEventStreamRef?
    private let target: String
    private let isFile: Bool
    private let callback: ([[String: Any]]) -> Void
    private var pending: [String: Set<String>] = [:]
    private var scheduled = false

    init(path: String, callback: @escaping ([[String: Any]]) -> Void) {
        target = path
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
        isFile = !isDir.boolValue
        self.callback = callback
        let watched = isFile ? (path as NSString).deletingLastPathComponent : path
        var ctx = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let cb: FSEventStreamCallback = { _, info, n, paths, flags, _ in
            let me = Unmanaged<PathWatch>.fromOpaque(info!).takeUnretainedValue()
            let list = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as! [String]
            for i in 0..<n { me.note(list[i], flags[i]) }
        }
        stream = FSEventStreamCreate(nil, cb, &ctx, [watched] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.02,
                                     FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagUseCFTypes))
        if let stream {
            FSEventStreamSetDispatchQueue(stream, .main)
            FSEventStreamStart(stream)
        }
    }

    func stop() {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
        stream = nil
    }

    deinit { stop() }

    private func note(_ raw: String, _ f: FSEventStreamEventFlags) {
        let p = (raw as NSString).standardizingPath
        if isFile ? p != target : !(p == target || p.hasPrefix(target + "/")) { return }
        if !target.contains("/.git") && (p.contains("/.git/") || p.hasSuffix("/.git")) { return }
        var kinds = pending[p] ?? []
        let flag = { (bit: Int) in f & FSEventStreamEventFlags(bit) != 0 }
        if flag(kFSEventStreamEventFlagItemCreated) { kinds.insert("created") }
        if flag(kFSEventStreamEventFlagItemRemoved) { kinds.insert("removed") }
        if flag(kFSEventStreamEventFlagItemRenamed) { kinds.insert("renamed") }
        if flag(kFSEventStreamEventFlagItemModified) || flag(kFSEventStreamEventFlagItemInodeMetaMod) { kinds.insert("modified") }
        if flag(kFSEventStreamEventFlagMustScanSubDirs) { kinds.insert("rescan") }
        pending[p] = kinds
        guard !scheduled else { return }
        scheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self, self.stream != nil else { return }
            self.scheduled = false
            let changes: [[String: Any]] = self.pending.map { path, kinds in
                // Renames come as two events; whether the path is there now says which half this is.
                var k = kinds
                if k.contains("renamed") { k.insert(FileManager.default.fileExists(atPath: path) ? "created" : "removed") }
                return ["path": path, "kinds": k.sorted(), "exists": FileManager.default.fileExists(atPath: path)]
            }
            self.pending = [:]
            self.callback(changes)
        }
    }
}
