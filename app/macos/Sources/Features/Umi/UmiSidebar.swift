import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

/// The left sidebar: Warp's vertical tabs panel and a project explorer. Its look follows Warp's
/// (`vertical_tabs.rs`): a 5% ink panel; a header with "Search tabs..." (Tabs mode), the
/// Tabs/Files buttons and +; rows 8 pt inside, 4 pt apart, radius 4; a selected row at 10% with
/// a 1 px border at 15%, a hovered one at 5% (S-1, S-2, S-3). Its width is per window, dragged
/// at its edge (S-8), and it is shown or hidden per window.
struct UmiSidebar: View {
    @ObservedObject var controller: TerminalController
    /// Height of the titlebar band above the sidebar content (traffic lights).
    let topInset: CGFloat

    @ObservedObject private var state = UmiState.shared
    @ObservedObject private var attention = UmiAttention.shared
    @ObservedObject private var updater = UmiUpdater.shared
    @ObservedObject private var hints = UmiTabHints.shared
    /// Periodic refresh for things nothing publishes (running command, branch).
    @State private var tick = 0
    @State private var listDropTargeted = false
    @State private var scroll = UmiOverlayScrollbar.Metrics()
    private let refresh = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear.frame(height: topInset)

            UmiSidebarHeader(controller: controller, model: controller.sidebarModel)

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: state.sidebarMode == .tabs ? 4 : 1) {
                    switch state.sidebarMode {
                    case .tabs: tabsList
                    case .files: UmiFileTreeView(model: UmiFileTreeModel.model(for: controller))
                    case .search: UmiGlobalSearchView(model: UmiGlobalSearchModel.model(for: controller))
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
                .background(UmiOverlayScrollbar.contentReader)
            }
            .coordinateSpace(name: UmiOverlayScrollbar.space)
            .background(UmiOverlayScrollbar.viewportReader)
            .onPreferenceChange(UmiOverlayScrollbar.ContentKey.self) { scroll.content = $0 }
            .onPreferenceChange(UmiOverlayScrollbar.ViewportKey.self) { scroll.viewport = $0 }
            // Warp's 4 px scrollbar over the list's right edge.
            .overlay(alignment: .topTrailing) { UmiOverlayScrollbar(metrics: scroll) }
            // Dropped below the rows: a tab goes to the end of this window's tabs, a pane
            // becomes a new tab there (M-4).
            .onDrop(of: UmiSidebarDrop.types, delegate: UmiSidebarListDropDelegate(
                controller: controller, targeted: $listDropTargeted))

            if let notice = updater.notice {
                UmiUpdateNotice(notice: notice)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(UmiTheme.sidebarFill)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Sidebar")
        .onReceive(refresh) { _ in
            if state.sidebarMode == .tabs { tick &+= 1 }
        }
    }

    // MARK: Tabs

    @ViewBuilder
    private var tabsList: some View {
        let _ = state.revision
        let _ = attention.revision
        let _ = hints.revealed
        let blocks = UmiTabGroups.sidebarBlocks(in: controller)

        if blocks.isEmpty && controller.sidebarModel.isSearching {
            Text("No tabs match your search.")
                .font(.system(size: 12))
                .foregroundColor(UmiTheme.rowSubtitle)
                .padding(12)
                .accessibilityLabel("No tabs match your search.")
        }
        ForEach(blocks) { block in
            switch block {
            case .tab(let tab):
                UmiSidebarTabRow(controller: controller, tab: tab, model: controller.sidebarModel, tick: tick)
            case .group(let group, let members):
                UmiTabGroupBox(controller: controller, group: group, model: controller.sidebarModel,
                               members: members, tick: tick)
            }
        }
        // Where a drop below the rows lands.
        UmiInsertionLine().opacity(listDropTargeted ? 1 : 0)
    }
}

// MARK: - Header

/// Warp's control bar: "Search tabs..." (12 pt icon, 24 high), then Umi's Tabs, Files and Search buttons
/// and +; 4 pt above and below, 8 at the sides, 4 between items.
struct UmiSidebarHeader: View {
    @ObservedObject var controller: TerminalController
    @ObservedObject var model: UmiSidebarModel
    @ObservedObject private var state = UmiState.shared
    @FocusState private var searchFocused: Bool

    var body: some View {
        HStack(spacing: 4) {
            if state.sidebarMode == .tabs {
                searchField
            } else {
                Spacer(minLength: 0)
            }
            modeButton(.tabs, symbol: "rectangle.stack", help: "Tabs")
            modeButton(.files, symbol: "folder", help: "Project Explorer (⇧⌘E)")
            modeButton(.search, symbol: "magnifyingglass", help: "Global Search (⇧⌘F)")
            Button {
                _ = try? UmiLayout.newTab(in: controller, options: .init(), tabName: nil, color: .none,
                                           index: nil, focus: true, inheritFrom: nil)
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(UmiIconButtonStyle(size: 24, radius: 4))
            .help("New Tab (⌘T)")
            .accessibilityLabel("New Tab")
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .onChange(of: model.searchFocusRequest) { _ in takeFocusRequest() }
        .onAppear { if model.searchFocusPending { takeFocusRequest() } }
        .onChange(of: searchFocused) { model.searchFocused = $0 }
    }

    /// ⌥⌘F: once the field is on screen, give it the keyboard.
    private func takeFocusRequest() {
        DispatchQueue.main.async {
            model.searchFocusPending = false
            searchFocused = true
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10, weight: .medium))
                .frame(width: 12, height: 12)
                .foregroundColor(UmiTheme.rowSubtitle)
            TextField("Search tabs...", text: $model.query)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundColor(UmiTheme.rowTitle)
                .focused($searchFocused)
                .onExitCommand { model.endSearch(in: controller) }
                .accessibilityLabel("Search tabs")
        }
        .frame(height: 24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { searchFocused = true }
    }

    private func modeButton(_ mode: UmiState.SidebarMode, symbol: String, help: String) -> some View {
        Button { state.sidebarMode = mode } label: {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(UmiIconButtonStyle(active: state.sidebarMode == mode, size: 24, radius: 4))
        .help(help)
        .accessibilityLabel(mode == .tabs ? "Tabs" : (mode == .files ? "Files" : "Search"))
    }
}

// MARK: - Scrollbar

/// Warp's overlay scrollbar: a 4 pt thumb over the list's right edge, shown while the list is
/// longer than the panel.
struct UmiOverlayScrollbar: View {
    struct Metrics: Equatable {
        var content = CGRect.zero
        var viewport = CGFloat.zero
    }

    let metrics: Metrics
    static let space = "umi.sidebar.scroll"

    struct ContentKey: PreferenceKey {
        static let defaultValue = CGRect.zero
        static func reduce(value: inout CGRect, nextValue: () -> CGRect) { value = nextValue() }
    }

    struct ViewportKey: PreferenceKey {
        static let defaultValue = CGFloat.zero
        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
    }

    static var contentReader: some View {
        GeometryReader { geo in
            Color.clear.preference(key: ContentKey.self, value: geo.frame(in: .named(space)))
        }
    }

    static var viewportReader: some View {
        GeometryReader { geo in Color.clear.preference(key: ViewportKey.self, value: geo.size.height) }
    }

    var body: some View {
        let content = metrics.content.height
        let viewport = metrics.viewport
        if content > viewport + 1, viewport > 0 {
            let thumb = max(24, viewport * viewport / content)
            let progress = min(max(-metrics.content.minY / (content - viewport), 0), 1)
            Capsule()
                .fill(UmiTheme.rowSubtitle.opacity(0.5))
                .frame(width: 4, height: thumb)
                .offset(x: -2, y: progress * (viewport - thumb))
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

// MARK: - Row model

/// What a tab's row shows (S-3). The view and `debug.ui.rows` both read it.
///
/// Line 1 is the tab's folder (the focused pane's), or the name the user gave the tab, with the
/// git branch (a linked worktree shown differently), a pane count when split, and pin and
/// close on hover. Line 2 is the title of the tab's agent when it has one, with the
/// agent's mark as the row icon; otherwise what the focused pane is doing (the command it is
/// running or last ran, an agent typed into it), else its folder's path.
@MainActor
struct UmiSidebarRowModel {
    enum Icon: String { case claude, codex, pin, terminal }

    enum Detail {
        case session(title: String, status: String)
        case command(text: String, running: Bool)
        case folder(String)

        var text: String {
            switch self {
            case .session(let title, _): return title
            case .command(let text, _): return text
            case .folder(let path): return path
            }
        }
    }

    let tab: UmiTab
    let selected: Bool
    let paneCount: Int
    let focusedPane: Ghostty.SurfaceView?
    let cwd: String?
    let git: UmiPaneContext.Git?
    let title: String
    let agent: UmiAttention.Agent?
    let detail: Detail
    /// The focused pane's last command failed (Warp's red triangle before the title).
    let failed: Bool
    /// A pane of the tab is zoomed (Warp's "Maximized" indicator).
    let maximized: Bool
    /// The key that selects the tab, while ⌘ is held (⌘1–⌘9).
    let hint: String?

    init(tab: UmiTab, in controller: TerminalController) {
        self.tab = tab
        selected = tab === controller.selectedTab
        let tree = controller.tree(of: tab)
        let panes = tree.root?.leaves() ?? []
        paneCount = panes.count
        maximized = tree.zoomed != nil
        let focusedPane = (selected ? controller.focusedSurface.flatMap { panes.contains($0) ? $0 : nil } : nil)
            ?? tab.effectiveFocusedSurface
        self.focusedPane = focusedPane
        let cwd = focusedPane.map(UmiTopology.cwd(of:)).flatMap { $0.isEmpty ? nil : $0 }
        self.cwd = cwd
        git = cwd.flatMap { UmiPaneContext.git(for: $0) }
        // Ask for the branch's pull request as soon as the branch is known, so the row menu has
        // "Copy pull request link" at its first right-click.
        if let cwd, let branch = git?.branch, !branch.isEmpty { UmiPullRequests.shared.prefetch(cwd: cwd, branch: branch) }
        title = tab.name.flatMap { $0.isEmpty ? nil : $0 } ?? cwd.map(UmiPaneContext.folderName) ?? tab.title
        // The pane that speaks for the tab (the `tab.summary` slot) gives the agent's mark and line 2.
        let summary = UmiSlots.summaryPane(of: tab, in: controller)
        let agent = summary.flatMap { UmiAttention.shared.agent(forPane: $0.id) }
        self.agent = agent
        let command = focusedPane.flatMap { UmiPaneContext.command(for: $0) }
        failed = command?.failed ?? false
        if let line = UmiSlots.line2(summary ?? focusedPane) {
            // The user's `sidebar.line2` template.
            detail = .folder(line)
        } else if let agent {
            detail = .session(title: agent.title.isEmpty ? Self.describe(agent.status.rawValue) : agent.title, status: agent.status.rawValue)
        } else if let command {
            detail = .command(text: command.text, running: command.running)
        } else {
            detail = .folder(cwd.map(Self.abbreviate) ?? "shell")
        }
        hint = UmiTabHints.shared.revealed
            ? controller.index(of: tab).flatMap { UmiTabHints.label(index: $0, count: controller.tabs.count) }
            : nil
    }

    var icon: Icon {
        switch agent?.kind {
        case .claude: return .claude
        case .codex: return .codex
        case nil: return .terminal
        }
    }

    /// The mark's name for the CLI and accessibility.
    var markName: String {
        switch agent?.mark ?? .none {
        case .none: return "none"
        case .finished: return "finished"
        case .needsYou: return "needs_you"
        }
    }

    var accessibilityValue: String {
        var parts: [String] = []
        if failed { parts.append("last command failed") }
        if maximized { parts.append("Maximized") }
        if tab.pinned { parts.append("pinned") }
        guard let agent else { return (parts + [detail.text]).joined(separator: " · ") }
        parts += [agent.kind.rawValue, Self.describe(agent.status.rawValue)]
        switch agent.mark {
        case .finished: parts.append("finished, not seen yet")
        case .needsYou: parts.append("needs you")
        case .none: break
        }
        return (parts + [detail.text]).joined(separator: " · ")
    }

    static func describe(_ status: String) -> String {
        status.replacingOccurrences(of: "_", with: " ")
    }

    static func abbreviate(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    func json(in controller: TerminalController? = nil) -> [String: Any] {
        var json: [String: Any] = [
            "tab": tab.idString, "selected": selected, "pinned": tab.pinned, "panes": paneCount,
            "line1": title, "line2": detail.text, "icon": icon.rawValue, "mark": markName,
            "color": UmiTopology.colorName(tab.color), "failed": failed, "maximized": maximized,
        ]
        if let hint { json["hint"] = hint }
        if let controller {
            json["shown"] = UmiTabGroups.isShown(tab, in: controller)
                && UmiSidebarModel.matches(self, query: controller.sidebarModel.query)
            if let group = UmiTabGroups.group(of: tab, in: controller) { json["group"] = group.name }
        }
        // Umi: synchronized input (L-32).
        if let window = UmiTopology.locate(tab: tab) { json["input_synced"] = UmiInputSync.shared.isSynced(tab, in: window) }
        if let git {
            json["branch"] = git.branch
            if let worktree = git.worktree { json["worktree"] = worktree }
        }
        if let agent {
            json["agent"] = ["kind": agent.kind.rawValue, "status": agent.status.rawValue, "title": agent.title,
                             "session": agent.session ?? "", "unseen": agent.unseen]
        }
        switch detail {
        case .session: json["detail"] = "session"
        case .command(_, let running): json["detail"] = running ? "running_command" : "last_command"
        case .folder: json["detail"] = "folder"
        }
        return json
    }
}

// MARK: - Row

/// One tab in the sidebar, on two lines (S-3; see `UmiSidebarRowModel`), drawn as Warp's
/// vertical tab rows. Rows can be clicked, double-clicked to rename in place, right-clicked for
/// Warp's menu (S-4), dragged to reorder or out of the window, and take panes and tabs dropped
/// on them (M-4).
struct UmiSidebarTabRow: View {
    @ObservedObject var controller: TerminalController
    @ObservedObject var tab: UmiTab
    @ObservedObject var model: UmiSidebarModel
    var tick: Int = 0
    @ObservedObject private var state = UmiState.shared
    @ObservedObject private var attention = UmiAttention.shared
    @State private var hovering = false
    @State private var dropZone: UmiSidebarDrop.Zone?
    @State private var draftName = ""
    @State private var rowHeight: CGFloat = 40
    @FocusState private var nameFieldFocused: Bool

    /// What this row is renaming in place, if anything.
    private var renaming: UmiSidebarModel.RenameTarget? {
        model.renaming.flatMap { $0.tabID == tab.id ? $0 : nil }
    }

    var body: some View {
        let _ = state.revision
        let _ = attention.revision
        let _ = tick
        let row = UmiSidebarRowModel(tab: tab, in: controller)

        HStack(alignment: .top, spacing: 8) {
            icon(row)

            VStack(alignment: .leading, spacing: 1) {
                // Line 1: the folder (or the tab's name), branch, pane count, indicators.
                HStack(spacing: 4) {
                    if row.failed {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 10, weight: .semibold))
                            .frame(width: 12, height: 12)
                            .foregroundColor(UmiTheme.errorRed)
                            .help("The last command failed")
                            .accessibilityLabel("Last command failed")
                    }
                    if let renaming {
                        renameField(renaming)
                    } else {
                        Text(row.title)
                            .font(.system(size: 12))
                            .foregroundColor(UmiTheme.rowTitle)
                            .lineLimit(1)
                            .layoutPriority(1)
                    }

                    if let git = row.git, renaming == nil {
                        HStack(spacing: 3) {
                            Image(systemName: git.worktree != nil ? "square.stack.3d.up" : "arrow.triangle.branch")
                                .font(.system(size: 7.5, weight: .semibold))
                                .frame(width: 8, height: 8)
                            Text(git.worktree != nil ? "\(git.branch) · worktree" : git.branch)
                                .lineLimit(1)
                        }
                        .font(.system(size: 10))
                        .foregroundColor(git.worktree != nil ? UmiTheme.accent.opacity(0.75) : UmiTheme.rowSubtitle)
                        .help(git.worktree.map { "linked worktree \($0) · branch \(git.branch)" } ?? "branch \(git.branch)")
                    }

                    if row.paneCount > 1 {
                        Text("\(row.paneCount)")
                            .font(.system(size: 10, weight: .medium, design: .rounded))
                            .foregroundColor(UmiTheme.rowSubtitle)
                            .padding(.horizontal, 4)
                            .background(RoundedRectangle(cornerRadius: 3).fill(UmiTheme.overlay2))
                            .help("\(row.paneCount) panes")
                    }
                    Spacer(minLength: 4)

                    if row.maximized {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 9, weight: .semibold))
                            .frame(width: 12, height: 12)
                            .foregroundColor(UmiTheme.rowSubtitle)
                            .help("Maximized")
                            .accessibilityLabel("Maximized")
                    }
                    if let hint = row.hint {
                        Text(hint)
                            .font(.system(size: 12))
                            .foregroundColor(UmiTheme.rowSubtitle)
                    }
                    // Umi: Warp's link mark on a tab whose input is synchronized (L-32).
                    if UmiInputSync.shared.isSynced(tab, in: controller) {
                        Image(systemName: "link")
                            .font(.system(size: 9.5, weight: .semibold))
                            .frame(width: 12, height: 12)
                            .foregroundColor(UmiTheme.syncedInput)
                            .help("Input is synchronized across this tab's panes")
                            .accessibilityLabel("Synchronized input")
                    }

                    if hovering && renaming == nil {
                        Button { pinToggle() } label: {
                            Image(systemName: tab.pinned ? "pin.slash" : "pin")
                                .font(.system(size: 9, weight: .semibold)).frame(width: 14, height: 14)
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(UmiTheme.rowSubtitle)
                        .help(tab.pinned ? "Unpin tab" : "Pin tab")
                        Button { controller.closeTab(tab, sender: nil) } label: {
                            Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).frame(width: 14, height: 14)
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(UmiTheme.rowSubtitle)
                        .help("Close tab")
                    }
                }
                .frame(minHeight: 15)

                // Line 2: the agent's title, or what the focused pane is doing.
                detail(row)
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(background(row))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .strokeBorder(row.selected ? UmiTheme.overlay3 : .clear, lineWidth: 1)
        )
        // Warp's pin: a 16 pt diagonal pin 6 pt inside the top-right corner, hidden on hover
        // (and while ⌘ shows the tab keys there).
        .overlay(alignment: .topTrailing) {
            if tab.pinned && !hovering && row.hint == nil {
                Image(systemName: "pin.fill")
                    .font(.system(size: 10))
                    .rotationEffect(.degrees(45))
                    .frame(width: 16, height: 16)
                    .foregroundColor(UmiTheme.rowSubtitle)
                    .padding(6)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .overlay(alignment: .top) { UmiInsertionLine().opacity(dropZone == .before ? 1 : 0).offset(y: -1) }
        .overlay(alignment: .bottom) { UmiInsertionLine().opacity(dropZone == .after ? 1 : 0).offset(y: 1) }
        .background(GeometryReader { geo in
            Color.clear.onAppear { rowHeight = geo.size.height }
                .onChange(of: geo.size.height) { rowHeight = $0 }
        })
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { UmiTabMenu.beginRename(.tab(tab.id), in: controller) }
        .onTapGesture { select() }
        .gesture(DragGesture(minimumDistance: 5).onChanged { _ in
            // An AppKit drag, so a drop outside the window can make a new window (M-4).
            guard renaming == nil else { return }
            UmiTabDragSource.shared.begin(tab: tab, in: controller, title: row.title)
        })
        .onDrop(of: UmiSidebarDrop.types, delegate: UmiSidebarRowDropDelegate(
            controller: controller, tab: tab, height: rowHeight, zone: $dropZone))
        // Warp's menu, as an AppKit menu so its colors can be a row of dots.
        .overlay(UmiRowMenuCatcher { UmiTabMenu.nsMenu(UmiTabMenu.items(for: tab, in: controller)) })
        .help(row.cwd.map(UmiSidebarRowModel.abbreviate) ?? row.title)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(row.title)
        // Umi: the link mark, which the combined row element would otherwise hide (L-32).
        .accessibilityValue(UmiInputSync.shared.isSynced(tab, in: controller)
                            ? "Synchronized input · " + row.accessibilityValue : row.accessibilityValue)
        .accessibilityAddTraits(row.selected ? [.isSelected, .isButton] : .isButton)
        .onAppear { if renaming != nil { startEditing() } }
        .onChange(of: renaming) { target in if target != nil { startEditing() } }
    }

    // MARK: Pieces

    /// Warp's backgrounds: a tab color at 15% (50% selected or hovered); otherwise 10% selected
    /// and 5% hovered, over the panel's 5% (and a group's box, which carries the group's color).
    private func background(_ row: UmiSidebarRowModel) -> Color {
        let lit = row.selected || hovering || dropZone == .into
        if let color = tab.color.displayColor {
            return Color(color).opacity(lit ? 0.5 : 0.15)
        }
        if row.selected { return UmiTheme.overlay2 }
        return hovering || dropZone == .into ? UmiTheme.overlay1 : .clear
    }

    /// Warp's leading icon: a 24 pt circle at 10% with a 16 pt glyph at 90%. A tab with an agent
    /// shows the agent's mark there instead (S-3).
    @ViewBuilder
    private func icon(_ row: UmiSidebarRowModel) -> some View {
        ZStack {
            Circle().fill(UmiTheme.overlay2)
            switch row.icon {
            case .claude, .codex:
                UmiAgentMark(kind: row.agent?.kind ?? .claude)
                    .foregroundColor(Self.markColor(row.agent?.mark ?? .none))
                    .frame(width: 12, height: 12)
                    .help(row.accessibilityValue)
            case .pin, .terminal:
                Image(systemName: "terminal")
                    .font(.system(size: 11, weight: .regular))
                    .frame(width: 16, height: 16)
                    .foregroundColor(UmiTheme.rowTitle)
            }
        }
        .frame(width: 24, height: 24)
    }

    /// The agent's mark is monochrome: a little brighter when its pane finished unseen or its
    /// agent needs the user.
    static func markColor(_ mark: UmiAttention.Mark) -> Color {
        // Quiet (60%), and the row title's 90% while marked.
        mark == .none ? UmiTheme.textSecondary : UmiTheme.rowTitle
    }

    /// Line 2: Warp's 10 pt at 60%.
    @ViewBuilder
    private func detail(_ row: UmiSidebarRowModel) -> some View {
        switch row.detail {
        case .session(let title, _):
            Text(title)
                .font(.system(size: 10))
                .foregroundColor(UmiTheme.rowSubtitle)
                .lineLimit(1)
                .truncationMode(.tail)
        case .command(let text, _):
            Text(text)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(UmiTheme.rowSubtitle)
                .lineLimit(1)
                .truncationMode(.tail)
        case .folder(let path):
            Text(path)
                .font(.system(size: 10))
                .foregroundColor(UmiTheme.rowSubtitle)
                .lineLimit(1)
                .truncationMode(.head)
        }
    }

    @ViewBuilder
    private func renameField(_ target: UmiSidebarModel.RenameTarget) -> some View {
        let placeholder: String = {
            if case .pane = target { return "Pane name" }
            return "Tab name"
        }()
        TextField(placeholder, text: $draftName)
            .textFieldStyle(.plain)
            .font(.system(size: 12))
            .foregroundColor(UmiTheme.rowTitle)
            .focused($nameFieldFocused)
            .onSubmit { UmiSidebarRename.commit(target, text: draftName, in: controller) }
            .onExitCommand { UmiSidebarRename.cancel(target, in: controller) }
            .onChange(of: nameFieldFocused) { focused in
                // Focus going elsewhere (a click outside) cancels, as Warp's CancelActiveRename.
                if !focused, model.renaming == target {
                    UmiSidebarRename.cancel(target, in: controller, focusPane: false)
                }
            }
            .accessibilityLabel(placeholder)
    }

    // MARK: Actions

    private func startEditing() {
        guard let renaming else { return }
        switch renaming {
        case .tab, .group: draftName = tab.name ?? ""
        case .pane(_, let paneID): draftName = UmiState.shared.paneName(paneID) ?? ""
        }
        DispatchQueue.main.async { nameFieldFocused = true }
    }

    private func select() {
        guard renaming == nil else { return }
        UmiLayout.focusTab(tab, in: controller)
    }

    private func pinToggle() {
        let pin = !tab.pinned
        UmiLayout.undoable(pin ? "Pin Tab" : "Unpin Tab", windows: [controller]) {
            controller.setPinned(tab, pin)
        }
    }
}

/// Opens an AppKit menu on a right-click (or ⌃-click) and lets every other event through to
/// the SwiftUI row underneath.
struct UmiRowMenuCatcher: NSViewRepresentable {
    let menu: @MainActor () -> NSMenu

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.menuProvider = menu
        return view
    }

    func updateNSView(_ view: CatcherView, context: Context) {
        view.menuProvider = menu
    }

    final class CatcherView: NSView {
        var menuProvider: (@MainActor () -> NSMenu)?

        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let event = NSApp.currentEvent else { return nil }
            let rightClick = event.type == .rightMouseDown || event.type == .rightMouseUp
                || (event.type == .leftMouseDown && event.modifierFlags.contains(.control))
            return rightClick ? super.hitTest(point) : nil
        }

        override func menu(for event: NSEvent) -> NSMenu? {
            MainActor.assumeIsolated { menuProvider?() }
        }

        override func accessibilityIsIgnored() -> Bool { true }
    }
}

/// The 2 pt accent line where a dragged tab or pane would land.
struct UmiInsertionLine: View {
    var body: some View {
        Capsule()
            .fill(UmiTheme.accent.opacity(0.8))
            .frame(height: 2)
            .padding(.horizontal, 4)
            .allowsHitTesting(false)
    }
}

/// Claude's and Codex's marks, small and monochrome (they take the row's quiet colors).
struct UmiAgentMark: View {
    let kind: UmiAttention.Kind

    var body: some View {
        switch kind {
        case .claude: ClaudeMark().stroke(style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
        case .codex: CodexMark().stroke(style: StrokeStyle(lineWidth: 1.3, lineJoin: .round))
        }
    }

    /// A starburst of rays, after Claude's spark.
    private struct ClaudeMark: Shape {
        func path(in rect: CGRect) -> Path {
            var path = Path()
            let center = CGPoint(x: rect.midX, y: rect.midY)
            let outer = min(rect.width, rect.height) / 2
            let rays = 8
            for i in 0..<rays {
                let angle = Double(i) / Double(rays) * 2 * .pi - .pi / 2
                let length = i.isMultiple(of: 2) ? outer : outer * 0.78
                path.move(to: CGPoint(x: center.x + CGFloat(cos(angle)) * outer * 0.22,
                                      y: center.y + CGFloat(sin(angle)) * outer * 0.22))
                path.addLine(to: CGPoint(x: center.x + CGFloat(cos(angle)) * length,
                                         y: center.y + CGFloat(sin(angle)) * length))
            }
            return path
        }
    }

    /// A hexagon around a dot, after OpenAI's knot.
    private struct CodexMark: Shape {
        func path(in rect: CGRect) -> Path {
            var path = Path()
            let center = CGPoint(x: rect.midX, y: rect.midY)
            let r = min(rect.width, rect.height) / 2 - 0.6
            for i in 0..<6 {
                let angle = Double(i) / 6 * 2 * .pi - .pi / 2
                let point = CGPoint(x: center.x + CGFloat(cos(angle)) * r, y: center.y + CGFloat(sin(angle)) * r)
                if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
            path.closeSubpath()
            path.addEllipse(in: CGRect(x: center.x - 1, y: center.y - 1, width: 2, height: 2))
            return path
        }
    }
}

/// The drag edge on the sidebar's trailing side (S-8): Warp's 5 pt strip inside the edge.
/// Double-click goes back to the default.
struct UmiSidebarResizeEdge: View {
    @ObservedObject var controller: TerminalController
    @State private var startWidth: CGFloat?
    @State private var cursorPushed = false

    var body: some View {
        Color.clear
            .frame(width: 5)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside, !cursorPushed {
                    NSCursor.resizeLeftRight.push()
                    cursorPushed = true
                } else if !inside, cursorPushed, startWidth == nil {
                    NSCursor.pop()
                    cursorPushed = false
                }
            }
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in
                    let start = startWidth ?? controller.sidebarWidth
                    if startWidth == nil { startWidth = start }
                    let width = UmiTheme.clampSidebarWidth(start + value.translation.width,
                                                            windowWidth: controller.window?.frame.width)
                    controller.sidebarWidth = width
                    UmiState.shared.sidebarWidth = width
                }
                .onEnded { _ in
                    startWidth = nil
                    if cursorPushed {
                        NSCursor.pop()
                        cursorPushed = false
                    }
                })
            .onTapGesture(count: 2) {
                controller.sidebarWidth = UmiTheme.sidebarWidth
                UmiState.shared.sidebarWidth = UmiTheme.sidebarWidth
            }
            .onDisappear {
                if cursorPushed {
                    NSCursor.pop()
                    cursorPushed = false
                }
            }
            .accessibilityLabel("Sidebar Edge")
            .accessibilityValue("\(Int(controller.sidebarWidth))")
    }
}

/// A quiet notice at the bottom of the sidebar about updates (I-4): the countdown before an
/// update installs at a quiet moment (Not now, Install now), or, with `auto-update = check`,
/// the question when a newer version is out (nothing downloads until Download), the download,
/// and the staged update. It never takes focus or blocks anything; it stays until answered.
private struct UmiUpdateNotice: View {
    let notice: UmiUpdater.Notice

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 11))
                    .padding(.top, 1)
                Text(text)
                    .font(.system(size: 11))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .foregroundColor(UmiTheme.textSecondary)
            .accessibilityElement(children: .combine)
            buttons
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 7).fill(UmiTheme.hoverFill))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Update")
    }

    private var symbol: String {
        switch notice {
        case .asking: return "arrow.down.circle"
        case .downloading: return "arrow.down.circle.dotted"
        case .ready: return "checkmark.circle"
        case .failed: return "exclamationmark.circle"
        case .updating, .waiting: return "arrow.triangle.2.circlepath"
        }
    }

    private var text: String {
        let name = UmiPaths.productName
        switch notice {
        case .asking(let version): return "\(name) \(version) is available (you have \(UmiVersion.current))."
        case .downloading(let version): return "Downloading \(name) \(version)…"
        case .ready(let version): return "\(name) \(version) is ready. It installs when you quit."
        case .failed(let version, let reason): return "Couldn't download \(name) \(version): \(reason)"
        case .updating(let version, let seconds):
            return seconds > 0
                ? "Updating to \(name) \(version) in \(seconds) s. \(name) relaunches, with your tabs and agents."
                : "Updating to \(name) \(version)…"
        case .waiting(let version):
            return "Updating to \(name) \(version) at the next quiet moment (nothing running, nobody typing)."
        }
    }

    @ViewBuilder
    private var buttons: some View {
        switch notice {
        case .asking:
            HStack(spacing: 4) {
                noticeButton("Download", prominent: true) { answer(.download) }
                noticeButton("Later") { answer(.later) }
                noticeButton("Skip", label: "Skip This Version") { answer(.skip) }
            }
        case .ready:
            noticeButton("Install Now…", prominent: true) { UmiUpdater.shared.presentReadyPrompt() }
        case .failed:
            HStack(spacing: 4) {
                noticeButton("Try Again", prominent: true) { answer(.download) }
                noticeButton("Later") { answer(.later) }
            }
        case .updating(_, let seconds) where seconds == 0:
            EmptyView()
        case .updating, .waiting:
            // The same buttons in both: a click on one stops the countdown (it's activity) and
            // the notice changes its words under the pointer, but the button still gets the click.
            HStack(spacing: 4) {
                noticeButton("Not now") { answer(.notNow) }
                noticeButton("Install now", prominent: true) {
                    Task { @MainActor in
                        do {
                            _ = try await UmiUpdater.shared.answer(.installNow)
                        } catch {
                            // Something runs now: say what installing would interrupt, and ask.
                            UmiUpdater.shared.presentReadyPrompt()
                        }
                    }
                }
            }
        case .downloading:
            EmptyView()
        }
    }

    private func answer(_ answer: UmiUpdater.Answer) {
        Task { @MainActor in _ = try? await UmiUpdater.shared.answer(answer) }
    }

    private func noticeButton(_ title: String, label: String? = nil, prominent: Bool = false,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: prominent ? .semibold : .regular))
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .contentShape(Rectangle())
        }
        .buttonStyle(UmiNoticeButtonStyle(prominent: prominent))
        .focusable(false)
        .accessibilityLabel(label ?? title)
    }
}

private struct UmiNoticeButtonStyle: ButtonStyle {
    let prominent: Bool

    func makeBody(configuration: Configuration) -> some View {
        UmiNoticeButtonBody(configuration: configuration, prominent: prominent)
    }
}

private struct UmiNoticeButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let prominent: Bool
    @State private var hovering = false

    var body: some View {
        configuration.label
            .foregroundColor(prominent || hovering ? UmiTheme.textPrimary : UmiTheme.textSecondary)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(configuration.isPressed || hovering ? UmiTheme.textPrimary.opacity(0.14)
                          : (prominent ? UmiTheme.textPrimary.opacity(0.09) : .clear))
            )
            .onHover { hovering = $0 }
    }
}
