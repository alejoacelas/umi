import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

/// The left sidebar: Warp-style vertical tabs and a project explorer. No cards, borders or
/// "agents" section: rows sit directly on the terminal background with a subtle hover and
/// selection tint (S-1, S-2). Its width is per window, dragged at its edge (S-8).
struct TernSidebar: View {
    @ObservedObject var controller: TerminalController
    /// Height of the titlebar band above the sidebar content (traffic lights).
    let topInset: CGFloat

    @ObservedObject private var state = TernState.shared
    @ObservedObject private var attention = TernAttention.shared
    @ObservedObject private var updater = TernUpdater.shared
    @StateObject private var files = TernFileTreeModel()
    /// Periodic refresh for things nothing publishes (running command, branch).
    @State private var tick = 0
    @State private var listDropTargeted = false
    private let refresh = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear.frame(height: topInset)

            modeBar
                .padding(.horizontal, 10)
                .padding(.bottom, 8)

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 1) {
                    switch state.sidebarMode {
                    case .tabs: tabsList
                    case .files: TernFileTreeView(model: files, hostWindow: controller.window)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 12)
            }
            // Dropped below the rows: a tab goes to the end of this window's tabs, a pane
            // becomes a new tab there (M-4).
            .onDrop(of: TernSidebarDrop.types, delegate: TernSidebarListDropDelegate(
                controller: controller, targeted: $listDropTargeted))

            if let notice = updater.notice {
                TernUpdateNotice(notice: notice)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Sidebar")
        .onChange(of: state.sidebarMode) { _ in syncFileTree() }
        .onAppear { syncFileTree() }
        .onDisappear { files.stop() }
        .onReceive(refresh) { _ in
            if state.sidebarMode == .tabs { tick &+= 1 }
        }
    }

    // MARK: Mode bar

    private var modeBar: some View {
        HStack(spacing: 2) {
            modeButton(.tabs, symbol: "rectangle.stack", help: "Tabs")
            modeButton(.files, symbol: "folder", help: "Project Explorer (⇧⌘E)")
            Spacer()
            Button {
                _ = try? TernLayout.newTab(in: controller, options: .init(), tabName: nil, color: .none,
                                           index: nil, focus: true, inheritFrom: nil)
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 26, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(TernIconButtonStyle(size: 22))
            .help("New Tab (⌘T)")
            .accessibilityLabel("New Tab")
        }
    }

    private func modeButton(_ mode: TernState.SidebarMode, symbol: String, help: String) -> some View {
        Button { state.sidebarMode = mode } label: {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 26, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(TernIconButtonStyle(active: state.sidebarMode == mode, size: 22))
        .help(help)
        .accessibilityLabel(mode == .tabs ? "Tabs" : "Files")
    }

    private func syncFileTree() {
        if state.sidebarMode == .files {
            files.start { [weak controller] in controller?.window }
        } else {
            files.stop()
        }
    }

    // MARK: Tabs

    @ViewBuilder
    private var tabsList: some View {
        let _ = state.revision
        let _ = attention.revision
        let tabs = controller.tabs
        let pinned = tabs.filter(\.pinned)
        let others = tabs.filter { !$0.pinned }

        if !pinned.isEmpty {
            ForEach(pinned) { tab in
                TernSidebarTabRow(controller: controller, tab: tab, tick: tick)
            }
            Rectangle().fill(TernTheme.hairline).frame(height: 1)
                .padding(.horizontal, 8).padding(.vertical, 5)
        }
        ForEach(others) { tab in
            TernSidebarTabRow(controller: controller, tab: tab, tick: tick)
        }
        // Where a drop below the rows lands.
        TernInsertionLine().opacity(listDropTargeted ? 1 : 0)
    }
}

// MARK: - Row model

/// What a tab's row shows (S-3). The view and `debug.sidebar.rows` both read it.
///
/// Line 1 is the tab's folder (the focused pane's), or the name the user gave the tab, with the
/// git branch (a linked worktree shown differently), a pane count when split, and pin and
/// close on hover. Line 2 is the title of the tab's agent session when it has one, with the
/// agent's mark as the row icon; otherwise what the focused pane is doing (the command it is
/// running or last ran, an agent typed into it), else its folder's path.
@MainActor
struct TernSidebarRowModel {
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

    let tab: TernTab
    let selected: Bool
    let paneCount: Int
    let focusedPane: Ghostty.SurfaceView?
    let cwd: String?
    let git: TernPaneContext.Git?
    let title: String
    let agent: TernAttention.Agent?
    let detail: Detail

    init(tab: TernTab, in controller: TerminalController) {
        self.tab = tab
        selected = tab === controller.selectedTab
        let panes = controller.tree(of: tab).root?.leaves() ?? []
        paneCount = panes.count
        let focusedPane = (selected ? controller.focusedSurface.flatMap { panes.contains($0) ? $0 : nil } : nil)
            ?? tab.effectiveFocusedSurface
        self.focusedPane = focusedPane
        let cwd = focusedPane.map(TernTopology.cwd(of:)).flatMap { $0.isEmpty ? nil : $0 }
        self.cwd = cwd
        git = cwd.flatMap { TernPaneContext.git(for: $0) }
        title = tab.name.flatMap { $0.isEmpty ? nil : $0 } ?? cwd.map(TernPaneContext.folderName) ?? tab.title
        let agent = TernAttention.shared.agent(for: tab, in: controller)
        self.agent = agent
        if let agent {
            detail = .session(title: agent.title.isEmpty ? Self.describe(agent.status) : agent.title, status: agent.status)
        } else if let command = focusedPane.flatMap({ TernPaneContext.command(for: $0) }) {
            detail = .command(text: command.text, running: command.running)
        } else {
            detail = .folder(cwd.map(Self.abbreviate) ?? "shell")
        }
    }

    var icon: Icon {
        switch agent?.kind {
        case .claude: return .claude
        case .codex: return .codex
        case nil: return tab.pinned ? .pin : .terminal
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
        guard let agent else { return detail.text }
        var parts = [agent.kind.rawValue, Self.describe(agent.status)]
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

    func json() -> [String: Any] {
        var json: [String: Any] = [
            "tab": tab.idString, "selected": selected, "pinned": tab.pinned, "panes": paneCount,
            "line1": title, "line2": detail.text, "icon": icon.rawValue, "mark": markName,
            "color": TernTopology.colorName(tab.color),
        ]
        if let git {
            json["branch"] = git.branch
            if let worktree = git.worktree { json["worktree"] = worktree }
        }
        if let agent {
            json["agent"] = ["kind": agent.kind.rawValue, "status": agent.status, "title": agent.title,
                             "session": agent.session ?? "", "live": agent.live]
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

/// One tab in the sidebar, on two lines (S-3; see `TernSidebarRowModel`). Rows can be
/// clicked, double-clicked to rename, right-clicked for Warp's menu (S-4), dragged to reorder
/// or out of the window, and take panes and tabs dropped on them (M-4).
struct TernSidebarTabRow: View {
    @ObservedObject var controller: TerminalController
    @ObservedObject var tab: TernTab
    var tick: Int = 0
    @ObservedObject private var state = TernState.shared
    @ObservedObject private var attention = TernAttention.shared
    @State private var hovering = false
    @State private var dropZone: TernSidebarDrop.Zone?
    @State private var editing = false
    @State private var draftName = ""
    @State private var rowHeight: CGFloat = 40
    @FocusState private var nameFieldFocused: Bool

    var body: some View {
        let _ = state.revision
        let _ = attention.revision
        let _ = tick
        let row = TernSidebarRowModel(tab: tab, in: controller)

        HStack(alignment: .top, spacing: 7) {
            icon(row)
                .frame(width: 14, height: 17)

            VStack(alignment: .leading, spacing: 2) {
                // Line 1: the folder (or the tab's name), branch, pane count, affordances.
                HStack(spacing: 6) {
                    if editing {
                        TextField("Tab name", text: $draftName, onCommit: commitRename)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12.5, weight: .semibold))
                            .focused($nameFieldFocused)
                            .onExitCommand { editing = false }
                    } else {
                        Text(row.title)
                            .font(.system(size: 12.5, weight: row.selected ? .semibold : .regular))
                            .foregroundColor(row.selected ? TernTheme.textPrimary : TernTheme.textSecondary)
                            .lineLimit(1)
                            .layoutPriority(1)
                    }

                    if let git = row.git, !editing {
                        HStack(spacing: 3) {
                            Image(systemName: git.worktree != nil ? "square.stack.3d.up" : "arrow.triangle.branch")
                                .font(.system(size: 8.5, weight: .semibold))
                            Text(git.worktree != nil ? "\(git.branch) · worktree" : git.branch)
                                .lineLimit(1)
                        }
                        .font(.system(size: 11))
                        .foregroundColor(git.worktree != nil ? TernTheme.accent.opacity(0.75) : TernTheme.textTertiary)
                        .help(git.worktree.map { "linked worktree \($0) · branch \(git.branch)" } ?? "branch \(git.branch)")
                    }

                    if row.paneCount > 1 {
                        Text("\(row.paneCount)")
                            .font(.system(size: 10, weight: .medium, design: .rounded))
                            .foregroundColor(TernTheme.textTertiary)
                            .padding(.horizontal, 4)
                            .background(RoundedRectangle(cornerRadius: 3).fill(TernTheme.hoverFill))
                            .help("\(row.paneCount) panes")
                    }
                    Spacer(minLength: 4)

                    if hovering && !editing {
                        Button { pinToggle() } label: {
                            Image(systemName: tab.pinned ? "pin.slash" : "pin")
                                .font(.system(size: 9, weight: .semibold)).frame(width: 14, height: 14)
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(TernTheme.textTertiary)
                        .help(tab.pinned ? "Unpin tab" : "Pin tab")
                        Button { controller.closeTab(tab, sender: nil) } label: {
                            Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).frame(width: 14, height: 14)
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(TernTheme.textTertiary)
                        .help("Close tab")
                    }
                }

                // Line 2: the session's title, or what the focused pane is doing.
                detail(row)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(background(row))
        )
        .overlay(alignment: .top) { TernInsertionLine().opacity(dropZone == .before ? 1 : 0).offset(y: -1) }
        .overlay(alignment: .bottom) { TernInsertionLine().opacity(dropZone == .after ? 1 : 0).offset(y: 1) }
        .background(GeometryReader { geo in
            Color.clear.onAppear { rowHeight = geo.size.height }
                .onChange(of: geo.size.height) { rowHeight = $0 }
        })
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { beginRename() }
        .onTapGesture { select() }
        .gesture(DragGesture(minimumDistance: 5).onChanged { _ in
            // An AppKit drag, so a drop outside the window can make a new window (M-4).
            guard !editing else { return }
            TernTabDragSource.shared.begin(tab: tab, in: controller, title: row.title)
        })
        .onDrop(of: TernSidebarDrop.types, delegate: TernSidebarRowDropDelegate(
            controller: controller, tab: tab, height: rowHeight, zone: $dropZone))
        .contextMenu { TernTabMenuView(items: TernTabMenu.items(for: tab, in: controller, row: row, rename: beginRename)) }
        .help(row.cwd.map(TernSidebarRowModel.abbreviate) ?? row.title)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(row.title)
        .accessibilityValue(row.accessibilityValue)
        .accessibilityAddTraits(row.selected ? [.isSelected, .isButton] : .isButton)
    }

    // MARK: Pieces

    private func background(_ row: TernSidebarRowModel) -> Color {
        let lit = row.selected || hovering || dropZone == .into
        // A tab color tints its row, quietly (as Warp does).
        if let color = tab.color.displayColor {
            return Color(color).opacity(lit ? 0.16 : 0.08)
        }
        if row.selected { return TernTheme.selectedFill }
        return hovering || dropZone == .into ? TernTheme.hoverFill : .clear
    }

    @ViewBuilder
    private func icon(_ row: TernSidebarRowModel) -> some View {
        switch row.icon {
        case .claude, .codex:
            TernAgentMark(kind: row.agent?.kind ?? .claude)
                .foregroundColor(Self.markColor(row.agent?.mark ?? .none))
                .frame(width: 11, height: 11)
                .help(row.accessibilityValue)
        case .pin:
            Image(systemName: "pin.fill").font(.system(size: 8.5))
                .foregroundColor(TernTheme.textTertiary)
        case .terminal:
            Image(systemName: "terminal").font(.system(size: 10, weight: .medium))
                .foregroundColor(TernTheme.textTertiary)
        }
    }

    /// The agent's icon takes a quiet color when its session finished unseen or needs the
    /// user; otherwise it is as quiet as the rest of the chrome.
    static func markColor(_ mark: TernAttention.Mark) -> Color {
        switch mark {
        case .none: return TernTheme.textTertiary
        case .finished: return TernTheme.accent.opacity(0.85)
        case .needsYou: return Color(red: 0.93, green: 0.66, blue: 0.30).opacity(0.9)
        }
    }

    @ViewBuilder
    private func detail(_ row: TernSidebarRowModel) -> some View {
        switch row.detail {
        case .session(let title, let status):
            Text(title)
                .font(.system(size: 11))
                .foregroundColor(status == "working" ? TernTheme.textSecondary : TernTheme.textTertiary)
                .lineLimit(1)
                .truncationMode(.tail)
        case .command(let text, let running):
            HStack(spacing: 4) {
                if running {
                    Image(systemName: "play.fill")
                        .font(.system(size: 6))
                        .foregroundColor(TernTheme.accent)
                }
                Text(text)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(running ? TernTheme.textSecondary : TernTheme.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        case .folder(let path):
            Text(path)
                .font(.system(size: 11))
                .foregroundColor(TernTheme.textTertiary)
                .lineLimit(1)
                .truncationMode(.head)
        }
    }

    // MARK: Actions

    private func select() {
        guard !editing else { return }
        TernLayout.focusTab(tab, in: controller)
    }

    private func pinToggle() {
        let pin = !tab.pinned
        TernLayout.undoable(pin ? "Pin Tab" : "Unpin Tab", windows: [controller]) {
            controller.setPinned(tab, pin)
        }
    }

    private func beginRename() {
        draftName = tab.name ?? ""
        editing = true
        DispatchQueue.main.async { nameFieldFocused = true }
    }

    private func commitRename() {
        editing = false
        TernTabMenu.rename(tab, in: controller, to: draftName)
    }
}

/// The 2 pt accent line where a dragged tab or pane would land.
struct TernInsertionLine: View {
    var body: some View {
        Capsule()
            .fill(TernTheme.accent.opacity(0.8))
            .frame(height: 2)
            .padding(.horizontal, 4)
            .allowsHitTesting(false)
    }
}

/// Claude's and Codex's marks, small and monochrome (they take the row's quiet colors).
struct TernAgentMark: View {
    let kind: TernAttention.Kind

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

/// The drag edge on the sidebar's trailing side (S-8). Double-click goes back to the default.
struct TernSidebarResizeEdge: View {
    @ObservedObject var controller: TerminalController
    @State private var startWidth: CGFloat?
    @State private var cursorPushed = false

    var body: some View {
        Color.clear
            .frame(width: 7)
            .contentShape(Rectangle())
            .offset(x: 3)
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
                    let width = TernTheme.clampSidebarWidth(start + value.translation.width,
                                                            windowWidth: controller.window?.frame.width)
                    controller.sidebarWidth = width
                    TernState.shared.sidebarWidth = width
                }
                .onEnded { _ in
                    startWidth = nil
                    if cursorPushed {
                        NSCursor.pop()
                        cursorPushed = false
                    }
                })
            .onTapGesture(count: 2) {
                controller.sidebarWidth = TernTheme.sidebarWidth
                TernState.shared.sidebarWidth = TernTheme.sidebarWidth
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

/// A quiet notice at the bottom of the sidebar about updates (I-4): the question when a
/// newer version is out (nothing downloads until Download), the download, and the staged
/// update. It never takes focus or blocks anything; it stays until answered.
private struct TernUpdateNotice: View {
    let notice: TernUpdater.Notice

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
            .foregroundColor(TernTheme.textSecondary)
            .accessibilityElement(children: .combine)
            buttons
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 7).fill(TernTheme.hoverFill))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Update")
    }

    private var symbol: String {
        switch notice {
        case .asking: return "arrow.down.circle"
        case .downloading: return "arrow.down.circle.dotted"
        case .ready: return "checkmark.circle"
        case .failed: return "exclamationmark.circle"
        }
    }

    private var text: String {
        let name = TernPaths.productName
        switch notice {
        case .asking(let version): return "\(name) \(version) is available (you have \(TernVersion.current))."
        case .downloading(let version): return "Downloading \(name) \(version)…"
        case .ready(let version): return "\(name) \(version) is ready. It installs when you quit."
        case .failed(let version, let reason): return "Couldn't download \(name) \(version): \(reason)"
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
            noticeButton("Install Now…", prominent: true) { TernUpdater.shared.presentReadyPrompt() }
        case .failed:
            HStack(spacing: 4) {
                noticeButton("Try Again", prominent: true) { answer(.download) }
                noticeButton("Later") { answer(.later) }
            }
        case .downloading:
            EmptyView()
        }
    }

    private func answer(_ answer: TernUpdater.Answer) {
        Task { @MainActor in _ = try? await TernUpdater.shared.answer(answer) }
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
        .buttonStyle(TernNoticeButtonStyle(prominent: prominent))
        .focusable(false)
        .accessibilityLabel(label ?? title)
    }
}

private struct TernNoticeButtonStyle: ButtonStyle {
    let prominent: Bool

    func makeBody(configuration: Configuration) -> some View {
        TernNoticeButtonBody(configuration: configuration, prominent: prominent)
    }
}

private struct TernNoticeButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let prominent: Bool
    @State private var hovering = false

    var body: some View {
        configuration.label
            .foregroundColor(prominent || hovering ? TernTheme.textPrimary : TernTheme.textSecondary)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(configuration.isPressed || hovering ? TernTheme.textPrimary.opacity(0.14)
                          : (prominent ? TernTheme.textPrimary.opacity(0.09) : .clear))
            )
            .onHover { hovering = $0 }
    }
}
