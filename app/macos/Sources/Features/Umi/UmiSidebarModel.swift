import AppKit
import Combine
import GhosttyKit
import SwiftUI

// MARK: - A window's sidebar state

/// What one window's sidebar is doing besides listing tabs, as in Warp's vertical tabs panel:
/// the "Search tabs..." query, which row is being renamed in place, and the request to focus
/// the search field (⌥⌘F). Each window has its own (`TerminalController.sidebarModel`).
@MainActor
final class UmiSidebarModel: ObservableObject {
    /// The search query. While it isn't empty the sidebar lists only the matching tabs, and
    /// ⇧⌘[ / ⇧⌘] and ⌃Tab / ⌃⇧Tab cycle through them only.
    @Published var query: String = ""

    /// Bumped to move keyboard focus into the search field.
    @Published private(set) var searchFocusRequest = 0

    /// A row being renamed in place: the tab, the tab's focused pane, or a tab group's header.
    enum RenameTarget: Equatable {
        case tab(UUID)
        case pane(tab: UUID, pane: UUID)
        case group(UUID)

        /// The tab whose row holds the field (none for a group's header).
        var tabID: UUID? {
            switch self {
            case .tab(let id): return id
            case .pane(let tab, _): return tab
            case .group: return nil
            }
        }
    }

    @Published var renaming: RenameTarget?

    /// The window's tab groups (Warp's "New group with tab"), in no particular order: the sidebar
    /// lists each where its first member is. Their tabs say which they belong to (`UmiTab.groupID`).
    @Published var groups: [UmiTabGroup] = []

    /// Whether the search field has keyboard focus (set by the field).
    var searchFocused = false

    var isSearching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    /// A focus request the field hasn't taken yet (the sidebar may be appearing for it).
    var searchFocusPending = false

    func focusSearch() {
        searchFocusPending = true
        searchFocusRequest &+= 1
    }

    /// Esc in the field: clear the query and give focus back to the window's pane.
    func endSearch(in controller: TerminalController) {
        query = ""
        if let pane = controller.selectedTab.effectiveFocusedSurface {
            UmiLayout.focusPane(pane, activate: false)
        }
    }

    // MARK: Matching

    /// What a query is matched against: the title, folder, branch, command and agent title.
    static func searchText(_ row: UmiSidebarRowModel) -> [String] {
        var fragments = [row.title, row.tab.title]
        if let name = row.tab.name { fragments.append(name) }
        if let cwd = row.cwd { fragments += [cwd, UmiSidebarRowModel.abbreviate(cwd)] }
        if let git = row.git {
            fragments.append(git.branch)
            if let worktree = git.worktree { fragments.append(worktree) }
        }
        fragments.append(row.detail.text)
        if let agent = row.agent, !agent.title.isEmpty { fragments.append(agent.title) }
        if let pane = row.focusedPane, let name = UmiState.shared.paneName(pane.id) { fragments.append(name) }
        return fragments
    }

    static func matches(_ row: UmiSidebarRowModel, query: String) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return true }
        return searchText(row).contains { $0.lowercased().contains(needle) }
    }

    /// The window's tabs the query admits, in sidebar order (all of them without a query).
    func matchingTabs(in controller: TerminalController) -> [UmiTab] {
        guard isSearching else { return controller.tabs }
        return controller.tabs.filter { UmiTabGroups.tabMatches($0, query: query, in: controller) }
    }

    /// The tab ⇧⌘] / ⌃Tab (`delta` 1) or ⇧⌘[ / ⌃⇧Tab (-1) go to while searching: the next or
    /// previous matching tab after the current one, wrapping around (as Warp's
    /// `activate_next_tab` does with a query).
    func adjacentMatch(_ delta: Int, in controller: TerminalController) -> UmiTab? {
        let matching = matchingTabs(in: controller)
        guard !matching.isEmpty, let current = controller.index(of: controller.selectedTab) else { return nil }
        let indexed = matching.compactMap { tab in controller.index(of: tab).map { ($0, tab) } }
        if delta > 0 {
            return (indexed.first { $0.0 > current } ?? indexed.first)?.1
        }
        return (indexed.last { $0.0 < current } ?? indexed.last)?.1
    }
}

// MARK: - The sidebar's search, from the keyboard

@MainActor
enum UmiSidebarSearch {
    /// ⌥⌘F: show the sidebar's tab list and put the cursor in its search field.
    static func focusField(in window: TerminalController? = nil) {
        guard let window = window ?? UmiTopology.currentWindow else { return }
        UmiSidebarVisibility.set(true, in: window)
        UmiState.shared.sidebarMode = .tabs
        window.sidebarModel.focusSearch()
    }

    /// Next or previous tab for ⇧⌘] and ⌃Tab (and ⇧⌘[ and ⌃⇧Tab): only the matching tabs
    /// while the current window's sidebar has a query. Returns nil when no query applies.
    static func cycleMatches(_ delta: Int) -> UmiTab?? {
        guard let window = UmiTopology.currentWindow, window.sidebarModel.isSearching else { return nil }
        guard let tab = window.sidebarModel.adjacentMatch(delta, in: window) else { return .some(nil) }
        if tab !== window.selectedTab { UmiLayout.focusTab(tab, in: window) }
        return .some(tab)
    }
}

// MARK: - Showing and hiding the sidebar

/// Each window shows or hides its own sidebar, at once, as Warp's left panel (⌘B, ⌘\).
@MainActor
enum UmiSidebarVisibility {
    static func set(_ visible: Bool, in window: TerminalController) {
        window.sidebarVisible = visible
        // A new window starts as the last one toggled.
        UmiState.shared.sidebarVisible = visible
    }

    static func toggle(in window: TerminalController? = nil) {
        guard let window = window ?? UmiTopology.currentWindow else {
            UmiState.shared.sidebarVisible.toggle()
            return
        }
        set(!window.sidebarVisible, in: window)
    }
}

// MARK: - ⌘ held: the tab-switch keys on the rows

/// While ⌘ (the modifier of ⌘1–⌘9) is held for 750 ms, each row shows the key that selects
/// it, as Warp does: ⌘1–⌘8 for the first eight tabs and ⌘9 for the last.
@MainActor
final class UmiTabHints: ObservableObject {
    static let shared = UmiTabHints()

    @Published private(set) var revealed = false
    private var monitor: Any?
    private var pending: DispatchWorkItem?
    static let delay: TimeInterval = 0.75

    func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { event in
            MainActor.assumeIsolated { UmiTabHints.shared.handle(event) }
            return event
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil,
                                               queue: .main) { _ in
            MainActor.assumeIsolated { UmiTabHints.shared.set(held: false) }
        }
    }

    private func handle(_ event: NSEvent) {
        switch event.type {
        case .flagsChanged:
            // Only ⌘ on its own, the modifier the tab-switch keys use.
            let flags = event.modifierFlags.intersection([.command, .shift, .control, .option])
            set(held: flags == .command)
        case .keyDown:
            // A shortcut pressed while ⌘ is down: Warp keeps the hints, so do we; nothing to do.
            break
        default:
            break
        }
    }

    /// ⌘ went down (true) or up (false). Also driven by `debug.ui.hints`.
    func set(held: Bool, immediately: Bool = false) {
        pending?.cancel()
        pending = nil
        guard held else {
            if revealed { revealed = false }
            return
        }
        if immediately {
            revealed = true
            return
        }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.revealed = true }
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.delay, execute: work)
    }

    /// The key that selects the tab at `index` of `count` tabs, or nil.
    static func label(index: Int, count: Int) -> String? {
        guard index >= 0, index < count else { return nil }
        if index < 8 { return "⌘\(index + 1)" }
        return index == count - 1 ? "⌘9" : nil
    }
}

// MARK: - Pull requests (Copy pull request link)

/// The pull request of a folder's branch, found with GitHub's `gh` the way Warp finds it.
/// Looked up in the background and cached; the row menu's "Copy pull request link" shows only
/// when one was found.
@MainActor
final class UmiPullRequests {
    static let shared = UmiPullRequests()

    private struct Entry { let url: String?; let at: Date }
    private var cache: [String: Entry] = [:]
    private var inFlight: Set<String> = []
    /// How long an answer is kept before `gh` is asked again.
    static let ttl: TimeInterval = 120

    private static func key(_ cwd: String, _ branch: String) -> String { cwd + "\u{0}" + branch }

    /// The PR link for the branch checked out in `cwd`, if known. Starts a lookup when the
    /// answer is missing or old.
    func url(cwd: String, branch: String) -> String? {
        let key = Self.key(cwd, branch)
        let entry = cache[key]
        if entry == nil || Date().timeIntervalSince(entry!.at) > Self.ttl { lookUp(cwd: cwd, branch: branch) }
        return entry?.url
    }

    private func lookUp(cwd: String, branch: String) {
        let key = Self.key(cwd, branch)
        guard !inFlight.contains(key) else { return }
        inFlight.insert(key)
        DispatchQueue.global(qos: .utility).async {
            let url = Self.run(cwd: cwd, branch: branch)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let shared = UmiPullRequests.shared
                    shared.inFlight.remove(key)
                    let changed = shared.cache[key]?.url != url
                    shared.cache[key] = Entry(url: url, at: Date())
                    if changed { UmiState.shared.layoutDidChange() }
                }
            }
        }
    }

    /// `gh pr view BRANCH --json url --jq .url` in the folder. `UMI_GH_BIN` names another
    /// executable (the acceptance tests' stand-in); otherwise `gh` from the login shell's PATH.
    nonisolated private static func run(cwd: String, branch: String) -> String? {
        let env = UmiAgentEnvironment.login().env
        let gh: String
        if let override = ProcessInfo.processInfo.environment["UMI_GH_BIN"], !override.isEmpty {
            gh = override
        } else {
            let dirs = (env["PATH"] ?? "").split(separator: ":").map(String.init)
            guard let found = dirs.map({ $0 + "/gh" }).first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
                return nil
            }
            gh = found
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: gh)
        process.arguments = ["pr", "view", branch, "--json", "url", "--jq", ".url"]
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        process.environment = env.merging(["GH_PROMPT_DISABLED": "1", "NO_COLOR": "1"]) { $1 }
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let deadline = Date().addingTimeInterval(10)
        while process.isRunning && Date() < deadline { usleep(50_000) }
        if process.isRunning { process.terminate(); return nil }
        guard process.terminationStatus == 0 else { return nil }
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.hasPrefix("http") ? text : nil
    }
}

// MARK: - The terminal palette

extension Ghostty.Config {
    /// Umi: the first 16 colors of the configured terminal palette.
    var umiANSIPalette: [NSColor]? {
        guard let config else { return nil }
        var palette = ghostty_config_palette_s()
        let key = "palette"
        guard ghostty_config_get(config, &palette, key, UInt(key.lengthOfBytes(using: .utf8))) else { return nil }
        return withUnsafeBytes(of: &palette.colors) { raw in
            let colors = raw.bindMemory(to: ghostty_config_color_s.self)
            return (0..<16).map { i in
                NSColor(srgbRed: CGFloat(colors[i].r) / 255, green: CGFloat(colors[i].g) / 255,
                        blue: CGFloat(colors[i].b) / 255, alpha: 1)
            }
        }
    }
}

// MARK: - Renaming in place

@MainActor
enum UmiSidebarRename {
    /// The row's field was confirmed: name the tab or the pane (an empty name resets it), then
    /// give the keyboard back to the window's pane.
    static func commit(_ target: UmiSidebarModel.RenameTarget, text: String, in controller: TerminalController) {
        guard controller.sidebarModel.renaming == target else { return }
        controller.sidebarModel.renaming = nil
        let name = text.trimmingCharacters(in: .whitespaces)
        switch target {
        case .tab(let id):
            if let tab = controller.tabs.first(where: { $0.id == id }) { UmiTabMenu.rename(tab, in: controller, to: name) }
        case .pane(_, let paneID):
            if let pane = UmiTopology.allSurfaces.first(where: { $0.id == paneID }) { UmiTabMenu.setPaneName(pane, name) }
        case .group(let id):
            if let group = controller.sidebarModel.groups.first(where: { $0.id == id }) {
                UmiTabGroups.rename(group, to: name, in: controller)
            }
        }
        returnFocus(in: controller)
    }

    /// Esc: leave the names as they were.
    /// Focus that already went elsewhere (a click outside the field) stays there.
    static func cancel(_ target: UmiSidebarModel.RenameTarget, in controller: TerminalController,
                       focusPane: Bool = true) {
        guard controller.sidebarModel.renaming == target else { return }
        controller.sidebarModel.renaming = nil
        if focusPane { returnFocus(in: controller) }
    }

    private static func returnFocus(in controller: TerminalController) {
        if let pane = controller.selectedTab.effectiveFocusedSurface { UmiLayout.focusPane(pane, activate: false) }
    }
}
