import AppKit
import SwiftUI

// MARK: - The archive (design/archive.md)

extension UmiTab {
    /// In its window's archive: the tab attribute `archived=true`. It keeps running, out of the
    /// sidebar's list until the archive is opened.
    var archived: Bool { attributes["archived"] == "true" }
}

extension TerminalController {
    /// The tabs out of the archive, in sidebar order: what ⇧⌘[ ⇧⌘], ⌘1–9 and tab moves go through.
    var activeTabs: [UmiTab] { tabs.filter { !$0.archived } }
    /// The archived tabs, in the order they were archived (latest last).
    var archivedTabs: [UmiTab] { tabs.filter(\.archived) }
}

/// Archiving and bringing back tabs: ⌃⌘A, the row menu, Window ▸ Archive Tab / Unarchive Tab /
/// Show Archived, `tab archive|unarchive`, `tab set archived=…` and a ⌃⇧↑ tab move past the top.
///
/// An archived tab stays in its window's `tabs`, at their end in archive order; the sidebar lists
/// it under the Archived row instead of with the others. Archiving takes the tab out of its group
/// and unpins it; unarchiving puts it at the top of the unpinned tabs.
@MainActor
enum UmiArchive {
    // MARK: Archiving

    /// Put a tab in its window's archive. If it was selected, the window shows the tab the sidebar
    /// would select after closing it (a window with no other tab out of the archive keeps showing it).
    static func archive(_ tab: UmiTab, in window: TerminalController) {
        guard !tab.archived else { return }
        if tab.groupID != nil { UmiTabGroups.remove(tab, in: window) }
        if tab.pinned {
            window.setPinned(tab, false)
            UmiEvents.shared.emit("tab.unpinned", ["tab": tab.idString, "window": window.umiIDString])
        }
        let next = tab === window.selectedTab ? neighbor(afterRemoving: tab, in: window) : nil
        tab.attributes["archived"] = "true"
        window.moveTab(tab, to: window.tabs.count)
        if window.sidebarModel.renaming?.tabID == tab.id { window.sidebarModel.renaming = nil }
        UmiTabGroups.normalize(window)
        UmiEvents.shared.emit("tab.archived", ["tab": tab.idString, "window": window.umiIDString])
        if let next {
            if UmiTopology.currentWindow === window { UmiLayout.focusTab(next, in: window) } else { window.selectTab(next, focus: false) }
        }
        UmiState.shared.layoutDidChange()
    }

    /// Bring a tab back from the archive, to the top of the unpinned tabs. Its pending `--until`
    /// conditions go with it. Selection doesn't change.
    static func unarchive(_ tab: UmiTab, in window: TerminalController, byCondition: Bool = false) {
        conditions[tab.id] = nil
        guard tab.archived else { return }
        tab.attributes.removeValue(forKey: "archived")
        window.moveTab(tab, to: window.tabs.filter(\.pinned).count)
        var data: [String: Any] = ["tab": tab.idString, "window": window.umiIDString]
        if byCondition { data["by_condition"] = true }
        UmiEvents.shared.emit("tab.unarchived", data)
        UmiState.shared.layoutDidChange()
    }

    /// The tab a window shows after `tab` leaves its list, as closing it would: the next tab of the
    /// same list (out of the archive, or in it) at its place, else the one before; else any other.
    static func neighbor(afterRemoving tab: UmiTab, in window: TerminalController) -> UmiTab? {
        let list = tab.archived ? window.archivedTabs : window.activeTabs
        if let index = list.firstIndex(where: { $0 === tab }) {
            let rest = list.filter { $0 !== tab }
            if !rest.isEmpty { return rest[min(index, rest.count - 1)] }
        }
        let others = (tab.archived ? window.archivedTabs : window.activeTabs).isEmpty ? window.tabs : window.activeTabs
        return others.first { $0 !== tab } ?? window.tabs.first { $0 !== tab }
    }

    // MARK: From the keyboard and the menus

    /// ⌃⌘A: archive the current tab, or bring it back when it is archived.
    static func toggleCurrent() {
        guard let window = UmiTopology.currentWindow else { NSSound.beep(); return }
        let tab = window.selectedTab
        if tab.archived { unarchive(tab, in: window) } else { archive(tab, in: window) }
    }

    static func archiveCurrent() {
        guard let window = UmiTopology.currentWindow, !window.selectedTab.archived else { NSSound.beep(); return }
        archive(window.selectedTab, in: window)
    }

    static func unarchiveCurrent() {
        guard let window = UmiTopology.currentWindow, window.selectedTab.archived else { NSSound.beep(); return }
        unarchive(window.selectedTab, in: window)
    }

    static var currentIsArchived: Bool { UmiTopology.currentWindow?.selectedTab.archived ?? false }
    static var currentHasArchive: Bool { !(UmiTopology.currentWindow?.archivedTabs.isEmpty ?? true) }

    /// Show Archived: open the archive and select its first tab.
    static func showArchived(in window: TerminalController? = nil) {
        guard let window = window ?? UmiTopology.currentWindow, let first = window.archivedTabs.first else {
            NSSound.beep()
            return
        }
        setOpen(true, in: window)
        if !window.sidebarVisible { UmiSidebarVisibility.set(true, in: window) }
        UmiState.shared.sidebarMode = .tabs
        UmiLayout.focusTab(first, in: window)
    }

    /// Open or close the window's archive (a click on the Archived row).
    static func setOpen(_ open: Bool, in window: TerminalController) {
        guard window.sidebarModel.archiveOpen != open else { return }
        window.sidebarModel.archiveOpen = open
        UmiState.shared.layoutDidChange()
    }

    // MARK: `tab archive --until`

    /// Each archived tab's pending conditions (queries about any of its panes, or moments); the first
    /// to hold brings it back. Unarchiving by any means clears them.
    private(set) static var conditions: [UUID: [UmiHidden.Condition]] = [:]
    private static var listener: UUID?
    private static var timer: Timer?

    static func setConditions(_ list: [UmiHidden.Condition], for tab: UmiTab) {
        conditions[tab.id] = list.isEmpty ? nil : list
        startWatching()
        for condition in list {
            if let at = condition.at {
                let delay = max(at.timeIntervalSinceNow, 0) + 0.05
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { checkConditions() }
            }
        }
        UmiState.shared.layoutDidChange(persistOnly: true)
        checkConditions(only: tab.id)
    }

    /// Conditions saved with the layout come back with the tab.
    static func restoreConditions(_ json: Any?, for tab: UmiTab) {
        guard let list = json as? [[String: Any]], !list.isEmpty else { return }
        let parsed = list.map { item in
            UmiHidden.Condition(query: item["query"] as? String, at: (item["at"] as? String).flatMap(UmiTime.parseISO))
        }
        DispatchQueue.main.async { setConditions(parsed, for: tab) }
    }

    /// Checked whenever one of the tab's panes changes and once a minute, as `pane hide --until`.
    private static func startWatching() {
        if listener == nil {
            listener = UmiEvents.shared.addListener { name, _ in
                guard name == "pane.changed" else { return }
                DispatchQueue.main.async { if !conditions.isEmpty { checkConditions() } }
            }
        }
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
                MainActor.assumeIsolated { checkConditions() }
            }
        }
    }

    static func checkConditions(only id: UUID? = nil) {
        guard !conditions.isEmpty else { return }
        let now = Date()
        for (tabID, list) in conditions where id == nil || tabID == id {
            guard let (window, tab) = UmiTopology.windows.lazy.compactMap({ window in
                window.tabs.first { $0.id == tabID }.map { (window, $0) }
            }).first else {
                // The tab is gone.
                conditions[tabID] = nil
                continue
            }
            guard tab.archived else {
                conditions[tabID] = nil
                continue
            }
            let holds = list.contains { condition in
                if let at = condition.at, at <= now { return true }
                if let text = condition.query, let query = try? UmiTopology.parseQuery(text) {
                    let placed = (UmiTopology.panes(of: tab, in: window) + window.hiddenPanes(of: tab))
                        .map { UmiTopology.Placed(pane: $0, tab: tab, window: window) }
                    return !((try? UmiTopology.match(query, among: placed)) ?? []).isEmpty
                }
                return false
            }
            guard holds else { continue }
            UmiCause.during(UmiCause(kind: "config")) {
                unarchive(tab, in: window, byCondition: true)
            }
        }
    }

    static func conditionsJSON(_ tab: UmiTab) -> [[String: Any]]? {
        conditions[tab.id].map { $0.map(\.json) }
    }

    // MARK: The CLI

    /// `--until` arguments: durations become moments; anything else must parse as a query.
    static func parseConditions(_ texts: [String]) throws -> [UmiHidden.Condition] {
        try texts.map { text in
            if let seconds = UmiQuery.duration(text), seconds > 0 {
                return UmiHidden.Condition(query: nil, at: Date().addingTimeInterval(seconds))
            }
            _ = try UmiTopology.parseQuery(text)
            return UmiHidden.Condition(query: text, at: nil)
        }
    }

    static func json(_ window: TerminalController) -> [String: Any] {
        ["open": window.sidebarModel.archiveOpen, "tabs": window.archivedTabs.map(\.idString)]
    }
}

// MARK: - The Archived row and its box

/// The archive at the top of the sidebar: the Archived row ("Archived · 3"), and while open its
/// tabs under it in the box a tab group uses. The row shows no indicator.
struct UmiArchiveBox: View {
    @ObservedObject var controller: TerminalController
    @ObservedObject var model: UmiSidebarModel
    /// The archived tabs the sidebar lists (all, or the matches of a search).
    let tabs: [UmiTab]
    var tick: Int = 0
    @State private var hovering = false

    private var open: Bool { model.archiveOpen || model.isSearching }

    var body: some View {
        let shown = open ? tabs : []
        let active = controller.archivedTabs.contains { $0 === controller.selectedTab }
        VStack(alignment: .leading, spacing: 4) {
            UmiArchiveRow(controller: controller, model: model, count: controller.archivedTabs.count,
                          open: open, holdsSelected: active && !open)
            ForEach(shown, id: \.id) { tab in
                UmiSidebarTabRow(controller: controller, tab: tab, model: model, tick: tick)
                    .padding(.leading, UmiTabGroups.memberIndent)
                    .padding(.trailing, UmiTabGroups.contentInset)
            }
        }
        .padding(.bottom, shown.isEmpty ? 0 : UmiTabGroups.contentInset)
        .background(RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(UmiTabGroupBox.fill(.none, lit: hovering || active)))
        .onHover { hovering = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Archive")
    }
}

/// The Archived row: a box icon, "Archived · N", a chevron while open. A click opens or closes it.
struct UmiArchiveRow: View {
    @ObservedObject var controller: TerminalController
    @ObservedObject var model: UmiSidebarModel
    let count: Int
    let open: Bool
    /// The archive is closed and holds the tab the window shows.
    let holdsSelected: Bool
    @State private var hovering = false

    static func title(count: Int) -> String { "Archived · \(count)" }

    var body: some View {
        HStack(spacing: 8) {
            ZStack {
                Image(systemName: open ? "chevron.down" : "archivebox")
                    .font(.system(size: open ? 10 : 11, weight: open ? .semibold : .regular))
                    .frame(width: 16, height: 16)
                    .foregroundColor(UmiTheme.rowTitle)
            }
            .frame(width: 24, height: 24)
            Text(Self.title(count: count))
                .font(.system(size: 12))
                .foregroundColor(UmiTheme.rowTitle)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(hovering || holdsSelected ? UmiTheme.overlay2 : .clear))
        .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous)
            .strokeBorder(holdsSelected ? UmiTheme.overlay3 : .clear, lineWidth: 1))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { UmiArchive.setOpen(!model.archiveOpen, in: controller) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.title(count: count))
        .accessibilityValue(open ? "expanded" : "collapsed")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { UmiArchive.setOpen(!model.archiveOpen, in: controller) }
    }
}
