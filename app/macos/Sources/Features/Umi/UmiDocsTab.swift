import AppKit

/// The tab Markdown files opened from outside Umi share (E-10): Finder, `open FILE`, `open -a Umi
/// FILE`. Its documents share one place, as a stack (M-7) ordered most recently opened first: the
/// strip names the three most recent, the rest are counted ("+2 · ⌘[ ⌘]") and reached with ⌘[ / ⌘].
/// Closing a document shows the next one; closing the last closes the tab, and the next file
/// opened from outside makes a new one.
@MainActor
enum UmiDocsTab {
    /// How many documents the strip names.
    static let named = 3

    /// The docs tab: the current window's first, then the other windows'.
    static func find() -> (window: TerminalController, tab: UmiTab)? {
        let current = UmiTopology.currentWindow
        let windows = (current.map { [$0] } ?? []) + UmiTopology.windows.filter { $0 !== current }
        for window in windows {
            if let tab = window.tabs.first(where: \.isDocs) { return (window, tab) }
        }
        return nil
    }

    /// Open a Markdown file from outside Umi. A file already open shows where it is (in the docs tab
    /// it also becomes the most recent); otherwise it joins the docs tab, made if there is none.
    static func open(_ url: URL) throws -> (TerminalController, UmiTab) {
        let url = url.standardizedFileURL.resolvingSymlinksInPath()
        let pane: Ghostty.SurfaceView
        if let existing = UmiFilePanes.shared.pane(showing: url) {
            if let location = UmiTopology.locate(existing), location.tab.isDocs { makeMostRecent(existing, in: location.tab) }
            pane = existing
        } else if let (window, tab) = find(), let place = place(in: tab, window: window) {
            let doc = try UmiDocument(url: url, mode: nil)
            doc.reviewWaiters = UmiEvents.shared.waiters(on: doc.url.path)
            pane = try UmiStacks.addMember(onto: place, cwd: url.deletingLastPathComponent().path, at: 0)
            UmiFilePanes.shared.attach(doc, to: pane)
            UmiEvents.shared.emit("editor.opened", ["path": doc.url.path, "pane": pane.umiID,
                                                    "tab": tab.idString, "window": window.umiIDString])
        } else {
            let doc = try UmiDocument(url: url, mode: nil)
            doc.reviewWaiters = UmiEvents.shared.waiters(on: doc.url.path)
            var options = UmiLayout.PaneOptions()
            options.cwd = url.deletingLastPathComponent().path
            let created: [String: Any]
            if let current = UmiTopology.currentWindow {
                created = try UmiLayout.newTab(in: current, options: options, tabName: "Docs", color: .none,
                                                index: current.newTabIndex(selecting: true) + 1, focus: false,
                                                inheritFrom: nil)
            } else {
                created = try UmiLayout.newWindow(options, tabName: "Docs", focus: false)
            }
            guard let id = created["pane"] as? String,
                  let made = UmiTopology.allSurfaces.first(where: { $0.umiID == id }),
                  let location = UmiTopology.locate(made) else {
                throw UmiError.failed("couldn't make a tab for \(url.lastPathComponent)")
            }
            // The Docs tab is the tab with `role=docs` (a `tab.changed` event, like any attribute).
            try UmiAttributes.shared.set([("role", "docs")], on: location.tab, in: location.window)
            UmiFilePanes.shared.attach(doc, to: made)
            UmiEvents.shared.emit("editor.opened", ["path": doc.url.path, "pane": made.umiID,
                                                    "tab": location.tab.idString, "window": location.window.umiIDString])
            pane = made
        }
        UmiLayout.focusPane(pane, activate: true)
        UmiState.shared.layoutDidChange()
        guard let location = UmiTopology.locate(pane) else { throw UmiError.failed("the file's pane went away") }
        return (location.window, location.tab)
    }

    /// Where new documents go in the docs tab: the stack of documents, else a file pane on show
    /// (the one used most recently), else any pane on show.
    private static func place(in tab: UmiTab, window: TerminalController) -> Ghostty.SurfaceView? {
        let files = UmiFilePanes.shared
        if let stack = tab.stacks.first(where: { $0.members.contains { files.document(of: $0) != nil } }),
           let shown = window.shownMember(of: stack, in: tab) {
            return shown
        }
        let shown = window.tree(of: tab).root?.leaves() ?? []
        let filePanes = shown.filter { files.document(of: $0) != nil }
        return UmiFocusHistory.mostRecent(among: filePanes) ?? filePanes.first ?? tab.effectiveFocusedSurface
    }

    /// Put a document first in its stack's order.
    private static func makeMostRecent(_ pane: Ghostty.SurfaceView, in tab: UmiTab) {
        guard let stack = tab.stack(of: pane), let index = stack.members.firstIndex(where: { $0 === pane }), index > 0 else { return }
        stack.members.remove(at: index)
        stack.members.insert(pane, at: 0)
    }
}
