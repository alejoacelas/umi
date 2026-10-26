import AppKit

/// A keyboard shortcut: a key and ⌃⌥⇧⌘ modifiers. Written as "ctrl+shift+cmd+left" in
/// `umi shortcuts` and shown as "⌃⇧⌘←".
struct UmiShortcut: Hashable {
    /// A single lowercased character, or one of `named`'s values (arrows, tab, return …).
    let key: String
    let modifiers: NSEvent.ModifierFlags

    static let relevant: NSEvent.ModifierFlags = [.control, .option, .shift, .command]

    init(key: String, modifiers: NSEvent.ModifierFlags) {
        self.key = key.count == 1 ? key.lowercased() : key
        self.modifiers = modifiers.intersection(Self.relevant)
    }

    static func == (a: UmiShortcut, b: UmiShortcut) -> Bool {
        a.key == b.key && a.modifiers.rawValue == b.modifiers.rawValue
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(key)
        hasher.combine(modifiers.rawValue)
    }

    typealias NamedKey = (name: String, character: String, symbol: String, ghostty: String)

    /// Keys with names, and the character AppKit uses for each in menus.
    static let named: [NamedKey] = {
        func fn(_ code: Int) -> String { String(UnicodeScalar(code)!) }
        var keys: [NamedKey] = [
            ("left", fn(NSLeftArrowFunctionKey), "←", "arrow_left"),
            ("right", fn(NSRightArrowFunctionKey), "→", "arrow_right"),
            ("up", fn(NSUpArrowFunctionKey), "↑", "arrow_up"),
            ("down", fn(NSDownArrowFunctionKey), "↓", "arrow_down"),
            ("home", fn(NSHomeFunctionKey), "↖", "home"),
            ("end", fn(NSEndFunctionKey), "↘", "end"),
            ("pageup", fn(NSPageUpFunctionKey), "⇞", "page_up"),
            ("pagedown", fn(NSPageDownFunctionKey), "⇟", "page_down"),
            ("forwarddelete", fn(NSDeleteFunctionKey), "⌦", "delete"),
            ("tab", "\t", "⇥", "tab"),
            ("return", "\r", "↩", "enter"),
            ("esc", "\u{1b}", "⎋", "escape"),
            ("space", " ", "Space", "space"),
            ("delete", "\u{8}", "⌫", "backspace"),
        ]
        for n in 1...20 {
            let key: NamedKey = ("f\(n)", fn(NSF1FunctionKey + n - 1), "F\(n)", "f\(n)")
            keys.append(key)
        }
        return keys
    }()

    /// The key a key event is, with the modifiers held.
    init?(event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(Self.relevant)
        let byCode: [UInt16: String] = [48: "tab", 36: "return", 76: "return", 53: "esc", 49: "space", 51: "delete",
                                        117: "forwarddelete", 123: "left", 124: "right", 126: "up", 125: "down",
                                        115: "home", 119: "end", 116: "pageup", 121: "pagedown"]
        if let name = byCode[event.keyCode], let entry = Self.named.first(where: { $0.name == name }) {
            self.init(key: entry.character, modifiers: modifiers)
            return
        }
        if let chars = event.charactersIgnoringModifiers, let scalar = chars.unicodeScalars.first,
           (NSF1FunctionKey...NSF35FunctionKey).contains(Int(scalar.value)) {
            self.init(key: chars, modifiers: modifiers)
            return
        }
        // The key's own character, as if no modifier were held (⇧⌘[ is "[" with ⇧, not "{").
        let plain = event.characters(byApplyingModifiers: []).flatMap { $0.count == 1 ? $0 : nil }
        guard let chars = plain ?? event.charactersIgnoringModifiers, chars.count == 1 else { return nil }
        self.init(key: chars, modifiers: modifiers)
    }

    /// A menu item's key equivalent.
    init?(menuItem: NSMenuItem) {
        let equivalent = menuItem.keyEquivalent
        guard !equivalent.isEmpty else { return nil }
        var modifiers = menuItem.keyEquivalentModifierMask
        if equivalent.count == 1, equivalent != equivalent.lowercased() { modifiers.insert(.shift) }
        self.init(key: equivalent, modifiers: modifiers)
    }

    /// Parse "ctrl+shift+cmd+left", "cmd+shift+[", "⌃⌘J" or "super+shift+]".
    init?(spec raw: String) {
        var text = raw.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        var modifiers: NSEvent.ModifierFlags = []
        // Symbols: ⌃⌥⇧⌘ prefixes.
        let symbols: [Character: NSEvent.ModifierFlags] = ["⌃": .control, "⌥": .option, "⇧": .shift, "⌘": .command]
        while let first = text.first, let flag = symbols[first], text.count > 1 {
            modifiers.insert(flag)
            text.removeFirst()
        }
        // Words: mod+mod+key (a "+" key is written as the last part, "cmd++").
        var parts = text.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        if text.hasSuffix("++") { parts = Array(parts.dropLast(2)) + ["+"] }
        guard let keyPart = parts.last, !keyPart.isEmpty else { return nil }
        for part in parts.dropLast() {
            switch part.lowercased() {
            case "cmd", "command", "super", "⌘": modifiers.insert(.command)
            case "ctrl", "control", "⌃": modifiers.insert(.control)
            case "option", "opt", "alt", "⌥": modifiers.insert(.option)
            case "shift", "⇧": modifiers.insert(.shift)
            default: return nil
            }
        }
        let lowered = keyPart.lowercased()
        if let entry = Self.named.first(where: { $0.name == lowered || $0.ghostty == lowered || $0.symbol == keyPart }) {
            self.init(key: entry.character, modifiers: modifiers)
            return
        }
        let aliases = ["enter": "return", "escape": "esc", "backspace": "delete", "arrow_left": "left"]
        if let alias = aliases[lowered], let entry = Self.named.first(where: { $0.name == alias }) {
            self.init(key: entry.character, modifiers: modifiers)
            return
        }
        // Ghostty's physical key names.
        if let physical = Self.physicalCharacter(lowered) {
            self.init(key: physical, modifiers: modifiers)
            return
        }
        guard keyPart.count == 1 else { return nil }
        self.init(key: keyPart, modifiers: modifiers)
    }

    private static func physicalCharacter(_ name: String) -> String? {
        if name.hasPrefix("digit_"), name.count == 7 { return String(name.last!) }
        if name.hasPrefix("key_"), name.count == 5 { return String(name.last!) }
        let table = ["bracket_left": "[", "bracket_right": "]", "comma": ",", "period": ".", "slash": "/",
                     "semicolon": ";", "quote": "'", "backquote": "`", "backslash": "\\", "minus": "-", "equal": "="]
        return table[name]
    }

    private var namedEntry: NamedKey? {
        Self.named.first { $0.character == key }
    }

    /// For `umi shortcuts`: "ctrl+shift+cmd+left".
    var spec: String {
        var parts: [String] = []
        if modifiers.contains(.control) { parts.append("ctrl") }
        if modifiers.contains(.option) { parts.append("option") }
        if modifiers.contains(.shift) { parts.append("shift") }
        if modifiers.contains(.command) { parts.append("cmd") }
        parts.append(namedEntry?.name ?? key)
        return parts.joined(separator: "+")
    }

    /// For Ghostty's config: "ctrl+shift+super+arrow_left".
    var ghosttyTrigger: String {
        var parts: [String] = []
        if modifiers.contains(.control) { parts.append("ctrl") }
        if modifiers.contains(.option) { parts.append("alt") }
        if modifiers.contains(.shift) { parts.append("shift") }
        if modifiers.contains(.command) { parts.append("super") }
        parts.append(namedEntry?.ghostty ?? key)
        return parts.joined(separator: "+")
    }

    /// Symbols for display, one per modifier and one for the key.
    var symbols: [String] {
        var out: [String] = []
        if modifiers.contains(.control) { out.append("⌃") }
        if modifiers.contains(.option) { out.append("⌥") }
        if modifiers.contains(.shift) { out.append("⇧") }
        if modifiers.contains(.command) { out.append("⌘") }
        out.append(namedEntry?.symbol ?? key.uppercased())
        return out
    }

    var display: String { symbols.joined() }

    /// F1–F35.
    var isFunctionKey: Bool {
        key.unicodeScalars.first.map { (NSF1FunctionKey...NSF35FunctionKey).contains(Int($0.value)) } ?? false
    }

    /// What a menu item's key equivalent is set to.
    var keyEquivalent: String { key }
}

// MARK: - Ghostty keybindings

/// Ghostty's keybindings in effect, worked out the way Umi loads its configuration: Ghostty's
/// built-in defaults, then Umi's defaults (`defaults.conf`), then the user's Ghostty config
/// files, then the changes made in Umi's shortcuts editor (`keybindings.conf`).
@MainActor
enum UmiGhosttyBindings {
    struct Binding {
        var trigger: String
        var action: String
        /// Where it was set: "Ghostty", "Umi", "your config" or "Umi shortcuts".
        var source: String
        var shortcut: UmiShortcut? { UmiShortcut(spec: trigger) }
    }

    private static var cachedDefaults: [(trigger: String, action: String)]?

    /// Ghostty's built-in defaults, from the app's own `+list-keybinds --default`.
    static func builtInDefaults() -> [(trigger: String, action: String)] {
        if let cachedDefaults { return cachedDefaults }
        let out = listDefaults()
        cachedDefaults = out
        return out
    }

    /// Read the defaults ahead of time, off the main thread.
    static func warm() {
        guard cachedDefaults == nil else { return }
        DispatchQueue.global(qos: .utility).async {
            let out = listDefaults()
            DispatchQueue.main.async { MainActor.assumeIsolated { if cachedDefaults == nil { cachedDefaults = out } } }
        }
    }

    /// Runs the app's executable with `+list-keybinds`. Reads to the end of its output rather
    /// than waiting on it, which would spin the run loop (and can re-enter SwiftUI updates).
    nonisolated private static func listDefaults() -> [(trigger: String, action: String)] {
        let process = Process()
        process.executableURL = Bundle.main.executableURL
        process.arguments = ["+list-keybinds", "--default", "--plain"]
        let pipe = UmiPipe.make()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        var out: [(String, String)] = []
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
                if case .bind(let trigger, let action)? = parse(String(line)) { out.append((trigger, action)) }
            }
        } catch {}
        return out
    }

    enum Line { case bind(String, String), unbind(String), clear }

    /// One `keybind = …` line.
    nonisolated static func parse(_ line: String) -> Line? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("keybind"), let eq = trimmed.firstIndex(of: "=") else { return nil }
        guard trimmed[..<eq].trimmingCharacters(in: .whitespaces) == "keybind" else { return nil }
        var value = trimmed[trimmed.index(after: eq)...].trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 { value = String(value.dropFirst().dropLast()) }
        if value == "clear" { return .clear }
        // The separator is the first "=" that doesn't start a key ("super+==action" binds "=").
        let chars = Array(value)
        var split: Int?
        for (index, c) in chars.enumerated() where c == "=" {
            let startsKey = index == 0 || chars[index - 1] == "+" || chars[index - 1] == ">" || chars[index - 1] == ":"
            if !startsKey { split = index; break }
        }
        guard let split else { return nil }
        var trigger = String(chars[..<split])
        let action = String(chars[(split + 1)...])
        for prefix in ["global:", "all:", "unconsumed:", "performable:"] {
            while trigger.hasPrefix(prefix) { trigger.removeFirst(prefix.count) }
        }
        if action == "unbind" { return .unbind(trigger) }
        return .bind(trigger, action)
    }

    /// The same trigger whatever its spelling ("cmd+shift+]" and "shift+super+]").
    static func normalized(_ trigger: String) -> String {
        trigger.split(separator: ">").map { step -> String in
            var parts = step.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
            if step.hasSuffix("++") { parts = Array(parts.dropLast(2)) + ["+"] }
            guard let key = parts.last else { return String(step) }
            let mods = parts.dropLast().map { mod -> String in
                switch mod.lowercased() {
                case "cmd", "command", "super": return "super"
                case "opt", "option", "alt": return "alt"
                case "control", "ctrl": return "ctrl"
                default: return mod.lowercased()
                }
            }.sorted()
            return (mods + [key.count == 1 ? key.lowercased() : key]).joined(separator: "+")
        }.joined(separator: ">")
    }

    /// The user's config files, in the order Umi loads them: Ghostty's, then Umi's own.
    static var userConfigFiles: [String] {
        let env = ProcessInfo.processInfo.environment
        let xdg = env["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? (NSHomeDirectory() + "/.config")
        let support = NSHomeDirectory() + "/Library/Application Support/com.mitchellh.ghostty"
        return [xdg + "/ghostty/config", xdg + "/ghostty/config.ghostty", support + "/config", support + "/config.ghostty",
                UmiPaths.userConfigFile]
    }

    /// Every binding in effect, in load order.
    static func effective() -> [Binding] {
        var bindings: [String: Binding] = [:]
        var order: [String] = []
        func apply(_ line: Line, source: String) {
            switch line {
            case .clear:
                bindings = [:]
                order = []
            case .unbind(let trigger):
                bindings.removeValue(forKey: normalized(trigger))
            case .bind(let trigger, let action):
                let key = normalized(trigger)
                if bindings[key] == nil { order.append(key) }
                bindings[key] = Binding(trigger: trigger, action: action, source: source)
            }
        }
        for (trigger, action) in builtInDefaults() { apply(.bind(trigger, action), source: "Ghostty") }
        if let defaults = UmiTheme.defaultsConfigPath() { load(defaults, source: "Umi", apply: apply) }
        // `config-file` includes load after the files that name them, as in Ghostty.
        var queue = userConfigFiles.map { ($0, true) }
        var index = 0
        var seen = Set<String>()
        while index < queue.count {
            let (path, optional) = queue[index]
            index += 1
            guard seen.insert(path).inserted else { continue }
            guard FileManager.default.fileExists(atPath: path) else { _ = optional; continue }
            for include in load(path, source: "your config", apply: apply) { queue.append((include, true)) }
        }
        load(UmiShortcutStore.ghosttyFile, source: "Umi shortcuts", apply: apply)
        return order.compactMap { bindings[$0] }
    }

    /// Apply a file's keybind lines; returns the files it includes.
    @discardableResult
    private static func load(_ path: String, source: String, apply: (Line, String) -> Void) -> [String] {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        var includes: [String] = []
        let dir = (path as NSString).deletingLastPathComponent
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") { continue }
            if line.hasPrefix("config-file"), let eq = line.firstIndex(of: "=") {
                var value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
                if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 { value = String(value.dropFirst().dropLast()) }
                if value.hasPrefix("?") { value.removeFirst() }
                value = (value as NSString).expandingTildeInPath
                if !value.hasPrefix("/") { value = dir + "/" + value }
                includes.append(value)
                continue
            }
            if let parsed = parse(line) { apply(parsed, source) }
        }
        return includes
    }
}

// MARK: - Store

/// Shortcuts changed in Umi's shortcuts editor (L-17), kept in Umi's state directory:
/// - `shortcuts.json`: the changes, for Umi's own items and for Ghostty actions;
/// - `keybindings.conf`: the Ghostty part as Ghostty `keybind` lines, which Umi loads after
///   the user's own Ghostty config files. The user's Ghostty config files are never edited.
@MainActor
final class UmiShortcutStore {
    static let shared = UmiShortcutStore()

    nonisolated static var file: String { UmiPaths.stateDirectory + "/shortcuts.json" }
    nonisolated static var ghosttyFile: String { UmiPaths.stateDirectory + "/keybindings.conf" }

    /// A change to a Ghostty action: its old triggers unbound, and an optional new one.
    struct GhosttyChange: Codable, Equatable {
        var unbind: [String]
        var bind: String?
    }

    private struct Saved: Codable {
        var version = 1
        /// Umi item id → shortcut spec ("" means none).
        var menu: [String: String] = [:]
        /// Ghostty action → change.
        var ghostty: [String: GhosttyChange] = [:]
    }

    private var saved = Saved()

    private init() {
        if let data = FileManager.default.contents(atPath: Self.file),
           let decoded = try? JSONDecoder().decode(Saved.self, from: data) {
            saved = decoded
        }
    }

    // MARK: Umi items

    func shortcut(for item: UmiShortcuts.Item) -> UmiShortcut? {
        guard let spec = saved.menu[item.id] else { return item.defaultShortcut }
        return UmiShortcut(spec: spec)
    }

    func isChanged(_ item: UmiShortcuts.Item) -> Bool { saved.menu[item.id] != nil }

    // MARK: Listing

    struct Entry {
        enum Kind: String { case umi, ghostty }
        let id: String
        let title: String
        let kind: Kind
        let menu: String?
        let shortcuts: [UmiShortcut]
        let triggers: [String]
        let defaults: [String]
        let changed: Bool
        let source: String?

        var json: [String: Any] {
            var out: [String: Any] = ["id": id, "title": title, "kind": kind.rawValue,
                                      "keys": kind == .umi ? shortcuts.map(\.spec) : triggers,
                                      "display": shortcuts.map(\.display), "default": defaults, "changed": changed]
            if let menu { out["menu"] = menu }
            if let source { out["source"] = source }
            return out
        }
    }

    /// Every Umi item and every Ghostty action that has (or had by default) a binding.
    func entries() -> [Entry] {
        var out: [Entry] = UmiShortcuts.items.map { item in
            Entry(id: item.id, title: item.title, kind: .umi, menu: item.submenu.map { "\(item.menu) > \($0)" } ?? item.menu,
                  shortcuts: item.shortcut.map { [$0] } ?? [], triggers: [],
                  defaults: item.defaultShortcut.map { [$0.spec] } ?? [], changed: isChanged(item), source: nil)
        }
        let effective = UmiGhosttyBindings.effective()
        var actions: [String] = []
        var defaults: [String: [String]] = [:]
        for (trigger, action) in UmiGhosttyBindings.builtInDefaults() {
            if defaults[action] == nil { actions.append(action) }
            defaults[action, default: []].append(trigger)
        }
        for binding in effective where defaults[binding.action] == nil && !actions.contains(binding.action) {
            actions.append(binding.action)
        }
        for action in actions {
            let bound = effective.filter { $0.action == action }
            out.append(Entry(id: "ghostty:" + action, title: Self.describe(action), kind: .ghostty, menu: nil,
                             shortcuts: bound.compactMap(\.shortcut), triggers: bound.map(\.trigger),
                             defaults: defaults[action] ?? [], changed: saved.ghostty[action] != nil,
                             source: bound.last?.source))
        }
        return out
    }

    /// "goto_split:previous" → "Goto split: previous".
    static func describe(_ action: String) -> String {
        let parts = action.split(separator: ":", maxSplits: 1).map(String.init)
        var name = (parts.first ?? action).replacingOccurrences(of: "_", with: " ")
        name = name.prefix(1).uppercased() + name.dropFirst()
        return parts.count > 1 ? "\(name): \(parts[1])" : name
    }

    // MARK: Changing

    enum StoreError: Error, CustomStringConvertible {
        case unknown(String), badShortcut(String), needsModifier
        var description: String {
            switch self {
            case .unknown(let id): return "no shortcut \"\(id)\" (see `umi shortcuts`)"
            case .badShortcut(let spec): return "can't read the shortcut \"\(spec)\" (write it like cmd+shift+] or ctrl+cmd+left)"
            case .needsModifier: return "a menu shortcut needs ⌘ or ⌃ (or is a function key)"
            }
        }
    }

    /// Set (nil: clear) the shortcut of an Umi item or Ghostty action. Returns notes about other
    /// shortcuts the change took the key from.
    @discardableResult
    func set(_ id: String, to shortcut: UmiShortcut?) throws -> [String] {
        // Menu shortcuts need ⌘ or ⌃ (anything else is typing); terminal bindings can be any key.
        if let shortcut, !id.hasPrefix("ghostty:") {
            guard shortcut.isFunctionKey || !shortcut.modifiers.isDisjoint(with: [.command, .control]) else { throw StoreError.needsModifier }
        }
        var notes: [String] = []
        if id.hasPrefix("ghostty:") {
            let action = String(id.dropFirst("ghostty:".count))
            // Only an action Ghostty has (bound by default or in the user's config): anything else
            // would be written into the configuration as a broken binding.
            guard Self.isKnownGhosttyAction(action) else { throw StoreError.unknown(id) }
            let current = UmiGhosttyBindings.effective().filter { $0.action == action }.map(\.trigger)
            var change = saved.ghostty[action] ?? GhosttyChange(unbind: [], bind: nil)
            // Unbind what's bound now (except what this change itself bound).
            for trigger in current where trigger != change.bind && !change.unbind.contains(trigger) { change.unbind.append(trigger) }
            change.bind = shortcut?.ghosttyTrigger
            saved.ghostty[action] = change
            // Another action given this key here before loses it: the latest assignment counts.
            if let shortcut, let trigger = change.bind {
                for (other, var otherChange) in saved.ghostty where other != action && otherChange.bind == trigger {
                    otherChange.bind = nil
                    saved.ghostty[other] = otherChange
                    notes.append("the terminal's \(Self.describe(other)) no longer has \(shortcut.display)")
                }
            }
            // An Umi item with this key would take it first.
            if let shortcut {
                for item in UmiShortcuts.items where item.shortcut == shortcut {
                    saved.menu[item.id] = ""
                    notes.append("\(item.title) no longer has \(shortcut.display)")
                }
            }
        } else {
            guard let item = UmiShortcuts.item(id: id) else { throw StoreError.unknown(id) }
            saved.menu[item.id] = shortcut?.spec ?? ""
            if saved.menu[item.id] == item.defaultShortcut?.spec ?? "" { saved.menu.removeValue(forKey: item.id) }
            if let shortcut {
                for other in UmiShortcuts.items where other.id != item.id && other.shortcut == shortcut {
                    saved.menu[other.id] = ""
                    notes.append("\(other.title) no longer has \(shortcut.display)")
                }
                // A Ghostty binding on the same key would take it first in terminals.
                for binding in UmiGhosttyBindings.effective() where binding.shortcut == shortcut {
                    var change = saved.ghostty[binding.action] ?? GhosttyChange(unbind: [], bind: nil)
                    if change.bind == binding.trigger { change.bind = nil }
                    if !change.unbind.contains(binding.trigger) { change.unbind.append(binding.trigger) }
                    saved.ghostty[binding.action] = change
                    notes.append("the terminal's \(Self.describe(binding.action)) no longer has \(shortcut.display)")
                }
            }
        }
        try save()
        return notes
    }

    /// An action Ghostty has: its name (before any `:parameter`) is one bound by default or in the
    /// user's config, and nothing in it would break the binding line.
    static func isKnownGhosttyAction(_ action: String) -> Bool {
        let name = String(action.split(separator: ":", maxSplits: 1).first ?? "")
        guard !name.isEmpty, !action.contains(where: { $0.isWhitespace || $0 == "=" }) else { return false }
        let known = UmiGhosttyBindings.builtInDefaults().map { $0.1 } + UmiGhosttyBindings.effective().map(\.action)
        return known.contains { $0 == action || $0.split(separator: ":", maxSplits: 1).first.map(String.init) == name }
    }

    /// Back to the default (nil: everything).
    func reset(_ id: String?) throws {
        if let id {
            if id.hasPrefix("ghostty:") {
                saved.ghostty.removeValue(forKey: String(id.dropFirst("ghostty:".count)))
            } else {
                guard let item = UmiShortcuts.item(id: id) else { throw StoreError.unknown(id) }
                // Its default key may have been given to something else meanwhile: setting it back
                // takes it from there, as any assignment does.
                try set(id, to: item.defaultShortcut)
                return
            }
        } else {
            saved = Saved()
        }
        try save()
    }

    func entry(_ id: String) -> Entry? { entries().first { $0.id == id } }

    /// Write both files and apply them: Umi's menu items at once, Ghostty's bindings by
    /// reloading the configuration (no restart).
    private func save() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(atPath: UmiPaths.stateDirectory, withIntermediateDirectories: true)
        try encoder.encode(saved).write(to: URL(fileURLWithPath: Self.file), options: .atomic)
        var lines = ["# Written by \(UmiPaths.productName)'s shortcuts editor (Settings, ⌘,). Loaded after your",
                     "# Ghostty config files; your own files aren't changed. Edit shortcuts in the app.", ""]
        // Every unbind first: a key freed from one action and given to another must end up bound.
        let actions = saved.ghostty.keys.sorted()
        for action in actions {
            for trigger in saved.ghostty[action]?.unbind ?? [] { lines.append("keybind = \(trigger)=unbind") }
        }
        for action in actions {
            if let bind = saved.ghostty[action]?.bind { lines.append("keybind = \(bind)=\(action)") }
        }
        try (lines.joined(separator: "\n") + "\n").write(toFile: Self.ghosttyFile, atomically: true, encoding: .utf8)
        UmiShortcuts.applyShortcuts()
        (NSApp.delegate as? AppDelegate)?.ghostty.reloadConfig()
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    static let didChange = Notification.Name("UmiShortcutsDidChange")
}
