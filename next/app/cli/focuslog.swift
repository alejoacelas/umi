// umi-next focus-log: the stretches of keyboard focus the app wrote to <state>/logs/focus/
// (Sources/UmiNext/FocusLog.swift; the format Umi writes, so the `day` skill reads either), plus
// the stretch going on now, from the running app. `--by` sums them with Umi's own code
// (app/macos/UmiCLI/focusgroups.swift).

import Foundation

func focusLogCommand(_ argv: [String]) {
    let args = parse(argv, ArgSpec(valued: ["--since", "--until", "--pane", "--by"]))
    let since = args.value("--since").map(parseTime)
    let until = args.value("--until").map(parseTime)
    if let by = args.value("--by"), !focusGroupings.contains(by) { fail("--by takes session, folder or pane") }
    let folder = stateDir + "/logs/focus"
    let day = DateFormatter()
    day.locale = Locale(identifier: "en_US_POSIX")
    day.dateFormat = "yyyy-MM-dd"
    let first = since.map { day.string(from: $0.addingTimeInterval(-86_400)) }
    let last = until.map { day.string(from: $0) }
    var all: [[String: Any]] = []
    for file in ((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []).sorted() where file.hasSuffix(".jsonl") {
        let d = String(file.dropLast(6))
        if let first, d < first { continue }
        if let last, d > last { continue }
        guard let data = FileManager.default.contents(atPath: folder + "/" + file) else { continue }
        for line in data.split(separator: 0x0A) where !line.isEmpty {
            if let r = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] { all.append(r) }
        }
    }
    // The stretch going on now, when the app runs.
    if let fd = connectSocket(uiSocket) {
        close(fd)
        if let open = (ui("native.focusOpen") as? [String: Any])?["stretch"] as? [String: Any] { all.append(open) }
    }
    let stretches = all.filter { s in
        let start = s["start_ts"] as? Double ?? 0, end = s["end_ts"] as? Double ?? 0
        if let since, end < since.timeIntervalSince1970 { return false }
        if let until, start > until.timeIntervalSince1970 { return false }
        if let p = args.value("--pane") {
            return (s["pane"] as? String)?.hasPrefix(p) == true || (s["session"] as? String) == p
        }
        return true
    }.sorted { ($0["start_ts"] as? Double ?? 0) < ($1["start_ts"] as? Double ?? 0) }

    if let by = args.value("--by") {
        let r = focusGroups(stretches, by: by, since: since?.timeIntervalSince1970, until: until?.timeIntervalSince1970)
        if jsonOutput { printJSON(r) } else { printFocusGroups(r) }
        return
    }
    if jsonOutput { printJSON(["stretches": stretches]); return }
    if stretches.isEmpty { print("No focus in that span."); return }
    for s in stretches {
        let secs = Int((s["seconds"] as? Double ?? 0).rounded())
        let what = (s["file"] as? String).map(abbreviateHome) ?? (s["title"] as? String ?? "")
        print("\(s["start"] as? String ?? "")  \(String(format: "%5ds", secs))  \(s["kind"] as? String ?? "")  \(what)"
              + dim("  \(abbreviateHome(s["cwd"] as? String ?? ""))") + (s["open"] as? Bool == true ? "  (now)" : ""))
    }
}
