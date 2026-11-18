import AppKit

/// The global shortcuts, as the page defines them (web/shortcuts.js). The page sends
/// `{type: "shortcuts", table: [{id, keys, native?}]}` on every load; the window intercepts a key
/// only when it matches an entry, so every other key reaches the focused terminal or page.
/// The last table is kept in <state>/shortcuts.json, so shortcuts work from launch on, and
/// entries with `native` ("reload", "quit") work even while the page is broken.
///
/// Keys: modifiers `cmd`, `shift`, `opt`, `ctrl` (or `hyper` for all four) joined by `+`, then one
/// key: a character as typed without modifiers (`d`, `[`, `1`, `/`) or a name: left right up down
/// enter escape tab space backspace delete home end pageup pagedown f1–f12.
struct ShortcutTable {
    struct Entry { let id: String; let mods: NSEvent.ModifierFlags; let keyCode: UInt16?; let char: String?; let native: String?
        /// `when: "terminal"`: taken only while a terminal has the keys (else the page gets the key).
        var terminalOnly = false }
    private(set) var entries: [Entry] = []

    static let file = Paths.stateDir + "/shortcuts.json"

    static let named: [String: UInt16] = [
        "left": 123, "right": 124, "down": 125, "up": 126, "enter": 36, "return": 36, "escape": 53, "esc": 53,
        "tab": 48, "space": 49, "backspace": 51, "delete": 117, "home": 115, "end": 119, "pageup": 116, "pagedown": 121,
        "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97, "f7": 98, "f8": 100, "f9": 101, "f10": 109,
        "f11": 103, "f12": 111,
    ]

    /// Parses a table; returns the entries it couldn't read as "id: keys".
    mutating func load(_ table: [[String: Any]]) -> [String] {
        var out: [Entry] = [], bad: [String] = []
        for item in table {
            guard let id = item["id"] as? String, let keys = item["keys"] as? String, var e = Self.parse(id, keys, item["native"] as? String) else {
                bad.append("\(item["id"] ?? "?"): \(item["keys"] ?? "?")")
                continue
            }
            e.terminalOnly = item["when"] as? String == "terminal"
            out.append(e)
        }
        entries = out
        return bad
    }

    static func parse(_ id: String, _ keys: String, _ native: String?) -> Entry? {
        var parts = keys.lowercased().split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        // "cmd++" means ⌘ and the plus key.
        if keys.hasSuffix("++") { parts.removeLast(2); parts.append("+") }
        guard let key = parts.popLast(), !key.isEmpty else { return nil }
        var mods: NSEvent.ModifierFlags = []
        for m in parts {
            switch m {
            case "cmd", "command": mods.insert(.command)
            case "shift": mods.insert(.shift)
            case "opt", "option", "alt": mods.insert(.option)
            case "ctrl", "control": mods.insert(.control)
            case "hyper": mods.formUnion([.command, .shift, .option, .control])
            default: return nil
            }
        }
        if let code = named[key] { return Entry(id: id, mods: mods, keyCode: code, char: nil, native: native) }
        guard key.count == 1 else { return nil }
        return Entry(id: id, mods: mods, keyCode: nil, char: key, native: native)
    }

    func match(_ e: NSEvent) -> Entry? {
        guard e.type == .keyDown else { return nil }
        let mods = e.modifierFlags.intersection([.command, .shift, .option, .control])
        // The key as typed with no modifiers, by the current layout (so ⇧⌘[ is "[", keypad 1 is "1").
        let base = e.characters(byApplyingModifiers: [])?.lowercased()
        return entries.first { $0.mods == mods && ($0.keyCode.map { $0 == e.keyCode } ?? ($0.char == base)) }
    }
}

extension ShortcutTable.Entry {
    /// The key as a menu item shows it (NSMenuItem.keyEquivalent), nil for one a menu can't show.
    var keyEquivalent: String? {
        if let char { return char }
        let function: [UInt16: Int] = [123: NSLeftArrowFunctionKey, 124: NSRightArrowFunctionKey, 125: NSDownArrowFunctionKey,
                                       126: NSUpArrowFunctionKey, 115: NSHomeFunctionKey, 119: NSEndFunctionKey,
                                       116: NSPageUpFunctionKey, 121: NSPageDownFunctionKey, 117: NSDeleteFunctionKey]
        let plain: [UInt16: String] = [36: "\r", 53: "\u{1b}", 48: "\t", 49: " ", 51: "\u{8}"]
        guard let keyCode else { return nil }
        if let s = plain[keyCode] { return s }
        return function[keyCode].flatMap { UnicodeScalar(UInt32($0)) }.map { String(Character($0)) }
    }
}
