import Foundation

// `focus-log --by session|folder|pane`: the stretches summed into groups, with the shape of the
// span (total, first and last focus, breaks of 30 minutes or more). Built here from the stretches
// the app returns, so scripts get totals without knowing how a stretch says what the pane showed
// (design/cli.md, "Attributes and logs").

let focusGroupings = ["session", "folder", "pane"]
let focusBreak: Double = 30 * 60

private let isoOut: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()

private func iso(_ ts: Double) -> String { isoOut.string(from: Date(timeIntervalSince1970: ts)) }

/// A terminal title without the status glyph agents put in front of it ("✳ Fix the build" → "Fix the build").
func plainTitle(_ title: String) -> String {
    let keep = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "~/.…([\"'`"))
    var scalars = Substring.UnicodeScalarView(title.unicodeScalars)
    while let first = scalars.first, !keep.contains(first) { scalars.removeFirst() }
    return String(scalars).trimmingCharacters(in: .whitespaces)
}

private struct Clipped {
    let stretch: [String: Any]
    let start: Double
    let end: Double
    var seconds: Double { max(0, end - start) }
    var pane: String { stretch["pane"] as? String ?? "" }
    var agent: [String: Any]? { stretch["agent"] as? [String: Any] }
    var session: String? { agent?["session"] as? String }
    var title: String { plainTitle(stretch["title"] as? String ?? "") }
    var cwd: String { stretch["cwd"] as? String ?? "" }
    var attributes: [String: Any] { stretch["attributes"] as? [String: Any] ?? [:] }
}

private struct Group {
    var key: String
    var kind: String
    var seconds: Double = 0
    var first: Double = .infinity
    var last: Double = 0
    var count = 0
    var cwd = ""
    var titleSeconds: [String: Double] = [:]
    var agent: [String: Any]?
    var summary: String?
    var file: String?
    var url: String?
    var panes: [String] = []
}

func focusGroups(_ stretches: [[String: Any]], by: String, since: Double?, until: Double?) -> [String: Any] {
    let clipped: [Clipped] = stretches.compactMap { stretch in
        var start = stretch["start_ts"] as? Double ?? 0
        var end = stretch["end_ts"] as? Double ?? start
        if let since { start = max(start, since) }
        if let until { end = min(end, until) }
        return end > start ? Clipped(stretch: stretch, start: start, end: end) : nil
    }

    // A pane loses its agent for a moment now and then (between hook reports); a stretch on that
    // pane whose title is the session's title still belongs to the session.
    var sessionByTitle: [String: String] = [:]  // "pane\ttitle" → session
    for c in clipped { if let s = c.session, !c.title.isEmpty { sessionByTitle["\(c.pane)\t\(c.title)"] = s } }

    var groups: [String: Group] = [:]
    var order: [String] = []
    for c in clipped {
        let session = c.session ?? sessionByTitle["\(c.pane)\t\(c.title)"]
        let file = c.stretch["file"] as? String
        let url = c.stretch["url"] as? String
        let key: String, kind: String
        switch by {
        case "pane":
            key = "pane:\(c.pane)"; kind = "pane"
        case "folder":
            key = "folder:\(c.cwd)"; kind = "folder"
        default:
            if let session { key = "session:\(session)"; kind = "session" }
            else if let file { key = "file:\(file)"; kind = "file" }
            else if let url { key = "web:\(url)"; kind = "web" }
            else { key = "folder:\(c.cwd)"; kind = "terminal" }
        }
        if groups[key] == nil { groups[key] = Group(key: key, kind: kind); order.append(key) }
        var g = groups[key]!
        g.seconds += c.seconds
        g.first = min(g.first, c.start)
        g.last = max(g.last, c.end)
        g.count += 1
        if !c.cwd.isEmpty { g.cwd = c.cwd }
        if !g.panes.contains(c.pane) { g.panes.append(c.pane) }
        if let file { g.file = file }
        if let url { g.url = url }
        if let agent = c.agent {
            // Only titles shown while the agent ran name the session; others are the shell's.
            if !c.title.isEmpty { g.titleSeconds[c.title, default: 0] += c.seconds }
            var info: [String: Any] = ["kind": agent["kind"] ?? ""]
            if let s = agent["session"] { info["session"] = s }
            if let prompt = agent["title"] as? String, !prompt.isEmpty { info["prompt"] = prompt }
            g.agent = info
        } else if session == nil, !c.title.isEmpty {
            g.titleSeconds[c.title, default: 0] += c.seconds
        }
        if let summary = c.attributes["agent.summary"] as? String, !summary.isEmpty { g.summary = summary }
        groups[key] = g
    }

    let out: [[String: Any]] = order.compactMap { groups[$0] }.sorted { $0.seconds > $1.seconds }.map { g in
        var label = g.titleSeconds.max { $0.value < $1.value }?.key ?? ""
        if let file = g.file, g.kind == "file" { label = (file as NSString).lastPathComponent }
        if label.isEmpty { label = g.agent?["prompt"] as? String ?? "" }
        if label.isEmpty { label = abbreviateHome(g.cwd) }
        var item: [String: Any] = ["key": g.key, "kind": g.kind, "label": label,
                                   "seconds": Int(g.seconds.rounded()),
                                   "first": iso(g.first), "last": iso(g.last),
                                   "stretches": g.count, "cwd": g.cwd, "panes": g.panes]
        if let agent = g.agent { item["agent"] = agent }
        if let summary = g.summary { item["summary"] = summary }
        if let file = g.file { item["file"] = file }
        if let url = g.url { item["url"] = url }
        return item
    }

    // The span's shape: merged focus intervals, and the gaps between them.
    var breaks: [[String: Any]] = []
    var reach: Double?
    for c in clipped.sorted(by: { $0.start < $1.start }) {
        if let r = reach, c.start - r >= focusBreak {
            breaks.append(["start": iso(r), "end": iso(c.start), "seconds": Int((c.start - r).rounded())])
        }
        reach = max(reach ?? c.end, c.end)
    }
    var result: [String: Any] = ["by": by, "groups": out, "breaks": breaks,
                                 "total_seconds": Int(clipped.reduce(0) { $0 + $1.seconds }.rounded())]
    if let first = clipped.map(\.start).min(), let last = clipped.map(\.end).max() {
        result["first"] = iso(first)
        result["last"] = iso(last)
    }
    return result
}

private func duration(_ seconds: Double) -> String {
    let minutes = Int((seconds / 60).rounded())
    return minutes >= 60 ? "\(minutes / 60)h\(String(format: "%02d", minutes % 60))m" : "\(minutes)m"
}

private func clock(_ iso: Any?) -> String {
    guard let text = iso as? String, let date = isoOut.date(from: text) else { return "?" }
    let out = DateFormatter()
    out.dateFormat = Calendar.current.isDateInToday(date) ? "HH:mm" : "MMM d HH:mm"
    return out.string(from: date)
}

func printFocusGroups(_ result: [String: Any]) {
    guard result["first"] != nil else { print("No focus in that span."); return }
    var head = "\(duration(Double(result["total_seconds"] as? Int ?? 0))) focused, \(clock(result["first"]))–\(clock(result["last"]))"
    let breaks = result["breaks"] as? [[String: Any]] ?? []
    if !breaks.isEmpty {
        head += "; breaks " + breaks.map { "\(clock($0["start"]))–\(clock($0["end"]))" }.joined(separator: ", ")
    }
    print(bold(head))
    for g in result["groups"] as? [[String: Any]] ?? [] {
        let seconds = Double(g["seconds"] as? Int ?? 0)
        let kind = (g["agent"] as? [String: Any])?["kind"] as? String ?? g["kind"] as? String ?? ""
        print("\(duration(seconds).padding(toLength: 7, withPad: " ", startingAt: 0))\(kind.padding(toLength: 9, withPad: " ", startingAt: 0))"
              + "\(g["label"] as? String ?? "")  \(dim(abbreviateHome(g["cwd"] as? String ?? "") + "  " + clock(g["first"]) + "–" + clock(g["last"])))")
        if let summary = g["summary"] as? String {
            print(dim("                \(summary.split(separator: "\n").first.map(String.init) ?? "")"))
        }
    }
}
