// `umi comments`: read and answer comments on a Markdown file (E-11). They're stored in the file
// itself (Roughdraft Flavored Markdown, see UmiComments.swift, compiled in by build.sh), so every
// command but `wait` works on the file directly, with or without Umi running.

import Darwin
import Foundation

let commentsHelp = """
umi comments: comments on a Markdown file, as left in Umi's editor (select text, then Comment or ⌥⌘M).

  comments [ls] FILE [--all]              open comments: id, line, the text each is on, replies
                                          (--all: resolved ones too; --json: JSON). "detached": its
                                          markup was removed from the text; shown from the copy kept
                                          at the end of the file
  comments add FILE --on TEXT [--nth N] BODY…   comment on TEXT (its first occurrence, or the Nth)
  comments reply FILE ID BODY…            reply to a comment (BODY - reads stdin)
  comments edit FILE ID BODY…             change a comment's text
  comments resolve FILE ID [--note TEXT]  mark a thread resolved (reopen: comments reopen FILE ID)
  comments delete FILE ID                 delete a comment (a thread goes with its replies)
  comments wait FILE [--timeout SECS]     block until the user presses Done in Umi's editor for
                                          FILE, then list its open comments (exit 124 on timeout)

Writes are signed --by NAME (default "AI", an agent). The comments live in the file: anchors like
{==the text==}{>>the comment<<}{#c1} in place, and who, when, replies and resolved state in a YAML
block at the end (Roughdraft Flavored Markdown), so reading the file shows them too.
"""

func commentsCommand(_ argv: [String]) {
    let subcommands: Set<String> = ["ls", "list", "add", "reply", "edit", "resolve", "reopen", "delete", "rm", "wait"]
    var words = argv
    let sub: String
    if let first = words.first, subcommands.contains(first) {
        sub = first
        words.removeFirst()
    } else {
        sub = "ls"
    }
    if words.first == "--help" || words.first == "-h" || argv.isEmpty {
        print(commentsHelp)
        if argv.isEmpty { exit(1) }
        return
    }
    let spec = ArgSpec(valued: ["--on", "--nth", "--by", "--note", "--timeout"], boolean: ["--all"])
    let args = parse(words, spec)
    var positional = args.positional + (args.rest ?? [])
    guard !positional.isEmpty else { fail("comments \(sub): name a file") }
    let path = realPath(absolutePath(positional.removeFirst()))
    let by = args.value("--by") ?? UmiComments.agentAuthor

    func body(_ words: [String]) -> String {
        if words == ["-"] || (words.isEmpty && isatty(STDIN_FILENO) == 0) { return readStdin() }
        guard !words.isEmpty else { fail("comments \(sub): give the text") }
        return words.joined(separator: " ")
    }
    func id(_ words: inout [String]) -> String {
        guard !words.isEmpty else { fail("comments \(sub): give a comment id (umi comments FILE lists them)") }
        return words.removeFirst()
    }

    switch sub {
    case "ls", "list":
        listComments(path, all: args.has("--all"))
    case "add":
        guard let on = args.value("--on"), !on.isEmpty else { fail("comments add: say which text with --on TEXT") }
        let nth = args.value("--nth").map { Int($0) ?? 0 } ?? 1
        guard nth >= 1 else { fail("--nth counts from 1") }
        let text = body(positional)
        change(path) { content in
            guard let range = locate(on, in: content, nth: nth) else {
                throw UmiComments.Failure("\"\(on)\" isn't in the text\(nth > 1 ? " \(nth) times" : "") (outside code and other comments)")
            }
            let result = try UmiComments.adding(text, on: range, in: content, by: by)
            return (result.text, ["id": result.id, "action": "added"])
        }
    case "reply":
        let target = id(&positional)
        let text = body(positional)
        change(path) { content in
            let result = try UmiComments.replying(to: target, text, in: content, by: by)
            return (result.text, ["id": result.id, "action": "replied", "re": target])
        }
    case "edit":
        let target = id(&positional)
        let text = body(positional)
        change(path) { content in (try UmiComments.editing(target, to: text, in: content), ["id": target, "action": "edited"]) }
    case "resolve", "reopen":
        let target = id(&positional)
        let note = args.value("--note")
        change(path) { content in
            (try UmiComments.resolving(target, sub == "resolve", note: note, in: content),
             ["id": target, "action": sub == "resolve" ? "resolved" : "reopened"])
        }
    case "delete", "rm":
        let target = id(&positional)
        change(path) { content in (try UmiComments.deleting(target, in: content), ["id": target, "action": "deleted"]) }
    case "wait":
        waitForReview(path, timeout: args.value("--timeout").map { Double($0) ?? -1 })
    default:
        fail("comments: unknown command \(sub)")
    }
}

/// Symlinks resolved, as the app names open files.
func realPath(_ path: String) -> String {
    var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
    return realpath(path, &buffer) != nil ? String(cString: buffer) : path
}

func readComments(_ path: String) -> (text: String, data: Data) {
    guard let data = FileManager.default.contents(atPath: path) else { fail("can't read \(path)") }
    var bytes = data
    if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes = bytes.dropFirst(3) }
    guard let text = String(data: bytes, encoding: .utf8) else { fail("\(path) isn't UTF-8 text") }
    return (text, data)
}

/// The Nth occurrence of `needle` in the body, outside code and review markup.
func locate(_ needle: String, in text: String, nth: Int) -> NSRange? {
    let doc = UmiComments.Document(text)
    let ns = text as NSString
    let code = UmiComments.codeRanges(doc.body)
    var from = 0
    var count = 0
    while from < doc.bodyEnd {
        let r = ns.range(of: needle, options: [], range: NSRange(location: from, length: doc.bodyEnd - from))
        guard r.location != NSNotFound else { return nil }
        from = r.location + 1
        let inMarkup = doc.anchors.contains { NSIntersectionRange($0.range, r).length > 0 && !NSEqualRanges($0.textRange, r) }
            || code.contains { NSIntersectionRange($0, r).length > 0 }
        if inMarkup { continue }
        count += 1
        if count == nth { return r }
    }
    return nil
}

/// Apply a change to the file (atomically, keeping its permissions and byte-order mark) and say
/// what happened.
func change(_ path: String, _ apply: (String) throws -> (String, [String: Any])) {
    let (text, data) = readComments(path)
    let result: (String, [String: Any])
    do {
        result = try apply(text)
    } catch let error as UmiComments.Failure {
        fail(error.message)
    } catch {
        fail("\(error)")
    }
    var out = data.starts(with: [0xEF, 0xBB, 0xBF]) ? Data([0xEF, 0xBB, 0xBF]) : Data()
    out.append(Data(result.0.utf8))
    let url = URL(fileURLWithPath: path)
    let temp = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).umi-\(getpid())")
    do {
        try out.write(to: temp)
        if let attributes = try? FileManager.default.attributesOfItem(atPath: path), let mode = attributes[.posixPermissions] {
            try? FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: temp.path)
        }
        guard rename(temp.path, path) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    } catch {
        try? FileManager.default.removeItem(at: temp)
        fail("couldn't write \(path): \(error.localizedDescription)")
    }
    var info = result.1
    info["path"] = path
    if jsonOutput {
        printJSON(info)
    } else {
        let id = info["id"] as? String ?? ""
        print("\(info["action"] as? String ?? "changed") \(id)")
    }
}

func listComments(_ path: String, all: Bool) {
    let (text, _) = readComments(path)
    let threads = UmiComments.Document(text).threads.filter { all || $0.isOpen }
    if jsonOutput {
        printJSON(["path": path, "comments": threads.map(\.json)])
        return
    }
    if threads.isEmpty {
        print(all ? "no comments" : "no open comments")
        return
    }
    func who(_ by: String) -> String { by == UmiComments.userAuthor ? "the user" : by == UmiComments.agentAuthor ? "an agent" : by }
    for (index, thread) in threads.enumerated() {
        if index > 0 { print("") }
        var head = bold(thread.id)
        if let line = thread.line { head += dim("  line \(line)") }
        head += dim("  \(who(thread.by))\(thread.at.isEmpty ? "" : ", \(thread.at)")")
        if thread.resolved { head += dim("  resolved\(thread.resolvedNote.map { ": \($0)" } ?? "")") }
        if thread.detached { head += dim("  detached (the text it was on is gone)") }
        print(head)
        if !thread.quote.isEmpty {
            print("  on: \"\(thread.quote)\"")
        } else if thread.anchorDeleted {
            print("  on: (the words it was on were deleted)")
        } else if !thread.detached {
            print("  on: (a point in the text)")
        }
        print(thread.body.split(separator: "\n", omittingEmptySubsequences: false).map { "  " + $0 }.joined(separator: "\n"))
        for reply in thread.replies {
            let lines = reply.body.split(separator: "\n", omittingEmptySubsequences: false)
            print("  ↳ \(reply.id) \(who(reply.by)): \(lines.first ?? "")")
            for line in lines.dropFirst() { print("    \(line)") }
        }
    }
}

/// Wait for the user's Done in Umi's editor (a `comments.done` event for this file).
func waitForReview(_ path: String, timeout: Double?) {
    if let timeout {
        guard timeout > 0 else { fail("--timeout takes a number of seconds") }
        signal(SIGALRM) { _ in
            let message = "umi: timed out waiting for the review\n"
            _ = message.withCString { write(STDERR_FILENO, $0, strlen($0)) }
            _exit(124)
        }
        alarm(UInt32(max(1, timeout.rounded(.up))))
    }
    let client = connect()
    // The app names the file its own way (/tmp for /private/tmp): its events use that name.
    var watched = path
    do {
        let reply = try client.call("comments.wait", ["path": path])
        if let named = (reply as? [String: Any])?["path"] as? String { watched = named }
    } catch let error as RPCError {
        fail(error.message)
    } catch {
        fail("\(error)")
    }
    while let message = client.readLine() {
        guard message["event"] as? String == "comments.done",
              let data = message["data"] as? [String: Any], data["path"] as? String == watched else { continue }
        alarm(0)
        listComments(path, all: false)
        return
    }
    fail("Umi closed the connection before the review was done")
}
