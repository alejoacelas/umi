import AppKit

/// Events (pane.created, tab.renamed, pane.changed, …) fanned out to subscribed CLI connections and
/// written to the activity log (`UmiActivityLog`). Each carries when it happened (`at`) and its
/// cause (`UmiCause`): a key, the mouse, the palette, a CLI call, a hook, or Umi itself.
///
/// Emitting never blocks: each subscriber has its own bounded outgoing buffer in its
/// connection, and a subscriber that falls too far behind is disconnected (T-4).
@MainActor
final class UmiEvents {
    static let shared = UmiEvents()

    private struct Subscriber {
        weak var connection: UmiConnection?
        let filters: [String]
        let pane: String?
        /// Only events about this file (`umi comments wait`).
        var path: String?
    }

    private var subscribers: [ObjectIdentifier: Subscriber] = [:]

    /// Observers inside the app (sidebar refresh, persistence).
    private var listeners: [UUID: (String, [String: Any]) -> Void] = [:]

    /// A subscriber's backlog limit before it's disconnected.
    static let subscriberBacklogLimit = 4 * 1024 * 1024

    func addSubscriber(_ connection: UmiConnection, filters: [String], pane: String?, path: String? = nil) {
        connection.setOutgoingLimit(Self.subscriberBacklogLimit)
        subscribers[ObjectIdentifier(connection)] = .init(connection: connection, filters: filters, pane: pane, path: path)
        if path != nil { UmiCommentsUI.waitersChanged() }
    }

    func removeSubscriber(_ connection: UmiConnection) {
        let removed = subscribers.removeValue(forKey: ObjectIdentifier(connection))
        if removed?.path != nil { UmiCommentsUI.waitersChanged() }
    }

    /// Connections waiting for the review of `path` to be done (E-11).
    func waiters(on path: String) -> Int {
        subscribers.values.filter { $0.connection != nil && $0.path == path && Self.matches("comments.done", filters: $0.filters) }.count
    }

    @discardableResult
    func addListener(_ block: @escaping (String, [String: Any]) -> Void) -> UUID {
        let id = UUID()
        listeners[id] = block
        return id
    }

    func removeListener(_ id: UUID) {
        listeners.removeValue(forKey: id)
    }

    /// Events that aren't changes, kept out of the activity log: the update notice's countdown ticks.
    static let unlogged: Set<String> = ["update.countdown"]

    func emit(_ name: String, _ data: [String: Any] = [:]) {
        let now = Date()
        let event: [String: Any] = [
            "event": name,
            "at": UmiTime.iso(now),
            "cause": UmiCause.now.json,
            "data": data,
            "ts": now.timeIntervalSince1970,
        ]
        if !Self.unlogged.contains(name) { UmiActivityLog.shared.append(event) }
        for (key, sub) in subscribers {
            guard let connection = sub.connection else {
                subscribers.removeValue(forKey: key)
                continue
            }
            guard Self.matches(name, filters: sub.filters) else { continue }
            if let pane = sub.pane {
                // Pane-filtered streams only carry events about that pane.
                guard Self.isAbout(data, pane: pane) else { continue }
            }
            if let path = sub.path {
                guard let eventPath = data["path"] as? String, eventPath == path else { continue }
            }
            connection.sendRaw(event)
        }
        for listener in listeners.values { listener(name, data) }
    }

    /// An event's data is about the pane (or, for a prefix of an id, a pane whose id starts with it).
    static func isAbout(_ data: [String: Any], pane: String) -> Bool {
        guard let eventPane = data["pane"] as? String else { return false }
        return eventPane == pane || (pane.count < eventPane.count && eventPane.hasPrefix(pane))
    }

    /// A filter keeps events whose name starts with it ("pane." keeps pane.created, …).
    static func matches(_ name: String, filters: [String]) -> Bool {
        if filters.isEmpty { return true }
        return filters.contains { filter in
            if filter.isEmpty || filter == "*" { return true }
            if filter.hasSuffix("*") { return name.hasPrefix(String(filter.dropLast())) }
            return name.hasPrefix(filter)
        }
    }
}

/// What caused a change, for the events and the activity log (design/cli.md, "Events and logs"):
/// `key` (with `key`), `mouse`, `palette` (with `command`), `cli` (with `command` and the calling
/// `pane`), `hook`, `config` (a condition or a slot) or `umi` (Umi on its own).
///
/// Where it comes from, most specific first: a scope Umi's own key handling or the palette opens
/// around what it does (`during`), the control request being handled (a task-local set by the
/// control server), the key press or click AppKit is dispatching at that moment, else Umi.
struct UmiCause: Sendable, Equatable {
    var kind: String
    var command: String?
    var key: String?
    var pane: String?

    static let umi = UmiCause(kind: "umi")

    var json: [String: Any] {
        var out: [String: Any] = ["kind": kind]
        if let command { out["command"] = command }
        if let key { out["key"] = key }
        if let pane { out["pane"] = pane }
        return out
    }

    /// The control request being handled (set around each request by the control server).
    @TaskLocal static var request: UmiCause?

    /// A cause in force while synchronous code runs (`during`).
    @MainActor private static var ambient: [UmiCause] = []

    @MainActor
    static func during<T>(_ cause: UmiCause, _ body: () throws -> T) rethrows -> T {
        ambient.append(cause)
        defer { ambient.removeLast() }
        return try body()
    }

    @MainActor
    static var now: UmiCause {
        if let cause = ambient.last { return cause }
        if let request { return request }
        if let event = fromCurrentEvent() { return event }
        return .umi
    }

    /// The key presses and clicks AppKit is dispatching right now, innermost last
    /// (`dispatching(_:_:)`, from the windows' `sendEvent`), and the one a local event monitor saw
    /// last, which counts until the run loop's current turn ends (`noteDispatch`).
    @MainActor private static var dispatched: [NSEvent] = []
    @MainActor private static var monitored: NSEvent?
    @MainActor private static var monitor: Any?

    /// Run `body` while AppKit dispatches `event` to a window: what it changes is caused by the event.
    @MainActor
    static func dispatching<T>(_ event: NSEvent, _ body: () throws -> T) rethrows -> T {
        dispatched.append(event)
        defer { dispatched.removeLast() }
        return try body()
    }

    /// Watch the key presses and clicks the app receives (also those a menu or the app handles
    /// before any window: key equivalents). Each counts only until the run loop's turn that
    /// dispatches it ends.
    @MainActor
    static func startWatchingEvents() {
        guard monitor == nil else { return }
        let types: NSEvent.EventTypeMask = [.keyDown, .keyUp, .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
                                            .otherMouseDown, .otherMouseUp, .scrollWheel]
        monitor = NSEvent.addLocalMonitorForEvents(matching: types) { event in
            MainActor.assumeIsolated {
                monitored = event
                // Cleared on the next turn of the main run loop, after AppKit dispatched it.
                RunLoop.main.perform(inModes: [.common]) {
                    MainActor.assumeIsolated { if monitored === event { monitored = nil } }
                }
            }
            return event
        }
    }

    /// The key press or click AppKit is dispatching at this moment, if any. `NSApp.currentEvent`
    /// alone isn't enough: it stays set after the event was handled, so changes Umi makes on its own
    /// later would be put down to the user's last key.
    @MainActor
    private static func fromCurrentEvent() -> UmiCause? {
        guard let event = dispatched.last ?? monitored else { return nil }
        switch event.type {
        case .keyDown, .keyUp:
            return key(event)
        case .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp,
             .leftMouseDragged, .rightMouseDragged, .otherMouseDragged, .scrollWheel:
            return UmiCause(kind: "mouse")
        default:
            return nil
        }
    }

    /// A key press, named as `umi shortcuts` names keys ("ctrl+cmd+j").
    @MainActor
    static func key(_ event: NSEvent) -> UmiCause {
        UmiCause(kind: "key", key: UmiShortcut(event: event)?.spec ?? event.charactersIgnoringModifiers ?? "")
    }

    /// A request's cause, from what the CLI sends: `UMI_CAUSE` in its environment (`palette`,
    /// `key:<keys>`, set for commands the palette or a key binding runs), else the CLI itself.
    static func request(method: String, caller: UmiCaller) -> UmiCause {
        let command = caller.argv.map { (["umi"] + $0).joined(separator: " ") }
        if method == "hook" || method == "agent.hook" { return UmiCause(kind: "hook", command: command, pane: caller.pane) }
        if let given = caller.cause {
            if given == "palette" || given.hasPrefix("palette:") {
                return UmiCause(kind: "palette", command: command)
            }
            if given.hasPrefix("key:") {
                return UmiCause(kind: "key", command: command, key: String(given.dropFirst(4)))
            }
        }
        return UmiCause(kind: "cli", command: command, pane: caller.pane?.lowercased())
    }
}

/// Times as Umi writes them in JSON: ISO 8601 with the local time zone.
enum UmiTime {
    private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = .current
        return f
    }()
    private static let lock = NSLock()

    static func iso(_ date: Date) -> String {
        lock.lock()
        defer { lock.unlock() }
        return formatter.string(from: date)
    }

    static func parseISO(_ text: String) -> Date? {
        lock.lock()
        defer { lock.unlock() }
        return formatter.date(from: text)
    }
}
