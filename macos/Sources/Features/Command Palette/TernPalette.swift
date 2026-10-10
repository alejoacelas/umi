import AppKit
import SwiftUI

/// Tern's palette, over a window. Three lists:
/// - **Commands (⌘P, L-14):** the CLI's commands, built at runtime from `tern help --json`
///   (so the palette follows the CLI as it changes) and run through the bundled CLI in the
///   context of the focused pane, asking for arguments a command needs; plus Tern's menu
///   actions, managed sessions and Ghostty's actions.
/// - **Panes (⇧⌘P, L-15):** every pane in every window, most recently used first, each with
///   its own title.
/// - **Files (⌘O, L-16):** a quick search over the focused pane's repository.
@MainActor
final class TernPaletteModel: ObservableObject {
    enum Mode: String { case commands, panes, files }
    enum Step: Equatable { case list, ask, running, output }

    @Published private(set) var isPresented = false
    @Published private(set) var mode: Mode = .commands
    @Published private(set) var step: Step = .list
    @Published var query = "" {
        didSet { if query != oldValue { refresh() } }
    }
    @Published var selection = 0
    @Published private(set) var entries: [TernPaletteEntry] = []
    /// The question asked while collecting an argument.
    @Published private(set) var prompt: String?
    /// A command's output, shown after it ran.
    @Published private(set) var output: (title: String, text: String, failed: Bool)?
    /// What's in progress ("Running tern ls…", "Indexing files…").
    @Published private(set) var busy: String?

    private weak var window: TerminalController?
    /// The pane the palette acts for: the focused one when it opened.
    private(set) weak var pane: Ghostty.SurfaceView?
    private weak var previousResponder: NSResponder?

    /// Everything the current list filters, built when the list opens.
    private var base: [TernPaletteEntry] = []
    /// A CLI action whose arguments are being asked, and the answers so far.
    private var pending: (action: TernCLICatalog.Action, answers: [String])?
    private var process: Process?
    private var files: TernFileIndex?
    private var filesTask: Task<Void, Never>?

    // MARK: Opening and closing

    /// Open (or close, if it shows that list already) the palette over the current window.
    static func present(_ mode: Mode) {
        guard let window = TernTopology.currentWindow else {
            NSSound.beep()
            return
        }
        window.window?.makeKeyAndOrderFront(nil)
        window.palette.toggle(mode, in: window)
    }

    func toggle(_ mode: Mode, in window: TerminalController) {
        if isPresented && self.mode == mode && step == .list {
            close()
            return
        }
        open(mode, in: window)
    }

    func open(_ mode: Mode, in window: TerminalController) {
        cancelRun()
        if !isPresented {
            previousResponder = window.window?.firstResponder
            pane = TernTopology.currentWindow === window ? TernTopology.currentPane : window.focusedSurface
            pane = pane ?? window.selectedTab.effectiveFocusedSurface
        }
        self.window = window
        self.mode = mode
        step = .list
        pending = nil
        prompt = nil
        output = nil
        busy = nil
        base = []
        query = ""
        buildBase()
        refresh()
        isPresented = true
        TernEvents.shared.emit("palette.opened", ["mode": mode.rawValue, "window": window.ternIDString])
    }

    func close(restoreFocus: Bool = true) {
        guard isPresented else { return }
        isPresented = false
        filesTask?.cancel()
        pending = nil
        step = .list
        guard restoreFocus, let window = window?.window else { return }
        let previous = previousResponder
        DispatchQueue.main.async {
            // Focus goes back where it was, unless the action put it somewhere else.
            let current = window.firstResponder
            let fieldEditor = window.fieldEditor(false, for: nil)
            let lost = current == nil || current === window || (fieldEditor != nil && current === fieldEditor)
            guard lost else { return }
            if let view = previous as? NSView, view.window === window, view !== fieldEditor {
                window.makeFirstResponder(view)
            } else if let pane = self.pane, pane.window === window {
                Ghostty.moveFocus(to: pane)
            }
        }
    }

    // MARK: Lists

    private func buildBase() {
        switch mode {
        case .commands: base = commandEntries()
        case .panes: base = paneEntries()
        case .files: startFiles()
        }
    }

    /// Filter and rank for the current query.
    private func refresh() {
        switch step {
        case .ask:
            entries = rank(base, query: query, keepOrder: false)
        case .running, .output:
            entries = []
        case .list:
            switch mode {
            case .commands:
                var ranked = rank(base, query: query, keepOrder: false)
                if let run = freeRunEntry() { ranked.insert(run, at: 0) }
                entries = ranked
            case .panes:
                entries = rank(base, query: query, keepOrder: false)
            case .files:
                refreshFiles()
            }
        }
        selection = 0
    }

    private func rank(_ items: [TernPaletteEntry], query raw: String, keepOrder: Bool) -> [TernPaletteEntry] {
        let q = raw.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return items }
        let scored = items.enumerated().compactMap { index, entry -> (Int, Int, TernPaletteEntry)? in
            let title = TernFuzzy.score(q, entry.title).map { $0 * 2 }
            let sub = entry.subtitle.flatMap { TernFuzzy.score(q, $0) }
            let extra = entry.keywords.flatMap { TernFuzzy.score(q, $0) }
            guard let best = [title, sub, extra].compactMap({ $0 }).max() else { return nil }
            return (best, index, entry)
        }
        return scored.sorted { a, b in keepOrder || a.0 == b.0 ? a.1 < b.1 : a.0 > b.0 }.map(\.2)
    }

    // MARK: Commands

    private func commandEntries() -> [TernPaletteEntry] {
        var out: [TernPaletteEntry] = []
        let catalog = TernCLICatalog.shared
        if !catalog.isLoaded { catalog.load { [weak self] in self?.reloadCommands() } }
        // A menu action and a CLI command with the same title are one entry: the CLI's when
        // it asks for arguments (asked here rather than in a dialog), else the menu's.
        let asking = Dictionary(catalog.actions.filter { !$0.ask.isEmpty }.map { ($0.title, $0) }, uniquingKeysWith: { a, _ in a })
        var menuTitles = Set<String>()
        var symbols: [String: [String]] = [:]
        // Tern's menu actions (and managed sessions), with their shortcuts.
        for option in TernShortcuts.paletteOptions() {
            menuTitles.insert(option.title)
            if asking[option.title] != nil {
                symbols[option.title] = option.symbols
                continue
            }
            out.append(TernPaletteEntry(id: "tern:" + option.title, title: option.title, subtitle: option.description,
                                        symbols: option.symbols, icon: option.leadingIcon, kind: .action) { [weak self] in
                self?.close()
                option.action()
            })
        }
        // Ghostty's own actions on the focused terminal (a menu action of the same name wins).
        var ghostty: [TernPaletteEntry] = []
        if let pane, let window, let appDelegate = NSApp.delegate as? AppDelegate {
            for command in appDelegate.ghostty.config.commandPaletteEntries where command.isSupported && !menuTitles.contains(command.title) {
                let symbols = appDelegate.ghostty.config.keyboardShortcut(for: command.action)?.keyList
                ghostty.append(TernPaletteEntry(id: "ghostty:" + command.action, title: command.title, subtitle: command.description,
                                                symbols: symbols, icon: "terminal", kind: .action) { [weak self, weak window, weak pane] in
                    self?.close()
                    if let window, let pane { window.performAction(command.action, on: pane) }
                })
            }
        }
        // The CLI's commands. One without arguments named like a Ghostty action is that action
        // (which, unlike the CLI, asks before closing a running program).
        let taken = menuTitles.union(ghostty.map(\.title))
        var seen = Set<String>()
        for action in catalog.actions where !(action.ask.isEmpty && taken.contains(action.title)) && seen.insert(action.title).inserted {
            out.append(TernPaletteEntry(id: "cli:" + action.argv.joined(separator: " ") + action.title, title: action.title,
                                        subtitle: "\(TernPaths.cliName) " + action.display, symbols: symbols[action.title],
                                        icon: "terminal", keywords: action.usage, kind: .cli) { [weak self] in
                self?.begin(action)
            })
        }
        var titles = Set(out.map(\.title))
        return out + ghostty.filter { titles.insert($0.title).inserted }
    }

    private func reloadCommands() {
        guard isPresented, mode == .commands, step == .list else { return }
        base = commandEntries()
        let keep = selection
        refresh()
        selection = min(keep, max(entries.count - 1, 0))
    }

    /// "Run `tern <query>`" when the query starts like a CLI command.
    private func freeRunEntry() -> TernPaletteEntry? {
        var text = query.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix(TernPaths.cliName + " ") { text.removeFirst(TernPaths.cliName.count + 1) }
        let words = TernShellWords.split(text)
        guard let first = words.first, TernCLICatalog.shared.commandWords.contains(first) else { return nil }
        return TernPaletteEntry(id: "run:" + text, title: "Run \(TernPaths.cliName) \(text)", subtitle: "the command line as typed",
                                icon: "chevron.right", kind: .cli) { [weak self] in
            self?.run(words, title: "\(TernPaths.cliName) \(text)")
        }
    }

    /// Start a CLI action: ask for its arguments, then run it.
    private func begin(_ action: TernCLICatalog.Action) {
        pending = (action, [])
        askNext()
    }

    private func askNext() {
        guard let (action, answers) = pending else { return }
        guard answers.count < action.ask.count else {
            pending = nil
            run(action.argv(with: answers), title: "\(TernPaths.cliName) " + action.argv(with: answers).joined(separator: " "))
            return
        }
        let ask = action.ask[answers.count]
        step = .ask
        prompt = ask.prompt + (ask.optional ? " (optional)" : "")
        base = choices(for: ask)
        query = ""
        refresh()
    }

    /// Answer the current question.
    private func answer(_ value: String) {
        guard var current = pending else { return }
        let ask = current.action.ask[current.answers.count]
        if value.isEmpty && !ask.optional {
            NSSound.beep()
            return
        }
        current.answers.append(value)
        pending = current
        askNext()
    }

    private func choices(for ask: TernCLICatalog.Ask) -> [TernPaletteEntry] {
        if !ask.choices.isEmpty {
            return ask.choices.map { choice in
                TernPaletteEntry(id: "choice:" + choice, title: choice, kind: .choice) { [weak self] in self?.answer(choice) }
            }
        }
        switch ask.kind {
        case "pane":
            return paneEntries().map { entry in
                var choice = entry
                choice.perform = { [weak self] in self?.answer(entry.value ?? "") }
                return choice
            }
        case "tab":
            return TernTopology.windows.flatMap { window in
                window.tabs.enumerated().map { index, tab in
                    TernPaletteEntry(id: "tab:" + tab.idString, title: tab.title,
                                     subtitle: "tab #\(index + 1) · window #\(TernTopology.windowNumber(window))",
                                     icon: "rectangle.stack", kind: .choice) { [weak self] in self?.answer(tab.idString) }
                }
            }
        case "window":
            return TernTopology.windows.map { window in
                TernPaletteEntry(id: "window:" + window.ternIDString, title: "Window #\(TernTopology.windowNumber(window))",
                                 subtitle: window.selectedTab.title, icon: "macwindow", kind: .choice) { [weak self] in
                    self?.answer(window.ternIDString)
                }
            }
        default:
            return []
        }
    }

    // MARK: Running the CLI

    private func run(_ argv: [String], title: String) {
        step = .running
        busy = "Running \(title)…"
        entries = []
        let pane = self.pane
        let cwd = pane.map(TernTopology.cwd(of:)).flatMap { $0.isEmpty ? nil : $0 }
        process = TernCLIRunner.run(argv, pane: pane, cwd: cwd) { [weak self] status, out, err in
            guard let self else { return }
            self.process = nil
            self.busy = nil
            let text = (out + (err.isEmpty ? "" : (out.isEmpty ? "" : "\n") + err)).trimmingCharacters(in: .newlines)
            TernEvents.shared.emit("palette.ran", ["argv": argv, "status": Int(status)])
            if status == 0 && text.isEmpty {
                self.close()
                return
            }
            guard self.isPresented else { return }
            self.output = (title, text.isEmpty ? "(exit \(status))" : text, status != 0)
            self.step = .output
            self.query = ""
        }
    }

    private func cancelRun() {
        process?.terminate()
        process = nil
    }

    // MARK: Panes

    private func paneEntries() -> [TernPaletteEntry] {
        let all = TernTopology.allSurfaces
        let recent = TernFocusHistory.recentFirst.filter { pane in all.contains { $0 === pane } }
        let ordered = recent + all.filter { pane in !recent.contains { $0 === pane } }
        let manyWindows = TernTopology.windows.count > 1
        return ordered.compactMap { pane -> TernPaletteEntry? in
            guard let location = TernTopology.locate(pane) else { return nil }
            let cwd = TernTopology.cwd(of: pane)
            var details: [String] = []
            if !cwd.isEmpty {
                var place = Self.abbreviate(cwd)
                if let git = TernPaneContext.git(for: cwd) { place += " · " + git.branch }
                details.append(place)
            }
            if let agent = TernAttention.shared.agent(forPane: pane.id) {
                details.append("\(agent.kind.rawValue) · \(agent.status)")
            } else if let command = TernPaneContext.command(for: pane) {
                details.append(command.running ? "▸ \(command.text)" : command.text)
            }
            details.append("in \(location.tab.title)" + (manyWindows ? " · window #\(TernTopology.windowNumber(location.window))" : ""))
            return TernPaletteEntry(id: "pane:" + pane.ternID, title: Self.title(of: pane), subtitle: details.joined(separator: "  ·  "),
                                    icon: TernAttention.shared.agent(forPane: pane.id) != nil ? "bubble.left" : "terminal",
                                    color: location.tab.color.displayColor.map { Color($0) },
                                    badge: pane === self.pane ? "Current" : nil, value: pane.ternID,
                                    kind: .pane) { [weak self, weak pane] in
                self?.close(restoreFocus: false)
                if let pane { TernLayout.focusPane(pane, activate: true) }
            }
        }
    }

    /// A pane's own title: its name, else its agent's title, else what its program set, else
    /// its folder.
    static func title(of pane: Ghostty.SurfaceView) -> String {
        if let name = TernState.shared.paneName(pane.id), !name.isEmpty { return name }
        if let agent = TernAttention.shared.agent(forPane: pane.id), !agent.title.isEmpty { return agent.title }
        let title = pane.title.trimmingCharacters(in: .whitespaces)
        if !title.isEmpty, title != "👻" { return title }
        let cwd = TernTopology.cwd(of: pane)
        return cwd.isEmpty ? "Terminal" : TernPaneContext.folderName(cwd)
    }

    static func abbreviate(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path == home { return "~" }
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    // MARK: Files

    private func startFiles() {
        let cwd = pane.map(TernTopology.cwd(of:)).flatMap { $0.isEmpty ? nil : $0 } ?? NSHomeDirectory()
        let index = TernFileIndex(folder: cwd)
        files = index
        busy = "Indexing files…"
        index.load { [weak self, weak index] in
            guard let self, let index, self.files === index else { return }
            self.busy = nil
            if self.isPresented, self.mode == .files, self.step == .list { self.refresh() }
        }
    }

    private var browseEntry: TernPaletteEntry {
        TernPaletteEntry(id: "browse", title: "Browse…", subtitle: "the Open panel", icon: "folder", kind: .action) { [weak self] in
            self?.close()
            TernEditor.openPanel()
        }
    }

    private func refreshFiles() {
        filesTask?.cancel()
        guard let index = files, index.isLoaded else {
            entries = [browseEntry]
            return
        }
        let query = self.query
        filesTask = Task { [weak self] in
            guard let found = await self?.fileEntries(query, in: index) else { return }
            guard !Task.isCancelled, let self, self.query == query else { return }
            self.entries = found
            self.selection = 0
        }
    }

    private func fileEntries(_ query: String, in index: TernFileIndex) async -> [TernPaletteEntry] {
        let results = await index.search(query)
        return results.map { result in
            TernPaletteEntry(id: "file:" + result.path, title: (result.path as NSString).lastPathComponent,
                             subtitle: result.line.map { "\(result.path):\($0)" } ?? result.path,
                             icon: result.recent ? "clock" : (result.changed ? "pencil.circle" : "doc.text"),
                             value: result.path, kind: .file) { [weak self] in
                self?.openFile(index.root + "/" + result.path, line: result.line)
            }
        } + [browseEntry]
    }

    private func openFile(_ path: String, line: Int?) {
        let url = URL(fileURLWithPath: path)
        guard let window else { return }
        let tab = pane.flatMap { TernTopology.locate($0) }.map(\.tab) ?? window.selectedTab
        let target = TernTopology.locate(tab: tab) ?? window
        do {
            try TernTextFile.checkOpenable(url)
            let doc = try tab.editor.open(url, mode: line != nil ? .source : nil)
            if let line { doc.revealLine = line }
            TernFileIndex.noteOpened(url.path)
            close(restoreFocus: false)
            TernLayout.focusTab(tab, in: target)
            TernEvents.shared.emit("editor.opened", ["path": doc.url.path, "tab": tab.idString, "window": target.ternIDString])
        } catch let error as TernError {
            output = ("Open \(url.lastPathComponent)", error.message, true)
            step = .output
        } catch {
            output = ("Open \(url.lastPathComponent)", "\(error)", true)
            step = .output
        }
    }

    // MARK: Keys

    func submit() {
        switch step {
        case .output:
            close()
        case .running:
            break
        case .ask:
            if entries.indices.contains(selection) {
                entries[selection].perform()
            } else {
                answer(query.trimmingCharacters(in: .whitespaces))
            }
        case .list:
            if entries.indices.contains(selection) {
                entries[selection].perform()
            } else {
                NSSound.beep()
            }
        }
    }

    func cancel() {
        if step == .running { cancelRun() }
        close()
    }

    func move(_ delta: Int) {
        guard !entries.isEmpty else { return }
        selection = ((selection + delta) % entries.count + entries.count) % entries.count
    }

    var placeholder: String {
        switch step {
        case .ask: return prompt ?? "Value"
        case .running: return busy ?? "Running…"
        case .output: return "Return or Esc closes"
        case .list:
            switch mode {
            case .commands: return "Run a command, or type a \(TernPaths.cliName) command line…"
            case .panes: return "Go to a pane…"
            case .files: return "Open a file (name, or path:line)…"
            }
        }
    }

    // MARK: Scripted checks (debug.palette)

    /// Open a list with a query and return what it shows, once the CLI's commands or the
    /// files are loaded.
    func preview(_ mode: Mode, query: String, in window: TerminalController) async -> [TernPaletteEntry] {
        if mode == .commands { await TernCLICatalog.shared.ensureLoaded() }
        open(mode, in: window)
        if mode == .files, let index = files {
            while !index.isLoaded { try? await Task.sleep(nanoseconds: 50_000_000) }
            filesTask?.cancel()
            self.query = query
            filesTask?.cancel()
            entries = await fileEntries(query, in: index)
            selection = 0
            return entries
        }
        self.query = query
        return entries
    }

    /// Choose an entry by title (answering its questions in order) and wait for the result.
    func perform(title: String, answers: [String], timeout: TimeInterval) async -> [String: Any] {
        guard let entry = entries.first(where: { $0.title == title }) else {
            return ["error": "no entry \"\(title)\"", "entries": entries.map(\.title)]
        }
        entry.perform()
        for value in answers {
            guard step == .ask else { break }
            if let choice = entries.first(where: { $0.value == value || $0.title == value }) {
                choice.perform()
            } else {
                answer(value)
            }
        }
        let deadline = Date().addingTimeInterval(timeout)
        while step == .running && Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        var out: [String: Any] = ["presented": isPresented, "step": "\(step)"]
        if let output { out["output"] = output.text; out["failed"] = output.failed }
        if step == .ask { out["prompt"] = prompt ?? "" }
        return out
    }
}

/// One row of the palette.
struct TernPaletteEntry: Identifiable {
    enum Kind: String { case action, cli, pane, file, choice }

    let id: String
    var title: String
    var subtitle: String?
    var symbols: [String]?
    var icon: String?
    var color: Color?
    var badge: String?
    /// Extra text the query can match (a CLI command's syntax).
    var keywords: String?
    /// What choosing it stands for (a pane id, a file path).
    var value: String?
    let kind: Kind
    var perform: @MainActor () -> Void

    init(id: String, title: String, subtitle: String? = nil, symbols: [String]? = nil, icon: String? = nil,
         color: Color? = nil, badge: String? = nil, keywords: String? = nil, value: String? = nil, kind: Kind,
         perform: @escaping @MainActor () -> Void) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.symbols = symbols
        self.icon = icon
        self.color = color
        self.badge = badge
        self.keywords = keywords
        self.value = value
        self.kind = kind
        self.perform = perform
    }

    var json: [String: Any] {
        var out: [String: Any] = ["title": title, "kind": kind.rawValue]
        if let subtitle { out["subtitle"] = subtitle }
        if let badge { out["badge"] = badge }
        if let value { out["value"] = value }
        if let symbols { out["shortcut"] = symbols.joined() }
        return out
    }
}

// MARK: - The CLI's commands

/// The CLI's own description of its commands (`tern help --json`), read from the bundled CLI
/// once per run of the app.
@MainActor
final class TernCLICatalog {
    static let shared = TernCLICatalog()

    struct Ask {
        let name: String
        let prompt: String
        let option: String?
        let choices: [String]
        let optional: Bool
        let kind: String
        let words: Bool
    }

    struct Action {
        let title: String
        let argv: [String]
        let ask: [Ask]
        let usage: String

        /// The command line with the answers in place.
        func argv(with answers: [String]) -> [String] {
            var out = argv
            for (ask, value) in zip(self.ask, answers) where !value.isEmpty {
                if let option = ask.option { out.append(option) }
                if ask.words { out += TernShellWords.split(value) } else { out.append(value) }
            }
            return out
        }

        var display: String {
            (argv.filter { $0 != "--" } + ask.map { $0.option.map { o in "\(o) …" } ?? $0.name }).joined(separator: " ")
        }
    }

    private(set) var actions: [Action] = []
    /// First words of every command (`tab`, `ls`, `agent` …), for typed command lines.
    private(set) var commandWords: Set<String> = []
    private(set) var isLoaded = false
    private var loading = false
    private var waiters: [() -> Void] = []

    func ensureLoaded() async {
        guard !isLoaded else { return }
        await withCheckedContinuation { continuation in load { continuation.resume() } }
    }

    func load(_ done: @escaping @MainActor () -> Void) {
        waiters.append(done)
        guard !loading else { return }
        loading = true
        TernCLIRunner.run(["help", "--json"], pane: nil, cwd: nil) { [weak self] status, out, _ in
            guard let self else { return }
            self.loading = false
            if status == 0, let data = out.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                self.apply(json)
            }
            self.isLoaded = true
            let waiters = self.waiters
            self.waiters = []
            for waiter in waiters { waiter() }
        }
    }

    func apply(_ json: [String: Any]) {
        var actions: [Action] = []
        var words: Set<String> = []
        for command in json["commands"] as? [[String: Any]] ?? [] {
            let usage = command["usage"] as? String ?? ""
            if let first = usage.split(separator: " ").first {
                for word in first.split(separator: "|") { words.insert(String(word)) }
            }
            for item in command["actions"] as? [[String: Any]] ?? [] {
                guard let title = item["title"] as? String, let argv = item["argv"] as? [String], !argv.isEmpty else { continue }
                let asks = (item["ask"] as? [[String: Any]] ?? []).map { ask in
                    Ask(name: ask["name"] as? String ?? "VALUE", prompt: ask["prompt"] as? String ?? "Value",
                        option: ask["option"] as? String, choices: ask["choices"] as? [String] ?? [],
                        optional: ask["optional"] as? Bool ?? false, kind: ask["kind"] as? String ?? "text",
                        words: ask["words"] as? Bool ?? false)
                }
                actions.append(Action(title: title, argv: argv, ask: asks, usage: usage))
                words.insert(argv[0])
            }
        }
        self.actions = actions
        self.commandWords = words
    }
}

/// Runs the bundled CLI as the given pane would (its pane, instance and state directory), so
/// commands default to "this pane".
@MainActor
enum TernCLIRunner {
    @discardableResult
    static func run(_ argv: [String], pane: Ghostty.SurfaceView?, cwd: String?,
                     completion: @escaping @MainActor (Int32, String, String) -> Void) -> Process? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: TernPaths.cliPath)
        process.arguments = argv
        var env = ProcessInfo.processInfo.environment
        if let pane {
            for (key, value) in TernEnvironment.paneVariables(paneID: pane.id) { env[key] = value }
        } else {
            env["TERN_STATE_DIR"] = TernPaths.stateDirectory
            env.removeValue(forKey: "TERN_PANE_ID")
            env.removeValue(forKey: "TERN_INSTANCE")
        }
        process.environment = env
        if let cwd, FileManager.default.fileExists(atPath: cwd) { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        // Read on background queues so a large output never blocks the process.
        final class Buffer: @unchecked Sendable { var data = Data() }
        let outBuffer = Buffer(), errBuffer = Buffer()
        let group = DispatchGroup()
        for (pipe, buffer) in [(out, outBuffer), (err, errBuffer)] {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                buffer.data = pipe.fileHandleForReading.readDataToEndOfFile()
                group.leave()
            }
        }
        process.terminationHandler = { process in
            let status = process.terminationStatus
            group.notify(queue: .main) {
                MainActor.assumeIsolated {
                    completion(status, String(decoding: outBuffer.data, as: UTF8.self), String(decoding: errBuffer.data, as: UTF8.self))
                }
            }
        }
        do {
            try process.run()
        } catch {
            try? out.fileHandleForWriting.close()
            try? err.fileHandleForWriting.close()
            completion(127, "", "couldn't run \(TernPaths.cliPath): \(error.localizedDescription)")
            return nil
        }
        return process
    }
}

/// Words of a typed command line: spaces separate, quotes group, backslash escapes.
enum TernShellWords {
    static func split(_ text: String) -> [String] {
        var words: [String] = []
        var current = ""
        var inWord = false
        var quote: Character?
        var escaped = false
        for c in text {
            if escaped {
                current.append(c)
                escaped = false
                continue
            }
            if c == "\\" && quote != "'" {
                escaped = true
                inWord = true
                continue
            }
            if let q = quote {
                if c == q { quote = nil } else { current.append(c) }
                continue
            }
            if c == "\"" || c == "'" {
                quote = c
                inWord = true
            } else if c == " " || c == "\t" {
                if inWord { words.append(current) }
                current = ""
                inWord = false
            } else {
                current.append(c)
                inWord = true
            }
        }
        if inWord { words.append(current) }
        return words
    }
}

// MARK: - Fuzzy matching

enum TernFuzzy {
    /// How well `query` matches `text` as a subsequence (higher is better), nil when it doesn't.
    /// Consecutive characters and characters at the start of words count more.
    static func score(_ query: String, _ text: String) -> Int? {
        score(Array(query.lowercased().utf8), Array(text.utf8))
    }

    static func score(_ query: [UInt8], _ text: [UInt8]) -> Int? {
        guard !query.isEmpty else { return 0 }
        guard query.count <= text.count else { return nil }
        var score = 0
        var qi = 0
        var previous = -2
        var streak = 0
        for (ti, raw) in text.enumerated() {
            guard qi < query.count else { break }
            let c = lower(raw)
            guard c == query[qi] else { continue }
            var points = 1
            if ti == previous + 1 {
                streak += 1
                points += 4 + streak
            } else {
                streak = 0
                if previous >= 0 { points -= min(ti - previous - 1, 3) }
            }
            if ti == 0 {
                points += 8
            } else {
                let before = text[ti - 1]
                if isSeparator(before) || (isUpper(raw) && !isUpper(before)) { points += 6 }
            }
            score += points
            previous = ti
            qi += 1
        }
        guard qi == query.count else { return nil }
        // Shorter texts with the same matches rank higher.
        return score * 4 - min(text.count, 120) / 8
    }

    @inline(__always) static func lower(_ c: UInt8) -> UInt8 { c >= 65 && c <= 90 ? c + 32 : c }
    @inline(__always) static func isUpper(_ c: UInt8) -> Bool { c >= 65 && c <= 90 }
    @inline(__always) static func isSeparator(_ c: UInt8) -> Bool {
        c == 32 || c == 47 || c == 95 || c == 45 || c == 46 || c == 58
    }
}

// MARK: - Files (⌘O)

/// The files of the focused pane's repository (`git ls-files` plus untracked files that
/// aren't ignored), or of its folder when it isn't in one (that folder only, like Warp).
/// Recently opened files come first, then changed ones.
@MainActor
final class TernFileIndex {
    struct Result: Sendable {
        let path: String
        let line: Int?
        let recent: Bool
        let changed: Bool
    }

    private struct Candidate: Sendable {
        let path: String
        let lowered: [UInt8]
        let nameStart: Int
        var rank: Int
        var recent: Bool
        var changed: Bool
    }

    let folder: String
    private(set) var root: String
    private(set) var isLoaded = false
    private var candidates: [Candidate] = []

    /// Files opened from the palette or the editor, most recent first (absolute paths).
    private static var recent: [String] = []

    static func noteOpened(_ path: String) {
        recent.removeAll { $0 == path }
        recent.insert(path, at: 0)
        if recent.count > 100 { recent.removeLast(recent.count - 100) }
    }

    static let limit = 100

    init(folder: String) {
        self.folder = folder
        self.root = folder
    }

    func load(_ done: @escaping @MainActor () -> Void) {
        let folder = self.folder
        let recent = Self.recent
        Task.detached(priority: .userInitiated) {
            let listing = Self.list(folder)
            await MainActor.run {
                self.root = listing.root
                var candidates: [Candidate] = []
                candidates.reserveCapacity(listing.files.count)
                let changed = Set(listing.changed)
                for path in listing.files {
                    let absolute = listing.root + "/" + path
                    let recentIndex = recent.firstIndex(of: absolute)
                    let isChanged = changed.contains(path)
                    let nameStart = (path.lastIndex(of: "/").map { path.utf8.distance(from: path.startIndex, to: $0) + 1 }) ?? 0
                    let rank = recentIndex.map { 1000 - $0 } ?? (isChanged ? 100 : 0)
                    candidates.append(Candidate(path: path, lowered: Array(path.lowercased().utf8), nameStart: nameStart,
                                                rank: rank, recent: recentIndex != nil, changed: isChanged))
                }
                // Recent, then changed, then the rest by path.
                candidates.sort { a, b in a.rank != b.rank ? a.rank > b.rank : a.path < b.path }
                self.candidates = candidates
                self.isLoaded = true
                done()
            }
        }
    }

    /// The best matches for a query; `path:line` (and `path:line:column`) are understood.
    func search(_ raw: String) async -> [Result] {
        var query = raw.trimmingCharacters(in: .whitespaces)
        var line: Int?
        let parts = query.split(separator: ":", omittingEmptySubsequences: false)
        if parts.count >= 2, let n = Int(parts[1]) {
            line = n
            query = String(parts[0])
        } else if query.hasSuffix(":") {
            query.removeLast()
        }
        // A path typed from the root's parent folder ("repo/src/x") or with "./" still matches.
        if query.hasPrefix("./") { query.removeFirst(2) }
        let candidates = self.candidates
        let q = Array(query.lowercased().utf8)
        let limit = Self.limit
        return await Task.detached(priority: .userInitiated) {
            guard !q.isEmpty else {
                return candidates.prefix(limit).map { Result(path: $0.path, line: line, recent: $0.recent, changed: $0.changed) }
            }
            var scored: [(Int, Int)] = []
            for (index, candidate) in candidates.enumerated() {
                if index % 4096 == 0 && Task.isCancelled { return [] }
                guard var score = TernFuzzy.score(q, candidate.lowered) else { continue }
                // A match within the file name counts more.
                let nameStart = min(candidate.nameStart, candidate.lowered.count)
                if let nameScore = TernFuzzy.score(q, Array(candidate.lowered[nameStart...])) {
                    score = max(score, nameScore * 2)
                }
                score += candidate.rank > 0 ? min(candidate.rank, 200) / 10 : 0
                scored.append((score, index))
            }
            scored.sort { a, b in a.0 != b.0 ? a.0 > b.0 : a.1 < b.1 }
            return scored.prefix(limit).map { item in
                let c = candidates[item.1]
                return Result(path: c.path, line: line, recent: c.recent, changed: c.changed)
            }
        }.value
    }

    /// The repository's files (or the folder's), and the changed ones; paths relative to root.
    nonisolated private static func list(_ folder: String) -> (root: String, files: [String], changed: [String]) {
        if let top = git(["rev-parse", "--show-toplevel"], in: folder)?.trimmingCharacters(in: .whitespacesAndNewlines), !top.isEmpty {
            let files = git(["ls-files", "--cached", "--others", "--exclude-standard", "-z"], in: top)?
                .split(separator: "\0").map(String.init) ?? []
            var unique: [String] = []
            var seen = Set<String>()
            for file in files where seen.insert(file).inserted { unique.append(file) }
            let changed = git(["status", "--porcelain", "-z", "--untracked-files=no"], in: top)?
                .split(separator: "\0").compactMap { entry -> String? in
                    entry.count > 3 ? String(entry.dropFirst(3)) : nil
                } ?? []
            return (top, Array(unique.prefix(300_000)), changed)
        }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
        let files = names.filter { name in
            var isDir = ObjCBool(false)
            return !name.hasPrefix(".") && FileManager.default.fileExists(atPath: folder + "/" + name, isDirectory: &isDir) && !isDir.boolValue
        }.sorted()
        return (folder, files, [])
    }

    nonisolated private static func git(_ args: [String], in dir: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", dir] + args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}

// MARK: - View

/// The palette over a window's content.
struct TernPaletteView: View {
    @ObservedObject var model: TernPaletteModel
    let background: Color

    var body: some View {
        ZStack {
            if model.isPresented {
                GeometryReader { geometry in
                    VStack {
                        Spacer().frame(height: geometry.size.height * 0.05)
                        TernPalettePanel(model: model, background: background)
                            .frame(maxWidth: 580)
                        Spacer()
                    }
                    .frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
                }
            }
        }
    }
}

private struct TernPalettePanel: View {
    @ObservedObject var model: TernPaletteModel
    let background: Color
    @FocusState private var focused: Bool
    @State private var hovered: String?

    var body: some View {
        let scheme: ColorScheme = NSColor(background).isLightColor ? .light : .dark
        VStack(alignment: .leading, spacing: 0) {
            field
            if model.step == .ask, let prompt = model.prompt {
                Text(prompt)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 6)
            }
            Divider().opacity(0.6)
            content
        }
        .background(
            ZStack {
                Rectangle().fill(.ultraThinMaterial)
                Rectangle().fill(background).blendMode(.color)
            }
            .compositingGroup()
        )
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(nsColor: .tertiaryLabelColor).opacity(0.5)))
        .shadow(radius: 28, x: 0, y: 10)
        .padding()
        .environment(\.colorScheme, scheme)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Palette")
    }

    private var field: some View {
        ZStack {
            Group {
                Button { model.move(-1) } label: { Color.clear }
                    .buttonStyle(.plain).keyboardShortcut(.upArrow, modifiers: [])
                Button { model.move(1) } label: { Color.clear }
                    .buttonStyle(.plain).keyboardShortcut(.downArrow, modifiers: [])
                Button { model.move(-1) } label: { Color.clear }
                    .buttonStyle(.plain).keyboardShortcut(.init("p"), modifiers: [.control])
                Button { model.move(1) } label: { Color.clear }
                    .buttonStyle(.plain).keyboardShortcut(.init("n"), modifiers: [.control])
            }
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)

            HStack(spacing: 8) {
                if model.busy != nil {
                    ProgressView().controlSize(.small)
                }
                TextField(model.placeholder, text: $model.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 18, weight: .light))
                    .focused($focused)
                    .onSubmit { model.submit() }
                    .onExitCommand { model.cancel() }
                    .onMoveCommand { direction in
                        if direction == .up { model.move(-1) }
                        if direction == .down { model.move(1) }
                    }
                    .onChange(of: focused) { isFocused in
                        // Clicking elsewhere closes the palette (a running command finishes).
                        if !isFocused && model.isPresented && model.step != .running {
                            model.close(restoreFocus: false)
                        }
                    }
                    .onAppear { DispatchQueue.main.async { focused = true } }
                    .onChange(of: model.step) { _ in DispatchQueue.main.async { focused = true } }
                    .accessibilityLabel("Palette query")
            }
            .padding(.horizontal, 16)
            .frame(height: 46)
        }
    }

    @ViewBuilder
    private var content: some View {
        if let output = model.output, model.step == .output {
            VStack(alignment: .leading, spacing: 6) {
                Text(output.title).font(.caption).foregroundStyle(output.failed ? Color.red.opacity(0.8) : .secondary)
                ScrollView {
                    Text(output.text)
                        .font(.system(size: 11.5, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 320)
            }
            .padding(14)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Command output")
        } else if model.step == .running {
            Text(model.busy ?? "Running…").font(.caption).foregroundStyle(.secondary).padding(14)
        } else if model.entries.isEmpty {
            Text(model.busy ?? (model.step == .ask ? "Type a value, then Return" : "No matches"))
                .font(.caption).foregroundStyle(.secondary).padding(14)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(model.entries.enumerated()), id: \.element.id) { index, entry in
                            row(entry, selected: index == model.selection)
                                .id(entry.id)
                                .onTapGesture { model.selection = index; model.submit() }
                        }
                    }
                    .padding(8)
                }
                .frame(maxHeight: 340)
                .onChange(of: model.selection) { selection in
                    guard model.entries.indices.contains(selection) else { return }
                    proxy.scrollTo(model.entries[selection].id)
                }
            }
        }
    }

    private func row(_ entry: TernPaletteEntry, selected: Bool) -> some View {
        HStack(spacing: 9) {
            if let color = entry.color {
                Circle().fill(color).frame(width: 7, height: 7)
            }
            if let icon = entry.icon {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.title).lineLimit(1)
                if let subtitle = entry.subtitle, !subtitle.isEmpty {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer(minLength: 6)
            if let badge = entry.badge {
                Text(badge)
                    .font(.caption2.weight(.medium))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                    .foregroundStyle(Color.accentColor)
            }
            if let symbols = entry.symbols {
                HStack(spacing: 1) {
                    ForEach(Array(symbols.enumerated()), id: \.offset) { _, symbol in Text(symbol).frame(minWidth: 12) }
                }
                .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(selected ? Color.accentColor.opacity(0.2) : (hovered == entry.id ? Color.secondary.opacity(0.15) : .clear))
        )
        .onHover { hovered = $0 ? entry.id : (hovered == entry.id ? nil : hovered) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(entry.title)
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
    }
}
