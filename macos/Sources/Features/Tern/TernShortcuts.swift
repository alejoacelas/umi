import AppKit
import SwiftUI

/// Tern's menu items and their keyboard shortcuts (L-9), also listed in the command palette.
///
/// Every item works whatever has keyboard focus (L-10): a terminal, the editor, the sidebar
/// (its rename field and file tree), an agent pane's view or the palette. Menu key
/// equivalents alone don't guarantee that (a view can take a key first, and AppKit doesn't
/// match some shifted keys), so a local key monitor dispatches the items' shortcuts before
/// any view sees them. Tern's defaults unbind Ghostty's own bindings for the same keys.
@MainActor
enum TernShortcuts {
    struct Item {
        /// Stable id, used by the shortcuts editor and `tern shortcuts`.
        let id: String
        let title: String
        /// The default shortcut (empty key: none).
        let key: String
        let modifiers: NSEvent.ModifierFlags
        let symbol: String
        let menu: String
        /// A submenu of `menu` to put the item in.
        var submenu: String?
        let action: @MainActor () -> Void
        /// Whether the item applies right now.
        var enabled: @MainActor () -> Bool = { true }

        var defaultShortcut: TernShortcut? {
            key.isEmpty ? nil : TernShortcut(key: key, modifiers: modifiers)
        }

        /// The shortcut in effect: the user's choice from the shortcuts editor, else the default.
        @MainActor var shortcut: TernShortcut? { TernShortcutStore.shared.shortcut(for: self) }
    }

    static let leftArrow = String(UnicodeScalar(NSLeftArrowFunctionKey)!)
    static let rightArrow = String(UnicodeScalar(NSRightArrowFunctionKey)!)
    static let tab = "\t"

    static var items: [Item] {
        [
            Item(id: "app.settings", title: "Settings…", key: ",", modifiers: [.command], symbol: "gearshape", menu: "App",
                 action: { TernSettingsWindow.show() }),
            Item(id: "file.open_quickly", title: "Open Quickly…", key: "o", modifiers: [.command], symbol: "doc.text.magnifyingglass",
                 menu: "File", action: { TernPaletteModel.present(.files) }),
            Item(id: "file.open", title: "Open File…", key: "", modifiers: [], symbol: "doc", menu: "File",
                 action: { TernEditor.openPanel() }),
            Item(id: "file.save", title: "Save File", key: "s", modifiers: [.command], symbol: "square.and.arrow.down", menu: "File",
                 action: { TernEditor.currentDocument?.save() },
                 enabled: { TernEditor.currentDocument != nil }),
            Item(id: "view.palette", title: "Command Palette…", key: "p", modifiers: [.command], symbol: "command", menu: "View",
                 action: { TernPaletteModel.present(.commands) }),
            Item(id: "view.sidebar", title: "Toggle Sidebar", key: "b", modifiers: [.command], symbol: "sidebar.left", menu: "View",
                 action: { TernState.shared.sidebarVisible.toggle() }),
            Item(id: "view.explorer", title: "Show Project Explorer", key: "e", modifiers: [.command, .shift], symbol: "folder",
                 menu: "View", action: {
                     let state = TernState.shared
                     if state.sidebarVisible && state.sidebarMode == .files {
                         state.sidebarMode = .tabs
                     } else {
                         state.sidebarMode = .files
                         state.sidebarVisible = true
                     }
                 }),
            Item(id: "view.markdown", title: "Toggle Markdown Preview", key: "m", modifiers: [.command, .shift], symbol: "doc.richtext",
                 menu: "View", action: { TernEditor.currentDocument?.toggleMode() },
                 enabled: { TernEditor.currentDocument?.isMarkdown ?? false }),

            // Moving between tabs and panes (L-11, L-15).
            Item(id: "pane.go_to", title: "Go to Pane…", key: "p", modifiers: [.command, .shift], symbol: "rectangle.on.rectangle",
                 menu: "Window", action: { TernPaletteModel.present(.panes) }),
            Item(id: "tab.back", title: "Back to Previous Tab", key: "[", modifiers: [.command, .shift], symbol: "arrow.uturn.backward",
                 menu: "Window", action: { if TernNavigation.tabBack() == nil { NSSound.beep() } },
                 enabled: { TernTabHistory.canGoBack }),
            Item(id: "tab.next", title: "Show Next Tab", key: "]", modifiers: [.command, .shift], symbol: "arrow.down.square",
                 menu: "Window", action: { TernNavigation.selectAdjacentTab(1) },
                 enabled: { (TernTopology.currentWindow?.tabs.count ?? 0) > 1 }),
            Item(id: "tab.cycle_next", title: "Cycle to Next Tab", key: tab, modifiers: [.control], symbol: "arrow.down.square",
                 menu: "Window", action: { TernNavigation.selectAdjacentTab(1) },
                 enabled: { (TernTopology.currentWindow?.tabs.count ?? 0) > 1 }),
            Item(id: "tab.cycle_previous", title: "Cycle to Previous Tab", key: tab, modifiers: [.control, .shift],
                 symbol: "arrow.up.square", menu: "Window", action: { TernNavigation.selectAdjacentTab(-1) },
                 enabled: { (TernTopology.currentWindow?.tabs.count ?? 0) > 1 }),
        ] + (1...8).map { n in
            Item(id: "tab.\(n)", title: "Tab \(n)", key: "\(n)", modifiers: [.command], symbol: "\(n).square", menu: "Window",
                 submenu: "Show Tab", action: { TernNavigation.selectTab(number: n) },
                 enabled: { (TernTopology.currentWindow?.tabs.count ?? 0) >= n })
        } + [
            Item(id: "tab.last", title: "Last Tab", key: "9", modifiers: [.command], symbol: "9.square", menu: "Window",
                 submenu: "Show Tab", action: { TernNavigation.selectLastTab() }),
            Item(id: "tab.move_up", title: "Move Tab Up", key: leftArrow, modifiers: [.control, .shift], symbol: "arrow.up",
                 menu: "Window", action: { moveSelectedTab(-1) }, enabled: { canMoveSelectedTab(-1) }),
            Item(id: "tab.move_down", title: "Move Tab Down", key: rightArrow, modifiers: [.control, .shift], symbol: "arrow.down",
                 menu: "Window", action: { moveSelectedTab(1) }, enabled: { canMoveSelectedTab(1) }),

            // Moving panes and tabs, pins and names.
            Item(id: "pane.move_new_tab", title: "Move Pane to New Tab", key: "t", modifiers: [.command, .control],
                 symbol: "rectangle.badge.plus", menu: "Window", action: { movePane(.newTab) }),
            Item(id: "pane.move_new_window", title: "Move Pane to New Window", key: "n", modifiers: [.command, .control],
                 symbol: "macwindow.badge.plus", menu: "Window", action: { movePane(.newWindow) }),
            Item(id: "pane.move_previous_tab", title: "Move Pane to Previous Tab", key: leftArrow, modifiers: [.command, .control],
                 symbol: "arrow.left.square", menu: "Window", action: { movePane(.adjacentTab(-1)) }),
            Item(id: "pane.move_next_tab", title: "Move Pane to Next Tab", key: rightArrow, modifiers: [.command, .control],
                 symbol: "arrow.right.square", menu: "Window", action: { movePane(.adjacentTab(1)) }),
            Item(id: "tab.move_new_window", title: "Move Tab to New Window", key: "n", modifiers: [.command, .control, .shift],
                 symbol: "macwindow.on.rectangle", menu: "Window", action: { moveTabToNewWindow() }),
            Item(id: "tab.pin", title: "Pin or Unpin Tab", key: "p", modifiers: [.command, .control], symbol: "pin", menu: "Window",
                 action: { togglePin() }),
            Item(id: "tab.rename", title: "Rename Tab…", key: "r", modifiers: [.command, .control], symbol: "character.cursor.ibeam",
                 menu: "Window", action: { renameTab() }),
            Item(id: "pane.rename", title: "Rename Pane…", key: "r", modifiers: [.command, .control, .shift], symbol: "pencil",
                 menu: "Window", action: { renamePane() }),

            // Sessions that need the user (L-12).
            Item(id: "session.next_needing_you", title: "Jump to Next Session Needing You", key: "j", modifiers: [.command, .control],
                 symbol: "exclamationmark.bubble", menu: "Window",
                 action: { if TernNavigation.jumpToNextNeedingYou() == nil { NSSound.beep() } }),
            Item(id: "session.jump_back", title: "Jump Back", key: "k", modifiers: [.command, .control],
                 symbol: "arrow.uturn.backward.circle", menu: "Window",
                 action: { if TernNavigation.jumpBack() == nil { NSSound.beep() } },
                 enabled: { TernNavigation.canJumpBack }),
            // A session in the focused pane (AG-6, AG-8).
            Item(id: "session.take_over", title: "Take Over Session", key: "o", modifiers: [.command, .control],
                 symbol: "arrow.down.right.and.arrow.up.left", menu: "Window",
                 action: { if !TernAgentUI.takeOverFocused() { NSSound.beep() } },
                 enabled: { TernAgentUI.focusedSessionPane(live: false) != nil }),
            Item(id: "session.remove_from_pane", title: "Remove Session from Pane", key: "w", modifiers: [.command, .control],
                 symbol: "rectangle.badge.minus", menu: "Window",
                 action: { if !TernAgentUI.removeFocusedFromPane() { NSSound.beep() } },
                 enabled: { TernAgentUI.focusedSessionPane(live: nil) != nil }),
            Item(id: "pane.toggle_agent_terminal", title: "Toggle Session View and Shell", key: "", modifiers: [], symbol: "terminal",
                 menu: "Window",
                 action: {
                     guard let pane = TernTopology.currentPane, TernAgentUI.shared.session(forPane: pane.id) != nil else { return }
                     TernAgentUI.shared.toggleTerminal(pane)
                 },
                 enabled: { TernTopology.currentPane.map { TernAgentUI.shared.session(forPane: $0.id) != nil } ?? false }),
        ]
    }

    static func item(id: String) -> Item? { items.first { $0.id == id } }

    // MARK: Menu

    private static var handlers: [NSMenuItem: Item] = [:]
    private static var menuItems: [String: NSMenuItem] = [:]
    private static var monitor: Any?

    static func install() {
        guard let mainMenu = NSApp.mainMenu else { return }
        for item in items {
            guard let menu = topMenu(item.menu, in: mainMenu) else { continue }
            let menuItem = NSMenuItem(title: item.title, action: #selector(TernMenuTarget.performTernItem(_:)), keyEquivalent: "")
            menuItem.target = TernMenuTarget.shared
            if #available(macOS 26.0, *) {
                menuItem.image = NSImage(systemSymbolName: item.symbol, accessibilityDescription: nil)
            }
            let container = item.submenu.map { submenu(named: $0, in: menu) } ?? menu
            if item.menu == "App" {
                // Before Ghostty's own config item, which no longer takes ⌘, (Tern's defaults).
                let index = menu.items.firstIndex { $0.action == #selector(AppDelegate.openConfig(_:)) }
                if let index {
                    menu.items[index].title = "Open Ghostty Config File"
                    menu.insertItem(menuItem, at: index)
                } else {
                    menu.addItem(menuItem)
                }
            } else {
                if container === menu { addSeparatorOnce(to: menu) }
                container.addItem(menuItem)
            }
            handlers[menuItem] = item
            menuItems[item.id] = menuItem
        }
        applyShortcuts()
        // Ghostty's own palette item is Tern's Command Palette… now.
        for existing in allItems(mainMenu) where existing.action == #selector(BaseTerminalController.toggleCommandPalette(_:)) {
            existing.isHidden = true
        }
        // Every session, shown in a pane or not, with its status (AP-3, AP-4).
        if let windowMenu = topMenu("Window", in: mainMenu) {
            TernAgentMenu.shared.install(in: windowMenu)
        }
        installMonitor()
        TernTabOrder.start()
        TernGhosttyBindings.warm()
        // Ghostty re-syncs its own menu items' shortcuts when its config reloads; Tern's
        // shortcuts keep their keys.
        NotificationCenter.default.addObserver(forName: .ghosttyConfigDidChange, object: nil, queue: .main) { note in
            guard note.object == nil else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { applyShortcuts() } }
        }
    }

    /// Give each item its shortcut in effect, and take that key away from any other menu item.
    static func applyShortcuts() {
        guard let mainMenu = NSApp.mainMenu else { return }
        let all = allItems(mainMenu)
        for (menuItem, item) in handlers {
            let shortcut = item.shortcut
            menuItem.keyEquivalent = shortcut?.keyEquivalent ?? ""
            menuItem.keyEquivalentModifierMask = shortcut?.modifiers ?? []
            guard let shortcut else { continue }
            for existing in all where handlers[existing] == nil && TernShortcut(menuItem: existing) == shortcut {
                existing.keyEquivalent = ""
            }
        }
    }

    private static func topMenu(_ name: String, in mainMenu: NSMenu) -> NSMenu? {
        if name == "App" { return mainMenu.items.first?.submenu }
        return mainMenu.items.first(where: { $0.submenu?.title == name })?.submenu
            ?? mainMenu.items.first(where: { $0.title == name })?.submenu
    }

    private static func addSeparatorOnce(to menu: NSMenu) {
        guard !menu.items.contains(where: { $0.representedObject as? String == "tern-separator" }) else { return }
        let separator = NSMenuItem.separator()
        separator.representedObject = "tern-separator"
        menu.addItem(separator)
    }

    private static func submenu(named title: String, in menu: NSMenu) -> NSMenu {
        if let existing = menu.items.first(where: { $0.title == title && $0.representedObject as? String == "tern-submenu" })?.submenu {
            return existing
        }
        addSeparatorOnce(to: menu)
        let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        parent.representedObject = "tern-submenu"
        let submenu = NSMenu(title: title)
        parent.submenu = submenu
        menu.addItem(parent)
        return submenu
    }

    static func allItems(_ menu: NSMenu) -> [NSMenuItem] {
        menu.items.flatMap { [$0] + ($0.submenu.map(allItems) ?? []) }
    }

    fileprivate static func perform(_ menuItem: NSMenuItem) {
        handlers[menuItem]?.action()
    }

    fileprivate static func validate(_ menuItem: NSMenuItem) -> Bool {
        handlers[menuItem]?.enabled() ?? true
    }

    // MARK: Keys, whatever has focus

    /// While the shortcuts editor records a shortcut, keys go to it.
    static var suspended = false

    static var monitorInstalled: Bool { monitor != nil }

    private static func installMonitor() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            MainActor.assumeIsolated { dispatch(event) ? nil : event }
        }
    }

    /// Perform the Tern item whose shortcut this key is. True when the key was Tern's. Every
    /// key press goes through here before any view sees it.
    static func dispatch(_ event: NSEvent) -> Bool {
        guard !suspended, let pressed = TernShortcut(event: event) else { return false }
        // Only shortcuts with ⌘ or ⌃, or function keys: plain keys and ⌥-keys are typing.
        guard !pressed.modifiers.isDisjoint(with: [.command, .control]) || pressed.isFunctionKey else { return false }
        // A modal panel or alert keeps its keys.
        if NSApp.modalWindow != nil { return false }
        if let sheetParent = NSApp.keyWindow, sheetParent.attachedSheet != nil { return false }
        guard let (menuItem, item) = handlers.first(where: { $0.value.shortcut == pressed }) else { return false }
        guard item.enabled() else {
            NSSound.beep()
            return true
        }
        // Through the menu, so its title flashes as for any key equivalent. The menu's own
        // idea of what's enabled may be stale (it's refreshed when menus open).
        if let menu = menuItem.menu, case let index = menu.index(of: menuItem), index >= 0 {
            menu.update()
            if menuItem.isEnabled {
                menu.performActionForItem(at: index)
                return true
            }
        }
        item.action()
        return true
    }

    /// The same actions for the command palette.
    static func paletteOptions() -> [CommandOption] {
        let fixed = items.map { item in
            CommandOption(title: item.title, description: nil, symbols: item.shortcut?.symbols, leadingIcon: item.symbol) {
                guard item.enabled() else { NSSound.beep(); return }
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

    private static func moveSelectedTab(_ delta: Int) {
        guard let window = TernTopology.currentWindow else { return }
        if !TernNavigation.moveTab(window.selectedTab, by: delta, in: window) { NSSound.beep() }
    }

    private static func canMoveSelectedTab(_ delta: Int) -> Bool {
        guard let window = TernTopology.currentWindow else { return false }
        return TernNavigation.canMoveTab(window.selectedTab, by: delta, in: window)
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
