// tern agent …: managed Claude Code and Codex sessions (CLI.md, "Managed").
//
// Everything goes through the app's control socket. Long waits (`agent wait`) are answered
// by the app when the turn ends, the session needs input, or the timeout passes; if the app
// restarts meanwhile, the wait reconnects and keeps waiting.

import Darwin
import Foundation

let agentHelp = """
\(cliName) agent: managed Claude Code and Codex sessions.

  agent start claude|codex [PROMPT…] [--name N] [--cwd D] [--worktree W [--base REF]]
        [--model M] [--effort E] [--full-access] [--permission-mode M] [--profile P]
        [--env K=V]… [--tab [--window W] | --split [DIR] [--pane P] | --new-window] [--focus]
        [--background] [--wait [--timeout S]] [-- HARNESS ARGS]
                                    start a session; prints its id (shown in a new tab unless
                                    --background; --focus to switch to it)
  agent send SESSION TEXT… [--interrupt [--drop-queued]] [--wait [--timeout S]]
                                    a follow-up (queued while the agent works; a stopped session
                                    resumes); prints the message id. --interrupt: stop the running
                                    turn and make TEXT the next thing the agent sees
  agent wait SESSION [--message ID] [--timeout S]
                                    wait for the turn answering the latest (or given) message
  agent wait SESSION --report [--message ID] [--timeout S]
                                    wait for the worker's own report (see `agent report`)
  agent report done|blocked|failed [SUMMARY…] [--session S]
                                    inside a session: record your verdict on your task
  agent read SESSION [--message ID] | --transcript [--last N]
  agent ls [--live]                 agent info SESSION
  agent interrupt SESSION           agent stop SESSION          agent resume SESSION [PROMPT…]
  agent approve SESSION [REQUEST] [--always] [--message TEXT]
  agent deny SESSION [REQUEST] [--message TEXT]
  agent answer SESSION [TEXT…] [--answer N=TEXT]… [--request R]
  agent watch SESSION --notify OTHER [--message ID] [--text T]
  agent open SESSION [--tab [--window W] | --split [DIR] [--pane P] | --new-window] [--focus]
  agent rename SESSION NAME         agent rm SESSION [--force]

SESSION is an id or unique id prefix, a name, the harness's own session or thread id, or
`self` inside a managed agent. Text: words are joined; `-` reads stdin; text after `--` is text
(for `agent start`, what follows `--` goes to the harness).

\(idleNote)
"""

let idleNote = """
Note: an idle harness only means nothing is running right now, not that the task is done.
A worker can also start working again by itself (for example when a background command it
started finishes). Workers record their verdict with `\(cliName) agent report`; wait for it with
`\(cliName) agent wait SESSION --report`, whose output also says what the harness reports.
"""

let waitHelp = """
\(cliName) agent wait SESSION [--message ID] [--timeout S]
\(cliName) agent wait SESSION --report [--message ID] [--timeout S]

Waits for the turn that answers the latest message to SESSION (or message ID) and prints a
status, then the reply (or the pending requests):

  DONE 0 · NEEDS_INPUT 2 · INTERRUPTED, FAILED, EXITED, ERROR, CANCELLED 3 · TIMEOUT 124

With nothing pending it returns the session's current state at once; an old message's wait
returns that message's own reply. With --report it waits for a report the worker made (with
`agent report`) after that message: done 0, blocked 2, failed 3, timeout 124, followed by what
the harness says (its status and background tasks).

\(idleNote)
"""

let reportHelp = """
\(cliName) agent report done|blocked|failed [SUMMARY…] [--session S]

Inside a managed session, records your own verdict on your task (S defaults to `self`).
Whoever started you sees it in `agent info` and `agent ls`, and `agent wait SESSION --report`
returns when you report. Report when your task is done, when you're blocked, or when it failed.

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
    case "resume": agentResume(rest)
    case "approve", "allow": agentApprove(rest, deny: false)
    case "deny": agentApprove(rest, deny: true)
    case "answer": agentAnswer(rest)
    case "watch": agentWatch(rest)
    case "open", "show-pane": agentOpen(rest)
    case "rename": agentRename(rest)
    case "rm", "remove": agentRemove(rest)
    default: fail("agent: unknown subcommand \(sub) (see `\(cliName) agent --help`)")
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
    guard let kind = args.positional.first else { fail("agent start: claude or codex?") }
    guard kind == "claude" || kind == "codex" else { fail("agent start: unknown agent \"\(kind)\" (use claude or codex)") }
    var params = placementParams(args)
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
    let args = parse(argv, ArgSpec(boolean: ["--live"]))
    var params: [String: Any] = [:]
    if args.has("--live") { params["live"] = true }
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
    let args = parse(argv, placementSpec([], []))
    guard let session = args.positional.first else { fail("agent open SESSION [PLACEMENT]") }
    var params = placementParams(args)
    params["session"] = session
    params.removeValue(forKey: "background")
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
