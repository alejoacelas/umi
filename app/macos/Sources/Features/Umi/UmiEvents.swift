import Foundation

/// Layout events (pane.created, tab.renamed, …) fanned out to subscribed CLI connections.
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
    }

    private var subscribers: [ObjectIdentifier: Subscriber] = [:]

    /// Observers inside the app (sidebar refresh, persistence).
    private var listeners: [UUID: (String, [String: Any]) -> Void] = [:]

    /// A subscriber's backlog limit before it's disconnected.
    static let subscriberBacklogLimit = 4 * 1024 * 1024

    func addSubscriber(_ connection: UmiConnection, filters: [String], pane: String?) {
        connection.setOutgoingLimit(Self.subscriberBacklogLimit)
        subscribers[ObjectIdentifier(connection)] = .init(connection: connection, filters: filters, pane: pane)
    }

    func removeSubscriber(_ connection: UmiConnection) {
        subscribers.removeValue(forKey: ObjectIdentifier(connection))
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

    func emit(_ name: String, _ data: [String: Any] = [:]) {
        let event: [String: Any] = [
            "event": name,
            "data": data,
            "ts": Date().timeIntervalSince1970,
        ]
        for (key, sub) in subscribers {
            guard let connection = sub.connection else {
                subscribers.removeValue(forKey: key)
                continue
            }
            guard Self.matches(name, filters: sub.filters) else { continue }
            if let pane = sub.pane {
                // Pane-filtered streams only carry events about that pane.
                guard let eventPane = data["pane"] as? String, eventPane == pane else { continue }
            }
            connection.sendRaw(event)
        }
        for listener in listeners.values { listener(name, data) }
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
