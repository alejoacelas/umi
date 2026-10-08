import AppKit

/// AppleScript-facing wrapper around a single tab in a scripting window.
///
/// `ScriptWindow.tabs` vends these objects so AppleScript can traverse
/// `window -> tab` without knowing anything about AppKit controllers.
@MainActor
@objc(GhosttyScriptTab)
final class ScriptTab: NSObject {
    /// Stable identifier used by AppleScript `tab id "..."` references.
    private let stableID: String

    /// Weak back-reference to the scripting window that owns this tab wrapper.
    ///
    /// We only need this for dynamic properties (`index`, `selected`) and for
    /// building an object specifier path.
    private weak var window: ScriptWindow?

    /// Live terminal controller (window) holding this tab.
    ///
    /// This can become `nil` if the tab closes while a script is running.
    private weak var controller: BaseTerminalController?

    /// The Tern tab this wrapper stands for (nil for windows without Tern tabs, such as
    /// the quick terminal, whose one tab is the controller itself).
    private weak var tab: TernTab?

    /// Called by `ScriptWindow.tabs` / `ScriptWindow.selectedTab`.
    ///
    /// The ID is computed once so object specifiers built from this instance keep
    /// a consistent tab identity.
    init(window: ScriptWindow, controller: BaseTerminalController, tab: TernTab? = nil) {
        self.stableID = tab.map(Self.stableID(tab:)) ?? Self.stableID(controller: controller)
        self.window = window
        self.controller = controller
        self.tab = tab
    }

    private var ternController: TerminalController? { controller as? TerminalController }

    /// The tab's panes (its split tree, shown or not).
    private var tabSurfaces: [Ghostty.SurfaceView] {
        if let tab, let ternController { return ternController.tree(of: tab).root?.leaves() ?? [] }
        return controller?.surfaceTree.root?.leaves() ?? []
    }

    /// Exposed as the AppleScript `id` property.
    @objc(id)
    var idValue: String {
        guard NSApp.isAppleScriptEnabled else { return "" }
        return stableID
    }

    /// Exposed as the AppleScript `title` property.
    ///
    /// Returns the title of the tab's window.
    @objc(title)
    var title: String {
        guard NSApp.isAppleScriptEnabled else { return "" }
        if let tab { return tab.title }
        return controller?.window?.title ?? ""
    }

    /// Exposed as the AppleScript `index` property.
    ///
    /// Cocoa scripting expects this to be 1-based for user-facing collections.
    @objc(index)
    var index: Int {
        guard NSApp.isAppleScriptEnabled else { return 0 }
        if let tab, let ternController { return (ternController.index(of: tab) ?? -1) + 1 }
        guard let controller else { return 0 }
        return window?.tabIndex(for: controller) ?? 0
    }

    /// Exposed as the AppleScript `selected` property.
    ///
    /// Powers script conditions such as `if selected of tab 1 then ...`.
    @objc(selected)
    var selected: Bool {
        guard NSApp.isAppleScriptEnabled else { return false }
        if let tab, let ternController { return ternController.selectedTab === tab }
        guard let controller else { return false }
        return window?.tabIsSelected(controller) ?? false
    }

    /// Exposed as the AppleScript `focused terminal` property.
    ///
    /// Uses the currently focused surface for this tab.
    @objc(focusedTerminal)
    var focusedTerminal: ScriptTerminal? {
        guard NSApp.isAppleScriptEnabled else { return nil }
        if let tab, let ternController {
            let surface = (tab === ternController.selectedTab ? ternController.focusedSurface : nil)
                .flatMap { tab.contains($0) ? $0 : nil } ?? tab.effectiveFocusedSurface
            return surface.map(ScriptTerminal.init)
        }
        guard let controller else { return nil }
        guard let surface = controller.focusedSurface,
              controller.surfaceTree.contains(surface)
        else { return nil }

        return ScriptTerminal(surfaceView: surface)
    }

    /// Best-effort native window containing this tab.
    var parentWindow: NSWindow? {
        guard NSApp.isAppleScriptEnabled else { return nil }
        return controller?.window
    }

    /// Live controller backing this tab wrapper.
    var parentController: BaseTerminalController? {
        guard NSApp.isAppleScriptEnabled else { return nil }
        return controller
    }

    /// Exposed as the AppleScript `terminals` element on a tab.
    ///
    /// Returns all terminal surfaces (split panes) within this tab.
    @objc(terminals)
    var terminals: [ScriptTerminal] {
        guard NSApp.isAppleScriptEnabled else { return [] }
        return tabSurfaces.map(ScriptTerminal.init)
    }

    /// Enables unique-ID lookup for `terminals` references on a tab.
    @objc(valueInTerminalsWithUniqueID:)
    func valueInTerminals(uniqueID: String) -> ScriptTerminal? {
        guard NSApp.isAppleScriptEnabled else { return nil }
        return tabSurfaces
            .first(where: { $0.id.uuidString == uniqueID })
            .map(ScriptTerminal.init)
    }

    /// Handler for `select tab <tab>`.
    @objc(handleSelectTabCommand:)
    func handleSelectTab(_ command: NSScriptCommand) -> Any? {
        guard NSApp.validateScript(command: command) else { return nil }

        if let tab, let ternController {
            guard ternController.tabs.contains(where: { $0 === tab }) else {
                command.scriptErrorNumber = errAEEventFailed
                command.scriptErrorString = "Tab is no longer available."
                return nil
            }
            TernLayout.focusTab(tab, in: ternController)
            return nil
        }

        guard let tabContainerWindow = parentWindow else {
            command.scriptErrorNumber = errAEEventFailed
            command.scriptErrorString = "Tab is no longer available."
            return nil
        }

        tabContainerWindow.makeKeyAndOrderFront(nil)
        return nil
    }

    /// Handler for `close tab <tab>`.
    @objc(handleCloseTabCommand:)
    func handleCloseTab(_ command: NSScriptCommand) -> Any? {
        guard NSApp.validateScript(command: command) else { return nil }

        guard let tabController = parentController else {
            command.scriptErrorNumber = errAEEventFailed
            command.scriptErrorString = "Tab is no longer available."
            return nil
        }

        if let managedTerminalController = tabController as? TerminalController {
            // Close this tab (the one the script named), never whichever is selected.
            guard let tab, managedTerminalController.tabs.contains(where: { $0 === tab }) else {
                command.scriptErrorNumber = errAEEventFailed
                command.scriptErrorString = "Tab is no longer available."
                return nil
            }
            managedTerminalController.closeTabImmediately(tab, registerUndo: false)
            return nil
        }

        guard let tabContainerWindow = parentWindow else {
            command.scriptErrorNumber = errAEEventFailed
            command.scriptErrorString = "Tab container window is no longer available."
            return nil
        }

        tabContainerWindow.close()
        return nil
    }

    /// Provides Cocoa scripting with a canonical "path" back to this object.
    override var objectSpecifier: NSScriptObjectSpecifier? {
        guard NSApp.isAppleScriptEnabled else { return nil }
        guard let window else { return nil }
        guard let windowClassDescription = window.classDescription as? NSScriptClassDescription else {
            return nil
        }
        guard let windowSpecifier = window.objectSpecifier else { return nil }

        // This tells Cocoa how to re-find this tab later:
        // application -> scriptWindows[id] -> tabs[id].
        return NSUniqueIDSpecifier(
            containerClassDescription: windowClassDescription,
            containerSpecifier: windowSpecifier,
            key: "tabs",
            uniqueID: stableID
        )
    }
}

extension ScriptTab {
    /// Stable ID for one tab controller.
    ///
    /// Tab identity belongs to `ScriptTab`, so both tab creation and tab ID
    /// lookups in `ScriptWindow` call this helper.
    static func stableID(controller: BaseTerminalController) -> String {
        "tab-\(ObjectIdentifier(controller).hexString)"
    }

    /// Stable ID for one Tern tab (its own id, which survives moves between windows).
    static func stableID(tab: TernTab) -> String {
        "tab-\(tab.idString)"
    }
}
