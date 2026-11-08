import AppKit
import GhosttyKit

/// Key–value attributes on panes, tabs and windows (design/primitives.md, "Attributes"; design/cli.md,
/// "Attributes"). Values are strings.
///
/// - The user's and scripts' attributes, set with `umi pane|tab|window set`: kept here for panes,
///   on the `UmiTab` for tabs and on the `TerminalController` for windows. They are saved and
///   restored with the layout, and live and die with their pane, tab or window.
/// - `agent.*`, written by the hook plugin (anyone may write them): the pane's agent in
///   `UmiAttention`. Setting them changes that agent; the next hook event overwrites them.
/// - Read-only keys kept by Umi (`kind`, `cwd`, `seen_at`, …): computed when read, never stored.
///
/// `role` has one holder per value: among panes for panes, among tabs for tabs. Setting it takes
/// it from whoever had it. The Docs tab is the tab with `role=docs`.
///
/// Each change of a stored or agent attribute is an event: `pane.changed`, `tab.changed` or
/// `window.changed`, with `key`, `old` and `new`.
@MainActor
final class UmiAttributes {
    static let shared = UmiAttributes()

    /// Keys Umi keeps; setting one fails (design/cli.md, choice 12).
    static let readOnly: Set<String> = ["kind", "cwd", "branch", "command", "focused", "hidden", "in_drawer",
                                        "seen_at", "changed_at", "status_since", "idle_for", "visible_count"]
    /// Keys the hook plugin writes, held by the pane's agent (`UmiAttention`).
    static let agentKeys: Set<String> = ["agent.kind", "agent.status", "agent.title", "agent.summary",
                                         "agent.done", "agent.session"]
    /// Keys with one holder per value.
    static let singleHolder: Set<String> = ["role"]

    /// Each pane's own attributes (the user's and scripts'), by pane id.
    private(set) var panes: [UUID: [String: String]] = [:]

    // MARK: Names

    /// Letters, digits, ".", "-" and "_" (design/cli.md, "Queries").
    static func isValidKey(_ key: String) -> Bool {
        !key.isEmpty && key.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || $0 == "." || $0 == "-" || $0 == "_"
        }
    }

    static func checkWritable(_ key: String) throws {
        guard isValidKey(key) else {
            throw UmiError.badRequest("\"\(key)\" isn't an attribute name (letters, digits, \".\", \"-\" and \"_\")")
        }
        if readOnly.contains(key) { throw UmiError.badRequest("\(key) is kept by \(UmiPaths.productName) and can't be set") }
    }

    // MARK: Reading

    /// A pane's own attributes plus its agent's.
    func written(_ pane: UUID) -> [String: String] {
        var out = panes[pane] ?? [:]
        if let agent = UmiAttention.shared.agent(forPane: pane) {
            out.merge(agent.attributes) { _, agent in agent }
        }
        return out
    }

    /// Every attribute of a pane: its own, its agent's, and the read-only ones.
    func all(_ pane: Ghostty.SurfaceView, focused: Bool? = nil) -> [String: String] {
        var out = written(pane.id)
        out.merge(computed(pane, focused: focused)) { _, umi in umi }
        return out
    }

    /// The read-only attributes Umi keeps for a pane.
    func computed(_ pane: Ghostty.SurfaceView, focused: Bool? = nil) -> [String: String] {
        let location = UmiTopology.locate(pane)
        let cwd = UmiTopology.cwd(of: pane)
        var out: [String: String] = ["kind": Self.kind(of: pane), "cwd": cwd, "in_drawer": "false"]
        let isFocused = focused ?? (location.map { $0.tab.effectiveFocusedSurface === pane } ?? false)
        out["focused"] = isFocused ? "true" : "false"
        let shown = location.map { $0.window.tree(of: $0.tab).contains(pane) } ?? true
        out["hidden"] = shown ? "false" : "true"
        if !cwd.isEmpty, let git = UmiPaneContext.git(for: cwd) { out["branch"] = git.branch }
        if out["kind"] == "terminal", let command = UmiPaneContext.command(for: pane) { out["command"] = command.text }
        let attention = UmiAttention.shared
        // Seen while it is being looked at, so now.
        if UmiLooking.lookedAt === pane {
            out["seen_at"] = UmiTime.iso(Date())
        } else if let seen = attention.seenAt(pane.id) {
            out["seen_at"] = UmiTime.iso(seen)
        }
        if let agent = attention.agent(forPane: pane.id) {
            out["changed_at"] = UmiTime.iso(agent.changedAt)
            out["status_since"] = UmiTime.iso(agent.statusSince)
        }
        if let idle = UmiPaneOutput.shared.idleFor(pane) { out["idle_for"] = "\(Int(idle))s" }
        return out
    }

    static func kind(of pane: Ghostty.SurfaceView) -> String {
        if UmiFilePanes.shared.document(of: pane) != nil { return "file" }
        if UmiWebPanes.shared.page(of: pane) != nil { return "web" }
        return "terminal"
    }

    /// Every attribute of a tab: its own and `visible_count`.
    func all(_ tab: UmiTab, in window: TerminalController) -> [String: String] {
        var out = tab.attributes
        out["visible_count"] = String(window.tree(of: tab).root?.leaves().count ?? 0)
        return out
    }

    // MARK: Panes

    /// Set attributes on a pane, all or none: every key and value is checked before anything changes.
    func set(_ pairs: [(String, String)], on pane: Ghostty.SurfaceView) throws {
        for (key, _) in pairs { try Self.checkWritable(key) }
        let own = pairs.filter { !Self.agentKeys.contains($0.0) }
        let agent = Dictionary(pairs.filter { Self.agentKeys.contains($0.0) }, uniquingKeysWith: { _, last in last })
        let change = try agentChange(agent, pane: pane.id)
        for (key, value) in own { store(key, value, pane: pane.id) }
        change?()
    }

    /// Remove attributes from a pane. Removing one it doesn't have is not an error.
    func unset(_ keys: [String], on pane: Ghostty.SurfaceView) throws {
        for key in keys { try Self.checkWritable(key) }
        let agentKeys = keys.filter { Self.agentKeys.contains($0) }
        if agentKeys.contains("agent.status") && !agentKeys.contains("agent.kind")
            && UmiAttention.shared.agent(forPane: pane.id) != nil {
            throw UmiError.badRequest("agent.status can't be unset on its own; unset agent.kind to take the pane's agent away")
        }
        for key in keys where !Self.agentKeys.contains(key) { store(key, nil, pane: pane.id) }
        guard !agentKeys.isEmpty, UmiAttention.shared.agent(forPane: pane.id) != nil else { return }
        if agentKeys.contains("agent.kind") {
            UmiAttention.shared.set(nil, forPane: pane.id)
            return
        }
        UmiAttention.shared.update(pane.id) { agent in
            for key in agentKeys {
                switch key {
                case "agent.title": agent.title = ""
                case "agent.summary": agent.summary = nil
                case "agent.done": agent.done = nil
                case "agent.session": agent.session = nil
                default: break
                }
            }
        }
    }

    private func store(_ key: String, _ value: String?, pane id: UUID) {
        let old = panes[id]?[key]
        guard old != value else { return }
        if let value, Self.singleHolder.contains(key) {
            // One holder: the pane that had it loses it (an open pane says so; a closed one, kept
            // for ⇧⌘T or gone, loses it quietly).
            let open = Set(UmiTopology.allSurfaces.map(\.id))
            for (other, attributes) in panes where other != id && attributes[key] == value {
                panes[other]?.removeValue(forKey: key)
                if open.contains(other) {
                    emit("pane.changed", ["pane": other.uuidString.lowercased(), "key": key, "old": value, "new": NSNull()])
                }
            }
        }
        if let value { panes[id, default: [:]][key] = value } else { panes[id]?.removeValue(forKey: key) }
        if panes[id]?.isEmpty == true { panes.removeValue(forKey: id) }
        emit("pane.changed", ["pane": id.uuidString.lowercased(), "key": key, "old": old ?? NSNull(), "new": value ?? NSNull()])
        UmiState.shared.layoutDidChange(persistOnly: true)
    }

    /// Check `agent.*` values; returns what writes them (nil: nothing to write).
    private func agentChange(_ pairs: [String: String], pane id: UUID) throws -> (() -> Void)? {
        guard !pairs.isEmpty else { return nil }
        var kind: UmiAgentKind?
        if let raw = pairs["agent.kind"] {
            guard let parsed = UmiAgentKind(rawValue: raw) else { throw UmiError.badRequest("agent.kind is claude or codex") }
            kind = parsed
        }
        var status: UmiAttention.Status?
        if let raw = pairs["agent.status"] {
            guard let parsed = UmiAttention.Status(rawValue: raw) else {
                throw UmiError.badRequest("agent.status is working, needs_input, idle, stopped or error")
            }
            status = parsed
        }
        if let done = pairs["agent.done"], done != "true" && done != "false" {
            throw UmiError.badRequest("agent.done is true or false")
        }
        let attention = UmiAttention.shared
        let existing = attention.agent(forPane: id)
        if existing == nil && kind == nil {
            throw UmiError.badRequest("the pane has no agent: set agent.kind (claude or codex) with the other agent.* keys")
        }
        return {
            func apply(_ agent: inout UmiAttention.Agent) {
                if let kind { agent.kind = kind }
                if let status {
                    agent.status = status
                    agent.idleInferred = false
                }
                if let title = pairs["agent.title"] { agent.title = title }
                if let summary = pairs["agent.summary"] { agent.summary = summary }
                if let done = pairs["agent.done"] { agent.done = done == "true" }
                if let session = pairs["agent.session"] { agent.session = session.isEmpty ? nil : session }
            }
            if existing != nil {
                attention.update(id, apply)
            } else if let kind {
                var agent = UmiAttention.Agent(kind: kind, status: status ?? .idle)
                apply(&agent)
                attention.set(agent, forPane: id)
            }
        }
    }

    // MARK: Tabs and windows

    func set(_ pairs: [(String, String)], on tab: UmiTab, in window: TerminalController) throws {
        for (key, _) in pairs { try Self.checkWritable(key) }
        for (key, value) in pairs { store(key, value, tab: tab, in: window) }
    }

    func unset(_ keys: [String], on tab: UmiTab, in window: TerminalController) throws {
        for key in keys { try Self.checkWritable(key) }
        for key in keys { store(key, nil, tab: tab, in: window) }
    }

    private func store(_ key: String, _ value: String?, tab: UmiTab, in window: TerminalController) {
        let old = tab.attributes[key]
        guard old != value else { return }
        if let value, Self.singleHolder.contains(key) {
            for other in UmiTopology.windows.flatMap(\.tabs) where other !== tab && other.attributes[key] == value {
                other.attributes.removeValue(forKey: key)
                emit("tab.changed", ["tab": other.idString, "key": key, "old": value, "new": NSNull()])
            }
        }
        if let value { tab.attributes[key] = value } else { tab.attributes.removeValue(forKey: key) }
        emit("tab.changed", ["tab": tab.idString, "window": window.umiIDString, "key": key,
                             "old": old ?? NSNull(), "new": value ?? NSNull()])
        UmiState.shared.layoutDidChange()
    }

    func set(_ pairs: [(String, String)], on window: TerminalController) throws {
        for (key, _) in pairs { try Self.checkWritable(key) }
        for (key, value) in pairs { store(key, value, window: window) }
    }

    func unset(_ keys: [String], on window: TerminalController) throws {
        for key in keys { try Self.checkWritable(key) }
        for key in keys { store(key, nil, window: window) }
    }

    private func store(_ key: String, _ value: String?, window: TerminalController) {
        let old = window.umiAttributes[key]
        guard old != value else { return }
        if let value { window.umiAttributes[key] = value } else { window.umiAttributes.removeValue(forKey: key) }
        emit("window.changed", ["window": window.umiIDString, "key": key, "old": old ?? NSNull(), "new": value ?? NSNull()])
        UmiState.shared.layoutDidChange(persistOnly: true)
    }

    private func emit(_ name: String, _ data: [String: Any]) {
        UmiEvents.shared.emit(name, data)
    }

    // MARK: Saving and restoring

    /// A restored pane's attributes (from `layout.json`), as they were saved: no events.
    func restore(_ attributes: [String: String], pane id: UUID) {
        let kept = attributes.filter { Self.isValidKey($0.key) && !Self.readOnly.contains($0.key) && !Self.agentKeys.contains($0.key) }
        if kept.isEmpty { panes.removeValue(forKey: id) } else { panes[id] = kept }
    }

    /// Forget the attributes of panes that are gone for good (not open, and not kept for ⇧⌘T).
    func prune(open: Set<UUID>) {
        panes = panes.filter { open.contains($0.key) || UmiReopen.shared.holds($0.key) }
    }
}

/// When each terminal pane last printed anything, for `idle_for`: sampled every couple of seconds
/// from the terminal's count of output bytes, and again whenever it is read.
@MainActor
final class UmiPaneOutput {
    static let shared = UmiPaneOutput()

    private var last: [UUID: (bytes: UInt64, at: Date)] = [:]
    private var timer: Timer?

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            MainActor.assumeIsolated { UmiPaneOutput.shared.sample() }
        }
    }

    private func sample() {
        let surfaces = UmiTopology.allSurfaces
        for pane in surfaces { _ = idleFor(pane) }
        if last.count > surfaces.count + 64 {
            let open = Set(surfaces.map(\.id))
            last = last.filter { open.contains($0.key) }
        }
    }

    /// Seconds since the pane's terminal last printed (nil for file and web panes). Counted from when
    /// Umi first saw the pane.
    func idleFor(_ pane: Ghostty.SurfaceView) -> TimeInterval? {
        guard UmiAttributes.kind(of: pane) == "terminal", pane.surface != nil else { return nil }
        let bytes = UmiInput.outputBytes(pane)
        let now = Date()
        if let seen = last[pane.id], seen.bytes == bytes { return max(0, now.timeIntervalSince(seen.at)) }
        last[pane.id] = (bytes, now)
        return 0
    }
}

/// `umi pane|tab|window set|unset|get` (design/cli.md, "Attributes").
@MainActor
enum UmiAttributesRPC {
    static let methods: Set<String> = ["pane.set", "pane.unset", "pane.get", "tab.set", "tab.unset", "tab.get",
                                       "window.set", "window.unset", "window.get"]

    private enum Target {
        case pane(Ghostty.SurfaceView)
        case tab(TerminalController, UmiTab)
        case window(TerminalController)
    }

    static func handle(_ method: String, _ params: UmiParams, caller: UmiCaller) throws -> [String: Any] {
        let parts = method.split(separator: ".").map(String.init)
        let (object, verb) = (parts[0], parts[1])
        var words = params.strings("words") ?? []
        // The target: the option given, else a leading word that names one, else the caller's.
        var selector = params.string(object)
        if selector == nil, let first = words.first {
            switch verb {
            case "set":
                if !first.contains("=") { selector = words.removeFirst() }
            default:
                // `unset [PANE] KEY…`, `get [PANE] [KEY…]`: a first word that names one is it.
                let names = (try? resolve(object, first, caller: caller)) != nil
                if verb == "unset" && words.count == 1 && names {
                    throw UmiError.badRequest("\(object) unset: give a KEY after the \(object)")
                }
                let minimum = verb == "unset" ? 2 : 1
                if words.count >= minimum, names { selector = words.removeFirst() }
            }
        }
        let target = try selector.map { try resolve(object, $0, caller: caller) } ?? defaultTarget(object, caller: caller)
        switch verb {
        case "set":
            guard !words.isEmpty else { throw UmiError.badRequest("\(object) set: give KEY=VALUE") }
            var pairs: [(String, String)] = []
            for word in words {
                guard let eq = word.firstIndex(of: "=") else {
                    throw UmiError.badRequest("\(object) set: \"\(word)\" isn't KEY=VALUE")
                }
                pairs.append((String(word[..<eq]), String(word[word.index(after: eq)...])))
            }
            let attributes = UmiAttributes.shared
            switch target {
            case .pane(let pane): try attributes.set(pairs, on: pane)
            case .tab(let window, let tab): try attributes.set(pairs, on: tab, in: window)
            case .window(let window): try attributes.set(pairs, on: window)
            }
            var set: [String: String] = [:]
            for (key, value) in pairs { set[key] = value }
            return ["\(object)s": [id(target)], "set": set]
        case "unset":
            guard !words.isEmpty else { throw UmiError.badRequest("\(object) unset: give a KEY") }
            let attributes = UmiAttributes.shared
            switch target {
            case .pane(let pane): try attributes.unset(words, on: pane)
            case .tab(let window, let tab): try attributes.unset(words, on: tab, in: window)
            case .window(let window): try attributes.unset(words, on: window)
            }
            return ["\(object)s": [id(target)], "unset": words]
        default:
            var all: [String: String]
            switch target {
            case .pane(let pane): all = UmiAttributes.shared.all(pane)
            case .tab(let window, let tab): all = UmiAttributes.shared.all(tab, in: window)
            case .window(let window): all = window.umiAttributes
            }
            if !words.isEmpty { all = all.filter { words.contains($0.key) } }
            return [object: id(target), "attributes": all, "keys": words]
        }
    }

    private static func resolve(_ object: String, _ selector: String, caller: UmiCaller) throws -> Target {
        switch object {
        case "pane": return .pane(try UmiTopology.resolvePane(selector, caller: caller))
        case "tab":
            let (window, tab) = try UmiTopology.resolveTab(selector, caller: caller)
            return .tab(window, tab)
        default: return .window(try UmiTopology.resolveWindow(selector, caller: caller))
        }
    }

    private static func defaultTarget(_ object: String, caller: UmiCaller) throws -> Target {
        switch object {
        case "pane": return .pane(try UmiTopology.pane(nil, caller: caller))
        case "tab":
            let (window, tab) = try UmiTopology.tab(nil, caller: caller)
            return .tab(window, tab)
        default: return .window(try UmiTopology.window(nil, caller: caller))
        }
    }

    private static func id(_ target: Target) -> String {
        switch target {
        case .pane(let pane): return pane.umiID
        case .tab(_, let tab): return tab.idString
        case .window(let window): return window.umiIDString
        }
    }
}
