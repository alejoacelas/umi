// umi-next: session I/O through the daemon (send, keys, read, wait), so it works while the UI is
// down. A selector names a session (id, unique id prefix, name) or, through the UI, a pane.

import Foundation

/// The daemon session a selector means. Absent: the session this CLI runs in, else the focused
/// pane's. Daemon names and ids first; anything else (a pane id, `.`) is the UI's to resolve.
func resolveSession(_ sel: String?) -> String {
    if sel == nil, let s = callerSession { return s }
    if let sel, sel != "." {
        let list = daemon(["op": "ls"])["sessions"] as? [[String: Any]] ?? []
        let ids = list.compactMap { $0["id"] as? String }
        if ids.contains(sel) { return sel }
        let named = list.filter { ($0["name"] as? String) == sel }.compactMap { $0["id"] as? String }
        if named.count == 1 { return named[0] }
        if named.count > 1 { fail("more than one session is named \"\(sel)\": \(named.joined(separator: ", "))") }
        let prefix = ids.filter { $0.hasPrefix(sel) }
        if prefix.count == 1 { return prefix[0] }
        if prefix.count > 1 { fail("\"\(sel)\" is ambiguous: \(prefix.joined(separator: ", "))") }
        // A pane id, or a name given in the UI: ask the UI, if it runs.
        if connectSocket(uiSocket).map({ close($0); return true }) != true { fail("no session \"\(sel)\"") }
    }
    var req: [String: Any] = [:]
    if let sel { req["pane"] = sel }
    let r = ui("resolve", req) as? [String: Any] ?? [:]
    guard let s = r["session"] as? String else { fail("that pane shows no session") }
    return s
}

func screen(_ sid: String) -> [String: Any] { daemon(["op": "screen", "id": sid, "format": "plain"]) }

func sendBytes(_ sid: String, _ bytes: [UInt8]) {
    _ = daemon(["op": "send", "id": sid, "data": Data(bytes).base64EncodedString()])
}

/// The last text `send` typed into each session, so `wait --pattern` can leave out the line
/// that echoes it (Umi tells program output from typed commands by the shell's marks; the
/// daemon's screen has no marks).
func sentFile(_ sid: String) -> String { stateDir + "/cli/sent-\(sid).txt" }

func tidy(_ text: String, lines: Int?) -> String {
    var rows = text.split(separator: "\n", omittingEmptySubsequences: false).map { String($0).replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression) }
    while let last = rows.last, last.isEmpty { rows.removeLast() }
    if let lines { rows = Array(rows.suffix(lines)) }
    return rows.joined(separator: "\n")
}

// MARK: send

func sendCommand(_ argv: [String]) {
    let args = parse(argv, ArgSpec(valued: ["--pane"], boolean: ["--enter"]))
    var text: String
    let words = args.words
    if words == ["-"] || (words.isEmpty && isatty(STDIN_FILENO) == 0) { text = readStdin() }
    else if words.isEmpty { fail("send [--pane P] [--enter] TEXT…") }
    else { text = words.joined(separator: " ") }
    let sid = resolveSession(args.value("--pane"))
    if !text.isEmpty {
        // Several lines go as a paste when the program asked for bracketed paste, as a terminal pastes.
        let paste = text.contains("\n") && (screen(sid)["bracketed_paste"] as? Bool ?? false)
        if paste { text = "\u{1B}[200~" + text + "\u{1B}[201~" }
        sendBytes(sid, Array(text.utf8))
        try? FileManager.default.createDirectory(atPath: stateDir + "/cli", withIntermediateDirectories: true)
        try? words.joined(separator: " ").write(toFile: sentFile(sid), atomically: true, encoding: .utf8)
    }
    if args.has("--enter") {
        if !text.isEmpty { usleep(60_000) }  // programs that read a paste then Enter as one burst drop the Enter
        sendBytes(sid, [0x0D])
    }
    if jsonOutput { printJSON(["session": sid]) }
}

// MARK: keys

/// Bytes for a key like `enter`, `esc`, `ctrl+c`, `shift+tab`, `up`, `f5`, `a`.
func keyBytes(_ spec: String, appCursor: Bool, kitty: Int) -> [UInt8] {
    var parts = spec.split(separator: "+", omittingEmptySubsequences: false).map { String($0) }
    if spec.hasSuffix("++") { parts = Array(parts.dropLast(2)) + ["+"] }
    guard let name0 = parts.popLast(), !name0.isEmpty else { fail("invalid key \"\(spec)\"") }
    var ctrl = false, shift = false, alt = false
    for m in parts {
        switch m.lowercased() {
        case "ctrl", "control", "c": ctrl = true
        case "shift", "s": shift = true
        case "alt", "opt", "option", "meta", "m": alt = true
        default: fail("unknown modifier \"\(m)\" in \"\(spec)\"")
        }
    }
    let name = name0.lowercased()
    let esc: UInt8 = 0x1B
    let disambiguate = kitty & 1 != 0
    // xterm modifier parameter: 1 + shift + 2·alt + 4·ctrl.
    let mod = 1 + (shift ? 1 : 0) + (alt ? 2 : 0) + (ctrl ? 4 : 0)
    func csi(_ s: String) -> [UInt8] { [esc] + Array(("[" + s).utf8) }
    let arrows: [String: String] = ["up": "A", "down": "B", "right": "C", "left": "D", "home": "H", "end": "F"]
    if let a = arrows[name] {
        if mod > 1 { return csi("1;\(mod)\(a)") }
        return appCursor ? [esc] + Array(("O" + a).utf8) : csi(a)
    }
    let tilde: [String: Int] = ["insert": 2, "delete": 3, "del": 3, "pageup": 5, "pgup": 5, "pagedown": 6, "pgdn": 6,
                                "f5": 15, "f6": 17, "f7": 18, "f8": 19, "f9": 20, "f10": 21, "f11": 23, "f12": 24]
    if let n = tilde[name] { return csi(mod > 1 ? "\(n);\(mod)~" : "\(n)~") }
    let ss3: [String: String] = ["f1": "P", "f2": "Q", "f3": "R", "f4": "S"]
    if let f = ss3[name] { return mod > 1 ? csi("1;\(mod)\(f)") : [esc] + Array(("O" + f).utf8) }
    var base: [UInt8]
    var codepoint: Int
    switch name {
    case "enter", "return", "ret", "cr", "nl": base = [0x0D]; codepoint = 13
    case "esc", "escape": base = [esc]; codepoint = 27
    case "tab": if shift { return csi("Z") }; base = [0x09]; codepoint = 9
    case "backspace", "bs": base = [0x7F]; codepoint = 127
    case "space", "spc": base = [0x20]; codepoint = 32
    default:
        guard name0.unicodeScalars.count == 1, let u = name0.unicodeScalars.first else {
            fail("unknown key \"\(name0)\" (try enter, esc, tab, backspace, up, ctrl+c, …)")
        }
        var ch = Character(u)
        if shift, ch.isLetter { ch = Character(ch.uppercased()) }
        codepoint = Int(Character(ch.lowercased()).unicodeScalars.first!.value)
        if ctrl {
            let c = ch.lowercased().unicodeScalars.first!.value
            if disambiguate { return csi("\(codepoint);\(mod)u") }
            if (0x61...0x7A).contains(c) { base = [UInt8(c - 0x60)] }
            else if ch == "[" { base = [esc] } else if ch == "\\" { base = [0x1C] } else if ch == "]" { base = [0x1D] }
            else if ch == " " || ch == "@" || ch == "2" { base = [0] }
            else { fail("can't type ctrl+\(ch)") }
            return alt ? [esc] + base : base
        }
        base = Array(String(ch).utf8)
        return alt ? [esc] + base : base
    }
    // Enter, Esc, Tab, Backspace, Space with modifiers, and Esc under the kitty protocol.
    if disambiguate && (name == "esc" || name == "escape" || mod > 1) { return csi("\(codepoint);\(mod)u") }
    if ctrl && name.hasPrefix("space") { return [0] }
    return alt ? [esc] + base : base
}

func keysCommand(_ argv: [String]) {
    let args = parse(argv, ArgSpec(valued: ["--pane"]))
    guard !args.words.isEmpty else { fail("keys [--pane P] KEY… (enter esc tab backspace up down left right ctrl+c shift+tab …)") }
    let sid = resolveSession(args.value("--pane"))
    let s = screen(sid)
    let appCursor = s["app_cursor_keys"] as? Bool ?? false
    let kitty = s["kitty_flags"] as? Int ?? 0
    let bytes = args.words.map { keyBytes($0, appCursor: appCursor, kitty: kitty) }
    for (i, b) in bytes.enumerated() {
        if i > 0 { usleep(20_000) }
        sendBytes(sid, b)
    }
    if jsonOutput { printJSON(["session": sid]) }
}

// MARK: read

func readCommand(_ argv: [String]) {
    let args = parse(argv, ArgSpec(valued: ["--pane", "--lines"], boolean: ["--scrollback"]))
    let lines = args.value("--lines").map { Int($0) ?? -1 }
    if let lines, lines < 1 { fail("--lines takes a positive number") }
    let sid = resolveSession(args.value("--pane") ?? args.positional.first)
    let scrollback = args.has("--scrollback")
    let r = daemon(["op": "screen", "id": sid, "format": "plain", "scrollback": scrollback])
    var raw = r["text"] as? String ?? ""
    if scrollback {
        // A daemon started before scrollback ignores the field and sends the screen alone.
        guard let history = r["history"] as? String else {
            fail("read --scrollback: the running umi-next daemon predates scrollback (it gives the screen only); it gets it when it restarts, which ends every session")
        }
        raw = history + (r["text"] as? String ?? "")
    }
    let text = tidy(raw, lines: lines)
    if jsonOutput { printJSON(["session": sid, "text": text]) } else { print(text) }
}

// MARK: wait

func waitCommand(_ argv: [String]) {
    let args = parse(argv, ArgSpec(valued: ["--pane", "--pattern", "--idle", "--timeout", "--attr"]))
    if args.value("--attr") != nil { fail("wait --attr: no pane attributes in Umi next; use --pattern or --idle") }
    let pattern = args.value("--pattern"), idle = args.value("--idle")
    guard (pattern == nil) != (idle == nil) else { fail("wait [--pane P] (--pattern RE | --idle SECS) [--timeout T]") }
    let timeout = args.value("--timeout").map { Double($0) ?? parseDuration($0) ?? -1 }
    if let timeout, timeout <= 0 { fail("--timeout takes seconds (or 90s, 5m, 2h)") }
    let sid = resolveSession(args.value("--pane"))
    let deadline = timeout.map { Date().addingTimeInterval($0) }
    func timedOut() -> Never {
        if jsonOutput { printJSON(["session": sid, "timed_out": true]) }
        eprint("\(cliName): timed out"); exit(124)
    }
    if let pattern {
        let re: NSRegularExpression
        do { re = try NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) }
        catch { fail("--pattern: not a regular expression: \(pattern)") }
        let sent = (try? String(contentsOfFile: sentFile(sid), encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        while true {
            let rows = (screen(sid)["text"] as? String ?? "").split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            // The line echoing the text `send` typed is the command, not its output.
            let output = rows.filter { sent.isEmpty || !$0.contains(sent) }.joined(separator: "\n")
            if let m = re.firstMatch(in: output, range: NSRange(output.startIndex..., in: output)),
               let r = Range(m.range, in: output) {
                let hit = String(output[r])
                if jsonOutput { printJSON(["session": sid, "match": hit]) } else { print(hit) }
                return
            }
            if let deadline, Date() >= deadline { timedOut() }
            usleep(150_000)
        }
    }
    guard let secs = Double(idle!) ?? parseDuration(idle!), secs > 0 else { fail("--idle takes seconds") }
    var last = screen(sid)["text"] as? String ?? ""
    var since = Date()
    while true {
        usleep(150_000)
        let now = screen(sid)["text"] as? String ?? ""
        if now != last { last = now; since = Date() }
        if Date().timeIntervalSince(since) >= secs {
            let text = tidy(now, lines: nil)
            if jsonOutput { printJSON(["session": sid, "text": text]) } else { print(text) }
            return
        }
        if let deadline, Date() >= deadline { timedOut() }
    }
}
