import AppKit

// MARK: - Queries over the open panes

extension UmiTopology {
    /// One open pane and where it is, in `ls` order.
    struct Placed {
        let pane: Ghostty.SurfaceView
        let tab: UmiTab
        let window: TerminalController
    }

    /// Every open pane in `ls` order: windows by index, tabs in sidebar order, panes on show in layout
    /// order, then hidden ones.
    static var placedPanes: [Placed] {
        windows.flatMap { window in
            window.tabs.flatMap { tab in
                (panes(of: tab, in: window) + window.hiddenPanes(of: tab)).map { Placed(pane: $0, tab: tab, window: window) }
            }
        }
    }

    static func queryItems(_ placed: [Placed]) -> [UmiQuery.Item] {
        let attributes = UmiAttributes.shared
        return placed.enumerated().map { index, entry in
            UmiQuery.Item(id: entry.pane.id, order: index, payload: entry) { [weak pane = entry.pane] key in
                pane.flatMap { attributes.value(key, of: $0) }
            }
        }
    }

    static func evaluator(_ placed: [Placed]? = nil) -> UmiQuery.Evaluator {
        let config = UmiConfig.shared
        return UmiQuery.Evaluator(items: queryItems(placed ?? placedPanes)) { config.list($0) }
    }

    /// Parse a query, failing as the CLI reports it (exit 1, with the position).
    static func parseQuery(_ text: String) throws -> UmiQuery.Query {
        switch UmiConfig.shared.parse(text) {
        case .success(let query): return query
        case .failure(let error): throw UmiError.badRequest(error.description)
        }
    }

    /// The panes a query picks, in its order. A list it names that doesn't exist is an error.
    static func match(_ query: UmiQuery.Query, among placed: [Placed]? = nil) throws -> [Placed] {
        for name in query.lists where UmiConfig.shared.listText(name) == nil {
            throw UmiError.notFound("there's no list \"\(name)\" (see `\(UmiPaths.cliName) list ls`)")
        }
        for name in query.lists {
            if let error = UmiConfig.shared.listError(name) { throw UmiError.badRequest("list \(name): \(error)") }
        }
        return evaluator(placed).run(query).compactMap { $0.payload as? Placed }
    }

    static func match(_ text: String) throws -> [Placed] { try match(try parseQuery(text)) }

    /// Every pane a selector names: all of a query's matches, else the one pane.
    static func resolvePanes(_ selector: String, caller: UmiCaller) throws -> [Ghostty.SurfaceView] {
        guard UmiQuery.looksLikeQuery(selector) else { return [try resolvePane(selector, caller: caller)] }
        let found = try match(selector).map(\.pane)
        guard !found.isEmpty else { throw UmiError.notFound("no pane matches \(selector)") }
        return found
    }

    /// The panes a request is about: the selector's, else the caller's own pane or the focused one.
    static func panes(_ selector: String?, caller: UmiCaller) throws -> [Ghostty.SurfaceView] {
        if let selector, !selector.isEmpty { return try resolvePanes(selector, caller: caller) }
        return [try pane(nil, caller: caller)]
    }

    /// Every tab a selector names: for a query, each tab holding a match (in the order of the
    /// first match in it); else the selector's one tab, or the request's own.
    static func everyTab(_ selector: String?, caller: UmiCaller) throws -> [(TerminalController, UmiTab)] {
        guard let selector, UmiQuery.looksLikeQuery(selector) else { return [try tab(selector, caller: caller)] }
        let found = try match(selector)
        guard !found.isEmpty else { throw UmiError.notFound("no tab holds a pane matching \(selector)") }
        var seen = Set<ObjectIdentifier>()
        return found.filter { seen.insert(ObjectIdentifier($0.tab)).inserted }.map { ($0.window, $0.tab) }
    }

    /// Every window a selector names: for a query, each window holding a match; else one.
    static func everyWindow(_ selector: String?, caller: UmiCaller) throws -> [TerminalController] {
        guard let selector, UmiQuery.looksLikeQuery(selector) else { return [try window(selector, caller: caller)] }
        let found = try match(selector)
        guard !found.isEmpty else { throw UmiError.notFound("no window holds a pane matching \(selector)") }
        var seen = Set<ObjectIdentifier>()
        return found.filter { seen.insert(ObjectIdentifier($0.window)).inserted }.map(\.window)
    }

    /// `ls --where QUERY`: the matching panes, each with its tab and window.
    static func whereJSON(_ text: String) throws -> [String: Any] {
        ["panes": try match(text).map { paneInfoJSON($0.pane) }]
    }
}

// MARK: - go

/// `go LIST|QUERY`, `go --next LIST|QUERY`, `go --back` (design/cli.md, "Lists and `go`"); ⌃⌘J and ⌃⌘K.
///
/// A walk belongs to the window it started in (design/cli.md choice 5). `go --next` continues the walk
/// whose last step is the pane focused now; anything else that moved focus since then starts a new
/// walk from where focus is. `go --back` returns to the pane focused before the walk's first step.
@MainActor
enum UmiGo {
    private struct Walk {
        var origin: Weak<Ghostty.SurfaceView>?
        var last: UUID?
    }

    private static var walks: [ObjectIdentifier: Walk] = [:]

    /// The query a `go` argument names: a list by name, else the text as a query.
    static func target(_ text: String) throws -> (UmiQuery.Query, String) {
        let config = UmiConfig.shared
        if config.listText(text) != nil {
            if let error = config.listError(text) { throw UmiError.badRequest("list \(text): \(error)") }
            return (try UmiTopology.parseQuery("@" + text), text)
        }
        if !UmiQuery.looksLikeQuery(text), !text.contains(" ") {
            // A bare word that isn't a list: a key that is set (`go pinned`), if it reads as one.
            guard UmiAttributes.isValidKey(text) else {
                throw UmiError.notFound("there's no list \"\(text)\" (see `\(UmiPaths.cliName) list ls`)")
            }
        }
        return (try UmiTopology.parseQuery(text), text)
    }

    /// Put a list's first pane (`next`: the walk's next pane) in front of the user.
    @discardableResult
    static func go(_ text: String, next: Bool) throws -> Ghostty.SurfaceView {
        let (query, name) = try target(text)
        let panes = try UmiTopology.match(query).map(\.pane)
        let here = UmiTopology.currentPane
        let continuing = next ? walkKey(endingAt: here) : nil
        var pick: Ghostty.SurfaceView?
        if next {
            if let key = continuing, let last = walks[key]?.last, let index = panes.firstIndex(where: { $0.id == last }) {
                // The one after the walk's last step, wrapping round.
                let rotated = Array(panes[(index + 1)...]) + Array(panes[...index])
                pick = rotated.first { $0 !== here }
            } else {
                pick = panes.first { $0 !== here }
            }
        } else {
            pick = panes.first
        }
        guard let pane = pick else {
            throw UmiError.notFound("nothing in \(name)")
        }
        if let key = continuing {
            walks[key]?.last = pane.id
        } else if let window = UmiTopology.currentWindow {
            walks[ObjectIdentifier(window)] = Walk(origin: here.map { Weak($0) }, last: pane.id)
        }
        UmiLayout.focusPane(pane, activate: true)
        return pane
    }

    /// Back to where the walk started.
    @discardableResult
    static func back() throws -> Ghostty.SurfaceView {
        guard let key = backKey, let origin = walks[key]?.origin?.value, UmiTopology.locate(origin) != nil else {
            throw UmiError.notFound("there's no walk to go back from")
        }
        walks.removeValue(forKey: key)
        UmiLayout.focusPane(origin, activate: true)
        return origin
    }

    static var canGoBack: Bool {
        guard let key = backKey, let origin = walks[key]?.origin?.value else { return false }
        return UmiTopology.locate(origin) != nil
    }

    /// The walk `go --back` returns from: the one whose last step is focused now, else the current
    /// window's.
    private static var backKey: ObjectIdentifier? {
        prune()
        if let key = walkKey(endingAt: UmiTopology.currentPane) { return key }
        guard let window = UmiTopology.currentWindow else { return nil }
        let key = ObjectIdentifier(window)
        return walks[key] == nil ? nil : key
    }

    private static func walkKey(endingAt pane: Ghostty.SurfaceView?) -> ObjectIdentifier? {
        guard let pane else { return nil }
        return walks.first { $0.value.last == pane.id }?.key
    }

    private static func prune() {
        let open = Set(UmiTopology.windows.map(ObjectIdentifier.init))
        walks = walks.filter { open.contains($0.key) }
    }

    /// For `debug.navigation`.
    static var state: [[String: Any]] {
        walks.map { ["origin": $0.value.origin?.value?.umiID ?? "", "last": $0.value.last?.uuidString.lowercased() ?? ""] }
    }
}

// MARK: - Slots that act

/// The slots read when Umi decides something (design/primitives.md, "Slots").
@MainActor
enum UmiSlots {
    /// The Dock badge: how many panes the `badge` slot picks.
    static var badgeCount: Int {
        guard let query = UmiConfig.shared.slotQuery("badge") else { return 0 }
        return (try? UmiTopology.match(query).count) ?? 0
    }

    /// The pane that speaks for a tab in its sidebar row (`tab.summary`): the first match among its
    /// panes (on show, then hidden).
    static func summaryPane(of tab: UmiTab, in window: TerminalController) -> Ghostty.SurfaceView? {
        // Its panes on show, then the hidden ones (attention-ui.md: a hidden pane that needs you
        // still speaks for its tab).
        let leaves = UmiTopology.panes(of: tab, in: window) + window.hiddenPanes(of: tab)
        guard !leaves.isEmpty, let query = UmiConfig.shared.slotQuery("tab.summary") else { return nil }
        let placed = leaves.map { UmiTopology.Placed(pane: $0, tab: tab, window: window) }
        return (try? UmiTopology.match(query, among: placed))?.first?.pane
    }

    /// A tab row's second line from the `sidebar.line2` template, when the user set one (nil: the
    /// built-in line, which is the default's look).
    static func line2(_ pane: Ghostty.SurfaceView?) -> String? {
        guard !UmiConfig.shared.isDefault(slot: "sidebar.line2"), let pane else { return nil }
        let template = UmiConfig.shared.slot("sidebar.line2")
        return UmiQuery.render(template) { key in
            let value = UmiAttributes.shared.value(key, of: pane)
            return key == "cwd" ? value.map(UmiSidebarRowModel.abbreviate) : value
        }
    }

    /// `done-check`: whether the agent's last message says it finished.
    static func doneCheck(_ reply: String) -> Bool {
        let last = reply.split(whereSeparator: \.isNewline).last { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard let last else { return false }
        let line = last.trimmingCharacters(in: .whitespaces)
        let pattern = UmiConfig.shared.slot("done-check")
        if let regex = try? NSRegularExpression(pattern: pattern) {
            return regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil
        }
        return line.hasPrefix("Status: done")
    }

    // MARK: landing

    private static var resignedAt: Date?
    private static var observers: [NSObjectProtocol] = []

    private static var badgePending = false

    /// The `badge` slot may count by any attribute: recount after any change to panes (once per turn
    /// of the run loop, however many changes it made).
    private static func badgeMayHaveChanged(_ event: String) {
        guard event.hasPrefix("pane.") || event.hasPrefix("tab.") || event.hasPrefix("window."), !badgePending else { return }
        badgePending = true
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                badgePending = false
                (NSApp.delegate as? AppDelegate)?.refreshDockBadge()
            }
        }
    }

    /// Watch Umi going to the background and coming back, for `landing`, and changes to panes, for
    /// `badge`.
    static func start() {
        guard observers.isEmpty else { return }
        UmiEvents.shared.addListener { name, _ in MainActor.assumeIsolated { badgeMayHaveChanged(name) } }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { resignedAt = Date() }
        })
        observers.append(center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                guard let since = resignedAt else { return }
                resignedAt = nil
                returned(after: Date().timeIntervalSince(since))
            }
        })
    }

    /// Umi came back to the front after `away` seconds: past `landing.after`, focus the first pane
    /// of `landing`. Caused by `config`. Returns the pane focused.
    @discardableResult
    static func returned(after away: TimeInterval) -> Ghostty.SurfaceView? {
        let config = UmiConfig.shared
        guard let query = config.slotQuery("landing") else { return nil }
        let after = UmiQuery.duration(config.slot("landing.after")) ?? 600
        guard away >= after, let pane = (try? UmiTopology.match(query))?.first?.pane else { return nil }
        UmiCause.during(UmiCause(kind: "config", command: "slot landing")) {
            UmiLayout.focusPane(pane, activate: false)
        }
        return pane
    }
}

// MARK: - Control methods

/// `list`, `go`, `slot`, `command`, `ls --where` and `wait --attr` (design/cli.md).
@MainActor
enum UmiListsRPC {
    static let methods: Set<String> = ["go", "list.ls", "list.show", "slot.ls", "command.ls", "command.run",
                                       "pane.match", "debug.landing", "debug.config_errors"]

    static func handle(_ method: String, _ params: UmiParams, caller: UmiCaller) async throws -> [String: Any] {
        let config = UmiConfig.shared
        switch method {
        case "go":
            let pane: Ghostty.SurfaceView
            if params.bool("back") ?? false {
                pane = try UmiGo.back()
            } else {
                guard let target = params.string("target"), !target.isEmpty else {
                    throw UmiError.badRequest("go: give a LIST or a QUERY (or --back)")
                }
                pane = try UmiGo.go(target, next: params.bool("next") ?? false)
            }
            var result = UmiTopology.paneInfoJSON(pane)
            result["pane"] = pane.umiID
            return result

        case "list.ls":
            let evaluator = UmiTopology.evaluator()
            return ["lists": config.listNames.map { name -> [String: Any] in
                var out: [String: Any] = ["name": name, "query": config.listText(name) ?? "", "default": config.isDefault(list: name)]
                if let error = config.listError(name) {
                    out["error"] = error
                    out["count"] = 0
                } else if let query = config.list(name) {
                    out["count"] = evaluator.run(query).count
                }
                return out
            }, "problems": config.problems.map(\.text)]

        case "list.show":
            guard let name = params.string("name"), !name.isEmpty else { throw UmiError.badRequest("list show: name a list") }
            guard config.listText(name) != nil else {
                throw UmiError.notFound("there's no list \"\(name)\" (see `\(UmiPaths.cliName) list ls`)")
            }
            return try UmiTopology.whereJSON("@" + name)

        case "slot.ls":
            return ["slots": UmiConfig.slots.map { slot -> [String: Any] in
                var out: [String: Any] = ["name": slot.name, "value": config.slot(slot.name),
                                          "default": config.isDefault(slot: slot.name), "summary": slot.summary]
                if let later = slot.later { out["used_from"] = later }
                let value = config.slot(slot.name)
                if ["jump", "badge", "landing", "tab.summary", "strip.make-room"].contains(slot.name), value != "none" {
                    switch config.parse(value) {
                    case .failure(let error): out["error"] = error.description
                    case .success(let query): if let error = config.referenceError(query) { out["error"] = error }
                    }
                }
                if let error = UmiIndicator.slotError(slot.name, value) { out["error"] = error }
                return out
            }, "problems": config.problems.map(\.text)]

        case "command.ls":
            return ["commands": config.commands.map { command -> [String: Any] in
                var out: [String: Any] = ["title": command.title]
                if let path = command.path { out["path"] = path }
                if let line = command.line { out["line"] = line }
                let keys = config.keys(for: command)
                if !keys.isEmpty { out["keys"] = keys }
                return out
            }]

        case "command.run":
            guard let title = params.string("title"), !title.isEmpty else { throw UmiError.badRequest("command run: give a TITLE") }
            guard let command = config.command(titled: title) else {
                throw UmiError.notFound("there's no command \"\(title)\" (see `\(UmiPaths.cliName) command ls`)")
            }
            let pane = try UmiTopology.pane(params.string("pane"), caller: caller)
            let cause = caller.cause ?? "palette"
            let (status, out, err) = await UmiCommandRunner.run(command, pane: pane, cause: cause)
            return ["title": command.title, "status": Int(status), "stdout": out, "stderr": err]

        case "pane.match":
            // `wait --attr`: whether the pane matches the query now, and its attributes.
            let pane = try UmiTopology.pane(params.string("pane"), caller: caller)
            let query = try UmiTopology.parseQuery(params.string("query") ?? "")
            guard let location = UmiTopology.locate(pane) else { throw UmiError.notFound("the pane isn't in a window") }
            let placed = [UmiTopology.Placed(pane: pane, tab: location.tab, window: location.window)]
            let matches = try !UmiTopology.match(query, among: placed).isEmpty
            return ["pane": pane.umiID, "matches": matches, "attributes": UmiAttributes.shared.all(pane)]

        case "debug.landing":
            // Umi coming back to the front after `away` seconds (the `landing` slot), without the screen.
            let pane = UmiSlots.returned(after: params.double("away") ?? 0)
            return ["pane": pane?.umiID ?? NSNull()]

        case "debug.config_errors":
            // What Ghostty reported when it loaded the config file (Umi's own lines must not be among it).
            let errors = (NSApp.delegate as? AppDelegate)?.ghostty.config.errors ?? []
            return ["errors": errors]

        default:
            throw UmiError.badRequest("unknown method \(method)")
        }
    }
}

// MARK: - Running palette and key commands

/// Runs a palette command (a config line or an executable in the commands folder), or a key
/// binding's `umi` command line, with the calling pane, tab and window in its environment
/// (design/cli.md, "Configuration").
@MainActor
enum UmiCommandRunner {
    /// The environment of a command the palette or a key binding runs.
    static func environment(pane: Ghostty.SurfaceView?, cause: String) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        for key in ["UMI_PANE", "UMI_TAB", "UMI_WINDOW", "UMI_INSTANCE", "UMI_CAUSE"] { env.removeValue(forKey: key) }
        if let pane {
            for (key, value) in UmiEnvironment.paneVariables(paneID: pane.id) { env[key] = value }
            if let location = UmiTopology.locate(pane) {
                env["UMI_TAB"] = location.tab.idString
                env["UMI_WINDOW"] = location.window.umiIDString
            }
        }
        env["UMI_STATE_DIR"] = UmiPaths.stateDirectory
        env["UMI_CLI"] = UmiPaths.cliPath
        env["UMI_CAUSE"] = cause
        // `umi` itself is found on PATH (the bundle's folder first).
        env["PATH"] = UmiPaths.executableDirectory + ":" + (env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
        return env
    }

    /// Run a palette command; returns its exit status, stdout and stderr.
    static func run(_ command: UmiConfig.Command, pane: Ghostty.SurfaceView?, cause: String) async -> (Int32, String, String) {
        await withCheckedContinuation { continuation in
            start(command, pane: pane, cause: cause) { status, out, err in continuation.resume(returning: (status, out, err)) }
        }
    }

    @discardableResult
    static func start(_ command: UmiConfig.Command, pane: Ghostty.SurfaceView?, cause: String,
                      completion: @escaping @MainActor (Int32, String, String) -> Void) -> Process? {
        let process = Process()
        if let path = command.path {
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = []
        } else {
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", command.line ?? ""]
        }
        process.environment = environment(pane: pane, cause: cause)
        let cwd = pane.map(UmiTopology.cwd(of:)) ?? ""
        process.currentDirectoryURL = URL(fileURLWithPath: !cwd.isEmpty && FileManager.default.fileExists(atPath: cwd) ? cwd : NSHomeDirectory())
        return launch(process, completion: completion)
    }

    /// Run a key binding's action: a palette command's title, `@LIST` (go --next to it), or a `umi`
    /// command line.
    static func runBinding(_ binding: UmiConfig.KeyBinding) {
        let pane = UmiTopology.currentPane
        let cause = "key:" + binding.shortcut.spec
        if let command = UmiConfig.shared.command(titled: binding.action) {
            start(command, pane: pane, cause: cause) { status, _, _ in if status != 0 { NSSound.beep() } }
            return
        }
        var words = UmiShellWords.split(binding.action)
        if words.first == UmiPaths.cliName { words.removeFirst() }
        if words.count == 1, words[0].hasPrefix("@") { words = ["go", "--next", words[0]] }
        guard !words.isEmpty else { NSSound.beep(); return }
        let cwd = pane.map(UmiTopology.cwd(of:)).flatMap { $0.isEmpty ? nil : $0 }
        UmiCLIRunner.run(words, pane: pane, cwd: cwd, cause: cause) { status, _, _ in
            if status != 0 { NSSound.beep() }
        }
    }

    private static func launch(_ process: Process, completion: @escaping @MainActor (Int32, String, String) -> Void) -> Process? {
        let out = UmiPipe.make(), err = UmiPipe.make()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        let outBuffer = UmiPipe.Collector(out), errBuffer = UmiPipe.Collector(err)
        process.terminationHandler = { process in
            let status = process.terminationStatus
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                MainActor.assumeIsolated { completion(status, outBuffer.finish(), errBuffer.finish()) }
            }
        }
        do {
            try process.run()
        } catch {
            _ = outBuffer.finish()
            _ = errBuffer.finish()
            completion(127, "", "couldn't run it: \(error.localizedDescription)")
            return nil
        }
        return process
    }
}
