import AppKit

/// Internal helpers behind the `debug.*` control methods: scripted checks of things that
/// otherwise need the accessibility tree (menus, the editor's key paths).
@MainActor
enum UmiDebug {
    static func menuItems() -> [[String: Any]] {
        guard let menu = NSApp.mainMenu else { return [] }
        var out: [[String: Any]] = []
        func walk(_ menu: NSMenu, path: [String]) {
            menu.delegate?.menuNeedsUpdate?(menu)
            menu.update()
            for item in menu.items where !item.isSeparatorItem {
                var mods: [String] = []
                let mask = item.keyEquivalentModifierMask
                if mask.contains(.control) { mods.append("ctrl") }
                if mask.contains(.option) { mods.append("option") }
                if mask.contains(.shift) { mods.append("shift") }
                if mask.contains(.command) { mods.append("cmd") }
                var key = item.keyEquivalent
                if key == String(UnicodeScalar(NSLeftArrowFunctionKey)!) { key = "left" }
                if key == String(UnicodeScalar(NSRightArrowFunctionKey)!) { key = "right" }
                out.append(["title": item.title, "menu": path.joined(separator: " > "), "key": key,
                            "modifiers": mods, "enabled": item.isEnabled, "state": item.state == .on ? "on" : "off"])
                if let submenu = item.submenu { walk(submenu, path: path + [item.title]) }
            }
        }
        walk(menu, path: [])
        return out
    }

    static func performMenuItem(_ title: String) throws {
        guard let menu = NSApp.mainMenu else { throw UmiError.failed("no main menu") }
        func find(_ menu: NSMenu) -> (NSMenu, Int)? {
            menu.delegate?.menuNeedsUpdate?(menu)
            menu.update()
            for (index, item) in menu.items.enumerated() {
                if item.title == title || item.title.hasPrefix(title + " ") { return (menu, index) }
                if let submenu = item.submenu, let found = find(submenu) { return found }
            }
            return nil
        }
        guard let (owner, index) = find(menu) else { throw UmiError.notFound("no menu item \"\(title)\"") }
        guard owner.items[index].isEnabled else { throw UmiError.failed("the menu item \"\(title)\" is disabled") }
        owner.performActionForItem(at: index)
    }

    /// Give keyboard focus to the editor's text (or preview) in a window: the selected tab's file
    /// pane (its focused pane when that shows a file), focused the way the app focuses one.
    static func focusEditor(in controller: TerminalController, selectEnd: Bool = false) {
        guard let window = controller.window else { return }
        let files = UmiFilePanes.shared
        let tabPanes = controller.selectedTab.tree.root?.leaves() ?? []
        let focused = controller.selectedTab.effectiveFocusedSurface
        guard let pane = (focused.flatMap { files.document(of: $0) != nil ? $0 : nil })
                ?? tabPanes.first(where: { files.document(of: $0) != nil }) else { return }
        files.focusEditor(of: pane)
        if selectEnd, let text = window.firstResponder as? NSTextView {
            text.setSelectedRange(NSRange(location: (text.string as NSString).length, length: 0))
        }
    }
}
