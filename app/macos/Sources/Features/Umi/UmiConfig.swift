import AppKit

/// What Umi reads from the user's config file itself (design/primitives.md, "Queries and lists",
/// "Slots", "Keys and palette commands"), next to Ghostty's settings in the same file:
///
/// ```
/// list.needs-you = agent.status=needs_input | sort status_since
/// slot.badge = @needs-you
/// key.ctrl+cmd+y = go --next @needs-you
/// command."Organize into tabs" = ~/bin/organize-tabs
/// ```
///
/// Ghostty skips these keys (`Config.umiOwnsKey`). Each executable in `~/.config/umi/commands/` is a
/// palette command too. The file (and the files it includes with `config-file`) is read again
/// whenever it changes.
@MainActor
final class UmiConfig {
    static let shared = UmiConfig()

    // MARK: Defaults

    /// The lists Umi defines; the config can redefine any of them.
    static let defaultLists: [(name: String, query: String)] = [
        ("needs-you", "agent.status=needs_input | sort status_since"),
        ("unseen", "unseen and agent.status!=working and agent.status!=needs_input | sort changed_at"),
        ("jump", "@needs-you then @unseen"),
        ("manager", "role=manager"),
    ]

    struct Slot {
        let name: String
        let defaultValue: String
        let summary: String
        /// The step that puts it to use, while it is only stored.
        var later: String?
    }

    /// The slots, a fixed set (design/primitives.md, "Slots"). `jump`'s value is the list `jump`.
    static let slots: [Slot] = [
        Slot(name: "jump", defaultValue: "@needs-you then @unseen",
             summary: "where ⌃⌘J (go --next jump) goes: the list `jump`"),
        Slot(name: "badge", defaultValue: "@needs-you", summary: "the Dock badge: how many panes match"),
        Slot(name: "landing", defaultValue: "none",
             summary: "the pane focused on returning to Umi after `landing.after` away (none: stay)"),
        Slot(name: "landing.after", defaultValue: "10m", summary: "how long away counts as returning"),
        Slot(name: "tab.summary",
             defaultValue: "focused and agent.kind then (agent.status=needs_input or agent.status=error) | sort -status_since"
                + " then unseen | sort -status_since then agent.kind | sort -status_since",
             summary: "which pane speaks for a tab in the sidebar and gives its row the pane indicator: the first match among its panes, those on show first"),
        Slot(name: "sidebar.line2", defaultValue: "{agent.title or command or cwd}",
             summary: "a tab row's second line, from the tab.summary pane"),
        Slot(name: "strip.make-room", defaultValue: "not pinned and not focused | sort seen_at",
             summary: "which pane is hidden when one comes in"),
        Slot(name: "indicator.working", defaultValue: "muted",
             summary: "the pane indicator's colour while working: muted, amber, green, violet, grey, #RRGGBB or none"),
        Slot(name: "indicator.needs_you", defaultValue: "amber",
             summary: "the pane indicator's colour while it needs you"),
        Slot(name: "indicator.finished", defaultValue: "muted",
             summary: "the pane indicator's colour while finished and unseen"),
        Slot(name: "indicator.focus", defaultValue: "3%",
             summary: "how much brighter the focused pane of a split is (0 for none, at most 20%)"),
        Slot(name: "done-check", defaultValue: "^Status: done",
             summary: "sets agent.done: a regular expression the last line of the agent's last message must match"),
    ]

    // MARK: What the config says

    struct Command {
        let title: String
        /// An executable in the commands folder.
        var path: String?
        /// A `command."Title" = …` line: a shell command.
        var line: String?
    }

    struct KeyBinding {
        let spec: String
        let shortcut: UmiShortcut
        let action: String
    }

    /// Something in the config Umi couldn't use.
    struct Problem {
        let file: String
        let line: Int
        let message: String
        var text: String { "\((file as NSString).lastPathComponent):\(line): \(message)" }
    }

    private(set) var userLists: [String: String] = [:]
    private(set) var userListOrder: [String] = []
    private(set) var userSlots: [String: String] = [:]
    private(set) var keyBindings: [KeyBinding] = []
    private(set) var lineCommands: [Command] = []
    private(set) var problems: [Problem] = []

    private var parsed: [String: Result<UmiQuery.Query, UmiQuery.ParseError>] = [:]
    private var stamps: [String: Date?] = [:]
    private var lastCheck = Date.distantPast

    /// Change it in tests.
    var configFile: String { UmiPaths.userConfigFile }
    var commandsDirectory: String { ((configFile as NSString).deletingLastPathComponent as NSString).appendingPathComponent("commands") }

    private init() {}

    // MARK: Reading the file

    /// Read the config again if any of its files changed (checked at most twice a second).
    func refresh(force: Bool = false) {
        let now = Date()
        guard force || now.timeIntervalSince(lastCheck) > 0.5 else { return }
        lastCheck = now
        if !force, !stamps.isEmpty, stamps.allSatisfy({ Self.modified($0.key) == $0.value }) { return }
        load()
    }

    private static func modified(_ path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }

    private func load() {
        var lists: [String: String] = [:]
        var order: [String] = []
        var slots: [String: String] = [:]
        var keys: [String: KeyBinding] = [:]
        var keyOrder: [String] = []
        var commands: [Command] = []
        var problems: [Problem] = []
        var stamps: [String: Date?] = [:]
        var queue = [configFile]
        var index = 0
        while index < queue.count {
            let path = queue[index]
            index += 1
            guard stamps[path] == nil else { continue }
            stamps[path] = Self.modified(path)
            guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
            let dir = (path as NSString).deletingLastPathComponent
            for (number, raw) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let line = raw.trimmingCharacters(in: .whitespaces)
                guard !line.isEmpty, !line.hasPrefix("#"), let eq = Self.separator(line) else { continue }
                let key = line[..<eq].trimmingCharacters(in: .whitespaces)
                let value = Self.unquote(line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces))
                func problem(_ message: String) { problems.append(Problem(file: path, line: number + 1, message: message)) }
                if key == "config-file" {
                    var include = value
                    if include.hasPrefix("?") { include.removeFirst() }
                    include = (include as NSString).expandingTildeInPath
                    if !include.hasPrefix("/") { include = dir + "/" + include }
                    queue.append(include)
                } else if key.hasPrefix("list.") {
                    let name = String(key.dropFirst(5))
                    guard UmiAttributes.isValidKey(name) else { problem("\"\(name)\" isn't a list name"); continue }
                    if lists[name] == nil { order.append(name) }
                    lists[name] = value
                } else if key.hasPrefix("slot.") {
                    let name = String(key.dropFirst(5))
                    guard Self.slots.contains(where: { $0.name == name }) else {
                        problem("there's no slot \"\(name)\" (see `\(UmiPaths.cliName) slot ls`)")
                        continue
                    }
                    if name == "jump" {
                        // The jump slot is the list `jump`.
                        if lists["jump"] == nil { order.append("jump") }
                        lists["jump"] = value
                    } else {
                        slots[name] = value
                    }
                } else if key.hasPrefix("key.") {
                    let spec = String(key.dropFirst(4))
                    guard let shortcut = UmiShortcut(spec: spec) else { problem("can't read the keys \"\(spec)\""); continue }
                    let id = shortcut.spec
                    if keys[id] == nil { keyOrder.append(id) }
                    if value.isEmpty || value == "unbind" {
                        keys.removeValue(forKey: id)
                    } else {
                        keys[id] = KeyBinding(spec: spec, shortcut: shortcut, action: value)
                    }
                } else if key.hasPrefix("command.") {
                    let title = Self.unquote(String(key.dropFirst(8)))
                    guard !title.isEmpty else { problem("a command needs a title"); continue }
                    commands.removeAll { $0.title == title }
                    if !value.isEmpty { commands.append(Command(title: title, line: value)) }
                }
            }
        }
        parsed = [:]
        userLists = lists
        userListOrder = order
        userSlots = slots
        keyBindings = keyOrder.compactMap { keys[$0] }
        lineCommands = commands
        self.stamps = stamps
        // Every list is checked once, here: it parses, and the lists it names exist and don't name it.
        let names = Self.defaultLists.map(\.name) + order.filter { name in !Self.defaultLists.contains { $0.name == name } }
        for name in names {
            if let error = listProblem(name) {
                problems.append(Problem(file: configFile, line: 0, message: "list \(name): \(error)"))
            }
        }
        self.problems = problems
    }

    /// The `=` between a key and its value: the first one, except inside a quoted key
    /// (`command."a = b" = …`).
    private static func separator(_ line: String) -> String.Index? {
        var quoted = false
        for index in line.indices {
            let c = line[index]
            if c == "\"" { quoted.toggle() }
            if c == "=" && !quoted { return index }
        }
        return nil
    }

    /// A value in double quotes, as Ghostty reads them: without the quotes.
    private static func unquote(_ text: String) -> String {
        guard text.count >= 2, text.hasPrefix("\""), text.hasSuffix("\""),
              text.filter({ $0 == "\"" }).count == 2 else { return text }
        return String(text.dropFirst().dropLast())
    }

    // MARK: Lists

    /// Every list's name: Umi's, then the config's own.
    var listNames: [String] {
        refresh()
        return Self.defaultLists.map(\.name) + userListOrder.filter { name in !Self.defaultLists.contains { $0.name == name } }
    }

    /// A list's query as written.
    func listText(_ name: String) -> String? {
        refresh()
        return userLists[name] ?? Self.defaultLists.first { $0.name == name }?.query
    }

    func isDefault(list name: String) -> Bool { userLists[name] == nil }

    /// A list's query, parsed (nil: no such list, or it doesn't parse; `listError` says which).
    func list(_ name: String) -> UmiQuery.Query? {
        guard let text = listText(name), case .success(let query) = parse(text) else { return nil }
        return query
    }

    /// What's wrong with a list: its query doesn't parse, or a list it names (directly or through
    /// other lists) doesn't exist, doesn't parse, or names it back.
    func listError(_ name: String) -> String? {
        refresh()
        return listProblem(name)
    }

    /// What's wrong with a query's lists (see `listError`), nil when nothing is.
    func referenceError(_ query: UmiQuery.Query) -> String? { referenceError(query, path: []) }

    private func storedText(_ name: String) -> String? {
        userLists[name] ?? Self.defaultLists.first { $0.name == name }?.query
    }

    private func listProblem(_ name: String) -> String? {
        guard let text = storedText(name) else { return nil }
        switch parse(text) {
        case .failure(let error): return error.description
        case .success(let query): return referenceError(query, path: [name])
        }
    }

    private func referenceError(_ query: UmiQuery.Query, path: [String]) -> String? {
        for name in query.lists {
            if path.contains(name) {
                return "@\(name) names itself (\((path + [name]).map { "@" + $0 }.joined(separator: " → ")))"
            }
            guard let text = storedText(name) else { return "there's no list \"\(name)\"" }
            guard case .success(let inner) = parse(text) else { return "list \(name) doesn't parse" }
            if let error = referenceError(inner, path: path + [name]) { return error }
        }
        return nil
    }

    func parse(_ text: String) -> Result<UmiQuery.Query, UmiQuery.ParseError> {
        if let known = parsed[text] { return known }
        let result: Result<UmiQuery.Query, UmiQuery.ParseError>
        do { result = .success(try UmiQuery.parse(text)) } catch let error as UmiQuery.ParseError { result = .failure(error) } catch {
            result = .failure(UmiQuery.ParseError(position: 1, message: "\(error)"))
        }
        if parsed.count > 256 { parsed = [:] }
        parsed[text] = result
        return result
    }

    // MARK: Slots

    func slot(_ name: String) -> String {
        refresh()
        if name == "jump" { return listText("jump") ?? "" }
        return userSlots[name] ?? Self.slots.first { $0.name == name }?.defaultValue ?? ""
    }

    func isDefault(slot name: String) -> Bool {
        name == "jump" ? userLists["jump"] == nil : userSlots[name] == nil
    }

    /// A slot whose value is a query, parsed; nil for `none` or a value that doesn't parse (which
    /// then falls back to the default).
    func slotQuery(_ name: String) -> UmiQuery.Query? {
        let value = slot(name)
        if value == "none" || value.isEmpty { return nil }
        if case .success(let query) = parse(value) { return query }
        guard let fallback = Self.slots.first(where: { $0.name == name })?.defaultValue,
              case .success(let query) = parse(fallback) else { return nil }
        return query
    }

    // MARK: Commands

    /// The palette's commands: the config's lines, then the commands folder's executables.
    var commands: [Command] {
        refresh()
        var out = lineCommands
        let dir = commandsDirectory
        let fm = FileManager.default
        let names = ((try? fm.contentsOfDirectory(atPath: dir)) ?? []).sorted()
        for name in names where !name.hasPrefix(".") {
            let path = (dir as NSString).appendingPathComponent(name)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue, fm.isExecutableFile(atPath: path) else { continue }
            let title = Self.title(forFile: name)
            guard !out.contains(where: { $0.title == title }) else { continue }
            out.append(Command(title: title, path: path))
        }
        return out
    }

    /// "organize-into-tabs.sh" → "Organize into tabs".
    static func title(forFile name: String) -> String {
        var base = (name as NSString).deletingPathExtension
        if base.isEmpty { base = name }
        let words = base.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
        return words.prefix(1).uppercased() + words.dropFirst()
    }

    func command(titled title: String) -> Command? {
        commands.first { $0.title == title } ?? commands.first { $0.title.lowercased() == title.lowercased() }
    }

    /// The keys bound to a command (`key.… = command run "Title"`, or the title itself).
    func keys(for command: Command) -> [String] {
        keyBindings.filter { binding in
            let words = UmiShellWords.split(binding.action)
            return binding.action == command.title || (words.count == 3 && words[0] == "command" && words[1] == "run" && words[2] == command.title)
        }.map { $0.shortcut.spec }
    }

    func binding(for shortcut: UmiShortcut) -> KeyBinding? {
        refresh()
        return keyBindings.last { $0.shortcut == shortcut }
    }
}
