import AppKit
import GhosttyKit

/// The terminal's right-click menu (L-21): Warp's items, in Warp's order, then Ghostty's
/// terminal items Umi keeps. Warp (`terminal/view.rs`, the block list's context menu) shows
/// Copy when text is selected, Paste, Clear, the four splits, and in a split Maximize (or
/// Minimize) and Close. Its block, prompt and AI items have nothing to act on in Umi.
@MainActor
enum UmiPaneMenu {
    struct Entry {
        let title: String
        /// The Ghostty action whose key the item shows (empty: none).
        var shortcutAction: String = ""
        var symbol: String?
        var enabled = true
        var checked = false
        let action: @MainActor () -> Void
    }

    /// The menu's items, nil for a separator.
    static func entries(for pane: Ghostty.SurfaceView) -> [Entry?] {
        var entries: [Entry?] = []
        if let text = pane.accessibilitySelectedText(), !text.isEmpty {
            entries.append(Entry(title: "Copy", shortcutAction: "copy_to_clipboard") { pane.copy(nil) })
        }
        let clipboardEmpty = (NSPasteboard.general.string(forType: .string) ?? "").isEmpty
        entries.append(Entry(title: "Paste", shortcutAction: "paste_from_clipboard", enabled: !clipboardEmpty) { pane.paste(nil) })
        entries.append(nil)
        entries.append(Entry(title: "Clear", shortcutAction: "clear_screen", symbol: "eraser") { binding("clear_screen", on: pane) })
        entries.append(nil)
        entries.append(Entry(title: "Split Pane Right", shortcutAction: "new_split:right",
                             symbol: "rectangle.righthalf.inset.filled") { pane.splitRight(pane) })
        entries.append(Entry(title: "Split Pane Left", shortcutAction: "new_split:left",
                             symbol: "rectangle.leadinghalf.inset.filled") { pane.splitLeft(pane) })
        entries.append(Entry(title: "Split Pane Down", shortcutAction: "new_split:down",
                             symbol: "rectangle.bottomhalf.inset.filled") { pane.splitDown(pane) })
        entries.append(Entry(title: "Split Pane Up", shortcutAction: "new_split:up",
                             symbol: "rectangle.tophalf.inset.filled") { pane.splitUp(pane) })
        if let location = UmiTopology.locate(pane) {
            let tree = location.window.tree(of: location.tab)
            if tree.isSplit {
                let maximized = tree.zoomed != nil && tree.zoomed == tree.root?.node(view: pane)
                entries.append(Entry(title: maximized ? "Minimize Pane" : "Maximize Pane", shortcutAction: "toggle_split_zoom",
                                     symbol: maximized ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right") {
                    binding("toggle_split_zoom", on: pane)
                })
                entries.append(Entry(title: "Close Pane", shortcutAction: "close_surface", symbol: "xmark") {
                    binding("close_surface", on: pane)
                })
            }
        }
        // Ghostty's own items.
        entries.append(nil)
        entries.append(Entry(title: "Reset Terminal", symbol: "arrow.trianglehead.2.clockwise") { pane.resetTerminal(pane) })
        entries.append(Entry(title: "Toggle Terminal Inspector", shortcutAction: "inspector:toggle", symbol: "scope") {
            pane.toggleTerminalInspector(pane)
        })
        entries.append(Entry(title: "Terminal Read-only", symbol: "eye.fill", checked: pane.readonly) { pane.toggleReadonly(nil) })
        entries.append(nil)
        entries.append(Entry(title: "Change Tab Title...", symbol: "pencil.line") {
            NSApp.sendAction(#selector(BaseTerminalController.changeTabTitle(_:)), to: nil, from: pane)
        })
        entries.append(Entry(title: "Change Terminal Title...") { pane.changeTitle(pane) })
        return entries
    }

    static func menu(for pane: Ghostty.SurfaceView) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let config = UmiTopology.locate(pane)?.window.ghostty.config
        let shortcuts = Ghostty.MenuShortcutManager()
        for entry in entries(for: pane) {
            guard let entry else {
                menu.addItem(.separator())
                continue
            }
            let item = NSMenuItem(title: entry.title, action: #selector(UmiPaneMenuTarget.perform(_:)), keyEquivalent: "")
            item.target = UmiPaneMenuTarget.shared
            item.representedObject = UmiPaneMenuTarget.Box(entry.action)
            item.isEnabled = entry.enabled
            item.state = entry.checked ? .on : .off
            if let symbol = entry.symbol { item.setImageIfDesired(systemSymbolName: symbol) }
            // The key shows in the menu (as in Warp); a context menu's keys don't act on their own.
            if let config, !entry.shortcutAction.isEmpty {
                shortcuts.syncMenuShortcut(config, action: entry.shortcutAction, menuItem: item)
            }
            menu.addItem(item)
        }
        return menu
    }

    private static func binding(_ action: String, on pane: Ghostty.SurfaceView) {
        guard let surface = pane.surface else { return }
        _ = ghostty_surface_binding_action(surface, action, UInt(action.lengthOfBytes(using: .utf8)))
    }
}

/// The target of the right-click menu's items.
final class UmiPaneMenuTarget: NSObject {
    static let shared = UmiPaneMenuTarget()

    final class Box: NSObject {
        let action: @MainActor () -> Void
        init(_ action: @escaping @MainActor () -> Void) { self.action = action }
    }

    @MainActor @objc func perform(_ sender: NSMenuItem) {
        (sender.representedObject as? Box)?.action()
    }
}
