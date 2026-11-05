import AppKit
import Combine
import SwiftUI

/// Global search (Warp parity 2026-11-05): the sidebar's Search mode, opened with ⇧⌘F (or ⌃3).
/// It searches the files of the focused pane's repository (its git root, else its folder) with
/// `git grep`, which skips what git ignores, and lists the matching lines grouped by file. As in
/// Warp: case-insensitive unless the case toggle is on, literal unless the regex toggle is on,
/// 300 ms after typing stops, at most 20,000 matches. ↓ moves from the query into the results,
/// ↑ on the first result goes back, ← / → collapse and expand a file, Enter opens the file at the
/// line (or folds a file's results).
@MainActor
final class UmiGlobalSearchModel: ObservableObject {
    struct Match: Equatable {
        let line: Int
        let column: Int
        let text: String
    }

    struct FileResult: Equatable {
        let path: String
        var matches: [Match]
    }

    /// A file's header or one of its matches. Rows carry what they show, so a view drawn from a
    /// row that just went away never looks into `files`.
    struct Row: Identifiable, Equatable {
        let id: String
        let path: String
        /// nil for the file's header row.
        let match: Match?
        /// The file's match count.
        let count: Int
    }

    enum Focus: String { case none, query, results }

    static let maxMatches = 20000
    static let debounce: TimeInterval = 0.3

    @Published var query = "" {
        didSet { if query != oldValue { scheduleSearch() } }
    }
    @Published var caseSensitive = false {
        didSet { if caseSensitive != oldValue { search() } }
    }
    @Published var regex = false {
        didSet { if regex != oldValue { search() } }
    }
    @Published private(set) var files: [FileResult] = []
    @Published private(set) var collapsed: Set<String> = []
    @Published private(set) var rows: [Row] = []
    @Published private(set) var selected: String?
    @Published private(set) var searching = false
    @Published private(set) var capped = false
    @Published private(set) var error: String?
    @Published private(set) var searched: String?
    @Published private(set) var root: String?
    /// Bumped to give the query field focus.
    @Published private(set) var queryFocusTick = 0
    /// Bumped to scroll the selected row into view.
    @Published private(set) var scrollTick = 0
    @Published private(set) var resultsFocusTick = 0
    var pendingResultsFocus = false
    weak var resultsKeyView: NSView?
    weak var queryField: UmiTextInputField?
    var pendingQueryFocus = false

    private weak var controller: TerminalController?
    private var debounceWork: DispatchWorkItem?
    private var process: Process?
    private var generation = 0

    // MARK: One model per window

    private static var models: [ObjectIdentifier: UmiGlobalSearchModel] = [:]

    static func model(for controller: TerminalController) -> UmiGlobalSearchModel {
        models = models.filter { $0.value.controller != nil }
        if let model = models[ObjectIdentifier(controller)] { return model }
        let model = UmiGlobalSearchModel()
        model.controller = controller
        models[ObjectIdentifier(controller)] = model
        return model
    }

    static func existing(for controller: TerminalController) -> UmiGlobalSearchModel? {
        models[ObjectIdentifier(controller)]
    }

    // MARK: Where to search

    var focusedPane: Ghostty.SurfaceView? {
        guard let controller, !controller.tabs.isEmpty else { return nil }
        return controller.focusedSurface ?? controller.selectedTab.effectiveFocusedSurface
    }

    func updateRoot() {
        guard let pane = focusedPane else { return }
        let pwd = UmiTopology.cwd(of: pane)
        guard !pwd.isEmpty else { return }
        let path = UmiFileTreeModel.projectRoot(for: URL(fileURLWithPath: pwd)).path
        if path != root {
            root = path
            if !query.isEmpty { search() }
        }
    }

    // MARK: Searching

    private func scheduleSearch() {
        debounceWork?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.search() } }
        debounceWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.debounce, execute: work)
    }

    /// Run the search now (the toggles, and the debounced query).
    func search() {
        debounceWork?.cancel()
        if let running = process, running.isRunning { running.terminate() }
        process = nil
        generation &+= 1
        let generation = generation
        updateRoot()
        let pattern = query
        guard !pattern.isEmpty, let root else {
            files = []
            searched = nil
            searching = false
            capped = false
            error = nil
            rebuild()
            return
        }
        searching = true
        error = nil
        var args = ["-C", root, "grep", "-n", "--column", "-I", "-z", "--no-color"]
        if FileManager.default.fileExists(atPath: root + "/.git") {
            args.append("--untracked")
        } else {
            args.append("--no-index")
        }
        if !caseSensitive { args.append("-i") }
        args.append(regex ? "-E" : "-F")
        args += ["-e", pattern]
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        self.process = process
        let limit = Self.maxMatches
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var found: [FileResult] = []
            var count = 0
            var hitLimit = false
            var failure: String?
            do {
                try process.run()
                let handle = out.fileHandleForReading
                var buffer = Data()
                reading: while true {
                    let chunk = handle.availableData
                    if chunk.isEmpty { break }
                    buffer.append(chunk)
                    while let newline = buffer.firstIndex(of: 0x0A) {
                        let line = buffer[buffer.startIndex..<newline]
                        buffer.removeSubrange(buffer.startIndex...newline)
                        guard let parsed = Self.parse(line) else { continue }
                        if found.last?.path == parsed.path {
                            found[found.count - 1].matches.append(parsed.match)
                        } else {
                            found.append(FileResult(path: parsed.path, matches: [parsed.match]))
                        }
                        count += 1
                        if count >= limit {
                            hitLimit = true
                            process.terminate()
                            break reading
                        }
                    }
                }
                process.waitUntilExit()
                // git grep exits 1 when nothing matches; 128 and up is an error (a bad regex).
                if !hitLimit, process.terminationStatus > 1 {
                    let message = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    failure = message.isEmpty ? "The search failed." : message
                }
            } catch {
                failure = "Couldn't run git: \(error.localizedDescription)"
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.generation == generation else { return }
                    self.process = nil
                    self.files = found
                    self.capped = hitLimit
                    self.error = failure
                    self.searching = false
                    self.searched = pattern
                    self.collapsed = []
                    self.rebuild()
                    if let first = self.rows.first, self.focus == .results, self.selected == nil {
                        self.select(first.id)
                    }
                }
            }
        }
    }

    /// One `git grep -z -n --column` line: path NUL line NUL column NUL text.
    nonisolated static func parse(_ data: Data) -> (path: String, match: Match)? {
        let parts = data.split(separator: 0, maxSplits: 3, omittingEmptySubsequences: false)
        guard parts.count == 4,
              let line = Int(String(decoding: parts[1], as: UTF8.self)),
              let column = Int(String(decoding: parts[2], as: UTF8.self)) else { return nil }
        return (String(decoding: parts[0], as: UTF8.self),
                Match(line: line, column: column, text: String(decoding: parts[3], as: UTF8.self)))
    }

    var matchCount: Int { files.reduce(0) { $0 + $1.matches.count } }

    /// The line under the query, as Warp words it.
    var message: String? {
        if let error { return error }
        guard searched != nil || searching else { return nil }
        let count = matchCount
        if searching && count == 0 { return "Searching…" }
        if count == 0 { return "No results found. Review your gitignore files." }
        let fileWord = files.count == 1 ? "file" : "files"
        return count == 1 ? "1 result in \(files.count) \(fileWord)" : "\(count) results in \(files.count) \(fileWord)"
    }

    static let cappedMessage = "The result set only contains a subset of all matches. Be more specific in your search to narrow down results."

    // MARK: Rows and selection

    private func rebuild() {
        var out: [Row] = []
        for file in files {
            out.append(Row(id: file.path, path: file.path, match: nil, count: file.matches.count))
            guard !collapsed.contains(file.path) else { continue }
            for (m, match) in file.matches.enumerated() {
                out.append(Row(id: "\(file.path)\u{0}\(m)", path: file.path, match: match, count: file.matches.count))
            }
        }
        rows = out
        if let selected, !out.contains(where: { $0.id == selected }) { self.selected = nil }
    }

    var selectedRow: Row? { rows.first { $0.id == selected } }

    func select(_ id: String?) {
        selected = id
        scrollTick &+= 1
    }

    var focus: Focus {
        if queryField?.isEditingNow == true { return .query }
        if let view = resultsKeyView, view.window?.firstResponder === view { return .results }
        return .none
    }

    func focusQuery() {
        if let field = queryField, let window = field.window {
            window.makeFirstResponder(field)
            field.currentEditor()?.selectAll(nil)
        } else {
            pendingQueryFocus = true
            queryFocusTick &+= 1
        }
    }

    func focusResults() {
        guard !rows.isEmpty else { return }
        if selectedRow == nil { select(rows[0].id) }
        if let view = resultsKeyView, let window = view.window {
            window.makeFirstResponder(view)
        } else {
            pendingResultsFocus = true
            resultsFocusTick &+= 1
        }
    }

    /// A key in the query field.
    func queryKey(_ key: UmiTextInput.Key) -> Bool {
        switch key {
        case .down:
            focusResults()
            return true
        case .enter:
            if debounceWork != nil { search() }
            focusResults()
            return true
        case .escape:
            focusPane()
            return true
        case .up:
            return false
        }
    }

    /// A key while the results have focus.
    func resultsKey(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return false }
        let index = rows.firstIndex { $0.id == selected }
        switch event.keyCode {
        case 126:
            if index == nil || index == 0 { selected = nil; focusQuery() } else { select(rows[index! - 1].id) }
        case 125:
            if let index { select(rows[min(rows.count - 1, index + 1)].id) } else if let first = rows.first { select(first.id) }
        case 123: setCollapsed(true)
        case 124: setCollapsed(false)
        case 36, 76: activateSelected()
        case 53: focusPane()
        default: return false
        }
        return true
    }

    private func setCollapsed(_ collapse: Bool) {
        guard let row = selectedRow, row.match == nil else { return }
        let path = row.path
        if collapse { collapsed.insert(path) } else { collapsed.remove(path) }
        rebuild()
    }

    func activateSelected() {
        guard let row = selectedRow else { return }
        activate(row)
    }

    func activate(_ row: Row) {
        select(row.id)
        guard let match = row.match else {
            setCollapsed(!collapsed.contains(row.path))
            return
        }
        open(row.path, line: match.line)
    }

    /// Open the file at the line, beside the focused pane (E-9), in source view.
    func open(_ relative: String, line: Int) {
        guard let root, let anchor = focusedPane else { return }
        let url = URL(fileURLWithPath: root).appendingPathComponent(relative)
        do {
            try UmiTextFile.checkOpenable(url)
            let doc = try UmiFilePanes.open(url, mode: .source, near: anchor, focus: true).doc
            doc.revealLine = line
        } catch let error as UmiError {
            let alert = NSAlert()
            alert.messageText = "Can't open \(url.lastPathComponent)"
            alert.informativeText = error.message
            if let window = controller?.window { alert.beginSheetModal(for: window) } else { alert.runModal() }
        } catch {}
    }

    func focusPane() {
        guard let pane = focusedPane else { return }
        UmiLayout.focusPane(pane, activate: true)
        pane.window?.makeFirstResponder(pane)
    }

    /// The line as shown: long lines start a little before the match, as in Warp.
    static func snippet(_ text: String, query: String, caseSensitive: Bool, regex: Bool) -> (text: String, ranges: [Range<String.Index>]) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        var shown = trimmed
        var ranges = matchRanges(in: shown, query: query, caseSensitive: caseSensitive, regex: regex)
        if let first = ranges.first, shown.distance(from: shown.startIndex, to: first.lowerBound) > 40 {
            let start = shown.index(first.lowerBound, offsetBy: -15)
            shown = "…" + shown[start...]
            ranges = matchRanges(in: shown, query: query, caseSensitive: caseSensitive, regex: regex)
        }
        if shown.count > 200 {
            shown = String(shown.prefix(200)) + "…"
            ranges = matchRanges(in: shown, query: query, caseSensitive: caseSensitive, regex: regex)
        }
        return (shown, ranges)
    }

    static func matchRanges(in text: String, query: String, caseSensitive: Bool, regex: Bool) -> [Range<String.Index>] {
        guard !query.isEmpty else { return [] }
        if regex {
            guard let expression = try? NSRegularExpression(pattern: query, options: caseSensitive ? [] : [.caseInsensitive]) else { return [] }
            return expression.matches(in: text, range: NSRange(text.startIndex..., in: text))
                .compactMap { Range($0.range, in: text) }
                .filter { !$0.isEmpty }
        }
        var out: [Range<String.Index>] = []
        var from = text.startIndex
        let options: String.CompareOptions = caseSensitive ? [] : [.caseInsensitive]
        while from < text.endIndex, let range = text.range(of: query, options: options, range: from..<text.endIndex) {
            out.append(range)
            from = range.upperBound
        }
        return out
    }

    // MARK: Tests (`debug.ui.search`)

    func json() -> [String: Any] {
        [
            "query": query, "case_sensitive": caseSensitive, "regex": regex, "root": root ?? "",
            "searching": searching, "capped": capped, "message": message ?? "", "focus": focus.rawValue,
            "selected": selected.map { id in rows.first { $0.id == id }.map(rowJSON) ?? [:] } ?? NSNull(),
            "files": files.map { ["path": $0.path, "matches": $0.matches.map { ["line": $0.line, "column": $0.column, "text": $0.text] }] },
            "rows": rows.map(rowJSON),
        ]
    }

    private func rowJSON(_ row: Row) -> [String: Any] {
        var json: [String: Any] = ["path": row.path, "kind": row.match == nil ? "file" : "match",
                                   "selected": row.id == selected, "collapsed": collapsed.contains(row.path)]
        if let match = row.match {
            json["line"] = match.line
            json["text"] = match.text
        } else {
            json["count"] = row.count
        }
        return json
    }
}

// MARK: - View

struct UmiGlobalSearchView: View {
    @ObservedObject var model: UmiGlobalSearchModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Search")
                .font(.system(size: 14))
                .foregroundColor(UmiFileTreeStyle.ink.opacity(0.6))
                .padding(.horizontal, 8)
            queryRow
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            if let message = model.message {
                Text(message)
                    .font(.system(size: 12))
                    .foregroundColor(UmiFileTreeStyle.ink.opacity(0.4))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 4)
                    .accessibilityLabel("Search Summary")
                    .accessibilityValue(message)
            }
            if model.capped {
                HStack(alignment: .top, spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundColor(Color(red: 0xfe / 255, green: 0xfd / 255, blue: 0xc2 / 255))
                    Text(UmiGlobalSearchModel.cappedMessage)
                        .font(.system(size: 12))
                        .foregroundColor(UmiFileTreeStyle.ink.opacity(0.6))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 4)
            }
            ScrollViewReader { proxy in
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(model.rows) { row in
                        UmiSearchRow(model: model, row: row).id(row.id)
                    }
                }
                .onChange(of: model.scrollTick) { _ in
                    guard let id = model.selected else { return }
                    proxy.scrollTo(id)
                }
            }
            .background(UmiSearchKeyCatcher(model: model))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Search Results")
        }
        .onAppear { model.updateRoot() }
    }

    private var queryRow: some View {
        HStack(spacing: 2) {
            let _ = model.queryFocusTick
            UmiTextInput(text: $model.query, placeholder: "Search in files", fontSize: 14,
                         claimFocus: { [weak model] in
                             guard let model, model.pendingQueryFocus else { return false }
                             model.pendingQueryFocus = false
                             return true
                         },
                         accessibilityLabel: "Search in files",
                         onKey: { model.queryKey($0) },
                         onMake: { [weak model] field in model?.queryField = field })
                .frame(minHeight: 18)
            toggle("textformat", help: "Toggle Case Sensitivity", on: model.caseSensitive) { model.caseSensitive.toggle() }
            toggle("chevron.left.forwardslash.chevron.right", help: "Toggle Regex", on: model.regex) { model.regex.toggle() }
        }
        .padding(6)
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(UmiFileTreeStyle.ink.opacity(0.15), lineWidth: 1))
    }

    private func toggle(_ symbol: String, help: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 20, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(UmiIconButtonStyle(active: on, size: 18))
        .help(help)
        .accessibilityLabel(help)
        .accessibilityValue(on ? "on" : "off")
    }
}

private struct UmiSearchRow: View {
    @ObservedObject var model: UmiGlobalSearchModel
    let row: UmiGlobalSearchModel.Row
    @State private var hovering = false

    var body: some View {
        let selected = model.selected == row.id
        let color = UmiFileTreeStyle.text(selected: selected, hovering: hovering)
        let path = row.path
        Group {
            if let match = row.match {
                matchText(match.text, color: color)
                    .padding(.leading, 32)
                    .padding(.trailing, 12)
                    .padding(.vertical, 4)
            } else {
                HStack(spacing: 0) {
                    Image(systemName: model.collapsed.contains(path) ? "chevron.right" : "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(color)
                        .frame(width: 16, height: 16)
                        .padding(.trailing, 8)
                    UmiFileIcon(url: URL(fileURLWithPath: path), size: 16, tint: color)
                        .padding(.trailing, 8)
                    Text((path as NSString).lastPathComponent)
                        .font(.system(size: 14))
                        .foregroundColor(color)
                        .lineLimit(1)
                        .layoutPriority(1)
                    let folder = (path as NSString).deletingLastPathComponent
                    if !folder.isEmpty {
                        Text(folder)
                            .font(.system(size: 12))
                            .foregroundColor(UmiFileTreeStyle.ink.opacity(0.4))
                            .lineLimit(1)
                            .truncationMode(.head)
                            .padding(.leading, 6)
                    }
                    Spacer(minLength: 6)
                    Text("\(row.count)")
                        .font(.system(size: 12))
                        .foregroundColor(.black)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(RoundedRectangle(cornerRadius: 4)
                            .fill(Color(red: 0xfe / 255, green: 0xfd / 255, blue: 0xc2 / 255)))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 4).fill(UmiFileTreeStyle.fill(selected: selected, hovering: hovering)))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture {
            model.focusResults()
            model.activate(row)
        }
        .help(row.match.map { "\(path):\($0.line)" } ?? path)
        .accessibilityElement(children: .combine)
    }

    private func matchText(_ line: String, color: Color) -> some View {
        let (shown, ranges) = UmiGlobalSearchModel.snippet(line, query: model.searched ?? model.query,
                                                          caseSensitive: model.caseSensitive, regex: model.regex)
        var attributed = AttributedString(shown)
        attributed.foregroundColor = color
        for range in ranges {
            guard let lower = AttributedString.Index(range.lowerBound, within: attributed),
                  let upper = AttributedString.Index(range.upperBound, within: attributed) else { continue }
            attributed[lower..<upper].backgroundColor = Color(red: 0xfe / 255, green: 0xfd / 255, blue: 0xc2 / 255).opacity(0.5)
        }
        return Text(attributed)
            .font(.system(size: 14))
            .lineLimit(1)
    }
}

/// The invisible view that takes keyboard focus for the results list.
private struct UmiSearchKeyCatcher: NSViewRepresentable {
    @ObservedObject var model: UmiGlobalSearchModel

    func makeNSView(context: Context) -> UmiKeyCatcherView {
        let view = UmiKeyCatcherView()
        model.resultsKeyView = view
        return view
    }

    func updateNSView(_ view: UmiKeyCatcherView, context: Context) {
        _ = model.resultsFocusTick
        model.resultsKeyView = view
        view.onKey = { [weak model] event in model?.resultsKey(event) ?? false }
        view.wantsFocus = { [weak model] in
            guard let model, model.pendingResultsFocus else { return false }
            model.pendingResultsFocus = false
            return true
        }
        view.takeFocusIfWanted()
    }
}
