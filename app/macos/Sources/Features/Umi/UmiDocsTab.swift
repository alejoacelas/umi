import AppKit

/// The tab Markdown files opened from outside Umi share (E-10): Finder, `open FILE`, `open -a Umi
/// FILE`. It is an ordinary tab named Docs, the one with the tab attribute `role=docs` (design/cli.md,
/// choice 10). A new document opens at the right end of its panes, under the same three-pane rule as
/// any tab (`strip.make-room` hides one when it shows three). Without a docs tab, one is made.
@MainActor
enum UmiDocsTab {
    /// The docs tab: the current window's first, then the other windows'.
    static func find() -> (window: TerminalController, tab: UmiTab)? {
        let current = UmiTopology.currentWindow
        let windows = (current.map { [$0] } ?? []) + UmiTopology.windows.filter { $0 !== current }
        for window in windows {
            if let tab = window.tabs.first(where: \.isDocs) { return (window, tab) }
        }
        return nil
    }

    /// Open a Markdown file from outside Umi. A file already open shows where it is (brought in if
    /// hidden); otherwise it joins the docs tab at the right end, made if there is none.
    static func open(_ url: URL) throws -> (TerminalController, UmiTab) {
        let url = url.standardizedFileURL.resolvingSymlinksInPath()
        let pane: Ghostty.SurfaceView
        if let existing = UmiFilePanes.shared.pane(showing: url) {
            pane = existing
        } else if let (window, tab) = find() {
            let doc = try UmiDocument(url: url, mode: nil)
            doc.reviewWaiters = UmiEvents.shared.waiters(on: doc.url.path)
            var options = UmiLayout.PaneOptions()
            options.cwd = url.deletingLastPathComponent().path
            let created = try UmiLayout.addPaneAtEnd(of: tab, in: window, options: options, inheritFrom: nil, focus: false)
            guard let id = created["pane"] as? String,
                  let made = UmiTopology.allSurfaces.first(where: { $0.umiID == id }) else {
                throw UmiError.failed("couldn't make a pane for \(url.lastPathComponent)")
            }
            UmiFilePanes.shared.attach(doc, to: made)
            UmiEvents.shared.emit("editor.opened", ["path": doc.url.path, "pane": made.umiID,
                                                    "tab": tab.idString, "window": window.umiIDString])
            pane = made
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
}
