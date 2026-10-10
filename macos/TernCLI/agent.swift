// tern agent …: managed Claude Code and Codex sessions (CLI.md, "Managed").
//
// Everything goes through the app's control socket. Long waits (`agent wait`) are answered
// by the app when the turn ends, the session needs input, or the timeout passes; if the app
// restarts meanwhile, the wait reconnects and keeps waiting.

import Darwin
import Foundation

let agentHelp = """
\(cliName) agent: run Claude Code and Codex sessions, and supervise them.

Start a session (it runs headless in the background; prints the session id):
  \(cliName) agent start claude|codex "TASK" [--name N] [--cwd DIR | --worktree NAME] [--model M]
        [--effort E] [--full-access] [--env K=V]… [--wait [--timeout S]] [-- AGENT ARGS…]
      With --tab, --split [right|down|left|up] or --new-window it also gets a pane there: it
      works headless until this first turn ends, then opens live in that pane for you
      (--focus switches to it).

Supervise:
  \(cliName) agent wait SESSION [--timeout S]
      Wait until it has finished (or needs input); prints STATUS, then its reply.
  \(cliName) agent send SESSION "TEXT" [--interrupt]
      Send a message: it steers the turn the agent is working on, or starts a new turn; a
      stopped session resumes. Prints the message id. --interrupt stops the current turn first.
  \(cliName) agent read SESSION [--transcript]       Its last reply (or everything, in order).
  \(cliName) agent ls [--parent self]                Sessions: status, activity, where they are.
  \(cliName) agent info SESSION                      One session in detail.
  \(cliName) agent interrupt SESSION                 Stop the current turn; the session stays.
  \(cliName) agent stop SESSION                      Stop it and all it started; a message resumes it.
  \(cliName) agent watch SESSION --notify OTHER      OTHER gets a message when SESSION finishes.
  \(cliName) agent report done|blocked|failed "SUMMARY"
      Inside a session: your verdict on your task (`agent wait SESSION --report` waits for it).

Show it to a person:
  \(cliName) agent open SESSION [--tab|--split|--new-window] [--live]
      Show it in a pane, read-only; --live (or the pane's Take Over button) opens the agent's
      own interface there on the same conversation.
  \(cliName) agent hide SESSION                      Take it out of its pane; it keeps running.

Example:
  \(cliName) agent start codex "Fix the failing test in tests/test_api.py" --name fix-api --full-access
  \(cliName) agent wait fix-api --timeout 1800        # DONE, then its reply
  \(cliName) agent send fix-api "Also run the linter"  # steers it if it's still working

Also: approve, deny, answer (for sessions without --full-access), rename, rm [--force],
attach SESSION (run its interface in this terminal), plugins [status|install|remove].
SESSION is a name, an id (or its start), the agent's own session id, or `self` inside a session.
`wait` exits 0 DONE, 2 NEEDS_INPUT, 3 STOPPED/ERROR/FAILED/INTERRUPTED/CANCELLED, 124 TIMEOUT.
"""

let idleNote = """
A session isn't finished while background work it started (that will wake it) is still running:
`agent wait` waits for that too, and its reply is the newest one. Workers record their own verdict
with `\(cliName) agent report`; `\(cliName) agent wait SESSION --report` waits for it.
"""

let waitHelp = """
\(cliName) agent wait SESSION [--message ID] [--timeout S]
\(cliName) agent wait SESSION --report [--message ID] [--timeout S]

Waits until the turn answering the latest message to SESSION (or message ID) has ended and the
session has settled, or until it needs input, then prints a status and the reply (or what it
waits on):

  DONE 0 · NEEDS_INPUT 2 · STOPPED, ERROR, FAILED, INTERRUPTED, CANCELLED 3 · TIMEOUT 124

On a timeout it says what is still running. With --report it waits for the worker's own report
(`agent report`) made after that message: done 0, blocked 2, failed 3, timeout 124.

\(idleNote)
"""

let reportHelp = """
\(cliName) agent report done|blocked|failed [SUMMARY…] [--session S]

Inside a session, records your own verdict on your task (S defaults to `self`). Whoever started
you sees it in `agent info` and `agent ls`, and `agent wait SESSION --report` returns when you
report. Report when your task is done, when you're blocked, or when it failed.

\(idleNote)
"""

/// Text for a message: words, `-` for stdin (without the trailing newline a pipe adds), or
/// what follows `--`.
func messageText(_ args: Args, words: [String]) -> String? {
    var parts = words
    if let rest = args.rest { parts += rest }
    if parts == ["-"] {
        var text = readStdin()
        while text.hasSuffix("\n") || text.hasSuffix("\r") { text.removeLast() }
        return text
    }
    if parts.isEmpty { return nil }
    return parts.joined(separator: " ")
}

// MARK: - Dispatch

func agentCommand(_ argv: [String]) {
    guard let sub = argv.first, sub != "help", sub != "--help", sub != "-h" else {
        print(agentHelp)
        return
    }
    let rest = Array(argv.dropFirst())
    let beforeSeparator = rest.prefix(while: { $0 != "--" })
    if beforeSeparator.contains("--help") || beforeSeparator.contains("-h") {
        switch sub {
        case "wait": print(waitHelp)
        case "report": print(reportHelp)
        default: print(agentHelp)
        }
        return
    }
    switch sub {
    case "start", "new": agentStart(rest)
    case "send": agentSend(rest)
    case "wait": agentWait(rest)
    case "report": agentReport(rest)
    case "read": agentRead(rest)
    case "ls", "list": agentList(rest)
    case "info", "show": agentInfo(rest)
    case "interrupt": agentSimple("agent.interrupt", rest, usage: "agent interrupt SESSION")
    case "stop", "kill": agentSimple("agent.stop", rest, usage: "agent stop SESSION")
    case "hide": agentSimple("agent.hide", rest, usage: "agent hide SESSION")
    case "attach": agentAttach(rest)
    case "hook": agentHook(rest)
    case "plugins", "plugin": agentPlugins(rest)
    case "resume": agentResume(rest)
    case "approve", "allow": agentApprove(rest, deny: false)
    case "deny": agentApprove(rest, deny: true)
    case "answer": agentAnswer(rest)
    case "watch": agentWatch(rest)
    case "open", "show-pane": agentOpen(rest)
    case "rename": agentRename(rest)
    case "rm", "remove": agentRemove(rest)
    default: fail("agent: unknown command \(sub) (`\(cliName) agent --help` lists them)")
    }
}

// MARK: - Placement

let placementValued: Set<String> = ["--window", "--pane"]
let placementBoolean: Set<String> = ["--tab", "--new-window", "--focus", "--background", "--no-focus"]
let directions: Set<String> = ["right", "down", "left", "up"]

func placementSpec(_ valued: Set<String>, _ boolean: Set<String>) -> ArgSpec {
    var spec = ArgSpec(valued: valued.union(placementValued), boolean: boolean.union(placementBoolean),
                       aliases: ["-p": "--pane", "-w": "--window"])
    spec.optionalValue["--split"] = { directions.contains($0) }
    return spec
}

/// Whether any option says where to show the session.
func hasPlacement(_ args: Args) -> Bool {
    ["--tab", "--split", "--new-window", "--focus"].contains { args.has($0) }
        || args.value("--window") != nil || args.value("--pane") != nil
}

func placementParams(_ args: Args) -> [String: Any] {
    var params: [String: Any] = [:]
    let choices = [args.has("--tab"), args.has("--split"), args.has("--new-window")].filter { $0 }.count
    if choices > 1 { fail("choose one of --tab, --split or --new-window") }
    if args.has("--split") {
        params["placement"] = "split"
        params["direction"] = args.value("--split") ?? "right"
    } else if args.has("--new-window") {
        params["placement"] = "window"
    } else {
        params["placement"] = "tab"
    }
    if let window = args.value("--window") { params["window"] = window }
    if let pane = args.value("--pane") { params["pane"] = pane }
    if args.has("--focus") { params["focus"] = true }
    if args.has("--background") { params["background"] = true }
    return params
}

// MARK: - start

func agentStart(_ argv: [String]) {
    let spec = placementSpec(["--name", "--cwd", "--worktree", "--base", "--model", "--effort", "--permission-mode",
                              "--profile", "--env", "--timeout"],
                             ["--full-access", "--wait"])
    let args = parse(argv, spec)
    guard let kind = args.positional.first else { fail("agent start claude|codex \"TASK\" (see `\(cliName) agent --help`)") }
    guard kind == "claude" || kind == "codex" else {
        fail("agent start: the agent is claude or codex, then the task: `\(cliName) agent start claude \"TASK\"`")
    }
    var params = placementParams(args)
    // AP-3: a session runs in the background (shown nowhere) unless a placement is given.
    let background = args.has("--background") || !hasPlacement(args)
    if background { params = ["background": true] }
    params["kind"] = kind
    let words = Array(args.positional.dropFirst())
    if words == ["-"] {
        var text = readStdin()
        while text.hasSuffix("\n") || text.hasSuffix("\r") { text.removeLast() }
        params["prompt"] = text
    } else if !words.isEmpty {
        params["prompt"] = words.joined(separator: " ")
    }
    var cwd = args.value("--cwd").map { absolutePath($0) } ?? FileManager.default.currentDirectoryPath
    if let worktree = args.value("--worktree") {
        cwd = resolveWorktree(worktree, base: cwd, baseRef: args.value("--base"))
    }
    var isDir = ObjCBool(false)
    guard FileManager.default.fileExists(atPath: cwd, isDirectory: &isDir), isDir.boolValue else {
        fail("agent start: no such folder: \(cwd)")
    }
    params["cwd"] = cwd
    if let name = args.value("--name") { params["name"] = name }
    if let model = args.value("--model") { params["model"] = model }
    if let effort = args.value("--effort") { params["effort"] = effort }
    if args.has("--full-access") { params["full_access"] = true }
    if let mode = args.value("--permission-mode") { params["permission_mode"] = mode }
    if let profile = args.value("--profile") { params["profile"] = profile }
    var env: [String: String] = [:]
    for pair in args.all("--env") {
        guard let eq = pair.firstIndex(of: "="), eq != pair.startIndex else { fail("--env takes KEY=VALUE (got \(pair))") }
        env[String(pair[..<eq])] = String(pair[pair.index(after: eq)...])
    }
    params["env"] = env
    params["harness_args"] = args.rest ?? []
    let timeout = parseTimeout(args)
    let result = callDict("agent.start", params)
    let session = result["session"] as? [String: Any] ?? [:]
    let id = session["id"] as? String ?? ""
    if let paneError = result["pane_error"] as? String { eprint("\(cliName): warning: \(paneError)") }
    if !jsonOutput && !args.has("--wait") {
        // Say what happened and what's next (on stderr: stdout is just the id, for scripts).
        let name = session["name"] as? String ?? id
        let quoted = name.contains(" ") ? "'\(name)'" : name
        if background {
            eprint(dim("started \(kind) session \(quoted) in the background; `\(cliName) agent wait \(quoted)` waits for its reply"))
        } else {
            eprint(dim("started \(kind) session \(quoted): its pane shows it now, and it opens live there when this turn ends"))
        }
    }
    if args.has("--wait") {
        var waitParams: [String: Any] = ["session": id]
        if let message = (result["message"] as? [String: Any])?["id"] as? String { waitParams["message"] = message }
        if let timeout { waitParams["timeout"] = timeout }
        finishWait(waitParams, report: false)
    }
    if jsonOutput { printJSON(result) } else { print(id) }
}

func parseTimeout(_ args: Args) -> Double? {
    guard let raw = args.value("--timeout") else { return nil }
    guard let seconds = Double(raw), seconds >= 0 else { fail("--timeout must be a number of seconds") }
    return seconds
}

// MARK: - send

func agentSend(_ argv: [String]) {
    let args = parse(argv, ArgSpec(valued: ["--timeout"], boolean: ["--interrupt", "--drop-queued", "--wait"]))
    guard let session = args.positional.first else { fail("agent send SESSION TEXT…") }
    guard let text = messageText(args, words: Array(args.positional.dropFirst())), !text.isEmpty else {
        fail("agent send: give the text to send (or - to read it from stdin)")
    }
    if args.has("--drop-queued") && !args.has("--interrupt") { fail("--drop-queued goes with --interrupt") }
    var params: [String: Any] = ["session": session, "text": text]
    if args.has("--interrupt") { params["interrupt"] = true }
    if args.has("--drop-queued") { params["drop_queued"] = true }
    let timeout = parseTimeout(args)
    let result = callDict("agent.send", params)
    let message = result["message"] as? [String: Any] ?? [:]
    if let note = result["note"] as? String, !jsonOutput { eprint("\(cliName): \(note)") }
    if args.has("--wait") {
        var waitParams: [String: Any] = ["session": session, "message": message["id"] as? String ?? ""]
        if let timeout { waitParams["timeout"] = timeout }
        finishWait(waitParams, report: false)
    }
    if jsonOutput { printJSON(result) } else { print(message["id"] as? String ?? "") }
}

// MARK: - wait

func agentWait(_ argv: [String]) {
    let args = parse(argv, ArgSpec(valued: ["--message", "--timeout"], boolean: ["--report"], aliases: ["-m": "--message"]))
    guard let session = args.positional.first else { fail("agent wait SESSION [--message ID] [--timeout S]") }
    if args.positional.count > 1 { fail("agent wait: unexpected argument \(args.positional[1])") }
    var params: [String: Any] = ["session": session]
    if let message = args.value("--message") { params["message"] = message }
    if let timeout = parseTimeout(args) { params["timeout"] = timeout }
    if args.has("--report") { params["report"] = true }
    finishWait(params, report: args.has("--report"))
}

/// Wait (reconnecting if the app restarts meanwhile), print the outcome and exit with its code.
func finishWait(_ params: [String: Any], report: Bool) -> Never {
    let deadline = (params["timeout"] as? Double).map { Date().addingTimeInterval($0) }
    var result: [String: Any]?
    var lastError: RPCError?
    var downSince: Date?
    while result == nil {
        var attempt = params
        if let deadline { attempt["timeout"] = max(0, deadline.timeIntervalSinceNow) }
        if let client = Client(path: socketPath(for: stateDirectory())) {
            downSince = nil
            do {
                result = try client.call("agent.wait", attempt) as? [String: Any] ?? [:]
            } catch let error as RPCError {
                if error.code == "io" {
                    lastError = error   // the app went away mid-wait: try again
                } else {
                    fail(error.message)
                }
            } catch {
                fail("\(error)")
            }
        } else {
            if downSince == nil { downSince = Date() }
            if Date().timeIntervalSince(downSince!) > 60 {
                fail(lastError?.message ?? "\(productName) isn't running for state directory \(stateDirectory())")
            }
        }
        if result == nil {
            if let deadline, Date() >= deadline {
                result = ["status": "TIMEOUT"]
                break
            }
            usleep(300_000)
        }
    }
    let out = result ?? [:]
    let session = out["session"] as? [String: Any] ?? [:]
    if let warning = out["warning"] as? String { eprint("\(cliName): warning: \(warning)") }
    if report, out["report"] == nil, out["status"] as? String == "ERROR" {
        // The session went away while waiting.
        if jsonOutput { printJSON(out) } else { print("ERROR: \(out["error"] as? String ?? "the wait ended")") }
        exit(3)
    }
    if report {
        let reportInfo = out["report"] as? [String: Any]
        let verdict = reportInfo?["verdict"] as? String
        if jsonOutput {
            var json = out
            if json["report"] == nil { json["status"] = "TIMEOUT" }
            printJSON(json)
        } else {
            if let reportInfo {
                print("\(verdict ?? "?"): \(reportInfo["summary"] as? String ?? "")")
            } else {
                print("TIMEOUT: no report yet")
            }
            print(harnessLine(session))
        }
        switch verdict {
        case "done": exit(0)
        case "blocked": exit(2)
        case "failed": exit(3)
        default: exit(124)
        }
    }
    let status = out["status"] as? String ?? "ERROR"
    if jsonOutput {
        printJSON(out)
    } else {
        print(status)
        if status == "NEEDS_INPUT" {
            for request in out["requests"] as? [[String: Any]] ?? [] { printRequest(request) }
        } else if let reply = out["reply"] as? String, !reply.isEmpty {
            print(reply)
        } else if let error = out["error"] as? String, !error.isEmpty {
            print(error)
        } else if status == "TIMEOUT" {
            print(harnessLine(session))
        }
    }
    exit(waitExitCode(status))
}

func waitExitCode(_ status: String) -> Int32 {
    switch status {
    case "DONE": return 0
    case "NEEDS_INPUT": return 2
    case "TIMEOUT": return 124
    default: return 3
    }
}

func harnessLine(_ session: [String: Any]) -> String {
    var line = "harness: \(session["status"] as? String ?? "?")"
    if let activity = session["activity"] as? String, !activity.isEmpty, activity != session["status"] as? String {
        line += " (\(activity))"
    }
    if let tasks = session["background_tasks"] as? Int { line += ", \(tasks) background task\(tasks == 1 ? "" : "s") running" }
    return line
}

func printRequest(_ request: [String: Any]) {
    let id = request["id"] as? String ?? "?"
    let kind = request["kind"] as? String ?? "request"
    print("[\(id)] \(kind): \(request["title"] as? String ?? "")")
    if let detail = request["detail"] as? String, !detail.isEmpty { print("    \(detail)") }
    if let url = (request["details"] as? [String: Any])?["url"] as? String { print("    link: \(url)") }
    for (index, question) in (request["questions"] as? [[String: Any]] ?? []).enumerated() {
        let options = question["options"] as? [String] ?? []
        var line = "    \(index + 1). \(question["question"] as? String ?? "?")"
        if let qid = question["id"] as? String, qid != "\(index + 1)" { line += "  (id \(qid))" }
        print(line)
        if !options.isEmpty { print("       options: \(options.joined(separator: " | "))") }
    }
}

// MARK: - report

func agentReport(_ argv: [String]) {
    let args = parse(argv, ArgSpec(valued: ["--session"], aliases: ["-s": "--session"]))
    guard let verdict = args.positional.first, ["done", "blocked", "failed"].contains(verdict) else {
        fail("agent report done|blocked|failed [SUMMARY…]")
    }
    var params: [String: Any] = ["verdict": verdict,
                                 "summary": messageText(args, words: Array(args.positional.dropFirst())) ?? ""]
    if let session = args.value("--session") { params["session"] = session }
    let result = callDict("agent.report", params)
    if jsonOutput { printJSON(["report": result["report"] ?? [String: Any]()]) } else { print("reported \(verdict)") }
}

// MARK: - read

func agentRead(_ argv: [String]) {
    let args = parse(argv, ArgSpec(valued: ["--message", "--last"], boolean: ["--transcript"],
                                   aliases: ["-m": "--message", "-n": "--last"]))
    guard let session = args.positional.first else { fail("agent read SESSION [--message ID | --transcript [--last N]]") }
    var params: [String: Any] = ["session": session]
    if args.has("--transcript") {
        params["transcript"] = true
        if let last = args.value("--last") {
            guard let n = Int(last), n >= 0 else { fail("--last must be 0 or more") }
            params["last"] = n
        }
        let result = callDict("agent.read", params)
        if jsonOutput {
            printJSON(["items": result["items"] ?? []])
            return
        }
        for item in result["items"] as? [[String: Any]] ?? [] { printItem(item) }
        return
    }
    if let message = args.value("--message") { params["message"] = message }
    let result = callDict("agent.read", params)
    if jsonOutput {
        var out: [String: Any] = ["reply": result["reply"] ?? ""]
        if let message = result["message"] { out["message"] = message }
        printJSON(out)
    } else {
        print(result["reply"] as? String ?? "")
    }
}

func printItem(_ item: [String: Any]) {
    let kind = item["kind"] as? String ?? "?"
    let text = item["text"] as? String ?? ""
    switch kind {
    case "tool":
        var line = "[tool] \(item["tool"] as? String ?? text)"
        if let detail = item["detail"] as? String, !detail.isEmpty { line += ": \(detail)" }
        if let state = item["state"] as? String { line += "  (\(state))" }
        print(line)
        if let output = item["output"] as? String, !output.isEmpty {
            for row in output.split(separator: "\n", omittingEmptySubsequences: false).prefix(20) { print("    \(row)") }
        }
    case "request":
        print("[request] \(text)\((item["detail"] as? String).map { ": \($0)" } ?? "")  (\(item["state"] as? String ?? ""))")
    default:
        print("[\(kind)] \(text)")
    }
}

// MARK: - ls, info

func agentList(_ argv: [String]) {
    let args = parse(argv, ArgSpec(valued: ["--parent"], boolean: ["--live"]))
    var params: [String: Any] = [:]
    if args.has("--live") { params["live"] = true }
    if let parent = args.value("--parent") { params["parent"] = parent }
    let result = callDict("agent.ls", params)
    let sessions = result["sessions"] as? [[String: Any]] ?? []
    if jsonOutput {
        printJSON(["sessions": sessions])
        return
    }
    if sessions.isEmpty {
        print(dim("no sessions"))
        return
    }
    for session in sessions {
        var line = "\(dim(shortID(session["id"])))  \(bold(session["name"] as? String ?? "?"))  \(session["kind"] as? String ?? "")"
        line += "  \(session["status"] as? String ?? "?")"
        if let activity = session["activity"] as? String, !activity.isEmpty, activity != session["status"] as? String {
            line += dim(" · \(activity)")
        }
        if let report = session["report"] as? [String: Any] {
            line += "  [report: \(report["verdict"] as? String ?? "?")]"
        }
        if let pane = session["pane"] as? String { line += dim("  (pane \(shortID(pane)))") }
        print(line)
    }
}

func agentInfo(_ argv: [String]) {
    let args = parse(argv, ArgSpec())
    guard let session = args.positional.first else { fail("agent info SESSION") }
    let info = callDict("agent.info", ["session": session])
    if jsonOutput {
        printJSON(info)
        return
    }
    print("\(bold(info["name"] as? String ?? "?"))  \(info["id"] as? String ?? "")")
    print("  kind     \(info["kind"] as? String ?? "")")
    print("  status   \(info["status"] as? String ?? "")\((info["activity"] as? String).map { " · \($0)" } ?? "")")
    print("  folder   \(abbreviateHome(info["cwd"] as? String ?? ""))")
    if let harness = info["harness_id"] as? String { print("  harness  \(harness)") }
    if let parent = info["parent"] as? String { print("  parent   \(parent)") }
    print("  shown    \((info["pane"] as? String).map { "in pane \($0)" } ?? "nowhere (background; `\(cliName) agent open` shows it)")")
    if let error = info["error"] as? String { print("  error    \(error)") }
    if let report = info["report"] as? [String: Any] {
        print("  report   \(report["verdict"] as? String ?? "?"): \(report["summary"] as? String ?? "") (\(report["at"] as? String ?? ""))")
    }
    if let tasks = info["background_tasks"] as? Int { print("  background tasks  \(tasks)") }
    if let startup = info["startup"] as? [String: Any] {
        print("  started  \(startup["at"] as? String ?? "")\((startup["model"] as? String).map { ", model \($0)" } ?? "")")
        for server in startup["mcp_servers"] as? [[String: Any]] ?? [] {
            print("    mcp \(server["name"] as? String ?? "?"): \(server["status"] as? String ?? "?")")
        }
        for flag in startup["flags"] as? [String] ?? [] { print("    ! \(flag)") }
    }
    for request in info["requests"] as? [[String: Any]] ?? [] { printRequest(request) }
}

// MARK: - simple commands

func agentSimple(_ method: String, _ argv: [String], usage: String) {
    let args = parse(argv, ArgSpec())
    guard let session = args.positional.first, args.positional.count == 1 else { fail(usage) }
    let result = callDict(method, ["session": session])
    printOK(result)
}

func agentResume(_ argv: [String]) {
    let args = parse(argv, ArgSpec())
    guard let session = args.positional.first else { fail("agent resume SESSION [PROMPT…]") }
    var params: [String: Any] = ["session": session]
    if let text = messageText(args, words: Array(args.positional.dropFirst())) { params["prompt"] = text }
    let result = callDict("agent.resume", params)
    if jsonOutput { printJSON(result) } else if let message = result["message"] as? [String: Any] {
        print(message["id"] as? String ?? "")
    }
}

func agentApprove(_ argv: [String], deny: Bool) {
    let args = parse(argv, ArgSpec(valued: ["--message"], boolean: deny ? [] : ["--always"], aliases: ["-m": "--message"]))
    guard let session = args.positional.first else { fail("agent \(deny ? "deny" : "approve") SESSION [REQUEST]") }
    var params: [String: Any] = ["session": session]
    if args.positional.count > 1 { params["request"] = args.positional[1] }
    if args.positional.count > 2 { fail("agent \(deny ? "deny" : "approve"): unexpected argument \(args.positional[2])") }
    if args.has("--always") { params["always"] = true }
    if let message = args.value("--message") { params["message"] = message }
    printOK(callDict(deny ? "agent.deny" : "agent.approve", params))
}

func agentAnswer(_ argv: [String]) {
    let args = parse(argv, ArgSpec(valued: ["--answer", "--request"], aliases: ["-a": "--answer", "-r": "--request"]))
    guard let session = args.positional.first else { fail("agent answer SESSION [TEXT…] [--answer N=TEXT]…") }
    var params: [String: Any] = ["session": session]
    if let request = args.value("--request") { params["request"] = request }
    if let text = messageText(args, words: Array(args.positional.dropFirst())) { params["text"] = text }
    var answers: [String: String] = [:]
    for pair in args.all("--answer") {
        guard let eq = pair.firstIndex(of: "="), eq != pair.startIndex else { fail("--answer takes N=TEXT (got \(pair))") }
        answers[String(pair[..<eq])] = String(pair[pair.index(after: eq)...])
    }
    params["answers"] = answers
    if params["text"] == nil && answers.isEmpty { fail("agent answer: give the answer (TEXT or --answer N=TEXT)") }
    printOK(callDict("agent.answer", params))
}

func agentWatch(_ argv: [String]) {
    let args = parse(argv, ArgSpec(valued: ["--notify", "--message", "--text"], aliases: ["-m": "--message"]))
    guard let session = args.positional.first, let other = args.value("--notify") else {
        fail("agent watch SESSION --notify OTHER [--message ID] [--text T]")
    }
    var params: [String: Any] = ["session": session, "notify": other]
    if let message = args.value("--message") { params["message"] = message }
    if let text = args.value("--text") { params["text"] = text }
    printOK(callDict("agent.watch", params))
}

func agentOpen(_ argv: [String]) {
    let args = parse(argv, placementSpec([], ["--live"]))
    guard let session = args.positional.first else { fail("agent open SESSION [--tab|--split|--new-window] [--live]") }
    var params = placementParams(args)
    params["session"] = session
    params.removeValue(forKey: "background")
    if args.has("--live") { params["live"] = true }
    let result = callDict("agent.open", params)
    if jsonOutput { printJSON(result) } else { print(result["pane"] as? String ?? "") }
}

func agentRename(_ argv: [String]) {
    let args = parse(argv, ArgSpec())
    guard args.positional.count == 2 else { fail("agent rename SESSION NAME") }
    printOK(callDict("agent.rename", ["session": args.positional[0], "name": args.positional[1]]))
}

func agentRemove(_ argv: [String]) {
    let args = parse(argv, ArgSpec(boolean: ["--force"], aliases: ["-f": "--force"]))
    guard let session = args.positional.first else { fail("agent rm SESSION [--force]") }
    var params: [String: Any] = ["session": session]
    if args.has("--force") { params["force"] = true }
    printOK(callDict("agent.rm", params))
}

// MARK: - attach: the session's own interface, here

/// Run the session's own interface (Claude Code's or Codex's) in this terminal, on its
/// conversation: what the Take Over button types into a session's pane (SPEC AG-6). The app
/// frees the conversation first (a running headless turn is taken over at once), then this
/// process becomes the agent's interface.
func agentAttach(_ argv: [String]) {
    let args = parse(argv, ArgSpec())
    guard let session = args.positional.first, args.positional.count == 1 else { fail("agent attach SESSION") }
    let spec = callDict("agent.attach", ["session": session])
    guard let binary = spec["binary"] as? String else { fail("agent attach: the app sent no command") }
    let arguments = spec["args"] as? [String] ?? []
    for (key, value) in spec["env"] as? [String: String] ?? [:] { setenv(key, value, 1) }
    unsetenv("TERN_HEADLESS")
    // This app's own CLI first on PATH, so `tern` inside the session reaches this instance.
    let ownDir = (CommandLine.arguments[0] as NSString).deletingLastPathComponent
    if ownDir.hasPrefix("/") {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
        setenv("PATH", ([ownDir] + path.split(separator: ":").map(String.init).filter { $0 != ownDir }).joined(separator: ":"), 1)
    }
    if let cwd = spec["cwd"] as? String, !cwd.isEmpty {
        if chdir(cwd) != 0 { fail("agent attach: can't enter \(cwd)") }
        setenv("PWD", cwd, 1)
    }
    let argvC = ([binary] + arguments).map { strdup($0) } + [nil]
    execv(binary, argvC)
    fail("agent attach: couldn't run \(binary): \(String(cString: strerror(errno)))")
}

// MARK: - hook: what Tern's plugins call

/// `agent hook EVENT --agent claude|codex --pid PID`, run by Tern's plugin inside Claude Code or
/// Codex with the hook's input on stdin. It tells the app and prints nothing; it never makes the
/// agent wait long or fail (SPEC AG-18).
func agentHook(_ argv: [String]) -> Never {
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
        // Tool output can be large; the app keeps what it needs.
        var payload = object
        if let response = payload["tool_response"], let data = try? JSONSerialization.data(withJSONObject: ["v": response]),
           data.count > 64 * 1024 {
            payload["tool_response"] = String(decoding: data.prefix(64 * 1024), as: UTF8.self)
        }
        params["payload"] = payload
    }
    guard let client = Client(path: socketPath(for: stateDirectory())) else { exit(0) }
    var timeout = timeval(tv_sec: 3, tv_usec: 0)
    setsockopt(client.fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    setsockopt(client.fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    _ = try? client.call("agent.hook", params)
    exit(0)
}

// MARK: - plugins

func agentPlugins(_ argv: [String]) {
    let args = parse(argv, ArgSpec(boolean: ["--force"]))
    let action = args.positional.first ?? "status"
    guard ["status", "install", "remove"].contains(action) else { fail("agent plugins [status|install|remove]") }
    var params: [String: Any] = ["action": action]
    if args.has("--force") { params["force"] = true }
    let result = callDict("agent.plugins", params)
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
        var line = "\(name): " + (installed ? "Tern's plugin \(info["version"] as? String ?? "?") installed" : "Tern's plugin not installed")
        if let bundled = info["bundled_version"] as? String, installed, info["current"] as? Bool != true {
            line += " (this app has \(bundled); `\(cliName) agent plugins install` updates it)"
        }
        if info["hooks_trusted"] as? Bool == false { line += ", its hooks not trusted yet" }
        if info["agent_installed"] as? Bool == false { line += " (\(kind) isn't installed)" }
        print(line)
        for step in info["steps"] as? [String] ?? [] { print(dim("  \(step)")) }
    }
    if action == "status", !(result["claude"].flatMap { ($0 as? [String: Any])?["installed"] as? Bool } ?? false) {
        print(dim("They tell \(productName) what claude/codex typed in its panes are doing; outside \(productName) they do nothing."))
    }
}

// MARK: - claude / codex: a session you'll use

/// `tern claude [TASK…] [options]` / `tern codex …`: a session for you, in a new tab (or
/// --split/--new-window), switched to. With a task it runs headless until that turn ends, then
/// opens live; without one it opens live at once. Shorthand for `agent start … --tab --focus`.
func agentShortcut(_ kind: String, _ argv: [String]) {
    let probe = parse(argv, placementSpec(["--name", "--cwd", "--worktree", "--base", "--model", "--effort",
                                           "--permission-mode", "--profile", "--env", "--timeout"],
                                          ["--full-access", "--wait", "--no-focus"]))
    let separator = argv.firstIndex(of: "--") ?? argv.count
    var options = Array(argv[..<separator]).filter { $0 != "--no-focus" }
    if !hasPlacement(probe) { options.append("--tab") }
    if !probe.has("--no-focus") && !probe.has("--focus") { options.append("--focus") }
    agentStart([kind] + options + Array(argv[separator...]))
}
