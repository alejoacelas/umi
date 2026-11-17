// umi-next comments: read and answer comments on a Markdown file (SPEC E-11) without the app.
// The page's own parser, web/comments.js (track a), runs here in JavaScriptCore, so the editor
// and the CLI read and write the markup the same way. `comments wait` needs the UI: it blocks on
// the socket until the user presses Done on the file's comments.
//
// It calls comments.js's `UmiComments` (threads, add, reply, edit, resolve, remove) through the
// small adapter below, which adds what only the CLI needs: finding the words of `--on TEXT
// [--nth N]` outside code and other comments, as Umi's CLI does. A failure (UmiComments.Failure)
// is shown as is.

import Darwin
import Foundation
import JavaScriptCore

let commentsHelp = """
umi-next comments: comments on a Markdown file, as left in Umi next's editor.

  comments [ls] FILE [--all]              open comments: id, line, the text each is on, replies
                                          (--all: resolved ones too; --json: JSON)
  comments add FILE --on TEXT [--nth N] BODY…   comment on TEXT (its first occurrence, or the Nth)
  comments reply FILE ID BODY…            reply to a comment (BODY - reads stdin)
  comments edit FILE ID BODY…             change a comment's text
  comments resolve FILE ID [--note TEXT]  mark a thread resolved (reopen: comments reopen FILE ID)
  comments delete FILE ID                 delete a comment (a thread goes with its replies)
  comments wait FILE [--timeout SECS]     block until the user presses Done in Umi next's editor
                                          for FILE, then list its open comments (exit 124 on timeout)

Writes are signed --by NAME (default "AI", an agent). The comments live in the file:
{==the text==}{>>the comment<<}{#c1} in place, and who, when, replies and resolved state in a YAML
block at the end (Roughdraft Flavored Markdown).
"""

let userAuthor = "user", agentAuthor = "AI"

/// web/comments.js in a JavaScript context of its own.
final class CommentsJS {
    let ctx = JSContext()!
    private(set) var api: JSValue!
    private var thrown: String?

    init() {
        guard let dir = webDir else { fail("can't find the web layer (no UmiNextSourceDir in the app; set UMI_NEXT_WEB_DIR)") }
        let file = dir + "/comments.js"
        guard let source = try? String(contentsOfFile: file, encoding: .utf8) else {
            fail("comments need \(abbreviateHome(file)) (PARITY track a), which isn't there")
        }
        ctx.exceptionHandler = { [weak self] _, e in self?.thrown = e?.objectForKeyedSubscript("message")?.toString() ?? e?.toString() }
        ctx.evaluateScript(source, withSourceURL: URL(fileURLWithPath: file))
        if let t = thrown { fail("\(abbreviateHome(file)): \(t)") }
        guard let c = ctx.objectForKeyedSubscript("UmiComments"), !c.isUndefined else {
            fail("\(abbreviateHome(file)) doesn't define UmiComments")
        }
        ctx.evaluateScript(Self.adapter)
        if let t = thrown { fail("the comments adapter: \(t)") }
        api = ctx.objectForKeyedSubscript("UmiCLIComments")
    }

    /// The CLI's calls, on top of comments.js.
    static let adapter = """
    var UmiCLIComments = (function (C) {
      var overlap = function (a0, a1, b0, b1) { return Math.min(a1, b1) - Math.max(a0, b0) > 0; };
      // The Nth occurrence of `needle` in the body, outside code and review markup (as Umi's CLI).
      function locate(text, needle, nth) {
        var doc = new C.Document(text), from = 0, count = 0;
        while (from < doc.bodyEnd) {
          var i = text.indexOf(needle, from), j = i + needle.length;
          if (i < 0 || j > doc.bodyEnd) return null;
          from = i + 1;
          var inMarkup = doc.anchors.some(function (a) { return overlap(a.start, a.end, i, j) && !(a.textStart === i && a.textEnd === j); })
            || doc.code.some(function (c) { return overlap(c[0], c[1], i, j); });
          if (inMarkup) continue;
          if (++count === nth) return { start: i, end: j };
        }
        return null;
      }
      return {
        list: function (text) { return C.threads(text); },
        add: function (text, o) {
          var r = locate(text, o.on, o.nth);
          if (!r) throw new C.Failure('"' + o.on + '" isn\\'t in the text' + (o.nth > 1 ? ' ' + o.nth + ' times' : '') + ' (outside code and other comments)');
          return C.add(text, o.body, r, o.by);
        },
        reply: function (text, id, body, by) { return C.reply(text, id, body, by); },
        edit: function (text, id, body) { return C.edit(text, id, body); },
        resolve: function (text, id, resolved, note) { return C.resolve(text, id, resolved, note); },
        remove: function (text, id) { return C.remove(text, id); },
      };
    })(UmiComments);
    """

    func call(_ name: String, _ args: [Any]) -> JSValue {
        guard let fn = api.objectForKeyedSubscript(name), !fn.isUndefined else { fail("no comments call \(name)") }
        thrown = nil
        let r = fn.call(withArguments: args)
        if let t = thrown { fail(t) }
        return r ?? JSValue(undefinedIn: ctx)
    }

    func text(_ v: JSValue) -> String {
        if v.isString { return v.toString() }
        if let t = v.objectForKeyedSubscript("text"), t.isString { return t.toString() }
        fail("web/comments.js returned no text")
    }
}

func commentsCommand(_ argv: [String]) {
    let subcommands: Set<String> = ["ls", "list", "add", "reply", "edit", "resolve", "reopen", "delete", "rm", "wait"]
    var words = argv
    var sub = "ls"
    if let first = words.first, subcommands.contains(first) { sub = first; words.removeFirst() }
    if argv.isEmpty || words.first == "--help" || words.first == "-h" { print(commentsHelp); if argv.isEmpty { exit(1) }; return }
    let args = parse(words, ArgSpec(valued: ["--on", "--nth", "--by", "--note", "--timeout"], boolean: ["--all"]))
    var pos = args.words
    guard !pos.isEmpty else { fail("comments \(sub): name a file") }
    let path = realPath(absolutePath(pos.removeFirst()))
    let by = args.value("--by") ?? agentAuthor

    func body(_ w: [String]) -> String {
        if w == ["-"] || (w.isEmpty && isatty(STDIN_FILENO) == 0) { return readStdin() }
        guard !w.isEmpty else { fail("comments \(sub): give the text") }
        return w.joined(separator: " ")
    }
    func id(_ w: inout [String]) -> String {
        guard !w.isEmpty else { fail("comments \(sub): give a comment id (umi-next comments FILE lists them)") }
        return w.removeFirst()
    }

    switch sub {
    case "ls", "list": listComments(path, all: args.has("--all"))
    case "add":
        guard let on = args.value("--on"), !on.isEmpty else { fail("comments add: say which text with --on TEXT") }
        let nth = args.value("--nth").map { Int($0) ?? 0 } ?? 1
        guard nth >= 1 else { fail("--nth counts from 1") }
        let text = body(pos)
        change(path) { js, content in
            let r = js.call("add", [content, ["on": on, "nth": nth, "body": text, "by": by]])
            return (js.text(r), ["id": r.objectForKeyedSubscript("id")?.toString() ?? "", "action": "added"])
        }
    case "reply":
        let target = id(&pos)
        let text = body(pos)
        change(path) { js, content in
            let r = js.call("reply", [content, target, text, by])
            return (js.text(r), ["id": r.objectForKeyedSubscript("id")?.toString() ?? "", "action": "replied", "re": target])
        }
    case "edit":
        let target = id(&pos)
        let text = body(pos)
        change(path) { js, content in (js.text(js.call("edit", [content, target, text])), ["id": target, "action": "edited"]) }
    case "resolve", "reopen":
        let target = id(&pos)
        let note: Any = args.value("--note") ?? NSNull()
        change(path) { js, content in
            (js.text(js.call("resolve", [content, target, sub == "resolve", note])),
             ["id": target, "action": sub == "resolve" ? "resolved" : "reopened"])
        }
    case "delete", "rm":
        let target = id(&pos)
        change(path) { js, content in (js.text(js.call("remove", [content, target])), ["id": target, "action": "deleted"]) }
    case "wait":
        waitForReview(path, timeout: args.value("--timeout").map { Double($0) ?? -1 })
    default:
        fail("comments: unknown command \(sub)")
    }
}

func readComments(_ path: String) -> (text: String, data: Data) {
    guard let data = FileManager.default.contents(atPath: path) else { fail("can't read \(path)") }
    var bytes = data
    if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes = bytes.dropFirst(3) }
    guard let text = String(data: bytes, encoding: .utf8) else { fail("\(path) isn't UTF-8 text") }
    return (text, data)
}

/// Applies a change to the file atomically, keeping its permissions and byte-order mark.
func change(_ path: String, _ apply: (CommentsJS, String) -> (String, [String: Any])) {
    let (text, data) = readComments(path)
    let js = CommentsJS()
    let result = apply(js, text)
    var out = data.starts(with: [0xEF, 0xBB, 0xBF]) ? Data([0xEF, 0xBB, 0xBF]) : Data()
    out.append(Data(result.0.utf8))
    let url = URL(fileURLWithPath: path)
    let temp = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).umi-next-\(getpid())")
    do {
        try out.write(to: temp)
        if let mode = (try? FileManager.default.attributesOfItem(atPath: path))?[.posixPermissions] {
            try? FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: temp.path)
        }
        guard rename(temp.path, path) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    } catch {
        try? FileManager.default.removeItem(at: temp)
        fail("couldn't write \(path): \(error.localizedDescription)")
    }
    var info = result.1
    info["path"] = path
    if jsonOutput { printJSON(info) } else { print("\(info["action"] as? String ?? "changed") \(info["id"] as? String ?? "")") }
}

func listComments(_ path: String, all: Bool) {
    let (text, _) = readComments(path)
    let js = CommentsJS()
    let threads = (js.call("list", [text]).toArray() as? [[String: Any]] ?? []).filter { all || ($0["status"] as? String) != "resolved" }
    if jsonOutput { printJSON(["path": path, "comments": threads]); return }
    if threads.isEmpty { print(all ? "no comments" : "no open comments"); return }
    func who(_ by: String) -> String { by == userAuthor ? "the user" : by == agentAuthor ? "an agent" : by }
    for (i, t) in threads.enumerated() {
        if i > 0 { print("") }
        var head = bold(t["id"] as? String ?? "?")
        if let line = t["line"] as? Int { head += dim("  line \(line)") }
        let at = t["at"] as? String ?? ""
        head += dim("  \(who(t["by"] as? String ?? ""))\(at.isEmpty ? "" : ", \(at)")")
        if t["status"] as? String == "resolved" { head += dim("  resolved\((t["resolved_note"] as? String).map { ": \($0)" } ?? "")") }
        if t["detached"] as? Bool == true { head += dim("  detached (the text it was on is gone)") }
        print(head)
        let quote = t["quote"] as? String ?? ""
        if !quote.isEmpty { print("  on: \"\(quote)\"") }
        else if t["anchor_deleted"] as? Bool == true { print("  on: (the words it was on were deleted)") }
        else if t["detached"] as? Bool != true { print("  on: (a point in the text)") }
        print((t["body"] as? String ?? "").split(separator: "\n", omittingEmptySubsequences: false).map { "  " + $0 }.joined(separator: "\n"))
        for r in t["replies"] as? [[String: Any]] ?? [] {
            let lines = (r["body"] as? String ?? "").split(separator: "\n", omittingEmptySubsequences: false)
            print("  ↳ \(r["id"] ?? "") \(who(r["by"] as? String ?? "")): \(lines.first ?? "")")
            for l in lines.dropFirst() { print("    \(l)") }
        }
    }
}

/// Blocks until the user presses Done on the file's comments in the editor (the page answers
/// the request then), and lists its open comments.
func waitForReview(_ path: String, timeout: Double?) {
    if let timeout {
        guard timeout > 0 else { fail("--timeout takes a number of seconds") }
        signal(SIGALRM) { _ in
            let m = "umi-next: timed out waiting for the review\n"
            _ = m.withCString { write(STDERR_FILENO, $0, strlen($0)) }
            _exit(124)
        }
        alarm(UInt32(max(1, timeout.rounded(.up))))
    }
    ui("comments.wait", ["path": path])
    alarm(0)
    listComments(path, all: false)
}
