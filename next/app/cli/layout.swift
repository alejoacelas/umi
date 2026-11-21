// umi-next: the commands the page answers (web/cli.js): ls, tab, split, pane, sidebar, notify,
// go, shortcuts, edit, editor.

import Foundation

let notMirrored: Set<String> = ["window", "drawer", "list", "slot", "command", "events", "log", "layout", "reopen",
                                "screenshot", "worktree", "link", "hook", "update", "plugins", "doctor"]

/// Prints `result` as JSON, or the line a person wants.
func show(_ result: Any, _ text: (([String: Any]) -> String)? = nil) {
    if jsonOutput { printJSON(result); return }
    guard let d = result as? [String: Any] else { return }
    if let text { let t = text(d); if !t.isEmpty { print(t) } }
}

func paneOrTab(_ args: Args) -> [String: Any] {
    var out: [String: Any] = [:]
    if let p = args.value("--pane") { out["pane"] = p }
    if let t = args.value("--tab") { out["tab"] = t }
    return out
}

// MARK: ls

func lsCommand(_ argv: [String]) {
    let args = parse(argv, ArgSpec(valued: ["--where"]))
    if args.value("--where") != nil { fail("ls --where: queries aren't in Umi next (next/PARITY.md)") }
    let r = ui("ls") as? [String: Any] ?? [:]
    if jsonOutput { printJSON(r); return }
    let windows = r["windows"] as? [[String: Any]] ?? []
    for w in windows {
        for t in w["tabs"] as? [[String: Any]] ?? [] {
            let sel = t["selected"] as? Bool == true ? "*" : " "
            print(bold("\(sel) tab \(t["index"] ?? "?") \(t["title"] as? String ?? "")") + dim("  \(t["id"] ?? "")"))
            for p in t["panes"] as? [[String: Any]] ?? [] {
                let mark = p["focused"] as? Bool == true ? "›" : " "
                let kind = p["kind"] as? String ?? "terminal"
                var line = "  \(mark) \(p["id"] ?? "")  \(kind)"
                if let name = p["name"] as? String { line += "  \(name)" }
                if let s = p["session"] as? String { line += dim("  session \(s)") }
                if let f = p["file"] as? String { line += "  \(abbreviateHome(f))" }
                else { line += dim("  \(abbreviateHome(p["cwd"] as? String ?? ""))") }
                if let i = p["indicator"] as? String, i != "none" { line += "  [\(i)]" }
                print(line)
            }
            let hidden = t["hidden"] as? [String] ?? []
            if !hidden.isEmpty { print(dim("    hidden: \(hidden.joined(separator: " "))")) }
        }
    }
    let unshown = (r["sessions"] as? [[String: Any]] ?? []).filter { $0["pane"] is NSNull || $0["pane"] == nil }
    if !unshown.isEmpty {
        print(bold("  not on show"))
        for s in unshown {
            print("    \(s["id"] ?? "")  \(s["name"] as? String ?? "")" + dim("  \(s["by"] ?? "")  \(s["state"] ?? "")"))
        }
    }
}

// MARK: tab

func tabCommand(_ argv: [String]) {
    guard let sub = argv.first else { fail("tab: use new, focus, close, rename, next, prev or move") }
    let words = Array(argv.dropFirst())
    let tabLine: ([String: Any]) -> String = { d in "\(d["tab"] ?? "")" }
    switch sub {
    case "new":
        let args = parse(words, ArgSpec(valued: ["--cwd", "--cmd", "--name"], boolean: ["--no-focus"]))
        var req: [String: Any] = ["noFocus": args.has("--no-focus")]
        if let t = args.positional.first { req["title"] = t }
        if let c = args.value("--cwd") { req["cwd"] = absolutePath(c) }
        if let c = args.value("--cmd") { req["cmd"] = c }
        if let n = args.value("--name") { req["name"] = n }
        show(ui("tab.new", req)) { "\($0["pane"] ?? "")" }
    case "focus", "close":
        let args = parse(words, ArgSpec(valued: ["--tab"]))
        var req: [String: Any] = [:]
        if let t = args.value("--tab") ?? args.positional.first { req["tab"] = t }
        show(ui("tab.\(sub)", req)) { _ in "" }
    case "rename":
        let args = parse(words, ArgSpec(valued: ["--tab"]))
        var req: [String: Any] = [:]
        var pos = args.words
        if let t = args.value("--tab") { req["tab"] = t } else if pos.count >= 2 { req["tab"] = pos.removeFirst() }
        guard !pos.isEmpty else { fail("tab rename [TAB] NAME (\"\" clears)") }
        req["name"] = pos.joined(separator: " ")
        show(ui("tab.rename", req)) { _ in "" }
    case "next", "prev":
        show(ui("tab.\(sub)")) { d in "\(d["index"] ?? "") \(d["title"] ?? "")" }
    case "move":
        let args = parse(words, ArgSpec(valued: ["--tab"], boolean: ["--up", "--down"]))
        guard args.has("--up") != args.has("--down") else {
            fail("tab move [TAB] --up|--down (Umi next has one window; --index is not mirrored)")
        }
        var req: [String: Any] = ["d": args.has("--up") ? -1 : 1]
        if let t = args.value("--tab") ?? args.positional.first { req["tab"] = t }
        show(ui("tab.move", req), tabLine)
    case "archive", "unarchive", "pin", "unpin", "color", "equalize", "set", "unset", "get":
        fail("tab \(sub) isn't in Umi next (next/PARITY.md)")
    default:
        fail("tab: unknown command \(sub)")
    }
}

// MARK: split

func splitCommand(_ argv: [String]) {
    let args = parse(argv, ArgSpec(valued: ["--pane", "--cwd", "--cmd", "--name", "--ratio", "--worktree"], boolean: ["--no-focus"]))
    if args.value("--worktree") != nil { fail("split --worktree isn't in Umi next") }
    var req = paneOrTab(args)
    req["dir"] = args.positional.first ?? "right"
    req["noFocus"] = args.has("--no-focus")
    if let c = args.value("--cwd") { req["cwd"] = absolutePath(c) }
    if let c = args.value("--cmd") { req["cmd"] = c }
    if let n = args.value("--name") { req["name"] = n }
    if let r = args.value("--ratio") {
        guard let v = Double(r) else { fail("--ratio takes a number between 0 and 1") }
        req["ratio"] = v
    }
    show(ui("split", req)) { "\($0["pane"] ?? "")" }
}

// MARK: pane

func paneCommand(_ argv: [String]) {
    guard let sub = argv.first else {
        fail("pane: use focus, close, exit, info, rename, zoom, swap, resize, move, hide or show")
    }
    let words = Array(argv.dropFirst())
    func target(_ args: Args, _ pos: inout [String]) -> [String: Any] {
        var req: [String: Any] = [:]
        if let p = args.value("--pane") { req["pane"] = p } else if !pos.isEmpty { req["pane"] = pos.removeFirst() }
        return req
    }
    switch sub {
    case "focus", "close", "exit", "info", "zoom", "hide":
        let args = parse(words, ArgSpec(valued: ["--pane", "--until"]))
        if args.value("--until") != nil { fail("pane hide --until: nothing comes back by itself in Umi next (DESIGN)") }
        var pos = args.positional
        let req = target(args, &pos)
        let r = ui("pane.\(sub)", req)
        if sub == "info" && !jsonOutput {
            let d = r as? [String: Any] ?? [:]
            for k in d.keys.sorted() { print("\(k)=\(d[k].map { "\($0)" } ?? "")") }
            return
        }
        show(r) { d in sub == "focus" ? "\(d["pane"] ?? "")" : "" }
    case "show":
        let args = parse(words, ArgSpec(valued: ["--pane"], boolean: ["--focus"]))
        var pos = args.positional
        var req = target(args, &pos)
        guard req["pane"] != nil else { fail("pane show SESSION|PANE [--focus]") }
        req["focus"] = args.has("--focus")
        show(ui("pane.show", req)) { d in (d["panes"] as? [String])?.joined(separator: " ") ?? "" }
    case "rename":
        let args = parse(words, ArgSpec(valued: ["--pane"]))
        var pos = args.words
        var req: [String: Any] = [:]
        if let p = args.value("--pane") { req["pane"] = p } else if pos.count >= 2 { req["pane"] = pos.removeFirst() }
        guard !pos.isEmpty else { fail("pane rename [PANE] NAME") }
        req["name"] = pos.joined(separator: " ")
        show(ui("pane.rename", req)) { _ in "" }
    case "swap":
        let args = parse(words, ArgSpec(valued: ["--pane"]))
        var pos = args.positional
        var req: [String: Any] = [:]
        if let p = args.value("--pane") { req["pane"] = p } else if pos.count == 2 { req["pane"] = pos.removeFirst() }
        guard pos.count == 1 else { fail("pane swap [PANE] TARGET") }
        req["target"] = pos[0]
        show(ui("pane.swap", req)) { _ in "" }
    case "resize":
        let args = parse(words, ArgSpec(valued: ["--pane"]))
        let dirs: Set<String> = ["up", "down", "left", "right"]
        var pos = args.positional
        var req: [String: Any] = [:]
        if let p = args.value("--pane") { req["pane"] = p }
        else if pos.count >= 2, dirs.contains(pos[1]), !dirs.contains(pos[0]) || pos.count == 3 { req["pane"] = pos.removeFirst() }
        guard let d = pos.first, dirs.contains(d) else { fail("pane resize [PANE] up|down|left|right [AMOUNT]") }
        req["dir"] = d
        if pos.count > 1 {
            guard let n = Int(pos[1]), n > 0 else { fail("pane resize: AMOUNT must be a positive number") }
            req["amount"] = n
        }
        show(ui("pane.resize", req)) { _ in "" }
    case "move":
        let args = parse(words, ArgSpec(valued: ["--pane", "--to", "--tab", "--dir", "--window"], boolean: ["--new-tab", "--no-focus", "--new-window"]))
        guard args.has("--new-tab") else { fail("pane move [PANE] --new-tab (the only move Umi next mirrors)") }
        var pos = args.positional
        var req = target(args, &pos)
        req["newTab"] = true
        req["noFocus"] = args.has("--no-focus")
        show(ui("pane.move", req)) { "\($0["tab"] ?? "")" }
    case "set", "unset", "get", "until":
        fail("pane \(sub) isn't in Umi next: no pane attributes (next/PARITY.md)")
    default:
        fail("pane: unknown command \(sub)")
    }
}

// MARK: sidebar, notify, go, shortcuts

func sidebarCommand(_ argv: [String]) {
    let args = parse(argv, ArgSpec(valued: ["--window"]))
    let mode = args.positional.first ?? "status"
    if mode == "width" { fail("sidebar width isn't in Umi next yet (PARITY track c)") }
    show(ui("sidebar", ["mode": mode])) { d in
        mode == "status" ? "\(d["visible"] as? Bool == true ? "on" : "off") \(d["mode"] ?? "")" : ""
    }
}

func notifyCommand(_ argv: [String]) {
    let args = parse(argv, ArgSpec(valued: ["--pane"]))
    let w = args.words
    guard let title = w.first else { fail("notify TITLE [BODY]") }
    var req: [String: Any] = ["title": title, "body": w.dropFirst().joined(separator: " ")]
    if let pane = args.value("--pane") { req["pane"] = pane }
    show(ui("notify", req)) { _ in "" }
}

func goCommand(_ argv: [String]) {
    let args = parse(argv, ArgSpec(boolean: ["--next", "--back"]))
    if args.has("--back") { show(ui("go", ["back": true])) { "\($0["pane"] ?? "")" }; return }
    guard args.has("--next"), args.positional == ["jump"] || args.positional == ["@jump"] else {
        fail("go: Umi next mirrors go --next jump (the next session waiting for you) and go --back")
    }
    show(ui("go", ["next": true])) { "\($0["pane"] ?? "")" }
}

func shortcutsCommand(_ argv: [String]) {
    if let sub = argv.first, sub != "ls" {
        fail("shortcuts \(sub): change shortcuts in next/app/web/shortcuts.js; the page reloads it live")
    }
    let r = ui("shortcuts") as? [String: Any] ?? [:]
    if jsonOutput { printJSON(r); return }
    var group = ""
    for s in r["shortcuts"] as? [[String: Any]] ?? [] {
        let g = s["group"] as? String ?? ""
        if g != group { group = g; print(bold(g)) }
        let keys = (s["display"] as? [String] ?? []).joined(separator: " ")
        print("  \(keys.padding(toLength: 12, withPad: " ", startingAt: 0)) \(s["title"] ?? "")" + dim("  \(s["id"] ?? "")"))
    }
}

// MARK: edit, editor

func editCommand(_ argv: [String]) {
    let args = parse(argv, ArgSpec(valued: ["--pane", "--tab"], boolean: ["--source", "--preview"]))
    var files = args.words
    if files.isEmpty {
        guard isatty(STDIN_FILENO) == 0 else { fail("edit FILE… [--source|--preview] [--pane P|--tab T]") }
        files = readStdin().split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }
    if args.value("--pane") != nil && args.value("--tab") != nil { fail("edit: give --pane or --tab, not both") }
    var req = paneOrTab(args)
    req["paths"] = files.map { $0.range(of: "^[A-Za-z]+://", options: .regularExpression) != nil ? $0 : realPath(absolutePath($0)) }
    if args.has("--source") { req["mode"] = "source" } else if args.has("--preview") { req["mode"] = "preview" }
    show(ui("edit", req)) { d in
        (d["documents"] as? [[String: Any]] ?? []).map { "\($0["pane"] ?? "")  \($0["path"] ?? "")" }.joined(separator: "\n")
    }
}

func editorCommand(_ argv: [String]) {
    guard let sub = argv.first else { fail("editor: use ls, close or mode") }
    let words = Array(argv.dropFirst())
    switch sub {
    case "ls":
        let args = parse(words, ArgSpec(valued: ["--pane", "--tab"]))
        show(ui("editor.ls", paneOrTab(args))) { d in
            (d["documents"] as? [[String: Any]] ?? []).map { doc in
                "\(doc["mode"] ?? "")\(doc["dirty"] as? Bool == true ? " •" : "  ") \(abbreviateHome(doc["path"] as? String ?? ""))" + dim("  \(doc["pane"] ?? "")")
            }.joined(separator: "\n")
        }
    case "close":
        let args = parse(words, ArgSpec(boolean: ["--force"]))
        var req: [String: Any] = ["force": args.has("--force")]
        if let f = args.positional.first { req["file"] = realPath(absolutePath(f)) }
        show(ui("editor.close", req)) { _ in "" }
    case "mode":
        let args = parse(words, ArgSpec())
        var pos = args.positional
        var req: [String: Any] = [:]
        if let m = pos.first, m == "preview" || m == "source" { req["mode"] = m; pos.removeFirst() }
        if let f = pos.first { req["file"] = realPath(absolutePath(f)) }
        show(ui("editor.mode", req)) { "\($0["mode"] ?? "")" }
    case "default":
        fail("editor default isn't in Umi next (next/PARITY.md)")
    default:
        fail("editor: unknown command \(sub)")
    }
}
