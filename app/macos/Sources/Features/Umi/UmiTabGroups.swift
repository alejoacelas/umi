import AppKit
import SwiftUI

// MARK: - Tab groups (S-14)

/// A named, collapsible run of tabs in a window's sidebar: Warp's tab groups ("New group with
/// tab" in a row's menu). A group's tabs stay next to each other in the window's order; the
/// sidebar shows a header above them and indents them by 12 pt.
@MainActor
final class UmiTabGroup: ObservableObject, Identifiable {
    let id: UUID
    @Published var name: String?
    @Published var color: TerminalTabColor = .none
    @Published var collapsed = false

    init(id: UUID = UUID()) { self.id = id }

    /// Warp's name for a group nobody named yet.
    static let untitled = "New Group"
    var displayName: String { name.flatMap { $0.isEmpty ? nil : $0 } ?? Self.untitled }
    var idString: String { id.uuidString.lowercased() }
}

@MainActor
enum UmiTabGroups {
    /// Members are indented under their header by Warp's 12 pt.
    static let memberIndent: CGFloat = 12

    /// One line of the sidebar's tab list.
    enum Entry: Identifiable {
        case tab(UmiTab, indent: CGFloat)
        case group(UmiTabGroup)

        var id: String {
            switch self {
            case .tab(let tab, _): return "tab-" + tab.id.uuidString
            case .group(let group): return "group-" + group.id.uuidString
            }
        }
    }

    // MARK: Reading

    static func group(of tab: UmiTab, in controller: TerminalController) -> UmiTabGroup? {
        guard let id = tab.groupID else { return nil }
        return controller.sidebarModel.groups.first { $0.id == id }
    }

    static func group(id: String, in controller: TerminalController) -> UmiTabGroup? {
        controller.sidebarModel.groups.first { $0.idString == id.lowercased() || $0.displayName == id }
    }

    static func members(of group: UmiTabGroup, in controller: TerminalController) -> [UmiTab] {
        controller.tabs.filter { $0.groupID == group.id }
    }

    /// The tab's row is on show: not hidden in a collapsed group (a search shows every match).
    static func isShown(_ tab: UmiTab, in controller: TerminalController) -> Bool {
        guard let group = group(of: tab, in: controller) else { return true }
        return !group.collapsed || controller.sidebarModel.isSearching
    }

    /// Whether a search admits the tab: its own text, or its group's name (which admits every
    /// tab of the group, as in Warp).
    static func tabMatches(_ tab: UmiTab, query: String, in controller: TerminalController) -> Bool {
        if UmiSidebarModel.matches(UmiSidebarRowModel(tab: tab, in: controller), query: query) { return true }
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty, let group = group(of: tab, in: controller) else { return false }
        return group.displayName.lowercased().contains(needle)
    }

    /// The sidebar's lines in order: ungrouped tabs, and each group's header where its first tab
    /// is, followed by its tabs unless it's collapsed. A search lists only what it admits.
    static func sidebarEntries(in controller: TerminalController) -> [Entry] {
        let model = controller.sidebarModel
        let admitted = Set(model.matchingTabs(in: controller).map(\.id))
        var entries: [Entry] = []
        var listed: Set<UUID> = []
        for tab in controller.tabs {
            guard let group = group(of: tab, in: controller) else {
                if admitted.contains(tab.id) { entries.append(.tab(tab, indent: 0)) }
                continue
            }
            guard !listed.contains(group.id) else { continue }
            listed.insert(group.id)
            let shown = members(of: group, in: controller).filter { admitted.contains($0.id) }
            if model.isSearching && shown.isEmpty { continue }
            entries.append(.group(group))
            if !group.collapsed || model.isSearching {
                entries += shown.map { .tab($0, indent: memberIndent) }
            }
        }
        return entries
    }

    /// Make sure a tab's row is on show: expand its group.
    static func reveal(_ tab: UmiTab, in controller: TerminalController) {
        guard let group = group(of: tab, in: controller), group.collapsed else { return }
        setCollapsed(group, false, in: controller)
    }

    // MARK: Changing

    /// "New group with tab": a group of just this tab (unpinned, after the rest of its old group),
    /// whose name is typed in place right away, as in Warp.
    static func newGroup(with tab: UmiTab, in controller: TerminalController) {
        if tab.pinned { controller.setPinned(tab, false) }
        if let previous = group(of: tab, in: controller),
           let last = members(of: previous, in: controller).last(where: { $0 !== tab }) {
            place(tab, after: last, in: controller)
        }
        let group = UmiTabGroup()
        controller.sidebarModel.groups.append(group)
        tab.groupID = group.id
        changed(controller, event: "tab.grouped", ["tab": tab.idString, "group": group.idString])
        UmiTabMenu.beginRename(.group(group.id), in: controller)
    }

    /// "Move to group": the tab joins the end of the group.
    static func move(_ tab: UmiTab, to group: UmiTabGroup, in controller: TerminalController) {
        guard tab.groupID != group.id else { return }
        if tab.pinned { controller.setPinned(tab, false) }
        let last = members(of: group, in: controller).last
        tab.groupID = group.id
        if let last { place(tab, after: last, in: controller) }
        changed(controller, event: "tab.grouped", ["tab": tab.idString, "group": group.idString])
    }

    /// "Remove from group": the tab goes right after the group, on its own.
    static func remove(_ tab: UmiTab, in controller: TerminalController) {
        guard let group = group(of: tab, in: controller) else { return }
        let last = members(of: group, in: controller).last(where: { $0 !== tab })
        tab.groupID = nil
        if let last { place(tab, after: last, in: controller) }
        changed(controller, event: "tab.ungrouped", ["tab": tab.idString, "group": group.idString])
    }

    /// "Ungroup tabs": the tabs stay where they are, the group goes.
    static func ungroup(_ group: UmiTabGroup, in controller: TerminalController) {
        for tab in members(of: group, in: controller) { tab.groupID = nil }
        controller.sidebarModel.groups.removeAll { $0 === group }
        changed(controller, event: "tab.ungrouped", ["group": group.idString])
    }

    static func setCollapsed(_ group: UmiTabGroup, _ collapsed: Bool, in controller: TerminalController) {
        guard group.collapsed != collapsed else { return }
        group.collapsed = collapsed
        changed(controller, event: nil, [:])
    }

    static func rename(_ group: UmiTabGroup, to name: String, in controller: TerminalController) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        group.name = trimmed.isEmpty ? nil : trimmed
        changed(controller, event: "tab.group.renamed", ["group": group.idString, "name": trimmed])
    }

    static func setColor(_ group: UmiTabGroup, _ color: TerminalTabColor, in controller: TerminalController) {
        group.color = color
        changed(controller, event: nil, [:])
    }

    /// "New tab in group": a new tab at the end of the group, shown.
    static func newTab(in group: UmiTabGroup, in controller: TerminalController) {
        let index = members(of: group, in: controller).last.flatMap { controller.index(of: $0) }.map { $0 + 2 }
        guard (try? UmiLayout.newTab(in: controller, options: .init(), tabName: nil, color: .none, index: index,
                                      focus: true, inheritFrom: nil)) != nil else { return }
        let tab = controller.selectedTab
        tab.groupID = group.id
        setCollapsed(group, false, in: controller)
        changed(controller, event: "tab.grouped", ["tab": tab.idString, "group": group.idString])
    }

    /// "Close all tabs in group" and "Close other tabs" (the tabs outside the group).
    static func close(_ group: UmiTabGroup, others: Bool, in controller: TerminalController) {
        let inside = members(of: group, in: controller)
        let toClose = others ? controller.tabs.filter { $0.groupID != group.id } : inside
        controller.closeTabs(toClose, actionName: others ? "Close Other Tabs" : "Close Tabs in Group",
                             question: others ? "Close Other Tabs?" : "Close Tabs in Group?")
    }

    /// Keep groups whole after any change: pinned tabs and tabs whose group isn't in their window
    /// leave it, a group's tabs sit together where its first tab is, and empty groups go.
    static func normalize(_ controller: TerminalController) {
        let model = controller.sidebarModel
        let ids = Set(model.groups.map(\.id))
        for tab in controller.tabs {
            guard let id = tab.groupID else { continue }
            if tab.pinned || !ids.contains(id) { tab.groupID = nil }
        }
        for group in model.groups {
            let members = members(of: group, in: controller)
            guard members.count > 1, let first = controller.index(of: members[0]) else { continue }
            for (offset, member) in members.enumerated().dropFirst() where controller.index(of: member) != first + offset {
                controller.moveTab(member, to: first + offset)
            }
        }
        let used = Set(controller.tabs.compactMap(\.groupID))
        if model.groups.contains(where: { !used.contains($0.id) }) {
            model.groups.removeAll { !used.contains($0.id) }
        }
    }

    static func normalizeAll() {
        for window in UmiTopology.windows { normalize(window) }
    }

    /// Move `tab` to right after `other` in the window's order.
    private static func place(_ tab: UmiTab, after other: UmiTab, in controller: TerminalController) {
        guard tab !== other, var target = controller.index(of: other).map({ $0 + 1 }) else { return }
        if let from = controller.index(of: tab), from < target { target -= 1 }
        if controller.index(of: tab) != target { controller.moveTab(tab, to: target) }
    }

    private static func changed(_ controller: TerminalController, event: String?, _ info: [String: Any]) {
        if let event {
            UmiEvents.shared.emit(event, info.merging(["window": controller.umiIDString]) { a, _ in a })
        }
        UmiState.shared.layoutDidChange()
    }

    // MARK: Menus

    /// The row menu's group items (Warp's): New group with tab (unless the tab is its group's only
    /// tab), Move to group ▸ (when another group exists), Remove from group (when in one).
    static func menuItems(for tab: UmiTab, in controller: TerminalController) -> [UmiTabMenuItem] {
        let own = group(of: tab, in: controller)
        var items: [UmiTabMenuItem] = []
        if own == nil || members(of: own!, in: controller).count > 1 {
            items.append(.init(title: "New group with tab") { newGroup(with: tab, in: controller) })
        }
        let others = controller.sidebarModel.groups.filter { $0 !== own }
        if !others.isEmpty {
            items.append(.init(title: "Move to group", children: others.map { group in
                UmiTabMenuItem(title: group.displayName) { move(tab, to: group, in: controller) }
            }))
        }
        if own != nil {
            items.append(.init(title: "Remove from group") { remove(tab, in: controller) })
        }
        return items
    }

    /// A group header's menu (Warp's): Ungroup tabs, New tab in group | Rename | Close all tabs in
    /// group, Close other tabs | the color dots.
    static func headerMenuItems(for group: UmiTabGroup, in controller: TerminalController) -> [UmiTabMenuItem] {
        let inside = members(of: group, in: controller)
        var close: [UmiTabMenuItem] = [.init(title: "Close all tabs in group") { self.close(group, others: false, in: controller) }]
        if inside.count < controller.tabs.count {
            close.append(.init(title: "Close other tabs") { self.close(group, others: true, in: controller) })
        }
        return UmiTabMenu.joined([
            [.init(title: "Ungroup tabs") { ungroup(group, in: controller) },
             .init(title: "New tab in group") { newTab(in: group, in: controller) }],
            [.init(title: "Rename") { UmiTabMenu.beginRename(.group(group.id), in: controller) }],
            close,
            [UmiTabMenu.colorRow(current: group.color) { setColor(group, $0, in: controller) }],
        ])
    }

    // MARK: From the keyboard (Window menu and the palette)

    static func currentGroup() -> (TerminalController, UmiTabGroup)? {
        guard let window = UmiTopology.currentWindow, let group = group(of: window.selectedTab, in: window) else { return nil }
        return (window, group)
    }

    static func json(_ group: UmiTabGroup, in controller: TerminalController) -> [String: Any] {
        ["id": group.idString, "name": group.displayName, "named": group.name != nil, "collapsed": group.collapsed,
         "color": UmiTopology.colorName(group.color), "tabs": members(of: group, in: controller).map(\.idString)]
    }
}

// MARK: - Header

/// A group's header in the sidebar, as Warp's: a 24 pt icon (a chevron while open, the stacked
/// tabs while collapsed), the name at 12 pt over "N tabs" at 10 pt, 8 pt inside, radius 4. A
/// click opens or collapses it, a double-click renames it in place, a right-click has its menu.
struct UmiTabGroupHeader: View {
    @ObservedObject var controller: TerminalController
    @ObservedObject var group: UmiTabGroup
    @ObservedObject var model: UmiSidebarModel
    @State private var hovering = false
    @State private var draftName = ""
    @FocusState private var nameFieldFocused: Bool

    private var renaming: Bool { model.renaming == .group(group.id) }

    var body: some View {
        let members = UmiTabGroups.members(of: group, in: controller)
        let holdsSelected = group.collapsed && members.contains { $0 === controller.selectedTab }

        HStack(spacing: 8) {
            ZStack {
                if group.collapsed {
                    Circle().fill(UmiTheme.overlay2)
                    Image(systemName: "square.stack")
                        .font(.system(size: 11))
                        .foregroundColor(UmiTheme.rowTitle)
                } else {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 16, height: 16)
                        .foregroundColor(UmiTheme.rowTitle)
                }
            }
            .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 1) {
                if renaming {
                    TextField("Group name", text: $draftName)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundColor(UmiTheme.rowTitle)
                        .focused($nameFieldFocused)
                        .onSubmit { UmiSidebarRename.commit(.group(group.id), text: draftName, in: controller) }
                        .onExitCommand { UmiSidebarRename.cancel(.group(group.id), in: controller) }
                        .onChange(of: nameFieldFocused) { focused in
                            if !focused, renaming {
                                UmiSidebarRename.cancel(.group(group.id), in: controller, focusPane: false)
                            }
                        }
                        .accessibilityLabel("Group name")
                } else {
                    Text(group.displayName)
                        .font(.system(size: 12))
                        .foregroundColor(UmiTheme.rowTitle)
                        .lineLimit(1)
                }
                Text(members.count == 1 ? "1 tab" : "\(members.count) tabs")
                    .font(.system(size: 10))
                    .foregroundColor(UmiTheme.rowSubtitle)
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(background(holdsSelected)))
        .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous)
            .strokeBorder(holdsSelected ? UmiTheme.overlay3 : .clear, lineWidth: 1))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) {
            UmiTabGroups.setCollapsed(group, !group.collapsed, in: controller)
            UmiTabMenu.beginRename(.group(group.id), in: controller)
        }
        .onTapGesture { if !renaming { UmiTabGroups.setCollapsed(group, !group.collapsed, in: controller) } }
        .overlay(UmiRowMenuCatcher { UmiTabMenu.nsMenu(UmiTabGroups.headerMenuItems(for: group, in: controller)) })
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Group: \(group.displayName)")
        .accessibilityValue(group.collapsed ? "collapsed" : "expanded")
        .accessibilityAddTraits(.isButton)
        .onAppear { if renaming { startEditing() } }
        .onChange(of: model.renaming) { _ in if renaming { startEditing() } }
    }

    /// Warp's: the group color at 50%, else 10%, when hovered or holding the selected tab.
    private func background(_ holdsSelected: Bool) -> Color {
        guard hovering || holdsSelected else { return .clear }
        if let color = group.color.displayColor { return Color(color).opacity(0.5) }
        return UmiTheme.overlay2
    }

    private func startEditing() {
        draftName = group.name ?? ""
        DispatchQueue.main.async { nameFieldFocused = true }
    }
}
