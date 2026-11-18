import Foundation

/// The Ghostty keybindings in effect in the terminals, for the shortcuts page (bridge op
/// `ghosttyBindings`), as Umi's UmiGhosttyBindings works them out: Ghostty's built-in defaults
/// (this app's own `+list-keybinds --default --plain`), then the `keybind` lines of the config
/// files the terminals load (Paths.terminalConfigFiles: next/app/terminal.conf, the user's Umi
/// config, and the files their `config-file` lines include), in load order. libghostty has no
/// call that lists them.
enum GhosttyBindings {
    struct Binding {
        var trigger: String
        var action: String
        /// Where it was set: "Ghostty" or the config file's path.
        var source: String
    }

    private static let lock = NSLock()
    private static var cachedDefaults: [(String, String)]?

    /// [{trigger, keys, action, title, source}]: `keys` is the trigger in web/shortcuts.js's
    /// spelling (cmd+shift+d), null for one it can't write (a sequence such as ctrl+a>n, or a
    /// physical key).
    static func list() -> [[String: Any]] {
        effective().map { b in
            ["trigger": b.trigger, "keys": pageKeys(b.trigger) ?? NSNull(), "action": b.action,
             "title": describe(b.action), "source": b.source]
        }
    }

    static func defaults() -> [(String, String)] {
        lock.lock(); defer { lock.unlock() }
        if let cachedDefaults { return cachedDefaults }
        var out: [(String, String)] = []
        let p = Process()
        p.executableURL = Bundle.main.executableURL
        p.arguments = ["+list-keybinds", "--default", "--plain"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        if (try? p.run()) != nil {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
                if case .bind(let t, let a)? = parse(String(line)) { out.append((t, a)) }
            }
        }
        if !out.isEmpty { cachedDefaults = out }
        return out
    }

    enum Line { case bind(String, String), unbind(String), clear }

    /// One `keybind = …` line (Umi's UmiGhosttyBindings.parse).
    static func parse(_ line: String) -> Line? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("keybind"), let eq = trimmed.firstIndex(of: "=") else { return nil }
        guard trimmed[..<eq].trimmingCharacters(in: .whitespaces) == "keybind" else { return nil }
        var value = trimmed[trimmed.index(after: eq)...].trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 { value = String(value.dropFirst().dropLast()) }
        if value == "clear" { return .clear }
        // The separator is the first "=" that doesn't start a key ("super+==action" binds "=").
        let chars = Array(value)
        var split: Int?
        for (i, c) in chars.enumerated() where c == "=" {
            let startsKey = i == 0 || chars[i - 1] == "+" || chars[i - 1] == ">" || chars[i - 1] == ":"
            if !startsKey { split = i; break }
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

    /// Every binding in effect, in load order.
    static func effective() -> [Binding] {
        var bindings: [String: Binding] = [:]
        var order: [String] = []
        func apply(_ line: Line, _ source: String) {
            switch line {
            case .clear: bindings = [:]; order = []
            case .unbind(let t): bindings.removeValue(forKey: normalized(t))
            case .bind(let t, let a):
                let key = normalized(t)
                if bindings[key] == nil { order.append(key) }
                bindings[key] = Binding(trigger: t, action: a, source: source)
            }
        }
        for (t, a) in defaults() { apply(.bind(t, a), "Ghostty") }
        // `config-file` includes load after the files that name them, as in Ghostty.
        var queue = Paths.terminalConfigFiles
        var seen = Set<String>()
        var i = 0
        while i < queue.count {
            let path = queue[i]
            i += 1
            guard seen.insert(path).inserted, let text = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
            let dir = (path as NSString).deletingLastPathComponent
            for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
                let line = raw.trimmingCharacters(in: .whitespaces)
                if line.hasPrefix("#") { continue }
                if line.hasPrefix("config-file"), let eq = line.firstIndex(of: "=") {
                    var v = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
                    if v.hasPrefix("\""), v.hasSuffix("\""), v.count >= 2 { v = String(v.dropFirst().dropLast()) }
                    if v.hasPrefix("?") { v.removeFirst() }
                    v = (v as NSString).expandingTildeInPath
                    if !v.hasPrefix("/") { v = dir + "/" + v }
                    queue.append(v)
                    continue
                }
                if let parsed = parse(line) { apply(parsed, path) }
            }
        }
        return order.compactMap { bindings[$0] }
    }

    /// A one-step trigger in the page's spelling: super → cmd, alt → opt, Ghostty's key names to
    /// the table's (arrow_up → up, enter, …); nil when the page can't write it.
    static func pageKeys(_ trigger: String) -> String? {
        guard !trigger.contains(">") else { return nil }
        var parts = trigger.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        if trigger.hasSuffix("++") { parts = Array(parts.dropLast(2)) + ["+"] }
        guard var key = parts.popLast(), !key.isEmpty, !key.contains(":") else { return nil }
        var mods: [String] = []
        for m in parts {
            switch m.lowercased() {
            case "cmd", "command", "super": mods.append("cmd")
            case "opt", "option", "alt": mods.append("opt")
            case "ctrl", "control": mods.append("ctrl")
            case "shift": mods.append("shift")
            default: return nil
            }
        }
        let names = ["arrow_up": "up", "arrow_down": "down", "arrow_left": "left", "arrow_right": "right",
                     "page_up": "pageup", "page_down": "pagedown", "enter": "enter", "return": "enter", "escape": "escape",
                     "tab": "tab", "space": "space", "backspace": "backspace", "delete": "delete", "home": "home", "end": "end",
                     "equal": "=", "minus": "-", "comma": ",", "period": ".", "slash": "/", "backslash": "\\",
                     "bracket_left": "[", "bracket_right": "]", "semicolon": ";", "quote": "'", "backquote": "`", "plus": "+"]
        if let n = names[key.lowercased()] { key = n }
        else if key.hasPrefix("digit_"), key.count == 7 { key = String(key.last!) }
        else if key.hasPrefix("key_"), key.count == 5 { key = String(key.last!).lowercased() }
        else if key.count > 1, !(key.lowercased().hasPrefix("f") && Int(key.dropFirst()) != nil) { return nil }
        let order = ["cmd", "ctrl", "opt", "shift"]
        return (mods.sorted { order.firstIndex(of: $0)! < order.firstIndex(of: $1)! } + [key.lowercased()]).joined(separator: "+")
    }

    /// "goto_split:previous" → "Goto split: previous" (Umi's UmiShortcutStore.describe).
    static func describe(_ action: String) -> String {
        let parts = action.split(separator: ":", maxSplits: 1).map(String.init)
        var name = (parts.first ?? action).replacingOccurrences(of: "_", with: " ")
        name = name.prefix(1).uppercased() + name.dropFirst()
        return parts.count > 1 ? "\(name): \(parts[1])" : name
    }
}
