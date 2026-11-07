import AppKit
import SwiftUI
import GhosttyKit

/// Panes that share one place in a tab's split tree, like tabs inside a pane (M-7). The tree
/// holds the member on show; the others keep running, occluded, until the user switches to them
/// (the strip of names along the top of the place, ⌘[ / ⌘], or the CLI).
@MainActor
final class UmiPaneStack: ObservableObject, Identifiable {
    let id = UUID()
    /// In strip order.
    @Published var members: [Ghostty.SurfaceView]

    init(members: [Ghostty.SurfaceView]) { self.members = members }
}

@MainActor
extension TerminalController {
    /// Stack members of a tab that aren't on show.
    func hiddenPanes(of tab: UmiTab) -> [Ghostty.SurfaceView] {
        let tree = tree(of: tab)
        return tab.stacks.flatMap { $0.members.filter { !tree.contains($0) } }
    }

    /// The member of a stack that the tab shows.
    func shownMember(of stack: UmiPaneStack, in tab: UmiTab) -> Ghostty.SurfaceView? {
        let tree = tree(of: tab)
        return stack.members.first { tree.contains($0) }
    }

    /// `tree` without `node`. When the node is the shown member of a stack, the next member takes
    /// its place instead (and is returned), so a stack's place outlives any one member. The
    /// removed pane leaves its stack; a stack left with one member dissolves.
    func umiRemoving(_ node: SplitTree<Ghostty.SurfaceView>.Node, from tree: SplitTree<Ghostty.SurfaceView>,
                     in tab: UmiTab) -> (tree: SplitTree<Ghostty.SurfaceView>, replacement: Ghostty.SurfaceView?) {
        guard case .leaf(let view) = node, let stack = tab.stack(of: view),
              let index = stack.members.firstIndex(where: { $0 === view }) else {
            return (tree.removing(node), nil)
        }
        stack.members.remove(at: index)
        let replacement = stack.members.isEmpty ? nil : stack.members[min(index, stack.members.count - 1)]
        if stack.members.count <= 1 { tab.stacks.removeAll { $0 === stack } }
        guard let replacement, let replaced = try? tree.replacing(node: node, with: .leaf(view: replacement)) else {
            return (tree.removing(node), nil)
        }
        setOccluded([replacement], occluded: tab !== selectedTab)
        return (replaced, replacement)
    }

    /// Change a tab's tree and stacks as one undoable step. `stacks` are the tab's stacks after the
    /// change, each with its members in strip order (an existing stack object keeps its identity).
    /// Undo puts both back; panes it takes out of the tab stay alive for redo, as Ghostty keeps an
    /// undone split's pane.
    func replaceLayout(_ newTree: SplitTree<Ghostty.SurfaceView>, stacks: [(UmiPaneStack, [Ghostty.SurfaceView])],
                       for tab: UmiTab, undoAction: String) {
        let oldTree = tree(of: tab)
        let oldStacks = tab.stacks.map { ($0, $0.members) }
        let before = (oldTree.root?.leaves() ?? []) + oldStacks.flatMap(\.1)
        let lostFocus = tab === selectedTab && focusedSurface.map { !newTree.contains($0) } ?? false
        for (stack, members) in stacks { stack.members = members }
        tab.stacks = stacks.map(\.0)
        setTree(newTree, for: tab)
        // Only the panes on show draw; members waiting in a stack, and panes taken out, don't.
        let onShow = newTree.root?.leaves() ?? []
        setOccluded(before.filter { pane in !onShow.contains { $0 === pane } }, occluded: true)
        if tab === selectedTab { setOccluded(onShow, occluded: false) }
        if tab.focusedSurface.map({ !newTree.contains($0) }) ?? false {
            tab.focusedSurface = UmiFocusHistory.mostRecent(among: onShow) ?? onShow.first
        }
        if lostFocus, let next = tab.focusedSurface {
            DispatchQueue.main.async { Ghostty.moveFocus(to: next) }
        }
        UmiState.shared.layoutDidChange()
        guard let undoManager else { return }
        undoManager.setActionName(undoAction)
        undoManager.registerUndo(withTarget: self, expiresAfter: undoExpiration) { target in
            guard !target.isClosed, target.tabs.contains(where: { $0 === tab }) else { return }
            target.replaceLayout(oldTree, stacks: oldStacks, for: tab, undoAction: undoAction)
        }
    }

    /// A stack member that isn't on show went away (its program ended, or it was closed).
    func removeHiddenMember(_ view: Ghostty.SurfaceView, from tab: UmiTab) {
        guard let stack = tab.stack(of: view), !tree(of: tab).contains(view) else { return }
        stack.members.removeAll { $0 === view }
        if stack.members.count <= 1 { tab.stacks.removeAll { $0 === stack } }
        UmiEvents.shared.emit("pane.closed", ["pane": view.umiID, "tab": tab.idString, "window": umiIDString])
        UmiState.shared.layoutDidChange()
    }
}

@MainActor
enum UmiStacks {
    /// Put `pane` on `target`'s place: the two (or `pane` and target's stack) share it, with
    /// `pane` on show and focused. `pane` leaves wherever it was (another tab or window too).
    @discardableResult
    static func stack(_ pane: Ghostty.SurfaceView, onto target: Ghostty.SurfaceView, focus: Bool = true) throws -> UmiTopology.Location {
        guard pane !== target else { throw UmiError.badRequest("can't stack a pane on itself") }
        guard let destination = UmiTopology.locate(target) else { throw UmiError.notFound("the target pane isn't in a window") }
        if let stack = destination.tab.stack(of: target), stack.members.contains(where: { $0 === pane }) {
            try show(pane)
            return UmiTopology.Location(window: destination.window, tab: destination.tab, pane: pane)
        }
        // A target waiting in its stack: stack onto the member on show.
        let window = destination.window
        let tab = destination.tab
        let shownTarget: Ghostty.SurfaceView
        if window.tree(of: tab).contains(target) {
            shownTarget = target
        } else if let stack = tab.stack(of: target), let shown = window.shownMember(of: stack, in: tab) {
            shownTarget = shown
        } else {
            throw UmiError.notFound("the target pane isn't in its tab")
        }

        try UmiLayout.undoable("Stack Pane", windows: [window] + (UmiTopology.locate(pane).map { [$0.window] } ?? [])) {
            // Bring the pane beside the target first (from anywhere; its old place closes or is
            // taken by its stack's next member), then into the target's place.
            if UmiTopology.locate(pane)?.tab !== tab || !window.tree(of: tab).contains(pane) {
                try UmiLayout.move(pane, to: .besidePane(shownTarget, .right), focus: false)
            }
            let tree = window.tree(of: tab)
            guard let paneNode = tree.root?.node(view: pane) else { throw UmiError.failed("the pane didn't arrive") }
            let without = tree.removing(paneNode)
            guard let targetNode = without.root?.node(view: shownTarget) else { throw UmiError.failed("the target went away") }
            let stacked = try without.replacing(node: targetNode, with: .leaf(view: pane))
            if let stack = tab.stack(of: shownTarget) {
                let at = (stack.members.firstIndex { $0 === shownTarget } ?? stack.members.count - 1) + 1
                stack.members.insert(pane, at: at)
            } else {
                tab.stacks.append(UmiPaneStack(members: [shownTarget, pane]))
            }
            window.setTree(SplitTree(root: stacked.root, zoomed: nil), for: tab)
            window.setOccluded([shownTarget], occluded: true)
        }
        UmiEvents.shared.emit("pane.stacked", ["pane": pane.umiID, "onto": shownTarget.umiID,
                                               "tab": tab.idString, "window": window.umiIDString])
        if focus { UmiLayout.focusPane(pane, activate: true) }
        UmiState.shared.layoutDidChange()
        return UmiTopology.Location(window: window, tab: tab, pane: pane)
    }

    /// How many places a tab shows (a stack counts once). A new pane in a tab that already shows
    /// this many joins a stack instead of taking a place of its own (E-9, M-7).
    static let placesPerTab = 3

    /// Whether a new pane in `tab` joins a stack: the tab already shows `placesPerTab` places.
    static func isFull(_ tab: UmiTab, in window: TerminalController) -> Bool {
        (window.tree(of: tab).root?.leaves().count ?? 0) >= placesPerTab
    }

    /// A new pane for `target`'s place, sized to it and not yet in any tree or stack.
    private static func makePane(for target: Ghostty.SurfaceView, options: UmiLayout.PaneOptions,
                                 config: Ghostty.SurfaceConfiguration?) throws -> Ghostty.SurfaceView {
        let ghostty = try UmiLayout.requireGhostty()
        guard let app = ghostty.app else { throw UmiError.failed("the terminal engine isn't ready") }
        let config = try config ?? UmiLayout.surfaceConfig(options, inheritingFrom: target, context: GHOSTTY_SURFACE_CONTEXT_SPLIT)
        let view = Ghostty.SurfaceView(app, baseConfig: config)
        UmiLayout.registerNewPane(view, options: options, config: config)
        // Start at the place's size, so its program sees the right columns and rows.
        let size = target.frame.size
        if size.width > 0, size.height > 0 {
            view.frame = CGRect(origin: .zero, size: size)
            view.sizeDidChange(size)
        }
        return view
    }

    /// A new pane in a full tab (E-9, M-7): it joins the stack at `target`'s place (made if there
    /// is none), right after the member on show, and comes on show. With `focus` it takes keyboard
    /// focus; without, it takes it only if the pane it covers had it, so focus never stays on a
    /// pane that isn't on show. One undoable step ("New Pane"); the layout is saved as any stack's.
    @discardableResult
    static func addOnShow(onto target: Ghostty.SurfaceView, options: UmiLayout.PaneOptions,
                          config: Ghostty.SurfaceConfiguration? = nil, focus: Bool) throws -> Ghostty.SurfaceView {
        guard let location = UmiTopology.locate(target) else { throw UmiError.notFound("the pane isn't in a window") }
        let window = location.window
        let tab = location.tab
        let tree = window.tree(of: tab)
        let shown: Ghostty.SurfaceView
        if tree.contains(target) {
            shown = target
        } else if let stack = tab.stack(of: target), let member = window.shownMember(of: stack, in: tab) {
            shown = member
        } else {
            throw UmiError.notFound("the pane isn't in its tab")
        }
        guard let node = tree.root?.node(view: shown) else { throw UmiError.notFound("the pane isn't in its tab") }
        let view = try makePane(for: shown, options: options, config: config)
        let coveredHadFocus = (tab === window.selectedTab ? window.focusedSurface : tab.focusedSurface) === shown

        var stacks = tab.stacks.map { ($0, $0.members) }
        if let index = stacks.firstIndex(where: { $0.0.members.contains { $0 === shown } }) {
            var members = stacks[index].1
            let at = (members.firstIndex { $0 === shown } ?? members.count - 1) + 1
            members.insert(view, at: at)
            stacks[index].1 = members
        } else {
            stacks.append((UmiPaneStack(members: []), [shown, view]))
        }
        let newTree = try tree.replacing(node: node, with: .leaf(view: view))
        let zoomed = tree.zoomed == node ? newTree.root?.node(view: view) : nil
        // Focus that was on the covered pane moves to the new one (rather than to another pane).
        if focus || coveredHadFocus { tab.focusedSurface = view }
        window.replaceLayout(SplitTree(root: newTree.root, zoomed: zoomed), stacks: stacks, for: tab, undoAction: "New Pane")
        UmiEvents.shared.emit("pane.created", ["pane": view.umiID, "tab": tab.idString, "window": window.umiIDString])
        UmiEvents.shared.emit("pane.stacked", ["pane": view.umiID, "onto": shown.umiID,
                                               "tab": tab.idString, "window": window.umiIDString])
        if focus {
            UmiLayout.focusPane(view, activate: true)
        } else if coveredHadFocus, tab === window.selectedTab {
            UmiLayout.focusPane(view, activate: false)
        }
        return view
    }

    /// A new pane in `target`'s place, at `index` of its stack's order (a stack is made if `target`
    /// had none). It isn't on show: `show` or `UmiLayout.focusPane` brings it up.
    static func addMember(onto target: Ghostty.SurfaceView, cwd: String?, at index: Int) throws -> Ghostty.SurfaceView {
        guard let location = UmiTopology.locate(target) else { throw UmiError.notFound("the pane isn't in a window") }
        var options = UmiLayout.PaneOptions()
        options.cwd = cwd
        let view = try makePane(for: target, options: options, config: nil)
        let tab = location.tab
        if let stack = tab.stack(of: target) {
            stack.members.insert(view, at: min(max(index, 0), stack.members.count))
        } else {
            tab.stacks.append(UmiPaneStack(members: index <= 0 ? [view, target] : [target, view]))
        }
        location.window.setOccluded([view], occluded: true)
        UmiEvents.shared.emit("pane.created", ["pane": view.umiID, "tab": tab.idString, "window": location.window.umiIDString])
        UmiState.shared.layoutDidChange()
        return view
    }

    /// Show a stack member in its stack's place (it takes keyboard focus).
    static func show(_ pane: Ghostty.SurfaceView, focus: Bool = true) throws {
        guard let location = UmiTopology.locate(pane) else { throw UmiError.notFound("the pane isn't in a window") }
        let window = location.window
        let tab = location.tab
        let tree = window.tree(of: tab)
        if !tree.contains(pane) {
            guard let stack = tab.stack(of: pane), let shown = window.shownMember(of: stack, in: tab),
                  let node = tree.root?.node(view: shown) else { throw UmiError.notFound("the pane isn't in its tab") }
            let newTree = try tree.replacing(node: node, with: .leaf(view: pane))
            let zoomed = tree.zoomed == node ? newTree.root?.node(view: pane) : nil
            window.setTree(SplitTree(root: newTree.root, zoomed: zoomed), for: tab)
            window.setOccluded([shown], occluded: true)
            if tab === window.selectedTab { window.setOccluded([pane], occluded: false) }
            UmiEvents.shared.emit("pane.shown", ["pane": pane.umiID, "tab": tab.idString, "window": window.umiIDString])
            UmiState.shared.layoutDidChange()
        }
        if focus { UmiLayout.focusPane(pane, activate: false) }
    }

    /// ⌘[ / ⌘]: the previous or next member of the focused pane's stack. Outside a stack, the
    /// previous or next pane of the tab, as these keys did before stacks.
    static func cycle(_ offset: Int) {
        guard let window = UmiTopology.currentWindow, let pane = UmiTopology.currentPane else { return }
        let tab = window.selectedTab
        if let stack = tab.stack(of: pane), stack.members.count > 1,
           let index = stack.members.firstIndex(where: { $0 === pane }) {
            let next = stack.members[(index + offset + stack.members.count) % stack.members.count]
            try? show(next)
            return
        }
        guard let node = window.surfaceTree.root?.node(view: pane),
              let next = window.surfaceTree.focusTarget(for: offset < 0 ? .previous : .next, from: node) else { return }
        UmiLayout.focusPane(next, activate: false)
    }

    /// The name a member goes by in its stack's strip.
    static func label(of pane: Ghostty.SurfaceView) -> String {
        if let doc = UmiFilePanes.shared.document(of: pane) { return doc.name }
        if let page = UmiWebPanes.shared.page(of: pane) { return page.displayTitle }
        if let name = UmiState.shared.paneName(pane.id), !name.isEmpty { return name }
        if !pane.title.isEmpty, pane.title != "👻" { return pane.title }
        let folder = UmiTopology.cwd(of: pane)
        return folder.isEmpty ? "Terminal" : UmiPaneContext.folderName(folder)
    }
}

/// A stack's one header row (M-7, E-24; Alejo's choice of 2026-11-07, "S1": the strip replaces
/// the pane's own header, so a stack never costs two rows). The drag grip moves the member on
/// show; then a chip per member (click shows it, ✕ closes it); on the right the shown member's own
/// controls, as its header has them (a file's or a web page's; a terminal or agent has none). A
/// right-click on the row opens the shown file's pane menu, as its header does.
struct UmiStackStrip: View {
    let surfaceView: Ghostty.SurfaceView
    @ObservedObject var stack: UmiPaneStack
    @ObservedObject private var files = UmiFilePanes.shared
    @ObservedObject private var web = UmiWebPanes.shared

    var body: some View {
        let doc = files.document(of: surfaceView)
        UmiPaneHeaderBar(surfaceView: surfaceView) {
            UmiStackChips(surfaceView: surfaceView, named: namedMembers, unnamed: stack.members.count - namedMembers.count)
        } trailing: {
            if let doc {
                UmiFilePaneControls(surfaceView: surfaceView, doc: doc)
            } else if let page = web.page(of: surfaceView) {
                UmiWebPaneControls(surfaceView: surfaceView, page: page)
            }
        }
        .background(UmiTheme.chromeFill)
        .contentShape(Rectangle())
        .modifier(UmiStackRowMenu(surfaceView: surfaceView, doc: doc))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Stacked panes")
    }

    /// The members the strip names: all of them, except in the docs tab, where only the most recent
    /// few are (and the one on show, if it's older).
    private var namedMembers: [Ghostty.SurfaceView] {
        guard UmiTopology.locate(surfaceView)?.tab.isDocs == true else { return stack.members }
        var named = Array(stack.members.prefix(UmiDocsTab.named))
        if !named.contains(where: { $0 === surfaceView }) { named.append(surfaceView) }
        return named
    }
}

/// The chips, in the room the folder and name take in a pane's own header. They show at full
/// width (300 points at most) when they fit, else each name shortens to 140 points, else they
/// scroll sideways, keeping the shown member's chip in view.
private struct UmiStackChips: View {
    let surfaceView: Ghostty.SurfaceView
    let named: [Ghostty.SurfaceView]
    let unnamed: Int

    var body: some View {
        ViewThatFits(in: .horizontal) {
            row(maxChip: 300)
            row(maxChip: 140)
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    row(maxChip: 140)
                }
                .onAppear { proxy.scrollTo(surfaceView.id) }
                .onChange(of: surfaceView.id) { id in withAnimation { proxy.scrollTo(id) } }
            }
        }
    }

    private func row(maxChip: CGFloat) -> some View {
        HStack(spacing: 2) {
            ForEach(named, id: \.id) { member in
                UmiStackChip(member: member, shown: member === surfaceView, maxWidth: maxChip)
                    .id(member.id)
            }
            if unnamed > 0 {
                Text("+\(unnamed) · ⌘[ ⌘]")
                    .font(UmiTheme.uiFont)
                    .foregroundColor(UmiTheme.textTertiary)
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, 6)
                    .help("\(unnamed) older \(unnamed == 1 ? "document" : "documents"): ⌘[ and ⌘] go through all of them")
                    .accessibilityLabel("\(unnamed) more")
            }
        }
    }
}

/// A right-click on a stack's row: the shown file's pane menu (other panes' headers have none).
private struct UmiStackRowMenu: ViewModifier {
    let surfaceView: Ghostty.SurfaceView
    let doc: UmiDocument?

    func body(content: Content) -> some View {
        if let doc {
            content.contextMenu { UmiFilePaneMenuItems(surfaceView: surfaceView, doc: doc) }
        } else {
            content
        }
    }
}

private struct UmiStackChip: View {
    @ObservedObject var member: Ghostty.SurfaceView
    let shown: Bool
    var maxWidth: CGFloat = 300
    @State private var hovering = false
    @ObservedObject private var files = UmiFilePanes.shared
    @ObservedObject private var web = UmiWebPanes.shared

    var body: some View {
        let doc = files.document(of: member)
        let page = web.page(of: member)
        HStack(spacing: 5) {
            // A file's type icon in its colors and its unsaved dot, as Warp's file tabs show them.
            if let doc {
                UmiFileIcon(url: doc.url)
                UmiChipDirtyDot(doc: doc)
            } else {
                Image(systemName: web.isWebPane(member.id) ? "globe" : "terminal")
                    .font(.system(size: 10))
                if let page { UmiChipPageState(page: page) }
            }
            Text(UmiStacks.label(of: member))
                .font(UmiTheme.uiFont)
                .lineLimit(1)
                .truncationMode(.middle)
                .layoutPriority(1)
            Button {
                UmiFilePanes.confirmClose(member)
            } label: {
                Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).frame(width: 14, height: 14)
            }
            .buttonStyle(.plain)
            .opacity(hovering || shown ? 1 : 0)
            .help("Close")
            .accessibilityLabel("Close \(UmiStacks.label(of: member))")
        }
        .foregroundColor(shown ? UmiTheme.textPrimary : UmiTheme.textTertiary)
        .padding(.horizontal, 8)
        .frame(height: 22)
        .frame(maxWidth: maxWidth)
        .background(RoundedRectangle(cornerRadius: 6).fill(shown ? UmiTheme.selectedFill : (hovering ? UmiTheme.hoverFill : .clear)))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { try? UmiStacks.show(member) }
        .help(tooltip(doc: doc, page: page))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(UmiStacks.label(of: member))
        .modifier(UmiChipDirtyValue(doc: doc))
        .accessibilityAddTraits(shown ? .isSelected : [])
        .accessibilityAddTraits(.isButton)
    }
}

extension UmiStackChip {
    /// What the pane's own header gave: the file's full path, the page's address, the terminal's folder.
    fileprivate func tooltip(doc: UmiDocument?, page: UmiWebPage?) -> String {
        if let doc { return doc.url.path }
        if let page { return page.url.absoluteString }
        return UmiTopology.cwd(of: member)
    }
}

/// A web chip's unsaved dot (a hosted page that says so) and its loading spinner, as the web pane's
/// header shows them.
private struct UmiChipPageState: View {
    @ObservedObject var page: UmiWebPage

    var body: some View {
        if page.hosted?.dirty == true {
            Circle().fill(UmiTheme.textSecondary).frame(width: 8, height: 8)
                .padding(.trailing, -1)
                .accessibilityLabel("Unsaved changes")
        }
        if page.loading { ProgressView().controlSize(.mini) }
    }
}

/// A file chip says "Unsaved changes" while its dot shows (the chip reads as one element).
private struct UmiChipDirtyValue: ViewModifier {
    let doc: UmiDocument?

    func body(content: Content) -> some View {
        if let doc { content.modifier(Observed(doc: doc)) } else { content }
    }

    private struct Observed: ViewModifier {
        @ObservedObject var doc: UmiDocument
        func body(content: Content) -> some View {
            content.accessibilityValue(doc.isDirty ? "Unsaved changes" : "")
        }
    }
}

/// A stack chip's unsaved-changes dot: 8 points, 4 before the name (Warp's tabs).
private struct UmiChipDirtyDot: View {
    @ObservedObject var doc: UmiDocument

    var body: some View {
        if doc.isDirty {
            Circle().fill(UmiTheme.textSecondary).frame(width: 8, height: 8)
                .padding(.trailing, -1)
                .accessibilityLabel("Unsaved changes")
        }
    }
}
