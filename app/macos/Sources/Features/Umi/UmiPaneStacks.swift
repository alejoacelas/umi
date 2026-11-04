import AppKit
import SwiftUI

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
        if let name = UmiState.shared.paneName(pane.id), !name.isEmpty { return name }
        if !pane.title.isEmpty, pane.title != "👻" { return pane.title }
        let folder = UmiTopology.cwd(of: pane)
        return folder.isEmpty ? "Terminal" : UmiPaneContext.folderName(folder)
    }
}

/// The strip of names along the top of a stack's place: click one to show it, ✕ to close it.
struct UmiStackStrip: View {
    let surfaceView: Ghostty.SurfaceView
    @ObservedObject var stack: UmiPaneStack

    var body: some View {
        HStack(spacing: 2) {
            ForEach(stack.members, id: \.id) { member in
                UmiStackChip(member: member, shown: member === surfaceView)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(height: 30)
        .background(UmiTheme.chromeFill)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Stacked panes")
    }
}

private struct UmiStackChip: View {
    @ObservedObject var member: Ghostty.SurfaceView
    let shown: Bool
    @State private var hovering = false
    @ObservedObject private var files = UmiFilePanes.shared

    var body: some View {
        let doc = files.document(of: member)
        HStack(spacing: 5) {
            Image(systemName: doc.map { UmiEditor.icon(for: $0.url) } ?? "terminal")
                .font(.system(size: 10))
            Text(UmiStacks.label(of: member))
                .font(UmiTheme.uiFont)
                .lineLimit(1)
                .truncationMode(.middle)
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
        .frame(maxWidth: 200)
        .background(RoundedRectangle(cornerRadius: 6).fill(shown ? UmiTheme.selectedFill : (hovering ? UmiTheme.hoverFill : .clear)))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { try? UmiStacks.show(member) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(UmiStacks.label(of: member))
        .accessibilityAddTraits(shown ? .isSelected : [])
        .accessibilityAddTraits(.isButton)
    }
}
