import AppKit
import SwiftUI

/// Umi's menu items and their keyboard shortcuts (L-9), also listed in the command palette.
///
/// Every item works whatever has keyboard focus (L-10): a terminal, the editor, the sidebar
/// (its rename field and file tree), an agent pane's view or the palette. Menu key
/// equivalents alone don't guarantee that (a view can take a key first, and AppKit doesn't
/// match some shifted keys), so a local key monitor dispatches the items' shortcuts before
/// any view sees them. Umi's defaults unbind Ghostty's own bindings for the same keys.
@MainActor
enum UmiShortcuts {
    struct Item {
        /// Stable id, used by `umi shortcuts`.
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
        /// When the item doesn't apply, its key goes on to whatever has focus (a terminal gets
        /// ⌃G) instead of beeping. Several items may share a key; the enabled one runs, and the
        /// key passes on only when every one of them is disabled and passes through.
        var passesThrough = false

        var defaultShortcut: UmiShortcut? {
            key.isEmpty ? nil : UmiShortcut(key: key, modifiers: modifiers)
        }

        /// The shortcut in effect: the user's choice from `umi shortcuts`, else the default.
        @MainActor var shortcut: UmiShortcut? { UmiShortcutStore.shared.shortcut(for: self) }
    }

    static let leftArrow = String(UnicodeScalar(NSLeftArrowFunctionKey)!)
    static let rightArrow = String(UnicodeScalar(NSRightArrowFunctionKey)!)
    static let tab = "\t"

    static var items: [Item] {
        [
            Item(id: "app.settings", title: "Settings…", key: ",", modifiers: [.command], symbol: "gearshape", menu: "App",
                 action: { UmiSettings.openConfigFile() }),
            Item(id: "file.open_quickly", title: "Open Quickly…", key: "o", modifiers: [.command], symbol: "doc.text.magnifyingglass",
                 menu: "File", action: { UmiPaletteModel.present(.files) }),
            Item(id: "file.open", title: "Open File…", key: "", modifiers: [], symbol: "doc", menu: "File",
                 action: { UmiEditor.openPanel() }),
            Item(id: "file.save", title: "Save File", key: "s", modifiers: [.command], symbol: "square.and.arrow.down", menu: "File",
                 action: { UmiEditor.currentDocument.map { UmiEditor.saveFromUser($0) } },
                 enabled: { UmiEditor.currentDocument != nil }),
            // The file editor (E-22, E-23), Warp's keys.
            Item(id: "file.save_as", title: "Save As…", key: "s", modifiers: [.command, .shift],
                 symbol: "square.and.arrow.down.on.square", menu: "File",
                 action: { UmiEditor.currentDocument.map { UmiEditor.saveAs($0) } },
                 enabled: { UmiEditor.currentDocument != nil }, passesThrough: true),
            Item(id: "edit.go_to_line", title: "Go to Line…", key: "g", modifiers: [.control], symbol: "arrow.right.to.line",
                 menu: "Edit", action: { UmiEditor.currentCode?.openGoToLine() },
                 enabled: { UmiEditor.currentCode != nil }, passesThrough: true),
            Item(id: "edit.toggle_comment", title: "Toggle Comment", key: "/", modifiers: [.command], symbol: "number",
                 menu: "Edit", action: { UmiEditor.currentCode?.toggleComment() },
                 enabled: { UmiEditor.currentCode?.language?.commentPrefix != nil }, passesThrough: true),
            // In a file pane, find acts on the file (Ghostty's Find items have no keys of their own); a
            // preview switches to its source first.
            Item(id: "edit.find", title: "Find in File…", key: "f", modifiers: [.command], symbol: "magnifyingglass",
                 menu: "Edit", action: { UmiEditor.find(previewAction: #selector(UmiPreviewWebView.find(_:)), inSource: { $0.openFind() }) },
                 enabled: { UmiEditor.currentDocument != nil }, passesThrough: true),
            Item(id: "edit.find_next", title: "Find Next in File", key: "g", modifiers: [.command], symbol: "chevron.down",
                 menu: "Edit", action: { UmiEditor.find(previewAction: #selector(UmiPreviewWebView.findNext(_:)), inSource: { $0.findStep(1) }) },
                 enabled: { UmiEditor.currentDocument != nil }, passesThrough: true),
            Item(id: "edit.find_previous", title: "Find Previous in File", key: "g", modifiers: [.command, .shift],
                 symbol: "chevron.up", menu: "Edit", action: { UmiEditor.find(previewAction: #selector(UmiPreviewWebView.findPrevious(_:)), inSource: { $0.findStep(-1) }) },
                 enabled: { UmiEditor.currentDocument != nil }, passesThrough: true),
            Item(id: "edit.find_replace", title: "Find and Replace…", key: "f", modifiers: [.command, .option],
                 symbol: "text.magnifyingglass", menu: "Edit", action: { UmiEditor.inSource { $0.openFind(replace: true) } },
                 enabled: { UmiEditor.currentDocument != nil }, passesThrough: true),
            // L-20. Its title names what it would reopen (see `validate`).
            Item(id: "file.reopen", title: UmiReopen.anyTitle, key: "t", modifiers: [.command, .shift],
                 symbol: "arrow.uturn.backward", menu: "File",
                 action: { if (try? UmiReopen.shared.reopen()) == nil { NSSound.beep() } },
                 enabled: { UmiReopen.shared.next != nil }),
            Item(id: "view.palette", title: "Command Palette…", key: "p", modifiers: [.command], symbol: "command", menu: "View",
                 action: { UmiPaletteModel.present(.commands) }),
            Item(id: "view.sidebar", title: "Toggle Sidebar", key: "b", modifiers: [.command], symbol: "sidebar.left", menu: "View",
                 action: { UmiSidebarVisibility.toggle() }),
            // Warp's key for its left panel, a second key for the same toggle.
            Item(id: "view.sidebar_left_panel", title: "Toggle Left Panel", key: "\\", modifiers: [.command],
                 symbol: "sidebar.left", menu: "View", action: { UmiSidebarVisibility.toggle() }),
            // Warp's "Search tabs..." field at the top of the sidebar.
            Item(id: "view.search_tabs", title: "Search Tabs", key: "f", modifiers: [.command, .option],
                 symbol: "magnifyingglass", menu: "View", action: { UmiSidebarSearch.focusField() }),
            Item(id: "view.explorer", title: "Show Project Explorer", key: "e", modifiers: [.command, .shift], symbol: "folder",
                 menu: "View", action: { UmiSidebarKeys.toggleExplorer() }),
            // Warp's keys for its left panel, the explorer's hidden files and global search.
            Item(id: "view.explorer_panel", title: "Left Panel: Project Explorer", key: "1", modifiers: [.control],
                 symbol: "folder", menu: "View", action: { UmiSidebarKeys.toggleExplorer() }),
            Item(id: "view.hidden_files", title: "Toggle Hidden Files in Project Explorer", key: ".", modifiers: [.command, .shift],
                 symbol: "eye", menu: "View", action: { UmiState.shared.showHiddenFiles.toggle() }),
            Item(id: "view.global_search", title: "Global Search", key: "f", modifiers: [.command, .shift],
                 symbol: "magnifyingglass", menu: "View", action: { UmiSidebarKeys.openSearch() }),
            Item(id: "view.search_panel", title: "Left Panel: Global Search", key: "3", modifiers: [.control],
                 symbol: "magnifyingglass", menu: "View", action: { UmiSidebarKeys.toggleSearch() }),
            // E-11: like Google Docs' ⌥⌘M.
            Item(id: "edit.comment", title: "Add Comment", key: "m", modifiers: [.command, .option], symbol: "text.bubble",
                 menu: "Edit", action: { UmiEditor.currentDocument?.commentTarget?.startComment() },
                 enabled: { UmiEditor.currentDocument.map { $0.isMarkdown && $0.commentTarget != nil } ?? false }),
            Item(id: "view.markdown", title: "Toggle Markdown Preview", key: "m", modifiers: [.command, .shift], symbol: "doc.richtext",
                 menu: "View", action: { UmiEditor.currentDocument?.toggleMode() },
                 enabled: { UmiEditor.currentDocument?.hasPreview ?? false }),

            // Moving between tabs and panes (L-11, L-15).
            Item(id: "pane.go_to", title: "Go to Pane…", key: "p", modifiers: [.command, .shift], symbol: "rectangle.on.rectangle",
                 menu: "Window", action: { UmiPaletteModel.present(.panes) }),
            // A stack's members (M-7); outside a stack, the previous or next pane.
            Item(id: "pane.stack_previous", title: "Previous in Stack", key: "[", modifiers: [.command],
                 symbol: "chevron.left.square", menu: "Window", action: { UmiStacks.cycle(-1) }),
            Item(id: "pane.stack_next", title: "Next in Stack", key: "]", modifiers: [.command],
                 symbol: "chevron.right.square", menu: "Window", action: { UmiStacks.cycle(1) }),
            Item(id: "tab.back", title: "Back to Previous Tab", key: "[", modifiers: [.command, .shift], symbol: "arrow.uturn.backward",
                 menu: "Window", action: {
                     // While the sidebar has a search query: the previous matching tab, as Warp.
                     if let searched = UmiSidebarSearch.cycleMatches(-1) { if searched == nil { NSSound.beep() }; return }
                     if UmiNavigation.tabBack() == nil { NSSound.beep() }
                 },
                 enabled: { UmiTabHistory.canGoBack || UmiTopology.currentWindow.map(UmiSidebarSearch.filtersCycling) == true }),
            Item(id: "tab.next", title: "Show Next Tab", key: "]", modifiers: [.command, .shift], symbol: "arrow.down.square",
                 menu: "Window", action: { adjacentTab(1) },
                 enabled: { (UmiTopology.currentWindow?.tabs.count ?? 0) > 1 }),
            Item(id: "tab.cycle_next", title: "Cycle to Next Tab", key: tab, modifiers: [.control], symbol: "arrow.down.square",
                 menu: "Window", action: { adjacentTab(1) },
                 enabled: { (UmiTopology.currentWindow?.tabs.count ?? 0) > 1 }),
            Item(id: "tab.cycle_previous", title: "Cycle to Previous Tab", key: tab, modifiers: [.control, .shift],
                 symbol: "arrow.up.square", menu: "Window", action: { adjacentTab(-1) },
                 enabled: { (UmiTopology.currentWindow?.tabs.count ?? 0) > 1 }),
        ] + (1...8).map { n in
            Item(id: "tab.\(n)", title: "Tab \(n)", key: "\(n)", modifiers: [.command], symbol: "\(n).square", menu: "Window",
                 submenu: "Show Tab", action: { UmiNavigation.selectTab(number: n) },
                 enabled: { (UmiTopology.currentWindow?.tabs.count ?? 0) >= n })
        } + [
            Item(id: "tab.last", title: "Last Tab", key: "9", modifiers: [.command], symbol: "9.square", menu: "Window",
                 submenu: "Show Tab", action: { UmiNavigation.selectLastTab() }),
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

            // Tab groups (Warp's "New group with tab"), from the keyboard through the palette.
            Item(id: "tab.group_new", title: "New Group with Tab", key: "", modifiers: [], symbol: "rectangle.stack.badge.plus",
                 menu: "Window", action: {
                     guard let window = UmiTopology.currentWindow else { return }
                     UmiTabGroups.newGroup(with: window.selectedTab, in: window)
                 }),
            Item(id: "tab.group_toggle", title: "Collapse or Expand Tab Group", key: "", modifiers: [],
                 symbol: "chevron.up.chevron.down", menu: "Window", action: {
                     guard let (window, group) = UmiTabGroups.currentGroup() else { NSSound.beep(); return }
                     UmiTabGroups.setCollapsed(group, !group.collapsed, in: window)
                 }, enabled: { UmiTabGroups.currentGroup() != nil }),
            Item(id: "tab.group_rename", title: "Rename Tab Group", key: "", modifiers: [], symbol: "pencil",
                 menu: "Window", action: {
                     guard let (window, group) = UmiTabGroups.currentGroup() else { NSSound.beep(); return }
                     UmiTabMenu.beginRename(.group(group.id), in: window)
                 }, enabled: { UmiTabGroups.currentGroup() != nil }),
            Item(id: "tab.group_remove", title: "Remove Tab from Group", key: "", modifiers: [], symbol: "rectangle.badge.minus",
                 menu: "Window", action: {
                     guard let (window, _) = UmiTabGroups.currentGroup() else { NSSound.beep(); return }
                     UmiTabGroups.remove(window.selectedTab, in: window)
                 }, enabled: { UmiTabGroups.currentGroup() != nil }),
            Item(id: "tab.group_new_tab", title: "New Tab in Group", key: "", modifiers: [], symbol: "plus.rectangle.on.rectangle",
                 menu: "Window", action: {
                     guard let (window, group) = UmiTabGroups.currentGroup() else { NSSound.beep(); return }
                     UmiTabGroups.newTab(in: group, in: window)
                 }, enabled: { UmiTabGroups.currentGroup() != nil }),
            Item(id: "tab.group_ungroup", title: "Ungroup Tabs", key: "", modifiers: [], symbol: "rectangle.stack",
                 menu: "Window", action: {
                     guard let (window, group) = UmiTabGroups.currentGroup() else { NSSound.beep(); return }
                     UmiTabGroups.ungroup(group, in: window)
                 }, enabled: { UmiTabGroups.currentGroup() != nil }),

            // Sessions that need the user (L-12).
            Item(id: "session.next_needing_you", title: "Jump to Next Session Needing You", key: "j", modifiers: [.command, .control],
                 symbol: "exclamationmark.bubble", menu: "Window",
                 action: { if UmiNavigation.jumpToNextNeedingYou() == nil { NSSound.beep() } }),
            Item(id: "session.jump_back", title: "Jump Back", key: "k", modifiers: [.command, .control],
                 symbol: "arrow.uturn.backward.circle", menu: "Window",
                 action: { if UmiNavigation.jumpBack() == nil { NSSound.beep() } },
                 enabled: { UmiNavigation.canJumpBack }),
            // A session in the focused pane (AG-6, AG-8).
            Item(id: "session.take_over", title: "Take Over Session", key: "o", modifiers: [.command, .control],
                 symbol: "arrow.down.right.and.arrow.up.left", menu: "Window",
                 action: { if !UmiAgentUI.takeOverFocused() { NSSound.beep() } },
                 enabled: { UmiAgentUI.focusedSessionPane(live: false) != nil }),
            Item(id: "session.remove_from_pane", title: "Remove Session from Pane", key: "w", modifiers: [.command, .control],
                 symbol: "rectangle.badge.minus", menu: "Window",
                 action: { if !UmiAgentUI.removeFocusedFromPane() { NSSound.beep() } },
                 enabled: { UmiAgentUI.focusedSessionPane(live: nil) != nil }),
            Item(id: "pane.toggle_agent_terminal", title: "Toggle Session View and Shell", key: "", modifiers: [], symbol: "terminal",
                 menu: "Window",
                 action: {
                     guard let pane = UmiTopology.currentPane, UmiAgentUI.shared.session(forPane: pane.id) != nil else { return }
                     UmiAgentUI.shared.toggleTerminal(pane)
                 },
                 enabled: { UmiTopology.currentPane.map { UmiAgentUI.shared.session(forPane: $0.id) != nil } ?? false }),
            // Warp's keybindings page (⌘/); in the editor's source the key is the editor's.
            Item(id: "help.shortcuts", title: "Keyboard Shortcuts", key: "/", modifiers: [.command], symbol: "keyboard",
                 menu: "Help", action: { UmiShortcutsPageModel.toggle() },
                 enabled: { !UmiShortcutsPageModel.editorSourceHasFocus }, passesThrough: true),
        ] + inputSyncItems + zoomItems
    }

    /// The interface's zoom and the terminals' font size, as Warp's (L-33).
    private static var zoomItems: [Item] {
        [
            Item(id: "view.zoom_in", title: "Zoom In", key: "=", modifiers: [.command], symbol: "plus.magnifyingglass",
                 menu: "View", action: { if !UmiZoom.shared.step(1) { NSSound.beep() } }),
            Item(id: "view.zoom_out", title: "Zoom Out", key: "-", modifiers: [.command], symbol: "minus.magnifyingglass",
                 menu: "View", action: { if !UmiZoom.shared.step(-1) { NSSound.beep() } }),
            Item(id: "view.zoom_reset", title: "Actual Size", key: "0", modifiers: [.command], symbol: "1.magnifyingglass",
                 menu: "View", action: { UmiZoom.shared.reset() }),
            Item(id: "view.font_bigger", title: "Increase Font Size", key: ".", modifiers: [.option, .shift],
                 symbol: "textformat.size.larger", menu: "View",
                 action: { if !UmiZoom.shared.stepFontSize(1) { NSSound.beep() } }),
            Item(id: "view.font_smaller", title: "Decrease Font Size", key: ",", modifiers: [.option, .shift],
                 symbol: "textformat.size.smaller", menu: "View",
                 action: { if !UmiZoom.shared.stepFontSize(-1) { NSSound.beep() } }),
            Item(id: "view.font_reset", title: "Reset Font Size", key: "", modifiers: [], symbol: "textformat.size",
                 menu: "View", action: { UmiZoom.shared.resetFontSize() }),
        ]
    }

    /// Synchronized input, as Warp's (L-32).
    private static var inputSyncItems: [Item] {
        [
            Item(id: "input.sync_tab", title: "Toggle Synchronizing All Panes in Current Tab", key: "i", modifiers: [.command, .option],
                 symbol: "link", menu: "Window", submenu: "Synchronize Input",
                 action: {
                     guard let window = UmiTopology.currentWindow else { return }
                     UmiInputSync.shared.toggleTab(window.selectedTab, in: window)
                 }),
            Item(id: "input.sync_all", title: "Toggle Synchronizing All Panes in All Tabs", key: "", modifiers: [],
                 symbol: "link.circle", menu: "Window", submenu: "Synchronize Input",
                 action: {
                     guard let window = UmiTopology.currentWindow else { return }
                     UmiInputSync.shared.toggleAll(in: window)
                 }),
            Item(id: "input.sync_stop", title: "Stop Synchronizing Any Panes", key: "i", modifiers: [.command, .option, .shift],
                 symbol: "personalhotspot.slash", menu: "Window", submenu: "Synchronize Input",
                 action: {
                     guard let window = UmiTopology.currentWindow else { return }
                     UmiInputSync.shared.stop(in: window)
                 },
                 enabled: { UmiTopology.currentWindow.map { UmiInputSync.shared.isSyncingAny($0) } ?? false }),
        ]
    }

    static func item(id: String) -> Item? { items.first { $0.id == id } }

    // MARK: Menu

    private static var handlers: [NSMenuItem: Item] = [:]
    private static var menuItems: [String: NSMenuItem] = [:]
    /// Each shortcut in effect and its menu items, for the key monitor. Items can share a key
    /// when at most one of them is enabled at a time (focus decides).
    private static var byShortcut: [UmiShortcut: [NSMenuItem]] = [:]
    private static var monitor: Any?

    static func install() {
        guard let mainMenu = NSApp.mainMenu else { return }
        for item in items {
            guard let menu = topMenu(item.menu, in: mainMenu) else { continue }
            let menuItem = NSMenuItem(title: item.title, action: #selector(UmiMenuTarget.performUmiItem(_:)), keyEquivalent: "")
            menuItem.target = UmiMenuTarget.shared
            if #available(macOS 26.0, *) {
                menuItem.image = NSImage(systemSymbolName: item.symbol, accessibilityDescription: nil)
            }
            let container = item.submenu.map { submenu(named: $0, in: menu) } ?? menu
            if item.menu == "App" {
                // Before Ghostty's own config item, which no longer takes ⌘, (Umi's defaults).
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
        // Ghostty's own palette item is Umi's Command Palette… now.
        for existing in allItems(mainMenu) where existing.action == #selector(BaseTerminalController.toggleCommandPalette(_:)) {
            existing.isHidden = true
        }
        // Its font size items go: Umi's (same titles) set the size for every pane, with the zoom (L-33).
        let fontActions = ["increaseFontSize:", "decreaseFontSize:", "resetFontSize:"].map(NSSelectorFromString)
        for existing in allItems(mainMenu) where handlers[existing] == nil && existing.action.map(fontActions.contains) == true {
            existing.menu?.removeItem(existing)
        }
        // Every session, shown in a pane or not, with its status (AP-3, AP-4).
        if let windowMenu = topMenu("Window", in: mainMenu) {
            UmiAgentMenu.shared.install(in: windowMenu)
            UmiTabGroupMenu.shared.install(in: windowMenu)
        }
        installMonitor()
        UmiTabHints.shared.install()
        UmiGhosttyBindings.warm()
        // The CLI's commands for the palette, so the first ⌘P has them.
        UmiCLICatalog.shared.load {}
        // Ghostty re-syncs its own menu items' shortcuts when its config reloads; Umi's
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
        byShortcut = [:]
        for (menuItem, item) in handlers {
            let shortcut = item.shortcut
            menuItem.keyEquivalent = shortcut?.keyEquivalent ?? ""
            menuItem.keyEquivalentModifierMask = shortcut?.modifiers ?? []
            guard let shortcut else { continue }
            byShortcut[shortcut, default: []].append(menuItem)
            for existing in all where handlers[existing] == nil && UmiShortcut(menuItem: existing) == shortcut {
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
        guard !menu.items.contains(where: { $0.representedObject as? String == "umi-separator" }) else { return }
        let separator = NSMenuItem.separator()
        separator.representedObject = "umi-separator"
        menu.addItem(separator)
    }

    private static func submenu(named title: String, in menu: NSMenu) -> NSMenu {
        if let existing = menu.items.first(where: { $0.title == title && $0.representedObject as? String == "umi-submenu" })?.submenu {
            return existing
        }
        addSeparatorOnce(to: menu)
        let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        parent.representedObject = "umi-submenu"
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
        if handlers[menuItem]?.id == "file.reopen" { menuItem.title = UmiReopen.shared.menuTitle }
        return handlers[menuItem]?.enabled() ?? true
    }

    // MARK: Keys, whatever has focus

    static var monitorInstalled: Bool { monitor != nil }

    private static func installMonitor() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            MainActor.assumeIsolated { dispatch(event) ? nil : event }
        }
    }

    /// Perform the Umi item whose shortcut this key is. True when the key was Umi's. Every
    /// key press goes through here before any view sees it.
    static func dispatch(_ event: NSEvent) -> Bool {
        // Only shortcuts with ⌘ or ⌃, or function keys: plain keys and ⌥-keys are typing,
        // except ⌥⇧ keys an item has (⌥⇧> and ⌥⇧<, Warp's font size keys).
        let isFunctionKey = event.specialKey.map { (NSF1FunctionKey...NSF35FunctionKey).contains($0.rawValue) } ?? false
        let isOptionShift = event.modifierFlags.contains([.option, .shift])
        guard !event.modifierFlags.isDisjoint(with: [.command, .control]) || isFunctionKey || isOptionShift else { return false }
        guard let pressed = UmiShortcut(event: event), let candidates = byShortcut[pressed], !candidates.isEmpty else {
            return false
        }
        // A modal panel or alert keeps its keys.
        if NSApp.modalWindow != nil { return false }
        if let sheetParent = NSApp.keyWindow, sheetParent.attachedSheet != nil { return false }
        guard let menuItem = candidates.first(where: { handlers[$0]?.enabled() ?? false }), let item = handlers[menuItem] else {
            if candidates.allSatisfy({ handlers[$0]?.passesThrough ?? false }) { return false }
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
        let agents = UmiAgentMenu.ordered().map { session in
            CommandOption(title: "Show Agent: \(session.name)",
                          description: "\(session.kind) · \(UmiAgentMenu.describe(status: session.status, activity: session.activity))",
                          symbols: nil, leadingIcon: UmiAgentMenu.symbol(for: session.status)) {
                _ = try? UmiAgentUI.open(session.id, placement: .init(kind: .tab, focus: true), caller: UmiCaller([:]))
            }
        }
        return fixed + UmiTabGroups.paletteOptions() + agents
    }

    // MARK: Actions

    enum PaneTarget { case newTab, newWindow, adjacentTab(Int) }

    private static func movePane(_ target: PaneTarget) {
        guard let window = UmiTopology.currentWindow, let pane = UmiTopology.currentPane else { return }
        do {
            switch target {
            case .newTab:
                try UmiLayout.move(pane, to: .newTab(window, index: nil), focus: true)
            case .newWindow:
                try UmiLayout.move(pane, to: .newWindow, focus: true)
            case .adjacentTab(let delta):
                guard let index = window.index(of: window.selectedTab) else { return }
                let targetIndex = index + delta
                guard window.tabs.indices.contains(targetIndex) else { NSSound.beep(); return }
                let tab = window.tabs[targetIndex]
                guard let anchor = tab.effectiveFocusedSurface else { return }
                try UmiLayout.move(pane, to: .besidePane(anchor, .right), focus: true)
            }
        } catch {
            NSSound.beep()
        }
    }

    /// The next or previous tab in sidebar order; only the matching ones while the sidebar has
    /// a search query.
    private static func adjacentTab(_ delta: Int) {
        if let searched = UmiSidebarSearch.cycleMatches(delta) {
            if searched == nil { NSSound.beep() }
            return
        }
        UmiNavigation.selectAdjacentTab(delta)
    }

    private static func moveSelectedTab(_ delta: Int) {
        guard let window = UmiTopology.currentWindow else { return }
        if !UmiNavigation.moveTab(window.selectedTab, by: delta, in: window) { NSSound.beep() }
    }

    private static func canMoveSelectedTab(_ delta: Int) -> Bool {
        guard let window = UmiTopology.currentWindow else { return false }
        return UmiNavigation.canMoveTab(window.selectedTab, by: delta, in: window)
    }

    private static func moveTabToNewWindow() {
        guard let window = UmiTopology.currentWindow else { return }
        _ = try? UmiLayout.move(tab: window.selectedTab, from: window, toWindow: nil, index: nil, newWindow: true, focus: true)
    }

    private static func togglePin() {
        guard let window = UmiTopology.currentWindow else { return }
        let tab = window.selectedTab
        let pin = !tab.pinned
        UmiLayout.undoable(pin ? "Pin Tab" : "Unpin Tab", windows: [window]) {
            window.setPinned(tab, pin)
        }
    }

    /// Rename the current tab in place, in its sidebar row (as Warp).
    private static func renameTab() {
        guard let window = UmiTopology.currentWindow else { return }
        UmiTabMenu.beginRename(.tab(window.selectedTab.id), in: window)
    }

    /// Rename the focused pane in place, in its tab's sidebar row (as Warp).
    private static func renamePane() {
        guard let window = UmiTopology.currentWindow, let pane = UmiTopology.currentPane,
              let tab = window.tab(containing: pane) else { return }
        UmiTabMenu.beginRename(.pane(tab: tab.id, pane: pane.id), in: window)
    }
}

/// The target of Umi's menu items.
final class UmiMenuTarget: NSObject, NSMenuItemValidation {
    static let shared = UmiMenuTarget()

    /// Not `perform(_:)`: that's NSObject's `performSelector:`.
    @MainActor @objc func performUmiItem(_ sender: NSMenuItem) {
        UmiShortcuts.perform(sender)
    }

    @MainActor func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        UmiShortcuts.validate(menuItem)
    }
}
