import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

/// The left sidebar: Warp-style vertical tabs and a project explorer. No cards, borders or
/// "agents" section: rows sit directly on the terminal background with a subtle hover and
/// selection tint (S-1, S-2).
struct TernSidebar: View {
    @ObservedObject var controller: TerminalController
    /// Height of the titlebar band above the sidebar content (traffic lights).
    let topInset: CGFloat

    @ObservedObject private var state = TernState.shared
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
            .onDrop(of: [UTType.plainText], isTargeted: $listDropTargeted) { providers in
                TernTabDrag.receive(providers) { tab, source in
                    // Dropped below the rows: the end of this window's tabs.
                    _ = try? TernLayout.move(tab: tab, from: source, toWindow: controller,
                                             index: controller.tabs.count + 1, newWindow: false, focus: true)
                }
            }

            if let notice = updater.sidebarNotice {
                TernUpdateNotice(text: notice)
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
    }
}

/// Drag and drop of tab rows, within a window and between windows (M-4).
@MainActor
enum TernTabDrag {
    static let prefix = "tern-tab:"

    static func provider(for tab: TernTab) -> NSItemProvider {
        NSItemProvider(object: (prefix + tab.idString) as NSString)
    }

    static func receive(_ providers: [NSItemProvider], perform: @escaping @MainActor (TernTab, TerminalController) -> Void) -> Bool {
        guard let provider = providers.first(where: { $0.canLoadObject(ofClass: NSString.self) }) else { return false }
        _ = provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let string = object as? String, string.hasPrefix(prefix) else { return }
            let id = String(string.dropFirst(prefix.count))
            DispatchQueue.main.async {
                for window in TernTopology.windows {
                    if let tab = window.tabs.first(where: { $0.idString == id }) {
                        perform(tab, window)
                        return
                    }
                }
            }
        }
        return true
    }
}

/// One tab in the sidebar, on two lines (S-3):
///   1. the tab's name (or the focused pane's folder) and its git branch / linked worktree,
///      a pane count when split, and pin and close affordances;
///   2. what the focused pane is doing: the command it is running or last ran, or the
///      state of an agent launched in it.
struct TernSidebarTabRow: View {
    @ObservedObject var controller: TerminalController
    @ObservedObject var tab: TernTab
    var tick: Int = 0
    @ObservedObject private var state = TernState.shared
    @State private var hovering = false
    @State private var dropTargeted = false
    @State private var editing = false
    @State private var draftName = ""
    @FocusState private var nameFieldFocused: Bool

    var body: some View {
        let _ = state.revision
        let _ = tick
        let selected = tab === controller.selectedTab
        let tree = controller.tree(of: tab)
        let panes = tree.root?.leaves() ?? []
        let focusedPane = (selected ? controller.focusedSurface.flatMap { panes.contains($0) ? $0 : nil } : nil)
            ?? tab.effectiveFocusedSurface
        let cwd = focusedPane.map(TernTopology.cwd(of:)).flatMap { $0.isEmpty ? nil : $0 }
        let git = cwd.flatMap { TernPaneContext.git(for: $0) }
        let primary = tab.name.flatMap { $0.isEmpty ? nil : $0 } ?? cwd.map(TernPaneContext.folderName) ?? tab.title
        let interactive = focusedPane.flatMap { state.interactiveAgents[$0.id] }
        let command = interactive == nil ? focusedPane.flatMap { TernPaneContext.command(for: $0) } : nil

        HStack(alignment: .top, spacing: 7) {
            Group {
                if let color = tab.color.displayColor {
                    Circle().fill(Color(color)).frame(width: 7, height: 7)
                } else if tab.pinned {
                    Image(systemName: "pin.fill").font(.system(size: 8.5))
                        .foregroundColor(TernTheme.textTertiary)
                } else {
                    Image(systemName: "terminal").font(.system(size: 10, weight: .medium))
                        .foregroundColor(TernTheme.textTertiary)
                }
            }
            .frame(width: 14, height: 17)

            VStack(alignment: .leading, spacing: 2) {
                // Line 1: name/folder, branch, pane count, affordances.
                HStack(spacing: 6) {
                    if editing {
                        TextField("Tab name", text: $draftName, onCommit: commitRename)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12.5, weight: .semibold))
                            .focused($nameFieldFocused)
                            .onExitCommand { editing = false }
                    } else {
                        Text(primary)
                            .font(.system(size: 12.5, weight: selected ? .semibold : .regular))
                            .foregroundColor(selected ? TernTheme.textPrimary : TernTheme.textSecondary)
                            .lineLimit(1)
                            .layoutPriority(1)
                    }

                    if let git, !editing {
                        HStack(spacing: 3) {
                            Image(systemName: git.worktree != nil ? "square.stack.3d.up" : "arrow.triangle.branch")
                                .font(.system(size: 8.5, weight: .semibold))
                            Text(git.worktree != nil ? "\(git.branch) · worktree" : git.branch)
                                .lineLimit(1)
                        }
                        .font(.system(size: 11))
                        .foregroundColor(git.worktree != nil ? TernTheme.accent.opacity(0.85) : TernTheme.textTertiary)
                        .help(git.worktree.map { "linked worktree \($0) · branch \(git.branch)" } ?? "branch \(git.branch)")
                    }

                    if panes.count > 1 {
                        Text("\(panes.count)")
                            .font(.system(size: 10, weight: .medium, design: .rounded))
                            .foregroundColor(TernTheme.textTertiary)
                            .padding(.horizontal, 4)
                            .background(RoundedRectangle(cornerRadius: 3).fill(TernTheme.hoverFill))
                            .help("\(panes.count) panes")
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

                // Line 2: what the focused pane is doing.
                if let interactive {
                    HStack(spacing: 5) {
                        Circle().fill(interactive.running ? TernTheme.accent : TernTheme.textTertiary)
                            .frame(width: 5, height: 5)
                        Text("\(interactive.kind) · \(interactive.running ? "running" : "exited")")
                            .font(.system(size: 11))
                            .foregroundColor(TernTheme.textTertiary)
                            .lineLimit(1)
                    }
                } else if let command {
                    HStack(spacing: 4) {
                        if command.running {
                            Image(systemName: "play.fill")
                                .font(.system(size: 6))
                                .foregroundColor(TernTheme.accent)
                        }
                        Text(command.text)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(command.running ? TernTheme.textSecondary : TernTheme.textTertiary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                } else {
                    Text(cwd.map(abbreviate) ?? "shell")
                        .font(.system(size: 11))
                        .foregroundColor(TernTheme.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(selected ? TernTheme.selectedFill : (hovering || dropTargeted ? TernTheme.hoverFill : .clear))
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { beginRename() }
        .onTapGesture { select() }
        .onDrag { TernTabDrag.provider(for: tab) }
        .onDrop(of: [UTType.plainText], isTargeted: $dropTargeted) { providers in
            TernTabDrag.receive(providers) { dragged, source in
                guard dragged !== tab, let index = controller.index(of: tab) else { return }
                _ = try? TernLayout.move(tab: dragged, from: source, toWindow: controller,
                                         index: index + 1, newWindow: false, focus: true)
            }
        }
        .contextMenu { menu }
        .help(cwd.map(abbreviate) ?? primary)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(primary)
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
    }

    private func abbreviate(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    @ViewBuilder
    private var menu: some View {
        Button("Rename Tab…") { beginRename() }
        Button(tab.pinned ? "Unpin Tab" : "Pin Tab") { pinToggle() }
        Menu("Tab Color") {
            ForEach(TerminalTabColor.allCases, id: \.self) { color in
                Button(color.localizedName) {
                    tab.color = color
                    TernState.shared.layoutDidChange()
                }
            }
        }
        Divider()
        Button("Move Tab to New Window") {
            _ = try? TernLayout.move(tab: tab, from: controller, toWindow: nil, index: nil, newWindow: true, focus: true)
        }
        let others = TernTopology.windows.filter { $0 !== controller }
        if !others.isEmpty {
            Menu("Move Tab to Window") {
                ForEach(others, id: \.ternID) { window in
                    Button("Window \(TernTopology.windowNumber(window)): \(window.selectedTab.title)") {
                        _ = try? TernLayout.move(tab: tab, from: controller, toWindow: window, index: nil,
                                                 newWindow: false, focus: true)
                    }
                }
            }
        }
        Divider()
        Button("Close Tab") { controller.closeTab(tab, sender: nil) }
    }

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
        let name = draftName.trimmingCharacters(in: .whitespaces)
        tab.name = name.isEmpty ? nil : name
        if tab === controller.selectedTab { controller.titleOverride = tab.name }
        TernEvents.shared.emit("tab.renamed", ["tab": tab.idString, "name": name, "window": controller.ternIDString])
        TernState.shared.layoutDidChange()
    }
}

/// A quiet line at the bottom of the sidebar when an update is ready.
private struct TernUpdateNotice: View {
    let text: String
    @State private var hovering = false

    var body: some View {
        Button {
            TernUpdater.shared.presentReadyPrompt()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.down.circle")
                    .font(.system(size: 11))
                Text(text)
                    .font(.system(size: 11))
                    .lineLimit(2)
                Spacer(minLength: 0)
            }
            .foregroundColor(hovering ? TernTheme.textPrimary : TernTheme.textSecondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 7).fill(TernTheme.hoverFill))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(text)
    }
}
