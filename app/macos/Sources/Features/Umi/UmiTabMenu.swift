import AppKit
import SwiftUI

// MARK: - The row's menu (S-4)

/// One item of a tab row's right-click menu.
struct UmiTabMenuItem {
    var title: String
    var enabled = true
    var checked = false
    var children: [UmiTabMenuItem] = []
    var isDivider = false
    /// Shown as a row of color dots (Warp's tab color picker); `children` are the colors.
    var isColorRow = false
    /// A color dot's color (nil: the "Default (no color)" dot).
    var color: NSColor?
    var action: (@MainActor () -> Void)?

    static var divider: UmiTabMenuItem { UmiTabMenuItem(title: "", isDivider: true) }
}

/// A tab row's right-click menu: Warp's items, labels and order (its `tab.rs`), then Umi's moves
/// to other windows. Sections are separated by dividers; an item that can't apply is left out,
/// as in Warp.
///
/// Pin tab | New group with tab | Copy branch, Copy tab title, Copy working directory, Copy pull
/// request link | Rename tab, Reset tab name, Rename active pane, Reset active pane name, Move Tab
/// Down, Move Tab Up | Close tab, Close other tabs, Close Tabs Below | Save as New Config |
/// color dots | Move Tab to New Window, Move Tab to Window ▸.
@MainActor
enum UmiTabMenu {
    /// Copies go here (tests point it at a private pasteboard).
    static var pasteboard: NSPasteboard = .general

    static func items(for tab: UmiTab, in controller: TerminalController,
                      row: UmiSidebarRowModel? = nil) -> [UmiTabMenuItem] {
        let row = row ?? UmiSidebarRowModel(tab: tab, in: controller)
        let pane = row.focusedPane
        let paneName = pane.flatMap { UmiState.shared.paneName($0.id) }
        var sections: [[UmiTabMenuItem]] = []

        sections.append([.init(title: tab.pinned ? "Unpin tab" : "Pin tab") {
            let pin = !tab.pinned
            UmiLayout.undoable(pin ? "Pin Tab" : "Unpin Tab", windows: [controller]) { controller.setPinned(tab, pin) }
            UmiEvents.shared.emit(pin ? "tab.pinned" : "tab.unpinned", ["tab": tab.idString, "window": controller.umiIDString])
        }])

        sections.append(UmiTabGroups.menuItems(for: tab, in: controller))

        var copies: [UmiTabMenuItem] = []
        if let branch = row.git?.branch, !branch.isEmpty {
            copies.append(.init(title: "Copy branch") { copy(branch) })
        }
        copies.append(.init(title: "Copy tab title") { copy(row.title) })
        if let cwd = row.cwd {
            copies.append(.init(title: "Copy working directory") { copy(cwd) })
        }
        if let cwd = row.cwd, let branch = row.git?.branch,
           let url = UmiPullRequests.shared.url(cwd: cwd, branch: branch) {
            copies.append(.init(title: "Copy pull request link") { copy(url) })
        }
        sections.append(copies)

        var modify: [UmiTabMenuItem] = [.init(title: "Rename tab") { beginRename(.tab(tab.id), in: controller) }]
        if tab.name != nil {
            modify.append(.init(title: "Reset tab name") { Self.rename(tab, in: controller, to: "") })
        }
        if let pane {
            modify.append(.init(title: "Rename active pane") {
                beginRename(.pane(tab: tab.id, pane: pane.id), in: controller)
            })
            if paneName != nil {
                modify.append(.init(title: "Reset active pane name") { setPaneName(pane, "") })
            }
        }
        if canMove(tab, by: 1, in: controller) {
            modify.append(.init(title: "Move Tab Down") { move(tab, by: 1, in: controller) })
        }
        if canMove(tab, by: -1, in: controller) {
            modify.append(.init(title: "Move Tab Up") { move(tab, by: -1, in: controller) })
        }
        sections.append(modify)

        var close: [UmiTabMenuItem] = [.init(title: "Close tab") { controller.closeTab(tab, sender: nil) }]
        if controller.tabs.count > 1 {
            close.append(.init(title: "Close other tabs") { controller.closeTabs(otherThan: tab) })
        }
        if let index = controller.index(of: tab), index < controller.tabs.count - 1 {
            close.append(.init(title: "Close Tabs Below") { controller.closeTabs(below: tab) })
        }
        sections.append(close)

        // Warp puts "Save as new config" between the close items and the colors (L-21). Greyed,
        // not left out, when the tab has no terminal pane to save.
        sections.append([.init(title: "Save as New Config",
                               enabled: UmiLaunchConfigs.capture(tab: tab, in: controller) != nil) {
            do {
                try UmiLaunchConfigs.saveTab(tab, in: controller)
            } catch {
                NSSound.beep()
            }
        }])

        sections.append([colorRow(current: tab.color) { color in setColor(tab, color, in: controller) }])

        var moves: [UmiTabMenuItem] = [.init(title: "Move Tab to New Window") {
            _ = try? UmiLayout.move(tab: tab, from: controller, toWindow: nil, index: nil, newWindow: true, focus: true)
        }]
        let others = UmiTopology.windows.filter { $0 !== controller }
        if !others.isEmpty {
            moves.append(.init(title: "Move Tab to Window", children: others.map { window in
                UmiTabMenuItem(title: "Window \(UmiTopology.windowNumber(window)): \(window.selectedTab.title)") {
                    _ = try? UmiLayout.move(tab: tab, from: controller, toWindow: window, index: nil,
                                             newWindow: false, focus: true)
                }
            }))
        }
        sections.append(moves)

        return joined(sections)
    }

    /// Sections with a divider between non-empty ones.
    static func joined(_ sections: [[UmiTabMenuItem]]) -> [UmiTabMenuItem] {
        var items: [UmiTabMenuItem] = []
        for section in sections where !section.isEmpty {
            if !items.isEmpty { items.append(.divider) }
            items += section
        }
        return items
    }

    /// Warp's color picker: a "Default (no color)" dot, then its six colors. Picking the current
    /// color again clears it, as Warp's toggle does.
    static func colorRow(current: TerminalTabColor,
                         pick: @escaping @MainActor (TerminalTabColor) -> Void) -> UmiTabMenuItem {
        let dots = [UmiTabMenuItem(title: "Default (no color)", checked: current == .none) { pick(.none) }]
            + TerminalTabColor.umiWarpChoices.map { color in
                UmiTabMenuItem(title: color.localizedName, checked: current == color, color: color.displayColor) {
                    pick(current == color ? .none : color)
                }
            }
        return UmiTabMenuItem(title: "Tab Color", children: dots, isColorRow: true)
    }

    // MARK: Actions

    static func copy(_ text: String) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    static func setColor(_ tab: UmiTab, _ color: TerminalTabColor, in controller: TerminalController) {
        tab.color = color
        UmiEvents.shared.emit("tab.colored", ["tab": tab.idString, "color": UmiTopology.colorName(color),
                                               "window": controller.umiIDString])
        UmiState.shared.layoutDidChange()
    }

    static func rename(_ tab: UmiTab, in controller: TerminalController, to draft: String) {
        let name = draft.trimmingCharacters(in: .whitespaces)
        tab.name = name.isEmpty ? nil : name
        if tab === controller.selectedTab { controller.titleOverride = tab.name }
        UmiEvents.shared.emit("tab.renamed", ["tab": tab.idString, "name": name, "window": controller.umiIDString])
        UmiState.shared.layoutDidChange()
    }

    static func setPaneName(_ pane: Ghostty.SurfaceView, _ name: String) {
        UmiState.shared.setPaneName(pane.id, name)
        UmiEvents.shared.emit("pane.renamed", ["pane": pane.umiID, "name": name])
    }

    /// Rename a tab, its active pane or a tab group in place, in its row (as Warp), showing the
    /// sidebar's tab list first if needed.
    static func beginRename(_ target: UmiSidebarModel.RenameTarget, in controller: TerminalController) {
        UmiSidebarVisibility.set(true, in: controller)
        UmiState.shared.sidebarMode = .tabs
        if let tabID = target.tabID, let tab = controller.tabs.first(where: { $0.id == tabID }) {
            // A row the search hides comes back.
            if controller.sidebarModel.isSearching,
               !UmiSidebarModel.matches(UmiSidebarRowModel(tab: tab, in: controller), query: controller.sidebarModel.query) {
                controller.sidebarModel.query = ""
            }
            UmiTabGroups.reveal(tab, in: controller)
        }
        controller.sidebarModel.renaming = target
    }

    /// Moving a tab up or down stays within its group (pinned or not): the same as ⌃⇧←/→
    /// (UmiNavigation), with its undo step, event and sidebar-order hold.
    static func canMove(_ tab: UmiTab, by delta: Int, in controller: TerminalController) -> Bool {
        UmiNavigation.canMoveTab(tab, by: delta, in: controller)
    }

    static func move(_ tab: UmiTab, by delta: Int, in controller: TerminalController) {
        UmiNavigation.moveTab(tab, by: delta, in: controller)
    }

    // MARK: Finding items (debug.ui.menu)

    static func flatten(_ items: [UmiTabMenuItem], path: [String] = []) -> [(path: [String], item: UmiTabMenuItem)] {
        items.filter { !$0.isDivider }.flatMap { item in
            [(path + [item.title], item)] + flatten(item.children, path: path + [item.title])
        }
    }

    // MARK: AppKit menu

    /// The items as an AppKit menu (a right-click on a row), the colors as one row of dots.
    static func nsMenu(_ items: [UmiTabMenuItem]) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for item in items {
            if item.isDivider {
                menu.addItem(.separator())
            } else if item.isColorRow {
                let menuItem = NSMenuItem()
                let view = NSHostingView(rootView: UmiColorDotsRow(dots: item.children) { [weak menu] in
                    menu?.cancelTracking()
                })
                view.frame.size = view.fittingSize
                menuItem.view = view
                menuItem.setAccessibilityLabel(item.title)
                menu.addItem(menuItem)
            } else {
                let menuItem = UmiClosureMenuItem(title: item.title, action: item.action)
                menuItem.isEnabled = item.enabled
                menuItem.state = item.checked ? .on : .off
                if !item.children.isEmpty { menuItem.submenu = nsMenu(item.children) }
                menu.addItem(menuItem)
            }
        }
        return menu
    }
}

/// An NSMenuItem that runs a closure.
final class UmiClosureMenuItem: NSMenuItem {
    private let run: (@MainActor () -> Void)?

    init(title: String, action run: (@MainActor () -> Void)?) {
        self.run = run
        super.init(title: title, action: run == nil ? nil : #selector(runClosure(_:)), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("not used") }

    // Not `perform(_:)`: that is NSObject's performSelector: in Objective-C, which the menu
    // would call with the item as the selector.
    @MainActor @objc private func runClosure(_ sender: Any?) { run?() }
}

/// Warp's tab color picker: 16 pt dots spread across the menu's width, the current one ringed
/// in the accent; the first, "Default (no color)", is a slashed circle.
struct UmiColorDotsRow: View {
    let dots: [UmiTabMenuItem]
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(dots.enumerated()), id: \.offset) { _, dot in
                Spacer(minLength: 4)
                Button {
                    dismiss()
                    dot.action?()
                } label: {
                    ZStack {
                        if let color = dot.color {
                            Circle().fill(Color(nsColor: color)).frame(width: 16, height: 16)
                        } else {
                            Image(systemName: "circle.slash")
                                .font(.system(size: 14))
                                .foregroundColor(Color(nsColor: .labelColor))
                                .frame(width: 16, height: 16)
                        }
                    }
                    .padding(2)
                    .overlay(Circle().strokeBorder(dot.checked ? UmiTheme.accent : .clear, lineWidth: 2))
                    .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(dot.title)
                .accessibilityLabel(dot.title)
                .accessibilityAddTraits(dot.checked ? [.isSelected] : [])
            }
            Spacer(minLength: 4)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .frame(minWidth: 220)
    }
}

/// The items as a SwiftUI context menu (the project explorer's rows). A color row shows as a
/// submenu of its colors.
struct UmiTabMenuView: View {
    let items: [UmiTabMenuItem]

    var body: some View {
        ForEach(Array(items.enumerated()), id: \.offset) { _, item in
            if item.isDivider {
                Divider()
            } else if !item.children.isEmpty {
                Menu(item.title) { UmiTabMenuView(items: item.children) }
            } else {
                Button {
                    item.action?()
                } label: {
                    if item.checked {
                        Label(item.title, systemImage: "checkmark")
                    } else {
                        Text(item.title)
                    }
                }
                .disabled(!item.enabled)
            }
        }
    }
}
