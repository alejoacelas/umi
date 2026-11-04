import SwiftUI
import UniformTypeIdentifiers

/// While a pane is being dragged, two targets over the panes' area: top centre moves the pane
/// to the previous tab, bottom centre to the next one (a new tab after the last). They show only
/// during a pane drag, so they never take clicks, and they accept the dragged pane even when it
/// is the only pane in its tab.
struct UmiPaneTabDropTargets: View {
    @ObservedObject var controller: TerminalController
    let draggingPane: Ghostty.SurfaceView.ID?

    enum Target { case previous, next }

    var body: some View {
        if draggingPane != nil, let index = controller.index(of: controller.selectedTab) {
            VStack {
                if index > 0 {
                    UmiPaneTabDropTarget(target: .previous, label: "Move to previous tab", symbol: "arrow.up",
                                         controller: controller)
                }
                Spacer()
                UmiPaneTabDropTarget(target: .next,
                                     label: index + 1 < controller.tabs.count ? "Move to next tab" : "Move to a new tab",
                                     symbol: "arrow.down", controller: controller)
            }
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Move a pane of the window's shown tab to the end of the tab before it or after it (a new
    /// tab after the last one), focusing it there.
    @MainActor
    @discardableResult
    static func move(_ pane: Ghostty.SurfaceView, _ target: Target, in controller: TerminalController) throws -> UmiTopology.Location {
        guard let index = controller.index(of: controller.selectedTab), controller.selectedTab.contains(pane) else {
            throw UmiError.badRequest("the pane must be in its window's shown tab")
        }
        let destination: UmiLayout.PaneDestination
        switch target {
        case .previous:
            guard index > 0, let last = controller.tree(of: controller.tabs[index - 1]).root?.leaves().last else {
                throw UmiError.badRequest("there's no previous tab")
            }
            destination = .besidePane(last, .right)
        case .next:
            if index + 1 < controller.tabs.count, let last = controller.tree(of: controller.tabs[index + 1]).root?.leaves().last {
                destination = .besidePane(last, .right)
            } else {
                destination = .newTab(controller, index: index + 1)
            }
        }
        return try UmiLayout.move(pane, to: destination, focus: true)
    }
}

private struct UmiPaneTabDropTarget: View {
    let target: UmiPaneTabDropTargets.Target
    let label: String
    let symbol: String
    let controller: TerminalController
    @State private var targeted = false

    var body: some View {
        Label(label, systemImage: symbol)
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(targeted ? .white : UmiTheme.textPrimary)
            .padding(.horizontal, 16)
            .frame(height: 36)
            .background(Capsule().fill(targeted ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.regularMaterial)))
            .overlay(Capsule().stroke(Color.accentColor.opacity(targeted ? 0 : 0.6), lineWidth: 1))
            .shadow(color: .black.opacity(0.25), radius: 8, y: 2)
            // A larger catch area than the capsule, so the drop isn't fiddly.
            .padding(.horizontal, 40).padding(.vertical, 8)
            .contentShape(Rectangle())
            .onDrop(of: [.ghosttySurfaceId], isTargeted: $targeted) { providers in
                guard let provider = providers.first else { return false }
                _ = provider.loadTransferable(type: Ghostty.SurfaceView.self) { result in
                    guard case .success(let pane) = result else { return }
                    DispatchQueue.main.async { _ = try? UmiPaneTabDropTargets.move(pane, target, in: controller) }
                }
                return true
            }
            .accessibilityLabel(label)
    }
}
