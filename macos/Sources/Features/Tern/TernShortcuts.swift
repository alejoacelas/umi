import AppKit
import SwiftUI

/// Tern's menu items and their keyboard shortcuts (L-9), also listed in the command palette.
@MainActor
enum TernShortcuts {
    struct Item {
        let title: String
        let key: String
        let modifiers: NSEvent.ModifierFlags
        let symbol: String
        let menu: String
        let action: @MainActor () -> Void
        /// Whether the item applies right now.
        var enabled: @MainActor () -> Bool = { true }
    }

    static let leftArrow = String(UnicodeScalar(NSLeftArrowFunctionKey)!)
    static let rightArrow = String(UnicodeScalar(NSRightArrowFunctionKey)!)

    static var items: [Item] {
        [
            Item(title: "Open File…", key: "o", modifiers: [.command], symbol: "doc", menu: "File",
                 action: { TernEditor.openPanel() }),
            Item(title: "Save File", key: "s", modifiers: [.command], symbol: "square.and.arrow.down", menu: "File",
                 action: { TernEditor.currentDocument?.save() },
                 enabled: { TernEditor.currentDocument != nil }),
            Item(title: "Toggle Sidebar", key: "b", modifiers: [.command], symbol: "sidebar.left", menu: "View",
                 action: { TernState.shared.sidebarVisible.toggle() }),
            Item(title: "Show Project Explorer", key: "e", modifiers: [.command, .shift], symbol: "folder", menu: "View",
                 action: {
                     let state = TernState.shared
                     if state.sidebarVisible && state.sidebarMode == .files {
                         state.sidebarMode = .tabs
                     } else {
                         state.sidebarMode = .files
                         state.sidebarVisible = true
                     }
                 }),
            Item(title: "Toggle Markdown Preview", key: "m", modifiers: [.command, .shift], symbol: "doc.richtext", menu: "View",
                 action: { TernEditor.currentDocument?.toggleMode() },
                 enabled: { TernEditor.currentDocument?.isMarkdown ?? false }),
            Item(title: "Move Pane to New Tab", key: "t", modifiers: [.command, .control], symbol: "rectangle.badge.plus", menu: "Window",
                 action: { movePane(.newTab) }),
            Item(title: "Move Pane to New Window", key: "n", modifiers: [.command, .control], symbol: "macwindow.badge.plus", menu: "Window",
                 action: { movePane(.newWindow) }),
            Item(title: "Move Pane to Previous Tab", key: leftArrow, modifiers: [.command, .control], symbol: "arrow.left.square", menu: "Window",
                 action: { movePane(.adjacentTab(-1)) }),
            Item(title: "Move Pane to Next Tab", key: rightArrow, modifiers: [.command, .control], symbol: "arrow.right.square", menu: "Window",
                 action: { movePane(.adjacentTab(1)) }),
            Item(title: "Move Tab to New Window", key: "n", modifiers: [.command, .control, .shift], symbol: "macwindow.on.rectangle", menu: "Window",
                 action: { moveTabToNewWindow() }),
            Item(title: "Pin or Unpin Tab", key: "p", modifiers: [.command, .control], symbol: "pin", menu: "Window",
                 action: { togglePin() }),
            Item(title: "Rename Tab…", key: "r", modifiers: [.command, .control], symbol: "character.cursor.ibeam", menu: "Window",
                 action: { renameTab() }),
            Item(title: "Rename Pane…", key: "r", modifiers: [.command, .control, .shift], symbol: "pencil", menu: "Window",
                 action: { renamePane() }),
            Item(title: "Jump to Agent Needing Input", key: "j", modifiers: [.command, .control], symbol: "exclamationmark.bubble",
                 menu: "Window", action: { TernAgentUI.shared.jumpToAgentNeedingInput() }),
            Item(title: "Toggle Agent Pane's Terminal", key: "", modifiers: [], symbol: "terminal", menu: "Window",
                 action: {
                     guard let pane = TernTopology.currentPane, TernAgentUI.shared.session(forPane: pane.id) != nil else { return }
                     TernAgentUI.shared.toggleTerminal(pane)
                 },
                 enabled: { TernTopology.currentPane.map { TernAgentUI.shared.session(forPane: $0.id) != nil } ?? false }),
        ]
    }

    // MARK: Menu

    private static var handlers: [NSMenuItem: Item] = [:]

    static func install() {
        guard let mainMenu = NSApp.mainMenu else { return }
        for item in items {
            guard let menu = mainMenu.items.first(where: { $0.submenu?.title == item.menu })?.submenu
                    ?? mainMenu.items.first(where: { $0.title == item.menu })?.submenu else { continue }
            // Take the key equivalent away from any other item that has it.
            for existing in allItems(mainMenu) where existing.keyEquivalent.lowercased() == item.key.lowercased()
                && existing.keyEquivalentModifierMask == item.modifiers && handlers[existing] == nil {
                existing.keyEquivalent = ""
            }
            let menuItem = NSMenuItem(title: item.title, action: #selector(TernMenuTarget.performTernItem(_:)), keyEquivalent: item.key)
            menuItem.keyEquivalentModifierMask = item.modifiers
            menuItem.target = TernMenuTarget.shared
            if #available(macOS 26.0, *) {
                menuItem.image = NSImage(systemSymbolName: item.symbol, accessibilityDescription: nil)
            }
            if !menu.items.contains(where: { $0.representedObject as? String == "tern-separator" }) {
                let separator = NSMenuItem.separator()
                separator.representedObject = "tern-separator"
                menu.addItem(separator)
            }
            menu.addItem(menuItem)
            handlers[menuItem] = item
        }
        // Every session, shown in a pane or not, with its status (AP-3, AP-4).
        if let windowMenu = mainMenu.items.first(where: { $0.submenu?.title == "Window" })?.submenu
            ?? mainMenu.items.first(where: { $0.title == "Window" })?.submenu {
            TernAgentMenu.shared.install(in: windowMenu)
        }
    }

    private static func allItems(_ menu: NSMenu) -> [NSMenuItem] {
        menu.items.flatMap { [$0] + ($0.submenu.map(allItems) ?? []) }
    }

    fileprivate static func perform(_ menuItem: NSMenuItem) {
        handlers[menuItem]?.action()
    }

    fileprivate static func validate(_ menuItem: NSMenuItem) -> Bool {
        handlers[menuItem]?.enabled() ?? true
    }

    /// The same actions for the command palette.
    static func paletteOptions() -> [CommandOption] {
        let fixed = items.map { item in
            CommandOption(title: item.title, description: nil, symbols: symbols(item), leadingIcon: item.symbol) {
                item.action()
            }
        }
        // Every managed session can be shown (again) from the palette (AP-3, AP-4), the ones
        // that need the user first.
        let agents = TernAgentMenu.ordered().map { session in
            CommandOption(title: "Show Agent: \(session.name)",
                          description: "\(session.kind) · \(TernAgentMenu.describe(status: session.status, activity: session.activity))",
                          symbols: nil, leadingIcon: TernAgentMenu.symbol(for: session.status)) {
                _ = try? TernAgentUI.open(session.id, placement: .init(kind: .tab, focus: true), caller: TernCaller([:]))
            }
        }
        return fixed + agents
    }

    private static func symbols(_ item: Item) -> [String] {
        var out: [String] = []
        if item.modifiers.contains(.control) { out.append("⌃") }
        if item.modifiers.contains(.option) { out.append("⌥") }
        if item.modifiers.contains(.shift) { out.append("⇧") }
        if item.modifiers.contains(.command) { out.append("⌘") }
        switch item.key {
        case leftArrow: out.append("←")
        case rightArrow: out.append("→")
        default: out.append(item.key.uppercased())
        }
        return out
    }

    // MARK: Actions

    enum PaneTarget { case newTab, newWindow, adjacentTab(Int) }

    private static func movePane(_ target: PaneTarget) {
        guard let window = TernTopology.currentWindow, let pane = TernTopology.currentPane else { return }
        do {
            switch target {
            case .newTab:
                try TernLayout.move(pane, to: .newTab(window, index: nil), focus: true)
            case .newWindow:
                try TernLayout.move(pane, to: .newWindow, focus: true)
            case .adjacentTab(let delta):
                guard let index = window.index(of: window.selectedTab) else { return }
                let targetIndex = index + delta
                guard window.tabs.indices.contains(targetIndex) else { NSSound.beep(); return }
                let tab = window.tabs[targetIndex]
                guard let anchor = tab.effectiveFocusedSurface else { return }
                try TernLayout.move(pane, to: .besidePane(anchor, .right), focus: true)
            }
        } catch {
            NSSound.beep()
        }
    }

    private static func moveTabToNewWindow() {
        guard let window = TernTopology.currentWindow else { return }
        _ = try? TernLayout.move(tab: window.selectedTab, from: window, toWindow: nil, index: nil, newWindow: true, focus: true)
    }

    private static func togglePin() {
        guard let window = TernTopology.currentWindow else { return }
        let tab = window.selectedTab
        let pin = !tab.pinned
        TernLayout.undoable(pin ? "Pin Tab" : "Unpin Tab", windows: [window]) {
            window.setPinned(tab, pin)
        }
    }

    private static func renameTab() {
        guard let window = TernTopology.currentWindow else { return }
        let tab = window.selectedTab
        prompt(title: "Rename Tab", message: "Leave blank to name the tab after its folder.", value: tab.name ?? "",
               window: window.window) { name in
            tab.name = name.isEmpty ? nil : name
            window.titleOverride = tab.name
            TernEvents.shared.emit("tab.renamed", ["tab": tab.idString, "name": name, "window": window.ternIDString])
            TernState.shared.layoutDidChange()
        }
    }

    private static func renamePane() {
        guard let window = TernTopology.currentWindow, let pane = TernTopology.currentPane else { return }
        prompt(title: "Rename Pane", message: "CLI commands can use the name as a selector.",
               value: TernState.shared.paneName(pane.id) ?? "", window: window.window) { name in
            TernState.shared.setPaneName(pane.id, name)
            TernEvents.shared.emit("pane.renamed", ["pane": pane.ternID, "name": name])
        }
    }

    private static func prompt(title: String, message: String, value: String, window: NSWindow?, completion: @escaping (String) -> Void) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = value
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        let handle: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .alertFirstButtonReturn else { return }
            completion(field.stringValue.trimmingCharacters(in: .whitespaces))
        }
        if let window { alert.beginSheetModal(for: window, completionHandler: handle) } else { handle(alert.runModal()) }
    }
}

/// The target of Tern's menu items.
final class TernMenuTarget: NSObject, NSMenuItemValidation {
    static let shared = TernMenuTarget()

    /// Not `perform(_:)`: that's NSObject's `performSelector:`.
    @MainActor @objc func performTernItem(_ sender: NSMenuItem) {
        TernShortcuts.perform(sender)
    }

    @MainActor func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        TernShortcuts.validate(menuItem)
    }
}
