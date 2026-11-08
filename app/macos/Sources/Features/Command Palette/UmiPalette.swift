import AppKit
import SwiftUI

/// Umi's palette, over a window: one palette, as Warp's, whose source a filter chooses.
/// - **Everything (⌘P, L-14):** the CLI's commands, built at runtime from `umi help --json`
///   (so the palette follows the CLI as it changes) and run through the bundled CLI in the
///   context of the focused pane, asking for arguments a command needs; Umi's menu actions,
///   Ghostty's actions, panes and files. Empty, it shows filter chips and the
///   Recent and Suggested sections.
/// - **Filters**, typed as a prefix (`files:`, `sessions:`, `actions:`, `tabs:`) and shown as an italic word before the query; Backspace in an empty query removes
///   it. ⇧⌘P opens the palette filtered to sessions (every pane, most recently used first, L-15)
///   and ⌘O to files (the focused pane's repository, L-16).
@MainActor
final class UmiPaletteModel: ObservableObject {
    /// The palette's source: everything (`commands`) or one of Warp's query filters.
    /// `panes` is Warp's "sessions" filter; `launchConfigs` is ⌃⌘L's list (L-21).
    enum Mode: String, CaseIterable { case commands, actions, panes, files, tabs, launchConfigs = "launch_configs" }
    enum Step: Equatable { case list, ask, running, output }

    @Published private(set) var isPresented = false
    @Published private(set) var mode: Mode = .commands
    @Published private(set) var step: Step = .list
    @Published var query = "" {
        didSet { if query != oldValue { queryChanged() } }
    }
    /// The selected row; -1 when none is (the empty ⌘P selects nothing until an arrow key).
    @Published var selection = 0
    @Published private(set) var entries: [UmiPaletteEntry] = []
    /// The question asked while collecting an argument.
    @Published private(set) var prompt: String?
    /// A command's output, shown after it ran.
    @Published private(set) var output: (title: String, text: String, failed: Bool)?
    /// What's in progress ("Running umi ls…", "Indexing files…").
    @Published private(set) var busy: String?

    private weak var window: TerminalController?
    /// The pane the palette acts for: the focused one when it opened.
    private(set) weak var pane: Ghostty.SurfaceView?
    private weak var previousResponder: NSResponder?

    /// Everything the current list filters, built when the list opens.
    private var base: [UmiPaletteEntry] = []
    /// A CLI action whose arguments are being asked, and the answers so far.
    private var pending: (action: UmiCLICatalog.Action, answers: [String])?
    private var process: Process?
    /// Which run the palette waits for: a cancelled or replaced run's completion is ignored.
    private var runID = 0
    private var files: UmiFileIndex?
    private var filesTask: Task<Void, Never>?
    /// Backspace in an empty query removes the filter.
    private var keyMonitor: Any?

    /// At most this many results, as Warp's palette.
    static let resultLimit = 250
    /// The Recent section's length (Warp: 3).
    static let recentCount = 3
    /// Entries chosen from the palette, most recent first (their ids).
    private static var chosen: [String] = []
    /// The files among `chosen`, by id: Recent lists them although the empty palette has no files.
    private static var chosenFiles: [String: UmiPaletteEntry.FileRef] = [:]
    /// The Suggested section: Umi's counterparts of Warp's (its theme chooser and settings).
    static let suggestedIDs = ["umi:Keyboard Shortcuts", "umi:Settings…", "umi:Show Project Explorer"]
    /// The filter chips of the empty palette, in Warp's order.
    static let chips: [Mode] = [.files, .actions, .panes]

    /// The shortcuts page (⌘/) of this window.
    let shortcutsPage = UmiShortcutsPageModel()

    // MARK: Opening and closing

    /// Open (or close, if it shows that list already) the palette over the current window.
    static func present(_ mode: Mode) {
        guard let window = UmiTopology.currentWindow else {
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

    /// How many times a palette has opened, in any window (changed on the main thread only).
    nonisolated(unsafe) private(set) static var openings = 0

    /// Whether a palette opened since a delayed focus move was asked for (when `openings` was
    /// `since`) still shows in `window`. The move then gives way, so ⌘P pressed right after a
    /// tab switch types into the palette. Moves asked for while it shows (a command it runs
    /// splits and focuses a pane) still happen. Call it on the main thread.
    nonisolated static func keepsFocus(in window: NSWindow?, since: Int) -> Bool {
        MainActor.assumeIsolated {
            guard openings != since, let controller = window?.windowController as? TerminalController else { return false }
            return controller.palette.isPresented
        }
    }

    func open(_ mode: Mode, in window: TerminalController) {
        cancelRun()
        filesTask?.cancel()
        if !isPresented {
            Self.openings += 1
            previousResponder = window.window?.firstResponder
            pane = UmiTopology.currentWindow === window ? UmiTopology.currentPane : window.focusedSurface
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
        files = nil
        query = ""
        buildBase()
        refresh()
        isPresented = true
        installKeyMonitor()
        UmiEvents.shared.emit("palette.opened", ["mode": mode.rawValue, "window": window.umiIDString])
    }

    func close(restoreFocus: Bool = true) {
        guard isPresented else { return }
        isPresented = false
        filesTask?.cancel()
        pending = nil
        step = .list
        removeKeyMonitor()
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

    // MARK: Filters

    /// Switch the list to another source, keeping the palette open (a typed prefix, a chip,
    /// Backspace in an empty query).
    func setFilter(_ mode: Mode, query newQuery: String = "") {
        guard isPresented, step == .list else { return }
        filesTask?.cancel()
        self.mode = mode
        busy = nil
        base = []
        buildBase()
        query = newQuery
        refresh()
        UmiEvents.shared.emit("palette.filter", ["mode": mode.rawValue])
    }

    /// The filter a query starts with, and the rest of the query.
    static func filterPrefix(in query: String) -> (Mode, String)? {
        let lowered = query.lowercased()
        for mode in Mode.allCases {
            guard let word = mode.filterWord, lowered.hasPrefix(word) else { continue }
            return (mode, String(query.dropFirst(word.count).drop(while: { $0 == " " })))
        }
        return nil
    }

    private func queryChanged() {
        if step == .list, mode == .commands, Self.filterPrefix(in: query) != nil {
            // After the field has taken the typed text, so it then shows the rest.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.step == .list, self.mode == .commands,
                      let (filter, rest) = Self.filterPrefix(in: self.query) else { return }
                self.setFilter(filter, query: rest)
            }
            return
        }
        refresh()
    }

    /// The empty unfiltered palette: filter chips, Recent and Suggested (Warp's zero state).
    var isZeroState: Bool {
        step == .list && mode == .commands && query.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self else { return event }
                if self.completesFilter(on: event) { return nil }
                guard self.removesFilter(on: event) else { return event }
                self.setFilter(.commands)
                return nil
            }
        }
    }

    /// The filter whose word the query begins, without the whole word typed (Warp's filter
    /// autosuggestion: "fi" suggests `files:`).
    private var suggestedFilter: Mode? {
        guard step == .list, mode == .commands, !query.isEmpty else { return nil }
        return Mode.allCases.first { $0.filterWord.map { $0.hasPrefix(query) && $0 != query } ?? false }
    }

    /// The rest of the suggested filter's word, shown dimmed after the query ("les: ").
    var filterSuggestion: String? {
        suggestedFilter?.filterWord.map { String($0.dropFirst(query.count)) + " " }
    }

    /// Tab with the palette's field focused applies the suggested filter (Warp).
    private func completesFilter(on event: NSEvent) -> Bool {
        guard isPresented, event.keyCode == 48,
              event.modifierFlags.isDisjoint(with: [.command, .control, .option, .shift]),
              let nsWindow = window?.window, event.window === nsWindow,
              let editor = nsWindow.firstResponder as? NSTextView, editor.isFieldEditor,
              let filter = suggestedFilter else { return false }
        setFilter(filter)
        return true
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    /// Backspace with the palette's empty query focused, under a filter.
    private func removesFilter(on event: NSEvent) -> Bool {
        // ⌃⌘L's list (launch configurations) has no filter word to remove.
        guard isPresented, step == .list, mode != .commands, mode.filterWord != nil, query.isEmpty, event.keyCode == 51,
              event.modifierFlags.isDisjoint(with: [.command, .control, .option]),
              let nsWindow = window?.window, event.window === nsWindow,
              let editor = nsWindow.firstResponder as? NSTextView, editor.isFieldEditor else { return false }
        return true
    }

    // MARK: Lists

    private func buildBase() {
        switch mode {
        case .commands:
            // Files are indexed once there's a query (see refresh): the empty palette shows none.
            base = commandEntries() + paneEntries()
        case .actions: base = commandEntries()
        case .panes: base = paneEntries()
        case .files: startFiles()
        case .tabs: base = tabEntries()
        case .launchConfigs: base = launchConfigEntries()
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
            if isZeroState {
                filesTask?.cancel()
                entries = zeroStateEntries()
                selection = -1
                return
            }
            switch mode {
            case .commands, .actions:
                var ranked = Array(rank(base, query: query, keepOrder: false).prefix(Self.resultLimit))
                if let run = freeRunEntry() { ranked.insert(run, at: 0) }
                entries = ranked
                if mode == .commands {
                    startFiles()
                    appendFiles()
                }
            case .launchConfigs:
                entries = rank(base, query: query, keepOrder: false)
            case .files:
                refreshFiles()
            case .panes, .tabs:
                entries = Array(rank(base, query: query, keepOrder: false).prefix(Self.resultLimit))
            }
        }
        selection = 0
    }

    private func rank(_ items: [UmiPaletteEntry], query raw: String, keepOrder: Bool) -> [UmiPaletteEntry] {
        let q = raw.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return items }
        let scored = items.enumerated().compactMap { index, entry -> (Int, Int, UmiPaletteEntry)? in
            let title = UmiFuzzy.score(q, entry.title).map { $0 * 2 }
            let sub = entry.subtitle.flatMap { UmiFuzzy.score(q, $0) }
            let extra = entry.keywords.flatMap { UmiFuzzy.score(q, $0) }
            guard let best = [title, sub, extra].compactMap({ $0 }).max() else { return nil }
            return (best, index, entry)
        }
        return scored.sorted { a, b in keepOrder || a.0 == b.0 ? a.1 < b.1 : a.0 > b.0 }.map(\.2)
    }

    /// Recent (the last entries chosen, at most three) and Suggested. An entry can be in both,
    /// as in Warp; its rows differ by `rowID`.
    private func zeroStateEntries() -> [UmiPaletteEntry] {
        var byID: [String: UmiPaletteEntry] = [:]
        for entry in base where byID[entry.id] == nil { byID[entry.id] = entry }
        let recent = Self.chosen.compactMap { byID[$0] ?? Self.chosenFiles[$0].flatMap(recentFileEntry) }
            .prefix(Self.recentCount).map { entry -> UmiPaletteEntry in
                var entry = entry
                entry.section = "Recent"
                return entry
            }
        let suggested = Self.suggestedIDs.compactMap { byID[$0] }.map { entry -> UmiPaletteEntry in
            var entry = entry
            entry.section = "Suggested"
            return entry
        }
        return recent + suggested
    }

    /// A file opened from the palette, for Recent (gone files are left out).
    private func recentFileEntry(_ ref: UmiPaletteEntry.FileRef) -> UmiPaletteEntry? {
        guard FileManager.default.fileExists(atPath: ref.absolute) else { return nil }
        var entry = UmiPaletteEntry(id: ref.id, title: (ref.path as NSString).lastPathComponent,
                                    subtitle: ref.line.map { "\(ref.path):\($0)" } ?? ref.path,
                                    icon: UmiPaletteFileIcon.symbol(for: ref.path), value: ref.path, kind: .file) { [weak self] in
            self?.openFile(ref.absolute, line: ref.line)
        }
        entry.fileRef = ref
        return entry
    }

    /// Perform a row, remembering it for the Recent section.
    func choose(_ entry: UmiPaletteEntry) {
        if step == .list, let ref = entry.fileRef {
            Self.remember(ref.id)
            Self.chosenFiles[ref.id] = ref
            Self.chosenFiles = Self.chosenFiles.filter { Self.chosen.contains($0.key) }
        } else if step == .list, [.action, .cli, .pane].contains(entry.kind), !entry.id.hasPrefix("run:") {
            Self.remember(entry.id)
        }
        entry.perform()
    }

    private static func remember(_ id: String) {
        chosen.removeAll { $0 == id }
        chosen.insert(id, at: 0)
        if chosen.count > 20 { chosen.removeLast(chosen.count - 20) }
    }

    // MARK: Commands

    private func commandEntries() -> [UmiPaletteEntry] {
        var out: [UmiPaletteEntry] = []
        let catalog = UmiCLICatalog.shared
        if !catalog.isLoaded { catalog.load { [weak self] in self?.reloadCommands() } }
        // A menu action and a CLI command with the same title are one entry: the CLI's when
        // it asks for arguments (asked here rather than in a dialog), else the menu's.
        let asking = Dictionary(catalog.actions.filter { !$0.ask.isEmpty }.map { ($0.title, $0) }, uniquingKeysWith: { a, _ in a })
        var menuTitles = Set<String>()
        var symbols: [String: [String]] = [:]
        // Umi's menu actions, with their shortcuts.
        for item in UmiShortcuts.items {
            menuTitles.insert(item.title)
            let keys = item.shortcut?.symbols
            if asking[item.title] != nil {
                symbols[item.title] = keys
                continue
            }
            out.append(UmiPaletteEntry(id: "umi:" + item.title, title: item.title, symbols: keys, icon: item.symbol,
                                        kind: .action) { [weak self] in
                self?.close()
                guard item.enabled() else { NSSound.beep(); return }
                item.action()
            })
        }
        // Ghostty's own actions on the focused terminal (a menu action of the same name wins).
        var ghostty: [UmiPaletteEntry] = []
        if let pane, let window, let appDelegate = NSApp.delegate as? AppDelegate {
            for command in appDelegate.ghostty.config.commandPaletteEntries where command.isSupported && !menuTitles.contains(command.title) {
                let symbols = appDelegate.ghostty.config.keyboardShortcut(for: command.action)?.keyList
                ghostty.append(UmiPaletteEntry(id: "ghostty:" + command.action, title: command.title, subtitle: command.description,
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
            out.append(UmiPaletteEntry(id: "cli:" + action.argv.joined(separator: " ") + action.title, title: action.title,
                                        subtitle: "\(UmiPaths.cliName) " + action.display, symbols: symbols[action.title],
                                        icon: "terminal", keywords: action.usage, kind: .cli) { [weak self] in
                self?.begin(action)
            })
        }
        var titles = Set(out.map(\.title))
        // Launch configurations by name, as in Warp's command palette (L-21).
        return out + ghostty.filter { titles.insert($0.title).inserted } + launchConfigEntries(inCommands: true)
    }

    /// Every tab of every window, the most recently shown first.
    private func tabEntries() -> [UmiPaletteEntry] {
        let recent = UmiTabHistory.recentFirst
        let manyWindows = UmiTopology.windows.count > 1
        var out: [(rank: Int, entry: UmiPaletteEntry)] = []
        for window in UmiTopology.windows {
            for (index, tab) in window.tabs.enumerated() {
                let rank = recent.firstIndex { $0 === tab } ?? Int.max
                let place = "tab #\(index + 1)" + (manyWindows ? " · window #\(UmiTopology.windowNumber(window))" : "")
                out.append((rank, UmiPaletteEntry(id: "tab:" + tab.idString, title: tab.title, subtitle: place,
                                                  icon: "rectangle.stack", color: tab.color.displayColor.map { Color($0) },
                                                  value: tab.idString, kind: .tab) { [weak self, weak window, weak tab] in
                    self?.close(restoreFocus: false)
                    if let window, let tab { UmiLayout.focusTab(tab, in: window) }
                }))
            }
        }
        return out.enumerated().sorted { a, b in
            a.element.rank != b.element.rank ? a.element.rank < b.element.rank : a.offset < b.offset
        }.map(\.element.entry)
    }

    private func reloadCommands() {
        guard isPresented, step == .list, mode == .commands || mode == .actions else { return }
        let keep = selection
        base = mode == .commands ? commandEntries() + paneEntries() : commandEntries()
        refresh()
        selection = isZeroState ? keep : min(max(keep, 0), max(entries.count - 1, 0))
    }

    /// "Run `umi <query>`" when the query starts like a CLI command.
    private func freeRunEntry() -> UmiPaletteEntry? {
        var text = query.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix(UmiPaths.cliName + " ") { text.removeFirst(UmiPaths.cliName.count + 1) }
        let words = UmiShellWords.split(text)
        guard let first = words.first, UmiCLICatalog.shared.commandWords.contains(first) else { return nil }
        return UmiPaletteEntry(id: "run:" + text, title: "Run \(UmiPaths.cliName) \(text)", subtitle: "the command line as typed",
                                icon: "chevron.right", kind: .cli) { [weak self] in
            self?.run(words, title: "\(UmiPaths.cliName) \(text)")
        }
    }

    /// Start a CLI action: ask for its arguments, then run it.
    private func begin(_ action: UmiCLICatalog.Action) {
        pending = (action, [])
        askNext()
    }

    private func askNext() {
        guard let (action, answers) = pending else { return }
        guard answers.count < action.ask.count else {
            pending = nil
            run(action.argv(with: answers), title: "\(UmiPaths.cliName) " + action.argv(with: answers).joined(separator: " "))
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
        if value.isEmpty && !ask.optional && !ask.keepEmpty {
            NSSound.beep()
            return
        }
        current.answers.append(value)
        pending = current
        askNext()
    }

    private func choices(for ask: UmiCLICatalog.Ask) -> [UmiPaletteEntry] {
        if !ask.choices.isEmpty {
            return ask.choices.map { choice in
                UmiPaletteEntry(id: "choice:" + choice, title: choice, kind: .choice) { [weak self] in self?.answer(choice) }
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
            return UmiTopology.windows.flatMap { window in
                window.tabs.enumerated().map { index, tab in
                    UmiPaletteEntry(id: "tab:" + tab.idString, title: tab.title,
                                     subtitle: "tab #\(index + 1) · window #\(UmiTopology.windowNumber(window))",
                                     icon: "rectangle.stack", kind: .choice) { [weak self] in self?.answer(tab.idString) }
                }
            }
        case "window":
            return UmiTopology.windows.map { window in
                UmiPaletteEntry(id: "window:" + window.umiIDString, title: "Window #\(UmiTopology.windowNumber(window))",
                                 subtitle: window.selectedTab.title, icon: "macwindow", kind: .choice) { [weak self] in
                    self?.answer(window.umiIDString)
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
        let cwd = pane.map(UmiTopology.cwd(of:)).flatMap { $0.isEmpty ? nil : $0 }
        runID += 1
        let mine = runID
        process = UmiCLIRunner.run(argv, pane: pane, cwd: cwd) { [weak self] status, out, err in
            guard let self, self.runID == mine else { return }
            self.process = nil
            self.busy = nil
            let text = (out + (err.isEmpty ? "" : (out.isEmpty ? "" : "\n") + err)).trimmingCharacters(in: .newlines)
            UmiEvents.shared.emit("palette.ran", ["argv": argv, "status": Int(status)])
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
        runID += 1
        process?.terminate()
        process = nil
    }

    // MARK: Panes

    private func paneEntries() -> [UmiPaletteEntry] {
        let all = UmiTopology.allSurfaces
        let recent = UmiFocusHistory.recentFirst.filter { pane in all.contains { $0 === pane } }
        let ordered = recent + all.filter { pane in !recent.contains { $0 === pane } }
        let manyWindows = UmiTopology.windows.count > 1
        return ordered.compactMap { pane -> UmiPaletteEntry? in
            guard let location = UmiTopology.locate(pane) else { return nil }
            let cwd = UmiTopology.cwd(of: pane)
            var details: [String] = []
            var row = UmiPaletteEntry.PaneRow()
            if !cwd.isEmpty {
                row.folder = Self.abbreviate(cwd)
                var place = row.folder ?? ""
                if let git = UmiPaneContext.git(for: cwd) {
                    row.branch = git.branch
                    place += " · " + git.branch
                }
                details.append(place)
            }
            if let agent = UmiAttention.shared.agent(forPane: pane.id) {
                details.append("\(agent.kind.rawValue) · \(agent.status.rawValue)")
                row.command = agent.kind.rawValue
                row.hint = agent.status.rawValue
            } else if let command = UmiPaneContext.command(for: pane) {
                details.append(command.running ? "▸ \(command.text)" : command.text)
                row.command = command.text
                row.hint = command.running ? "Running..." : "Completed"
            }
            let place = "in \(location.tab.title)" + (manyWindows ? " · window #\(UmiTopology.windowNumber(location.window))" : "")
            details.append(place)
            row.place = place
            var entry = UmiPaletteEntry(id: "pane:" + pane.umiID, title: Self.title(of: pane), subtitle: details.joined(separator: "  ·  "),
                                        icon: UmiAttention.shared.agent(forPane: pane.id) != nil ? "bubble.left" : "terminal",
                                        color: location.tab.color.displayColor.map { Color($0) },
                                        badge: pane === self.pane ? "Current" : nil, value: pane.umiID,
                                        kind: .pane) { [weak self, weak pane] in
                self?.close(restoreFocus: false)
                if let pane { UmiLayout.focusPane(pane, activate: true) }
            }
            entry.paneRow = row
            return entry
        }
    }

    /// A pane's own title: its name, else its agent's title, else what its program set, else
    /// its folder.
    static func title(of pane: Ghostty.SurfaceView) -> String {
        if let name = UmiState.shared.paneName(pane.id), !name.isEmpty { return name }
        if let agent = UmiAttention.shared.agent(forPane: pane.id), !agent.title.isEmpty { return agent.title }
        let title = pane.title.trimmingCharacters(in: .whitespaces)
        if !title.isEmpty, title != "👻" { return title }
        let cwd = UmiTopology.cwd(of: pane)
        return cwd.isEmpty ? "Terminal" : UmiPaneContext.folderName(cwd)
    }

    static func abbreviate(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path == home { return "~" }
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    // MARK: Launch configurations (⌃⌘L, L-21)

    /// The launch configurations; `inCommands` (⌘P's list) leaves out files that can't be read and
    /// says what each entry is.
    private func launchConfigEntries(inCommands: Bool = false) -> [UmiPaletteEntry] {
        UmiLaunchConfigs.list().filter { !inCommands || $0.config != nil }.map { item in
            let file = Self.abbreviate(item.path)
            guard let config = item.config else {
                return UmiPaletteEntry(id: "launch:" + item.path, title: (item.path as NSString).lastPathComponent,
                                        subtitle: item.error ?? file, icon: "exclamationmark.triangle", value: item.path,
                                        kind: .action) { [weak self] in
                    self?.close(restoreFocus: false)
                    _ = UmiEditor.openFromSystem(URL(fileURLWithPath: item.path), inCurrentTab: true)
                }
            }
            let windows = config.windows.count == 1 ? "1 window" : "\(config.windows.count) windows"
            let tabs = config.tabCount == 1 ? "1 tab" : "\(config.tabCount) tabs"
            let what = inCommands ? "Launch configuration · " : ""
            return UmiPaletteEntry(id: "launch:" + item.id, title: config.name, subtitle: "\(what)\(windows) · \(tabs)  ·  \(file)",
                                    icon: "rectangle.3.group", keywords: (item.path as NSString).lastPathComponent,
                                    value: item.path, kind: .action) { [weak self] in
                self?.close(restoreFocus: false)
                do {
                    try UmiLaunchConfigs.open(config)
                } catch {
                    NSSound.beep()
                }
            }
        }
    }

    // MARK: Files

    private func startFiles() {
        let cwd = pane.map(UmiTopology.cwd(of:)).flatMap { $0.isEmpty ? nil : $0 } ?? NSHomeDirectory()
        if let files, files.folder == cwd {
            if mode == .files && !files.isLoaded { busy = "Indexing files…" }
            return
        }
        let index = UmiFileIndex(folder: cwd)
        files = index
        if mode == .files { busy = "Indexing files…" }
        index.load { [weak self, weak index] in
            guard let self, let index, self.files === index else { return }
            self.busy = nil
            guard self.isPresented, self.step == .list else { return }
            if self.mode == .files { self.refresh() }
            if self.mode == .commands, !self.isZeroState { self.appendFiles() }
        }
    }

    private var browseEntry: UmiPaletteEntry {
        UmiPaletteEntry(id: "browse", title: "Browse…", subtitle: "the Open panel", icon: "folder", kind: .action) { [weak self] in
            self?.close()
            UmiEditor.openPanel()
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
            // Only while the palette still shows this file list (not another mode or a question).
            guard !Task.isCancelled, let self, self.query == query, self.mode == .files, self.step == .list,
                  self.files === index else { return }
            self.entries = found
            self.selection = 0
        }
    }

    /// The unfiltered palette's matching files, after its other results.
    private func appendFiles() {
        filesTask?.cancel()
        guard let index = files, index.isLoaded, !isZeroState else { return }
        let query = self.query
        filesTask = Task { [weak self] in
            guard let found = await self?.fileEntries(query, in: index, extras: false) else { return }
            guard !Task.isCancelled, let self, self.query == query, self.mode == .commands, self.step == .list,
                  self.files === index else { return }
            let room = max(Self.resultLimit - self.entries.count, 0)
            let known = Set(self.entries.map(\.id))
            self.entries += found.filter { !known.contains($0.id) }.prefix(room)
        }
    }

    private func fileEntries(_ query: String, in index: UmiFileIndex, extras: Bool = true) async -> [UmiPaletteEntry] {
        let results = await index.search(query)
        let found = results.map { result in
            var entry = UmiPaletteEntry(id: "file:" + result.path, title: (result.path as NSString).lastPathComponent,
                                        subtitle: result.line.map { "\(result.path):\($0)" } ?? result.path,
                                        icon: UmiPaletteFileIcon.symbol(for: result.path),
                                        value: result.path, kind: .file) { [weak self] in
                self?.openFile(index.root + "/" + result.path, line: result.line)
            }
            entry.fileRef = .init(root: index.root, path: result.path, line: result.line)
            return entry
        }
        guard extras else { return found }
        // Nothing matches a name: offer to make it, in the pane's folder (Warp); `~/…` and an
        // absolute path name the place themselves.
        let name = UmiFileIndex.fileName(in: query)
        if found.isEmpty, !name.isEmpty {
            let expanded = (name as NSString).expandingTildeInPath
            let path = expanded.hasPrefix("/") ? expanded : (index.folder as NSString).appendingPathComponent(name)
            let create = UmiPaletteEntry(id: "create:" + path, title: "Create a file named \(name)…", icon: "plus.circle",
                                         value: path, kind: .create) { [weak self] in
                self?.createFile(path)
            }
            return [create, browseEntry]
        }
        return found + [browseEntry]
    }

    private func createFile(_ path: String) {
        let fm = FileManager.default
        do {
            if !fm.fileExists(atPath: path) {
                try fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
                guard fm.createFile(atPath: path, contents: Data()) else {
                    throw UmiError.failed("couldn't create \(path)")
                }
            }
            openFile(path, line: nil)
        } catch let error as UmiError {
            output = ("Create \((path as NSString).lastPathComponent)", error.message, true)
            step = .output
        } catch {
            output = ("Create \((path as NSString).lastPathComponent)", error.localizedDescription, true)
            step = .output
        }
    }

    private func openFile(_ path: String, line: Int?) {
        let url = URL(fileURLWithPath: path)
        guard let window else { return }
        let tab = pane.flatMap { UmiTopology.locate($0) }.map(\.tab) ?? window.selectedTab
        do {
            try UmiTextFile.checkOpenable(url)
            // Beside the pane the palette was opened from (E-9), focused.
            close(restoreFocus: false)
            let anchor = pane ?? tab.effectiveFocusedSurface
            guard let anchor else { throw UmiError.notFound("the tab has no panes") }
            let doc = try UmiFilePanes.open(url, mode: line != nil ? .source : nil, near: anchor, focus: true).doc
            if let line { doc.revealLine = line }
        } catch let error as UmiError {
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
                choose(entries[selection])
            } else if !isZeroState {
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
        // Nothing selected (the empty palette): Down selects the first row.
        guard selection >= 0 else {
            if delta > 0 { selection = 0 }
            return
        }
        // The empty palette doesn't wrap (Warp): Up from the first row selects nothing again,
        // Down stays on the last.
        if isZeroState {
            selection = selection + delta < 0 ? -1 : min(selection + delta, entries.count - 1)
            return
        }
        selection = ((selection + delta) % entries.count + entries.count) % entries.count
    }

    var placeholder: String {
        switch step {
        case .ask: return prompt ?? "Value"
        case .running: return busy ?? "Running…"
        case .output: return "Return or Esc closes"
        case .list: return mode.placeholder
        }
    }

    /// The text a row's matched characters are found in: the query without a filter or `:line`.
    var matchQuery: String {
        let q = query.trimmingCharacters(in: .whitespaces)
        return mode == .files ? UmiFileIndex.fileName(in: q) : q
    }

    // MARK: Scripted checks (debug.palette)

    /// Open a list with a query and return what it shows, once the CLI's commands or the
    /// files are loaded.
    func preview(_ mode: Mode, query: String, in window: TerminalController) async -> [UmiPaletteEntry] {
        if mode == .commands || mode == .actions { await UmiCLICatalog.shared.ensureLoaded() }
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
        if mode == .commands, Self.filterPrefix(in: query) != nil {
            // The filter applies on the next turn of the main loop.
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return entries
    }

    /// Choose an entry by title (answering its questions in order) and wait for the result.
    func perform(title: String, answers: [String], timeout: TimeInterval) async -> [String: Any] {
        guard let entry = entries.first(where: { $0.title == title }) else {
            return ["error": "no entry \"\(title)\"", "entries": entries.map(\.title)]
        }
        choose(entry)
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

    /// What the palette shows now, for `debug.palette.state`.
    var stateJSON: [String: Any] {
        var out: [String: Any] = ["presented": isPresented, "mode": mode.rawValue, "step": "\(step)",
                                  "entries": entries.map(\.title), "output": output?.text ?? "",
                                  "query": query, "filter": mode.filterWord ?? "", "selection": selection,
                                  "zero_state": isZeroState, "placeholder": placeholder,
                                  "rows": entries.map(\.json), "files_index": files != nil,
                                  "suggestion": filterSuggestion ?? ""]
        if isZeroState {
            out["chips"] = Self.chips.compactMap(\.chipTitle)
            out["chip_icons"] = Self.chips.map { $0.chipSymbol ?? "" }
        }
        return out
    }
}

extension UmiPaletteModel.Mode {
    /// The prefix that chooses this filter, shown in italics before the query (Warp's filter
    /// atoms; `tabs:` is Umi's, Warp reaches tabs only through ⌃Tab).
    var filterWord: String? {
        switch self {
        case .commands: return nil
        case .actions: return "actions:"
        case .panes: return "sessions:"
        case .files: return "files:"
        case .tabs: return "tabs:"
        case .launchConfigs: return nil
        }
    }

    /// The filter chip's title in the empty palette.
    var chipTitle: String? {
        switch self {
        case .commands, .tabs, .launchConfigs: return nil
        case .actions: return "actions"
        case .panes: return "sessions"
        case .files: return "files"
        }
    }

    /// The filter chip's icon (SF Symbols like Warp's file and terminal icons;
    /// Warp's actions chip has none).
    var chipSymbol: String? {
        switch self {
        case .commands, .actions, .launchConfigs: return nil
        case .tabs, .panes: return "terminal"
        case .files: return "doc"
        }
    }

    /// The field's placeholder (Warp's).
    var placeholder: String {
        switch self {
        case .commands: return "Search for a command"
        case .actions: return "Search actions"
        case .panes: return "Search sessions"
        case .files: return "Search files"
        case .tabs: return "Search tabs"
        case .launchConfigs: return "Search launch configurations"
        }
    }
}

/// One row of the palette.
struct UmiPaletteEntry: Identifiable {
    enum Kind: String { case action, cli, pane, file, choice, tab, create }

    /// What a pane's two-line row shows (Warp's navigation palette).
    struct PaneRow {
        var folder: String?
        var branch: String?
        var command: String?
        var hint = "Empty Session"
        var place = ""
    }

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
    /// The empty palette's section ("Recent", "Suggested").
    var section: String?
    /// The row's identity in the list: one entry can show under Recent and under Suggested.
    var rowID: String { section.map { "\($0):\(id)" } ?? id }
    var paneRow: PaneRow?

    /// A file row's file: its project folder, its path there and the line asked for (what Warp
    /// remembers of a file opened from the palette).
    struct FileRef {
        let root: String
        let path: String
        let line: Int?
        var absolute: String { root + "/" + path }
        var id: String { "recent-file:" + absolute + (line.map { ":\($0)" } ?? "") }
    }
    var fileRef: FileRef?
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
        var out: [String: Any] = ["title": title, "kind": kind.rawValue, "id": id, "row_id": rowID]
        if let subtitle { out["subtitle"] = subtitle }
        if let badge { out["badge"] = badge }
        if let value { out["value"] = value }
        if let symbols { out["shortcut"] = symbols.joined() }
        if let section { out["section"] = section }
        if let icon { out["icon"] = icon }
        return out
    }
}

/// The icon of a file row: an SF Symbol by file type. (One function, so a shared file-icon
/// table can replace it.)
enum UmiPaletteFileIcon {
    static func symbol(for path: String) -> String {
        switch (path as NSString).pathExtension.lowercased() {
        case "md", "markdown", "txt", "rst": return "doc.text"
        case "swift", "zig", "rs", "go", "c", "h", "cpp", "m", "py", "rb", "js", "ts", "tsx", "jsx", "java", "kt", "sh", "zsh", "bash":
            return "chevron.left.forwardslash.chevron.right"
        case "json", "yaml", "yml", "toml", "xml", "plist", "conf", "ini": return "curlybraces"
        case "png", "jpg", "jpeg", "gif", "svg", "webp", "icns", "pdf": return "photo"
        case "html", "css": return "globe"
        default: return "doc"
        }
    }
}

// MARK: - The CLI's commands

/// The CLI's own description of its commands (`umi help --json`), read from the bundled CLI
/// once per run of the app.
@MainActor
final class UmiCLICatalog {
    static let shared = UmiCLICatalog()

    struct Ask {
        let name: String
        let prompt: String
        let option: String?
        let choices: [String]
        let optional: Bool
        let kind: String
        let words: Bool
        /// An empty answer is an empty argument (`tab rename ""` clears the name).
        let keepEmpty: Bool
    }

    struct Action {
        let title: String
        let argv: [String]
        let ask: [Ask]
        let usage: String

        /// The command line with the answers in place.
        func argv(with answers: [String]) -> [String] {
            var out = argv
            for (ask, value) in zip(self.ask, answers) where !value.isEmpty || ask.keepEmpty {
                if let option = ask.option { out.append(option) }
                if ask.words { out += UmiShellWords.split(value) } else { out.append(value) }
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
        UmiCLIRunner.run(["help", "--json"], pane: nil, cwd: nil) { [weak self] status, out, _ in
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
                        words: ask["words"] as? Bool ?? false, keepEmpty: ask["empty"] as? Bool ?? false)
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
enum UmiCLIRunner {
    @discardableResult
    static func run(_ argv: [String], pane: Ghostty.SurfaceView?, cwd: String?,
                     completion: @escaping @MainActor (Int32, String, String) -> Void) -> Process? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: UmiPaths.cliPath)
        process.arguments = argv
        var env = ProcessInfo.processInfo.environment
        if let pane {
            for (key, value) in UmiEnvironment.paneVariables(paneID: pane.id) { env[key] = value }
        } else {
            env["UMI_STATE_DIR"] = UmiPaths.stateDirectory
            env.removeValue(forKey: "UMI_PANE_ID")
            env.removeValue(forKey: "UMI_INSTANCE")
        }
        process.environment = env
        if let cwd, FileManager.default.fileExists(atPath: cwd) { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        let out = UmiPipe.make(), err = UmiPipe.make()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        let outBuffer = UmiPipe.Collector(out), errBuffer = UmiPipe.Collector(err)
        process.terminationHandler = { process in
            let status = process.terminationStatus
            // What the CLI wrote is in the pipes by now; don't wait for end-of-file, which a
            // program it started could hold off.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                MainActor.assumeIsolated {
                    completion(status, outBuffer.finish(), errBuffer.finish())
                }
            }
        }
        do {
            try process.run()
        } catch {
            _ = outBuffer.finish()
            _ = errBuffer.finish()
            completion(127, "", "couldn't run \(UmiPaths.cliPath): \(error.localizedDescription)")
            return nil
        }
        return process
    }
}

/// Pipes for programs Umi runs. Their ends are close-on-exec, so terminals started meanwhile
/// (Ghostty forks shells without closing other descriptors) never keep them open.
enum UmiPipe {
    static func make() -> Pipe {
        let pipe = Pipe()
        for fd in [pipe.fileHandleForReading.fileDescriptor, pipe.fileHandleForWriting.fileDescriptor] {
            _ = fcntl(fd, F_SETFD, fcntl(fd, F_GETFD) | FD_CLOEXEC)
        }
        return pipe
    }

    /// Collects a pipe's output as it arrives.
    final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        private let handle: FileHandle

        init(_ pipe: Pipe) {
            handle = pipe.fileHandleForReading
            handle.readabilityHandler = { [weak self] handle in
                guard let self else { return }
                self.lock.lock()
                defer { self.lock.unlock() }
                let chunk = handle.availableData
                if chunk.isEmpty { handle.readabilityHandler = nil }
                self.data.append(chunk)
            }
        }

        /// Everything read so far. (Called a moment after the program exited: what it wrote has
        /// been read by then. Never waits for end-of-file.)
        func finish() -> String {
            handle.readabilityHandler = nil
            lock.lock()
            defer { lock.unlock() }
            return String(decoding: data, as: UTF8.self)
        }
    }
}

/// Words of a typed command line: spaces separate, quotes group, backslash escapes.
enum UmiShellWords {
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

enum UmiFuzzy {
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

    /// Which characters of `text` a query matches (the same greedy left-to-right match as
    /// `score`), nil when it doesn't.
    static func positions(_ query: String, _ text: String) -> Set<Int>? {
        let q = query.map { String($0).lowercased() }
        guard !q.isEmpty else { return [] }
        var out = Set<Int>()
        var qi = 0
        for (index, character) in text.enumerated() where qi < q.count {
            if String(character).lowercased() == q[qi] {
                out.insert(index)
                qi += 1
            }
        }
        return qi == q.count ? out : nil
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
final class UmiFileIndex {
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
        // Resolved, so a folder reached through a symlink (/var and /private/var) matches.
        let path = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        recent.removeAll { $0 == path }
        recent.insert(path, at: 0)
        if recent.count > 100 { recent.removeLast(recent.count - 100) }
    }

    static let limit = 100

    /// A query's file name: without `:line` (or `:line:column`) and a leading "./".
    static func fileName(in raw: String) -> String {
        var query = raw.trimmingCharacters(in: .whitespaces)
        let parts = query.split(separator: ":", omittingEmptySubsequences: false)
        if parts.count >= 2, Int(parts[1]) != nil {
            query = String(parts[0])
        } else if query.hasSuffix(":") {
            query.removeLast()
        }
        if query.hasPrefix("./") { query.removeFirst(2) }
        return query
    }

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
                let resolvedRoot = URL(fileURLWithPath: listing.root).resolvingSymlinksInPath().path
                for path in listing.files {
                    let absolute = resolvedRoot + "/" + path
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
        // Off the caller's actor, and stopped when the caller is cancelled (a newer keystroke).
        let worker = Task.detached(priority: .userInitiated) { () -> [Result] in
            guard !q.isEmpty else {
                return candidates.prefix(limit).map { Result(path: $0.path, line: line, recent: $0.recent, changed: $0.changed) }
            }
            var scored: [(Int, Int)] = []
            for (index, candidate) in candidates.enumerated() {
                if index % 4096 == 0 && Task.isCancelled { return [] }
                guard var score = UmiFuzzy.score(q, candidate.lowered) else { continue }
                // A match within the file name counts more.
                let nameStart = min(candidate.nameStart, candidate.lowered.count)
                if let nameScore = UmiFuzzy.score(q, Array(candidate.lowered[nameStart...])) {
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
        }
        return await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            worker.cancel()
        }
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
        let pipe = UmiPipe.make()
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

/// Warp's palette measures (`search/palette_styles.rs`, `command_palette/view.rs`,
/// `zero_state.rs`, `filter_chip_renderer.rs`, `navigation/render.rs`).
enum UmiPaletteStyle {
    static let width: CGFloat = 640
    static let maxHeight: CGFloat = 464
    static let top: CGFloat = 117
    static let cornerRadius: CGFloat = 8
    static let paddingBottom: CGFloat = 10
    /// Warp's monospace size, which the field, rows and filter word use.
    static let fontSize: CGFloat = 13
    static let fieldPaddingVertical: CGFloat = 16
    static let paddingHorizontal: CGFloat = 24
    static let rowHeight: CGFloat = 28
    static let rowGutter: CGFloat = 4
    static let rowRadius: CGFloat = 4
    static let paneRowHeight: CGFloat = 70
    static let sectionHeight: CGFloat = 31
    static let chipsHeight: CGFloat = 31 + 16
    static let zeroStatePadding: CGFloat = 8
    /// Rows highlighted with the accent: 90% when selected, 20% hovered (`with_opacity(90/20)`).
    static let selectedOpacity = 0.9
    static let hoveredOpacity = 0.2
}

/// The palette over a window's content.
struct UmiPaletteView: View {
    @ObservedObject var model: UmiPaletteModel
    let background: Color

    var body: some View {
        ZStack {
            if model.isPresented {
                GeometryReader { geometry in
                    VStack(spacing: 0) {
                        Spacer().frame(height: UmiPaletteStyle.top)
                        UmiPalettePanel(model: model, background: background,
                                        maxHeight: max(min(UmiPaletteStyle.maxHeight, geometry.size.height - UmiPaletteStyle.top - 16), 120))
                            .frame(width: min(UmiPaletteStyle.width, max(geometry.size.width - 32, 200)))
                        Spacer(minLength: 0)
                    }
                    .frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
                }
                .ignoresSafeArea(.container, edges: .top)
            }
        }
    }
}

/// Colors of the palette, derived from the terminal background as Warp's theme derives them.
struct UmiPaletteColors {
    let background: Color
    let light: Bool

    init(background: Color) {
        self.background = background
        light = NSColor(background).isLightColor
    }

    var ink: Color { light ? .black : .white }
    /// `surface_2`: the background with the foreground at 10% over it.
    var surface: Color {
        let base = NSColor(background).usingColorSpace(.sRGB) ?? .black
        let mixed = base.blended(withFraction: 0.10, of: light ? .black : .white) ?? base
        return Color(nsColor: mixed)
    }
    /// `surface_2` with black at 25% over it (a hovered filter chip).
    var surfaceDarkened: Color {
        let base = NSColor(surface).usingColorSpace(.sRGB) ?? .black
        return Color(nsColor: base.blended(withFraction: 0.25, of: .black) ?? base)
    }
    /// `outline`: the foreground at 10%.
    var outline: Color { ink.opacity(0.10) }
    var main: Color { ink.opacity(0.9) }
    var sub: Color { ink.opacity(0.6) }
    var hint: Color { ink.opacity(0.4) }
    var keycap: Color { ink.opacity(0.05) }
    var selected: Color { UmiTheme.accent.opacity(UmiPaletteStyle.selectedOpacity) }
    var hovered: Color { UmiTheme.accent.opacity(UmiPaletteStyle.hoveredOpacity) }
    /// Text on the selected row: the color that contrasts most with the accent (black).
    var mainOnSelected: Color { Color.black.opacity(0.9) }
    var subOnSelected: Color { Color.black.opacity(0.6) }
}

private struct UmiPalettePanel: View {
    @ObservedObject var model: UmiPaletteModel
    let background: Color
    let maxHeight: CGFloat
    @FocusState private var focused: Bool
    @State private var hovered: String?
    @State private var hoveredChip: UmiPaletteModel.Mode?

    private var colors: UmiPaletteColors { UmiPaletteColors(background: background) }

    var body: some View {
        let colors = self.colors
        VStack(alignment: .leading, spacing: 0) {
            field
            if model.step == .ask, let prompt = model.prompt {
                Text(prompt)
                    .font(.system(size: 12))
                    .foregroundColor(colors.sub)
                    .padding(.horizontal, UmiPaletteStyle.paddingHorizontal)
                    .padding(.bottom, 6)
            }
            content
        }
        .padding(.bottom, UmiPaletteStyle.paddingBottom)
        .background(colors.surface)
        .clipShape(RoundedRectangle(cornerRadius: UmiPaletteStyle.cornerRadius))
        .overlay(RoundedRectangle(cornerRadius: UmiPaletteStyle.cornerRadius).strokeBorder(colors.outline, lineWidth: 1))
        .shadow(color: .black.opacity(0.25), radius: 8, x: 0, y: 4)
        .environment(\.colorScheme, colors.light ? .light : .dark)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Palette")
    }

    private var field: some View {
        let colors = self.colors
        return ZStack {
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

            HStack(spacing: 0) {
                if let word = model.step == .list ? model.mode.filterWord : nil {
                    // The filter, as Warp writes it: italic and semibold, before the query.
                    Text(word)
                        .font(.system(size: UmiPaletteStyle.fontSize, weight: .semibold).italic())
                        .foregroundColor(colors.main)
                        .padding(.trailing, 8)
                        .accessibilityLabel("Filter \(word)")
                } else {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: UmiPaletteStyle.fontSize - 1))
                        .foregroundColor(colors.sub)
                        .frame(width: UmiPaletteStyle.fontSize, height: UmiPaletteStyle.fontSize)
                        .padding(.trailing, 12)
                        .accessibilityHidden(true)
                }
                TextField(model.placeholder, text: $model.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: UmiPaletteStyle.fontSize))
                    .foregroundColor(colors.main)
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
                    .onChange(of: model.mode) { _ in DispatchQueue.main.async { focused = true } }
                    .accessibilityLabel("Palette query")
                    .overlay(alignment: .leading) {
                        // The rest of a filter word the query begins; Tab applies it.
                        if let rest = model.filterSuggestion {
                            HStack(spacing: 0) {
                                Text(model.query).hidden()
                                Text(rest).foregroundColor(colors.hint)
                            }
                            .font(.system(size: UmiPaletteStyle.fontSize))
                            .lineLimit(1)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                        }
                    }
                if model.busy != nil {
                    ProgressView().controlSize(.small).padding(.leading, 8)
                }
            }
            .padding(.horizontal, UmiPaletteStyle.paddingHorizontal)
            .padding(.vertical, UmiPaletteStyle.fieldPaddingVertical)
        }
    }

    @ViewBuilder
    private var content: some View {
        let colors = self.colors
        if let output = model.output, model.step == .output {
            VStack(alignment: .leading, spacing: 6) {
                Text(output.title).font(.system(size: 12)).foregroundColor(output.failed ? Color.red.opacity(0.8) : colors.sub)
                ScrollView {
                    Text(output.text)
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundColor(colors.main)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: maxHeight - 100)
            }
            .padding(.horizontal, UmiPaletteStyle.paddingHorizontal)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Command output")
        } else if model.step == .running {
            Text(model.busy ?? "Running…").font(.system(size: 12)).foregroundColor(colors.sub)
                .padding(.horizontal, UmiPaletteStyle.paddingHorizontal)
        } else if model.isZeroState {
            zeroState
        } else if model.entries.isEmpty {
            if let busy = model.busy {
                Text(busy).font(.system(size: 12)).foregroundColor(colors.sub)
                    .padding(.horizontal, UmiPaletteStyle.paddingHorizontal)
            } else if model.step == .ask {
                Text("Type a value, then Return").font(.system(size: 12)).foregroundColor(colors.sub)
                    .padding(.horizontal, UmiPaletteStyle.paddingHorizontal)
            } else {
                // Warp draws its placeholder row as selected.
                placeholderRow("No results found")
            }
        } else {
            list(model.entries, zero: false)
        }
    }

    /// The empty unfiltered palette: filter chips, then Recent and Suggested.
    private var zeroState: some View {
        let colors = self.colors
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                ForEach(UmiPaletteModel.chips, id: \.self) { mode in
                    if let title = mode.chipTitle {
                        // Warp's chip: title, its filter's icon 8 px after, 8 × 16 padding inside a
                        // 1 px border (the border is drawn over the padding here, so 9 × 17);
                        // hovered, a 2 px accent border on the fill darkened by 25%.
                        let hover = hoveredChip == mode
                        HStack(spacing: 8) {
                            Text(title)
                            if let symbol = mode.chipSymbol {
                                Image(systemName: symbol)
                                    .font(.system(size: UmiPaletteStyle.fontSize - 3))
                                    .frame(width: UmiPaletteStyle.fontSize - 2, height: UmiPaletteStyle.fontSize - 2)
                            }
                        }
                            .font(.system(size: UmiPaletteStyle.fontSize - 2))
                            .foregroundColor(colors.main)
                            .padding(.vertical, 9)
                            .padding(.horizontal, 17)
                            .background(Capsule().fill(hover ? colors.surfaceDarkened : colors.surface))
                            .overlay(Capsule().strokeBorder(hover ? UmiTheme.accent : colors.sub, lineWidth: hover ? 2 : 1))
                            .contentShape(Capsule())
                            .onHover { hoveredChip = $0 ? mode : (hoveredChip == mode ? nil : hoveredChip) }
                            .onTapGesture { model.setFilter(mode) }
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel("Filter \(title)")
                            .accessibilityAddTraits(.isButton)
                    }
                }
            }
            .padding(.bottom, 16)
            .padding(.horizontal, UmiPaletteStyle.paddingHorizontal)
            if !model.entries.isEmpty {
                list(model.entries, zero: true)
            }
        }
        .padding(.vertical, UmiPaletteStyle.zeroStatePadding)
    }

    private func height(of entry: UmiPaletteEntry) -> CGFloat {
        entry.kind == .pane && entry.paneRow != nil ? UmiPaletteStyle.paneRowHeight : UmiPaletteStyle.rowHeight
    }

    private func list(_ entries: [UmiPaletteEntry], zero: Bool) -> some View {
        var total: CGFloat = 0
        var previous: String?
        for entry in entries {
            if zero, entry.section != previous { total += UmiPaletteStyle.sectionHeight }
            previous = entry.section
            total += height(of: entry)
        }
        let room = maxHeight - (UmiPaletteStyle.fontSize + 4 + 2 * UmiPaletteStyle.fieldPaddingVertical)
            - UmiPaletteStyle.paddingBottom - (zero ? UmiPaletteStyle.chipsHeight + 2 * UmiPaletteStyle.zeroStatePadding : 0)
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(entries.enumerated()), id: \.element.rowID) { index, entry in
                        if zero, let section = entry.section, index == 0 || entries[index - 1].section != section {
                            Text(section)
                                .font(.system(size: 12))
                                .foregroundColor(colors.main)
                                .frame(height: UmiPaletteStyle.sectionHeight)
                                .padding(.horizontal, UmiPaletteStyle.paddingHorizontal)
                                .accessibilityAddTraits(.isHeader)
                        }
                        row(entry, selected: index == model.selection)
                            .id(entry.rowID)
                            .onTapGesture { model.selection = index; model.submit() }
                    }
                }
            }
            .frame(height: max(min(total, room), UmiPaletteStyle.rowHeight))
            .onChange(of: model.selection) { selection in
                guard model.entries.indices.contains(selection) else { return }
                proxy.scrollTo(model.entries[selection].rowID)
            }
        }
    }

    private func placeholderRow(_ text: String) -> some View {
        let colors = self.colors
        return HStack {
            Text(text).font(.system(size: UmiPaletteStyle.fontSize, weight: .bold)).foregroundColor(colors.subOnSelected)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, UmiPaletteStyle.paddingHorizontal - UmiPaletteStyle.rowGutter)
        .frame(height: UmiPaletteStyle.rowHeight)
        .background(RoundedRectangle(cornerRadius: UmiPaletteStyle.rowRadius).fill(colors.selected))
        .padding(.horizontal, UmiPaletteStyle.rowGutter)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(text)
    }

    @ViewBuilder
    private func row(_ entry: UmiPaletteEntry, selected: Bool) -> some View {
        let colors = self.colors
        let main = selected ? colors.mainOnSelected : colors.main
        let sub = selected ? colors.subOnSelected : colors.sub
        Group {
            if entry.kind == .pane, let pane = entry.paneRow {
                paneRow(entry, pane, main: main, sub: sub, selected: selected)
            } else if entry.kind == .file {
                fileRow(entry, main: main, sub: sub)
            } else {
                HStack(spacing: 0) {
                    icon(entry, color: selected ? main : colors.main.opacity(0.8))
                    if entry.kind == .create {
                        Text(entry.title).font(.system(size: UmiPaletteStyle.fontSize)).foregroundColor(sub).lineLimit(1)
                    } else {
                        // Bold, in the secondary color, the matched characters in the primary.
                        UmiHighlight.text(entry.title, matching: model.matchQuery, base: sub, match: main,
                                          size: UmiPaletteStyle.fontSize, weight: .bold, matchWeight: .bold)
                            .lineLimit(1)
                    }
                    // A tab's folder; a launch configuration's windows and tabs (L-21).
                    if entry.kind == .tab || entry.id.hasPrefix("launch:"), let subtitle = entry.subtitle {
                        Text(subtitle).font(.system(size: UmiPaletteStyle.fontSize - 2)).foregroundColor(sub)
                            .lineLimit(1).padding(.leading, 8)
                    }
                    Spacer(minLength: 8)
                    if let symbols = entry.symbols {
                        UmiKeycaps(symbols: symbols, colors: colors)
                    }
                }
                .frame(height: UmiPaletteStyle.rowHeight)
            }
        }
        .padding(.horizontal, UmiPaletteStyle.paddingHorizontal - UmiPaletteStyle.rowGutter)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: UmiPaletteStyle.rowRadius)
                .fill(selected ? colors.selected : (hovered == entry.rowID ? colors.hovered : .clear))
        )
        .padding(.horizontal, UmiPaletteStyle.rowGutter)
        .onHover { hovered = $0 ? entry.rowID : (hovered == entry.rowID ? nil : hovered) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(entry.title)
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
    }

    private func icon(_ entry: UmiPaletteEntry, color: Color) -> some View {
        HStack(spacing: 0) {
            if let dot = entry.color {
                Circle().fill(dot).frame(width: 7, height: 7).padding(.trailing, 6)
            }
            Image(systemName: entry.icon ?? "circle")
                .font(.system(size: 12))
                .foregroundColor(color)
                .opacity(entry.icon == nil ? 0 : 1)
                .frame(width: 16, height: 16)
                .padding(.trailing, 8)
        }
    }

    /// ⌘O's one-line row: file-type icon, name, then the folder, cut at its start.
    private func fileRow(_ entry: UmiPaletteEntry, main: Color, sub: Color) -> some View {
        let path = entry.value ?? entry.title
        let name = (path as NSString).lastPathComponent
        let folder = (path as NSString).deletingLastPathComponent
        let query = model.matchQuery
        let inName = UmiFuzzy.positions(query, name)
        let inPath = inName == nil ? UmiFuzzy.positions(query, path) : nil
        let nameStart = path.count - name.count
        let nameHits = inName ?? Set((inPath ?? []).filter { $0 >= nameStart }.map { $0 - nameStart })
        let folderHits = Set((inPath ?? []).filter { $0 < folder.count })
        return HStack(spacing: 0) {
            Image(systemName: entry.icon ?? "doc")
                .font(.system(size: 12))
                .foregroundColor(main.opacity(0.8))
                .frame(width: 16, height: 16)
                .padding(.trailing, 8)
            UmiHighlight.text(name, positions: nameHits, base: main, match: main,
                              size: UmiPaletteStyle.fontSize - 1, weight: .regular, matchWeight: .bold)
                .lineLimit(1)
                .layoutPriority(1)
            if !folder.isEmpty {
                UmiHighlight.text(folder, positions: folderHits, base: sub, match: sub,
                                  size: UmiPaletteStyle.fontSize - 2, weight: .regular, matchWeight: .bold)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .padding(.leading, 8)
            }
            if let subtitle = entry.subtitle, let colon = subtitle.lastIndex(of: ":"), subtitle.hasPrefix(path) {
                Text(String(subtitle[colon...])).font(.system(size: UmiPaletteStyle.fontSize - 2)).foregroundColor(sub)
            }
            Spacer(minLength: 0)
        }
        .frame(height: UmiPaletteStyle.rowHeight)
    }

    /// ⇧⌘P's two-line row (Warp's navigation palette): title and folder/branch chips, then what
    /// runs there and where, with a "Current" pill on the pane the palette was opened from.
    private func paneRow(_ entry: UmiPaletteEntry, _ pane: UmiPaletteEntry.PaneRow, main: Color, sub: Color,
                         selected: Bool) -> some View {
        let colors = self.colors
        let small = UmiPaletteStyle.fontSize - 2
        let query = model.matchQuery
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                icon(entry, color: main.opacity(0.8))
                UmiHighlight.text(entry.title, matching: query, base: main, match: main,
                                  size: UmiPaletteStyle.fontSize, weight: .bold, matchWeight: .bold)
                    .lineLimit(1)
                    .padding(.trailing, 6)
                if let folder = pane.folder { chip(folder, symbol: "folder", main: main) }
                if let branch = pane.branch { chip(branch, symbol: "arrow.triangle.branch", main: main) }
                Spacer(minLength: 0)
            }
            HStack(spacing: 0) {
                if let command = pane.command, !command.isEmpty {
                    UmiHighlight.text(command, matching: query, base: main, match: main,
                                      size: small, weight: .regular, matchWeight: .bold, monospaced: true)
                        .lineLimit(1)
                        .padding(.trailing, 10)
                }
                Text(pane.hint).font(.system(size: small, design: .monospaced)).foregroundColor(sub).lineLimit(1)
                    .padding(.horizontal, 5)
                Text(pane.place).font(.system(size: small)).foregroundColor(sub).lineLimit(1)
                    .padding(.leading, 5)
                Spacer(minLength: 0)
                if let badge = entry.badge {
                    Text(badge)
                        .font(.system(size: UmiPaletteStyle.fontSize * 0.85, design: .monospaced))
                        .foregroundColor(colors.main)
                        .padding(.horizontal, 5)
                        .background(RoundedRectangle(cornerRadius: 4).fill(colors.background))
                        .padding(.leading, 10)
                        .padding(.trailing, 8)
                }
            }
            .padding(.leading, 24)
        }
        .frame(height: UmiPaletteStyle.paneRowHeight)
    }

    private func chip(_ text: String, symbol: String, main: Color) -> some View {
        HStack(spacing: 3) {
            Image(systemName: symbol).font(.system(size: 9))
            Text(text).font(.system(size: UmiPaletteStyle.fontSize - 2, design: .monospaced)).lineLimit(1).truncationMode(.head)
        }
        .foregroundColor(main.opacity(0.8))
        .padding(.horizontal, 5)
        .padding(.vertical, 1)
        .background(RoundedRectangle(cornerRadius: 4).fill(colors.keycap))
    }
}

/// A shortcut drawn as Warp draws it: each key in its own box.
struct UmiKeycaps: View {
    let symbols: [String]
    let colors: UmiPaletteColors

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(symbols.enumerated()), id: \.offset) { _, symbol in
                Text(symbol)
                    .font(.system(size: 12))
                    .foregroundColor(colors.sub)
                    .frame(minWidth: 8)
                    .padding(.horizontal, 6)
                    .frame(height: 20)
                    .background(RoundedRectangle(cornerRadius: 4).fill(colors.keycap))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(symbols.joined())
    }
}

/// Text with the characters a query matched in another color and weight.
enum UmiHighlight {
    static func text(_ text: String, matching query: String, base: Color, match: Color, size: CGFloat,
                     weight: Font.Weight, matchWeight: Font.Weight, monospaced: Bool = false) -> Text {
        self.text(text, positions: UmiFuzzy.positions(query, text) ?? [], base: base, match: match, size: size,
                  weight: weight, matchWeight: matchWeight, monospaced: monospaced)
    }

    static func text(_ text: String, positions: Set<Int>, base: Color, match: Color, size: CGFloat,
                     weight: Font.Weight, matchWeight: Font.Weight, monospaced: Bool = false) -> Text {
        let design: Font.Design = monospaced ? .monospaced : .default
        guard !positions.isEmpty else {
            return Text(text).font(.system(size: size, weight: weight, design: design)).foregroundColor(base)
        }
        var out = Text("")
        var run = ""
        var runMatched = false
        func flush() {
            guard !run.isEmpty else { return }
            out = out + Text(run).font(.system(size: size, weight: runMatched ? matchWeight : weight, design: design))
                .foregroundColor(runMatched ? match : base)
            run = ""
        }
        for (index, character) in text.enumerated() {
            let matched = positions.contains(index)
            if matched != runMatched { flush(); runMatched = matched }
            run.append(character)
        }
        flush()
        return out
    }
}

extension UmiPaletteModel {
    /// The palette drawn on its own, over a transparent window-sized canvas, for `umi screenshot`
    /// (terminals are composited separately and would otherwise cover it).
    @MainActor
    func capturedImage(in content: NSView) -> (image: NSImage, frame: NSRect)? {
        guard isPresented, let ghostty = UmiLayout.ghostty else { return nil }
        let bounds = content.bounds
        let host = NSHostingView(rootView: UmiPaletteView(model: self, background: ghostty.config.backgroundColor)
            .frame(width: bounds.width, height: bounds.height))
        host.frame = NSRect(origin: .zero, size: bounds.size)
        host.appearance = content.window?.effectiveAppearance
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.cacheDisplay(in: host.bounds, to: rep)
        let image = NSImage(size: bounds.size)
        image.addRepresentation(rep)
        return (image, bounds)
    }
}
