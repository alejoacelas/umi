import AppKit
import Combine

/// Agent events inside the app, as Warp's notification mailbox and toasts (Warp parity,
/// 2026-11-05; SPEC S-3, S-9):
///
/// - Every agent shown in a pane that finishes its turn, asks for the user or fails adds one
///   item to the inbox (⇧⌘U), newest first, at most 100. A pane keeps one item: its newest. An
///   agent starting a new turn takes its item away, as Warp does.
/// - An item is read once the user looks at its pane (or it happened while they looked).
/// - An unread item also shows as a toast in the window the user is looking at (the key window
///   of the active app): 8 seconds, at most two at once, none while the inbox is open. ⌃⌘U
///   dismisses them; opening the inbox dismisses them too.
/// - After an update installs, a one-time note says so with the release's notes, until ⌃⌘U.
///
/// UmiAttention feeds it: every change to a pane's agent goes through `observe`.
@MainActor
final class UmiInbox: ObservableObject {
    static let shared = UmiInbox()

    /// Warp keeps 100.
    static let limit = 100
    /// Warp shows at most two toasts at once.
    static let maxToasts = 2
    /// Warp's toasts last 8 seconds. Isolated (test) instances may shorten it.
    static var toastSeconds: TimeInterval { UmiUpdater.seconds("UMI_TOAST_SECONDS", default: 8) }

    enum Category: String { case complete, request, error }

    enum Filter: String, CaseIterable {
        case all, unread, errors

        var label: String {
            switch self {
            case .all: return "All tabs"
            case .unread: return "Unread"
            case .errors: return "Errors"
            }
        }
    }

    struct Item: Identifiable, Equatable {
        let id = UUID()
        let pane: UUID
        let session: String?
        let kind: UmiAttention.Kind
        let title: String
        let message: String
        let category: Category
        var read: Bool
        let at: Date

        /// The badge its icon wears, as Warp maps notification categories to statuses.
        var badge: UmiAttention.Badge {
            switch category {
            case .complete: return .done
            case .request: return .needsYou
            case .error: return .error
            }
        }
    }

    struct Toast: Identifiable, Equatable {
        /// The item's id.
        let id: UUID
        /// The window it shows in.
        let window: ObjectIdentifier
    }

    struct UpdateNote: Equatable {
        let version: String
        let notes: String
    }

    @Published private(set) var items: [Item] = []
    @Published private(set) var toasts: [Toast] = []
    @Published private(set) var updateNote: UpdateNote?

    /// The window whose inbox is open (nil: closed).
    @Published private(set) var openWindow: ObjectIdentifier?
    @Published private(set) var filter: Filter = .all
    @Published private(set) var selected: Int?

    /// OSC 9/777 notifications dropped because an agent runs in the pane (S-3).
    private(set) var droppedNotifications = 0
    /// OSC 9/777 notifications let through (they're Ghostty's).
    private(set) var passedNotifications = 0
    private var keyMonitor: Any?
    /// Closes the inbox on a click outside it (Warp's mailbox sits in a Dismiss).
    private var mouseMonitor: Any?
    /// Closes the inbox when its window closes.
    private var closeObserver: NSObjectProtocol?
    /// The open panel's view (for the click-outside check).
    weak var panelView: NSView?

    // MARK: Agent events (from UmiAttention)

    private static func busy(_ status: String?) -> Bool { status == "working" || status == "starting" }

    func observe(old: UmiAttention.Agent?, new: UmiAttention.Agent?, pane: UUID) {
        guard let new else {
            // The pane no longer shows the agent: there's nothing to go to (Warp drops the item
            // when the session ends).
            if old != nil { remove(pane: pane) }
            return
        }
        if Self.busy(new.status) {
            // A new turn: the previous event is stale.
            if !Self.busy(old?.status) { remove(pane: pane) }
            return
        }
        // Warp's titles and messages for CLI agents (agent_management_model.rs).
        let name = new.kind == .claude ? "Claude" : "Codex"
        let detail = new.detail.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        let wasRunning = Self.busy(old?.status) || old?.status == "needs_input"
        let category: Category
        let fallback: String
        let message: String
        if (new.status == "needs_input" && old?.status != "needs_input") || (new.mark == .needsYou && old?.mark != .needsYou) {
            category = .request
            fallback = "\(name) needs attention"
            message = detail ?? "Waiting for input."
        } else if new.status == "error" && old?.status != "error" {
            category = .error
            fallback = "\(name) failed"
            message = detail ?? "The agent encountered an error."
        } else if new.status == "stopped" && old?.status != "stopped" && wasRunning {
            category = .complete
            fallback = "\(name) cancelled"
            message = "Cancelled by user."
        } else if (new.status == "idle" && wasRunning) || (new.mark == .finished && old?.mark != .finished) {
            category = .complete
            fallback = "\(name) completed"
            message = new.kind == .codex ? "Notification from Codex" : "Task completed."
        } else {
            return
        }
        // Read if the user looks at its tab as it happens (Warp's is_terminal_view_visible).
        add(Item(pane: pane, session: new.session, kind: new.kind, title: new.title.isEmpty ? fallback : new.title,
                 message: message, category: category, read: UmiLooking.isLookingAtTab(of: pane), at: Date()))
    }

    private func add(_ item: Item) {
        items.removeAll { $0.pane == item.pane }
        toasts.removeAll { toast in !items.contains { $0.id == toast.id } }
        items.insert(item, at: 0)
        if items.count > Self.limit { items.removeLast(items.count - Self.limit) }
        UmiEvents.shared.emit("inbox.added", ["category": item.category.rawValue, "title": item.title,
                                              "pane": item.pane.uuidString.lowercased(), "read": item.read])
        if !item.read { toast(item) }
        clampSelection()
    }

    /// The user looked at the pane: its items are read and their toasts go.
    func markRead(pane: UUID) {
        guard items.contains(where: { $0.pane == pane && !$0.read }) else { return }
        for index in items.indices where items[index].pane == pane { items[index].read = true }
        let read = Set(items.filter(\.read).map(\.id))
        toasts.removeAll { read.contains($0.id) }
    }

    func markAllRead() {
        for index in items.indices { items[index].read = true }
        toasts.removeAll()
    }

    private func remove(pane: UUID) {
        guard items.contains(where: { $0.pane == pane }) else { return }
        items.removeAll { $0.pane == pane }
        toasts.removeAll { toast in !items.contains { $0.id == toast.id } }
        clampSelection()
    }

    func item(_ id: UUID) -> Item? { items.first { $0.id == id } }

    // MARK: Toasts

    private func toast(_ item: Item) {
        // Only in the window the user is looking at, and not while its inbox shows it already.
        guard let window = UmiLooking.activeWindow, !isOpen(in: window) else { return }
        toasts.append(Toast(id: item.id, window: ObjectIdentifier(window)))
        while toasts.count > Self.maxToasts { toasts.removeFirst() }
        let id = item.id
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.toastSeconds) { [weak self] in
            self?.toasts.removeAll { $0.id == id }
        }
    }

    func toasts(in window: TerminalController) -> [Item] {
        let key = ObjectIdentifier(window)
        return toasts.filter { $0.window == key }.compactMap { item($0.id) }
    }

    /// ⌃⌘U: the toasts and the update note go.
    func dismissToasts() {
        toasts.removeAll()
        if updateNote != nil {
            updateNote = nil
            UmiEvents.shared.emit("update.note_dismissed", [:])
        }
    }

    var hasToasts: Bool { !toasts.isEmpty || updateNote != nil }

    // MARK: The update note

    /// After an update installed (UmiUpdater, once).
    func showUpdateNote(version: String, notes: String?) {
        let text = notes?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        updateNote = UpdateNote(version: version, notes: text.isEmpty ? "See what changed in the release notes." : text)
        UmiEvents.shared.emit("update.note", ["version": version])
    }

    // MARK: The inbox (⇧⌘U)

    var isOpen: Bool { openWindow != nil }

    func isOpen(in window: TerminalController) -> Bool { openWindow == ObjectIdentifier(window) }

    /// Filters with something in them (All always), as Warp shows them.
    var visibleFilters: [Filter] {
        Filter.allCases.filter { $0 == .all || count($0) > 0 }
    }

    func count(_ filter: Filter) -> Int { filtered(filter).count }

    func filtered(_ filter: Filter) -> [Item] {
        switch filter {
        case .all: return items
        case .unread: return items.filter { !$0.read }
        case .errors: return items.filter { $0.category == .error }
        }
    }

    var shown: [Item] { filtered(filter) }

    /// ⇧⌘U: close the inbox if it's open in this window; otherwise open it here (closing it in
    /// another window).
    func toggle(in window: TerminalController? = nil) {
        let here = window ?? UmiTopology.currentWindow
        if let here, isOpen(in: here) { close() } else { open(in: here) }
    }

    func open(in window: TerminalController? = nil) {
        guard let window = window ?? UmiTopology.currentWindow else { NSSound.beep(); return }
        if isOpen { close() }
        openWindow = ObjectIdentifier(window)
        // The inbox shows the same events (Warp dismisses the toasts as it opens).
        toasts.removeAll()
        if !visibleFilters.contains(filter) { filter = .all }
        selected = shown.isEmpty ? nil : 0
        installKeys(for: window)
        UmiEvents.shared.emit("inbox.opened", ["window": window.umiIDString])
    }

    func close() {
        guard openWindow != nil else { return }
        openWindow = nil
        selected = nil
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        mouseMonitor = nil
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        closeObserver = nil
        UmiEvents.shared.emit("inbox.closed", [:])
    }

    func setFilter(_ filter: Filter) {
        self.filter = visibleFilters.contains(filter) ? filter : .all
        selected = shown.isEmpty ? nil : 0
    }

    /// Shift-Tab (and Tab) go through the filters that have items.
    func cycleFilter() {
        let filters = visibleFilters
        let index = filters.firstIndex(of: filter) ?? 0
        setFilter(filters[(index + 1) % filters.count])
    }

    func move(_ delta: Int) {
        let count = shown.count
        guard count > 0 else { selected = nil; return }
        guard let current = selected else { selected = 0; return }
        selected = min(max(current + delta, 0), count - 1)
    }

    /// Enter: go to the selected item's session; the item is read and the inbox closes.
    func activateSelected() {
        guard let index = selected, shown.indices.contains(index) else { NSSound.beep(); return }
        activate(shown[index].id)
    }

    func activate(_ id: UUID) {
        guard let item = item(id) else { return }
        if let index = items.firstIndex(where: { $0.id == id }) { items[index].read = true }
        close()
        if let pane = UmiTopology.allSurfaces.first(where: { $0.id == item.pane }) {
            UmiLayout.focusPane(pane, activate: true)
        } else if let session = item.session {
            UmiAttention.shared.showSession?(session)
        }
    }

    private func clampSelection() {
        guard isOpen else { return }
        if !visibleFilters.contains(filter) { filter = .all }
        let count = shown.count
        if count == 0 { selected = nil } else if let s = selected, s >= count { selected = count - 1 }
    }

    /// While the inbox is open, its window's arrow keys, Return, Tab and Escape are the
    /// inbox's, whatever has focus; other typing is held back (the panel has the focus, as in
    /// Warp). Shortcuts with ⌘ or ⌃ still work.
    /// A click anywhere else in its window closes it, and the click goes on to what it hit (Warp
    /// closes its mailbox on an outside click). Closing its window closes it.
    private func installKeys(for window: TerminalController) {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        weak var target = window.window
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            MainActor.assumeIsolated {
                guard let target, event.window === target || NSApp.keyWindow === target else { return event }
                return UmiInbox.shared.handleKey(event) ? nil : event
            }
        }
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { event in
            MainActor.assumeIsolated {
                guard let target, event.window === target else { return event }
                UmiInbox.shared.clicked(at: event.locationInWindow)
                return event
            }
        }
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window.window, queue: .main
        ) { _ in
            MainActor.assumeIsolated { UmiInbox.shared.close() }
        }
    }

    /// A click in the inbox's window (window coordinates): outside the panel, the inbox closes.
    func clicked(at point: NSPoint) {
        guard isOpen else { return }
        if let panel = panelView, panel.window != nil, panel.bounds.contains(panel.convert(point, from: nil)) { return }
        close()
    }

    /// One key while the inbox is open. True when the inbox took it.
    @discardableResult
    func handleKey(_ event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if mods.contains(.command) { return false }
        if mods.contains(.control) {
            switch event.charactersIgnoringModifiers {
            case "p": move(-1); return true
            case "n": move(1); return true
            default: return false
            }
        }
        return handleKey(code: event.keyCode)
    }

    /// The inbox's keys by key code (also `debug.ui.inbox.key`).
    @discardableResult
    func handleKey(code: UInt16) -> Bool {
        switch code {
        case 126: move(-1)                  // ↑
        case 125: move(1)                   // ↓
        case 36, 76: activateSelected()     // Return, Enter
        case 53: close()                    // Escape
        case 48: cycleFilter()              // Tab, Shift-Tab
        default: break                      // other typing waits until the inbox closes
        }
        return true
    }

    // MARK: Agents' own desktop notifications (S-3)

    /// A desktop notification a pane's program asked for (OSC 9 or 777): dropped when an agent
    /// session runs in the pane, as Warp drops them for agents its plugin reports. True: dropped.
    func dropsDesktopNotification(fromPane id: UUID, title: String) -> Bool {
        // Only while the agent's own interface runs in the pane's terminal (Warp checks for an
        // active listener): once it exits or the session is stopped, the shell's are Ghostty's.
        guard let agent = UmiAttention.shared.agent(forPane: id), agent.live, agent.status != "stopped" else {
            passedNotifications += 1
            return false
        }
        droppedNotifications += 1
        UmiEvents.shared.emit("notify.dropped", ["pane": id.uuidString.lowercased(), "title": title])
        return true
    }

    // MARK: Checks (`debug.ui.inbox*`)

    func report(window: TerminalController?) -> [String: Any] {
        func json(_ item: Item) -> [String: Any] {
            ["title": item.title, "message": item.message, "category": item.category.rawValue, "read": item.read,
             "pane": item.pane.uuidString.lowercased(), "session": item.session ?? "", "badge": item.badge.rawValue]
        }
        var out: [String: Any] = [
            "open": isOpen, "filter": filter.rawValue, "filters": visibleFilters.map(\.rawValue),
            "selected": selected.map { $0 as Any } ?? NSNull(),
            "items": items.map(json), "shown": shown.map(json),
            "toasts": toasts.compactMap { toast in item(toast.id).map { json($0) } },
            "update_note": updateNote.map { ["version": $0.version, "notes": $0.notes] as [String: Any] } ?? NSNull(),
            "dropped_notifications": droppedNotifications, "passed_notifications": passedNotifications,
        ]
        if let window {
            out["open_here"] = isOpen(in: window)
            out["window_toasts"] = toasts(in: window).map(json)
        }
        return out
    }
}

/// Internal `debug.ui.inbox*` control methods (not part of the CLI contract): what the inbox
/// and toasts show, and its keys without the screen. Each runs the code the keys run.
@MainActor
enum UmiInboxDebug {
    static func handle(_ method: String, _ params: UmiParams, caller: UmiCaller) throws -> [String: Any] {
        let inbox = UmiInbox.shared
        let window = try params.string("window").map { try UmiTopology.window($0, caller: caller) } ?? UmiTopology.currentWindow
        switch method {
        case "debug.ui.inbox":
            break
        case "debug.ui.inbox.toggle":
            inbox.toggle(in: window)
        case "debug.ui.inbox.key":
            guard inbox.isOpen else { throw UmiError.badRequest("the inbox isn't open") }
            let codes: [String: UInt16] = ["up": 126, "down": 125, "return": 36, "escape": 53, "tab": 48]
            guard let code = params.string("key").flatMap({ codes[$0] }) else {
                throw UmiError.badRequest("key is up, down, return, escape or tab")
            }
            inbox.handleKey(code: code)
        case "debug.ui.inbox.dismiss":
            inbox.dismissToasts()
        case "debug.ui.inbox.fill":
            // Finishes from panes that don't exist, through the same path (checks the limit).
            let working = UmiAttention.Agent(session: nil, kind: .claude, title: "", status: "working", live: true,
                                             mark: .none, lastStop: nil)
            for n in 0..<(params.int("count") ?? 1) {
                var done = working
                done.status = "idle"
                done.mark = .finished
                done.title = "filler \(n)"
                inbox.observe(old: working, new: done, pane: UUID())
            }
        default:
            throw UmiError.badRequest("unknown method \(method)")
        }
        return inbox.report(window: window)
    }
}
