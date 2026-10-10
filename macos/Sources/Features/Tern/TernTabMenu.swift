import AppKit
import SwiftUI

// MARK: - The row's menu (S-4)

/// One item of a tab row's right-click menu.
struct TernTabMenuItem {
    var title: String
    var enabled = true
    var checked = false
    var children: [TernTabMenuItem] = []
    var isDivider = false
    var action: (@MainActor () -> Void)?

    static var divider: TernTabMenuItem { TernTabMenuItem(title: "", isDivider: true) }
}

/// A tab row's right-click menu, with Warp's items (WARP-PARITY gap 11): pin; copy the branch,
/// working directory and title; rename and reset the tab and its focused pane; move the tab up
/// and down; close it, the others, or the ones below; its color; move it to another window.
@MainActor
enum TernTabMenu {
    /// Copies go here (tests point it at a private pasteboard).
    static var pasteboard: NSPasteboard = .general

    static func items(for tab: TernTab, in controller: TerminalController, row: TernSidebarRowModel? = nil,
                      rename: (() -> Void)?) -> [TernTabMenuItem] {
        let row = row ?? TernSidebarRowModel(tab: tab, in: controller)
        let pane = row.focusedPane
        let paneName = pane.flatMap { TernState.shared.paneName($0.id) }
        var items: [TernTabMenuItem] = []

        items.append(.init(title: tab.pinned ? "Unpin Tab" : "Pin Tab") {
            let pin = !tab.pinned
            TernLayout.undoable(pin ? "Pin Tab" : "Unpin Tab", windows: [controller]) { controller.setPinned(tab, pin) }
            TernEvents.shared.emit(pin ? "tab.pinned" : "tab.unpinned", ["tab": tab.idString, "window": controller.ternIDString])
        })
        items.append(.divider)

        if let branch = row.git?.branch {
            items.append(.init(title: "Copy Branch") { copy(branch) })
        }
        if let cwd = row.cwd {
            items.append(.init(title: "Copy Working Directory") { copy(cwd) })
        }
        items.append(.init(title: "Copy Title") { copy(row.title) })
        items.append(.divider)

        items.append(.init(title: "Rename Tab…", enabled: rename != nil) { rename?() })
        if tab.name != nil {
            items.append(.init(title: "Reset Tab Name") { Self.rename(tab, in: controller, to: "") })
        }
        if let pane {
            items.append(.init(title: "Rename Pane…") { renamePane(pane, window: controller.window) })
            if paneName != nil {
                items.append(.init(title: "Reset Pane Name") { setPaneName(pane, "") })
            }
        }
        items.append(.init(title: "Move Tab Up", enabled: canMove(tab, by: -1, in: controller)) {
            move(tab, by: -1, in: controller)
        })
        items.append(.init(title: "Move Tab Down", enabled: canMove(tab, by: 1, in: controller)) {
            move(tab, by: 1, in: controller)
        })
        items.append(.divider)

        items.append(.init(title: "Close Tab") { controller.closeTab(tab, sender: nil) })
        items.append(.init(title: "Close Other Tabs", enabled: controller.tabs.count > 1) {
            controller.closeTabs(otherThan: tab)
        })
        let index = controller.index(of: tab) ?? 0
        items.append(.init(title: "Close Tabs Below", enabled: index < controller.tabs.count - 1) {
            controller.closeTabs(below: tab)
        })
        items.append(.divider)

        let colors = TerminalTabColor.allCases.map { color in
            TernTabMenuItem(title: color.localizedName, checked: tab.color == color) {
                tab.color = color
                TernEvents.shared.emit("tab.colored", ["tab": tab.idString, "color": TernTopology.colorName(color),
                                                       "window": controller.ternIDString])
                TernState.shared.layoutDidChange()
            }
        }
        items.append(.init(title: "Tab Color", children: colors))
        items.append(.divider)

        items.append(.init(title: "Move Tab to New Window") {
            _ = try? TernLayout.move(tab: tab, from: controller, toWindow: nil, index: nil, newWindow: true, focus: true)
        })
        let others = TernTopology.windows.filter { $0 !== controller }
        if !others.isEmpty {
            items.append(.init(title: "Move Tab to Window", children: others.map { window in
                TernTabMenuItem(title: "Window \(TernTopology.windowNumber(window)): \(window.selectedTab.title)") {
                    _ = try? TernLayout.move(tab: tab, from: controller, toWindow: window, index: nil,
                                             newWindow: false, focus: true)
                }
            }))
        }
        return items
    }

    // MARK: Actions

    static func copy(_ text: String) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    static func rename(_ tab: TernTab, in controller: TerminalController, to draft: String) {
        let name = draft.trimmingCharacters(in: .whitespaces)
        tab.name = name.isEmpty ? nil : name
        if tab === controller.selectedTab { controller.titleOverride = tab.name }
        TernEvents.shared.emit("tab.renamed", ["tab": tab.idString, "name": name, "window": controller.ternIDString])
        TernState.shared.layoutDidChange()
    }

    static func setPaneName(_ pane: Ghostty.SurfaceView, _ name: String) {
        TernState.shared.setPaneName(pane.id, name)
        TernEvents.shared.emit("pane.renamed", ["pane": pane.ternID, "name": name])
    }

    private static func renamePane(_ pane: Ghostty.SurfaceView, window: NSWindow?) {
        let alert = NSAlert()
        alert.messageText = "Rename Pane"
        alert.informativeText = "CLI commands can use the name as a selector."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = TernState.shared.paneName(pane.id) ?? ""
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        let handle: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .alertFirstButtonReturn else { return }
            setPaneName(pane, field.stringValue.trimmingCharacters(in: .whitespaces))
        }
        if let window { alert.beginSheetModal(for: window, completionHandler: handle) } else { handle(alert.runModal()) }
    }

    /// Moving a tab up or down stays within its group (pinned or not).
    /// (Overlaps UI-A's Move Tab Up/Down on ⌃⇧←/→; both use `TerminalController.moveTab`.)
    static func canMove(_ tab: TernTab, by delta: Int, in controller: TerminalController) -> Bool {
        guard let index = controller.index(of: tab) else { return false }
        let target = index + delta
        return controller.tabs.indices.contains(target) && controller.tabs[target].pinned == tab.pinned
    }

    static func move(_ tab: TernTab, by delta: Int, in controller: TerminalController) {
        guard canMove(tab, by: delta, in: controller), let index = controller.index(of: tab) else { return }
        TernLayout.undoable("Move Tab", windows: [controller]) { controller.moveTab(tab, to: index + delta) }
        TernEvents.shared.emit("tab.moved", ["tab": tab.idString, "from_window": controller.ternIDString,
                                             "window": controller.ternIDString])
    }

    // MARK: Finding items (debug.sidebar.menu)

    static func flatten(_ items: [TernTabMenuItem], path: [String] = []) -> [(path: [String], item: TernTabMenuItem)] {
        items.filter { !$0.isDivider }.flatMap { item in
            [(path + [item.title], item)] + flatten(item.children, path: path + [item.title])
        }
    }
}

/// The menu in SwiftUI.
struct TernTabMenuView: View {
    let items: [TernTabMenuItem]

    var body: some View {
        ForEach(Array(items.enumerated()), id: \.offset) { _, item in
            if item.isDivider {
                Divider()
            } else if !item.children.isEmpty {
                Menu(item.title) { TernTabMenuView(items: item.children) }
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
