import SwiftUI
import GhosttyKit
import os

/// This delegate is notified of actions and property changes regarding the terminal view. This
/// delegate is optional and can be used by a TerminalView caller to react to changes such as
/// titles being set, cell sizes being changed, etc.
protocol TerminalViewDelegate: AnyObject {
    /// Called when the currently focused surface changed. This can be nil.
    func focusedSurfaceDidChange(to: Ghostty.SurfaceView?)

    /// The URL of the pwd should change.
    func pwdDidChange(to: URL?)

    /// The cell size changed.
    func cellSizeDidChange(to: NSSize)

    /// Perform an action. At the time of writing this is only triggered by the command palette.
    func performAction(_ action: String, on: Ghostty.SurfaceView)

    /// A split tree operation
    func performSplitAction(_ action: TerminalSplitOperation)
}

/// The view model is a required implementation for TerminalView callers. This contains
/// the main state between the TerminalView caller and SwiftUI. This abstraction is what
/// allows AppKit to own most of the data in SwiftUI.
protocol TerminalViewModel: ObservableObject {
    /// The tree of terminal surfaces (splits) within the view. This is mutated by TerminalView
    /// and children. This should be @Published.
    var surfaceTree: SplitTree<Ghostty.SurfaceView> { get set }

    /// The command palette state.
    var commandPaletteIsShowing: Bool { get set }

    /// The update overlay should be visible.
    var updateOverlayIsVisible: Bool { get }
}

/// The main terminal view. This terminal view supports splits.
struct TerminalView<ViewModel: TerminalViewModel>: View {
    @ObservedObject var ghostty: Ghostty.App

    // The required view model
    @ObservedObject var viewModel: ViewModel

    // An optional delegate to receive information about terminal changes.
    weak var delegate: (any TerminalViewDelegate)?

    /// The most recently focused surface, equal to `focusedSurface` when it is non-nil.
    @State private var lastFocusedSurface: Weak<Ghostty.SurfaceView>?
    /// Umi: the pane being dragged, if any (for the previous/next tab drop targets).
    @State private var draggingPane: Ghostty.SurfaceView.ID?
    // Umi: a pane dragged by its chip in the pane strip.
    @State private var draggingChip: Ghostty.SurfaceView.ID?

    // This seems like a crutch after switching from SwiftUI to AppKit lifecycle.
    @FocusState private var focused: Bool

    // Various state values sent back up from the currently focused terminals.
    @FocusedValue(\.ghosttySurfaceView) private var focusedSurface
    @FocusedValue(\.ghosttySurfacePwd) private var surfacePwd
    @FocusedValue(\.ghosttySurfaceCellSize) private var cellSize

    // Umi: the sidebar beside a window's panes.
    @ObservedObject private var umiState = UmiState.shared
    // Umi: the interface's zoom (L-33).
    @ObservedObject private var umiZoom = UmiZoom.shared

    /// The focused terminal's initial size plus the sidebar.
    private var idealContentSize: CGSize? {
        guard let initial = lastFocusedSurface?.value?.initialSize else { return nil }
        let controller = viewModel as? TerminalController
        let chrome = UmiTheme.chromeSize(sidebar: controller?.sidebarVisible ?? false,
                                          width: controller?.sidebarWidth ?? UmiTheme.sidebarWidth)
        return CGSize(width: initial.width + chrome.width, height: initial.height + chrome.height)
    }

    // The pwd of the focused surface as a URL
    private var pwdURL: URL? {
        guard let surfacePwd, surfacePwd != "" else { return nil }
        return URL(fileURLWithPath: surfacePwd)
    }

    var body: some View {
        switch ghostty.readiness {
        case .loading:
            Text("Loading")
        case .error:
            ErrorView()
        case .ready:
            ZStack {
                GeometryReader { geometry in
                    // The window's content runs under the titlebar: the sidebar spans the
                    // full height and the terminals start below the titlebar band.
                    let topInset = geometry.safeAreaInsets.top
                    let controller = viewModel as? TerminalController
                    let _ = UmiTheme.adopt(background: ghostty.config.backgroundColor)
                    let _ = UmiTheme.adopt(palette: ghostty.config.umiANSIPalette)

                    HStack(spacing: 0) {
                        // Shown or hidden at once, per window, as Warp's panel.
                        if let controller, controller.sidebarVisible {
                            UmiSidebar(controller: controller, topInset: topInset / umiZoom.factor)
                                .umiZoomed(umiZoom.factor)
                                .frame(width: controller.sidebarWidth)
                                // Warp's 1 px line at foreground 10% between the panel and the panes.
                                .overlay(alignment: .trailing) {
                                    Rectangle().fill(UmiTheme.sidebarDivider).frame(width: 1).allowsHitTesting(false)
                                }
                                .overlay(alignment: .trailing) { UmiSidebarResizeEdge(controller: controller) }
                        }

                        VStack(spacing: 0) {
                            // Umi: the pane strip, in the title bar band above the panes.
                            if let controller {
                                UmiPaneStrip(controller: controller, tab: controller.selectedTab,
                                             leading: controller.sidebarVisible ? 8 : 78)
                                    .frame(height: max(topInset, 22))
                                    .onPreferenceChange(Ghostty.DraggingSurfaceKey.self) { draggingChip = $0 }
                            }
                            terminals
                        }
                        .padding(.top, controller == nil ? topInset : 0)
                        if let controller {
                            // Umi: the shortcuts page (⌘/), at the right as Warp's keybindings panel.
                            UmiShortcutsPageSlot(model: controller.palette.shortcutsPage,
                                                 background: ghostty.config.backgroundColor)
                                .padding(.top, topInset)
                        }
                    }
                    .ignoresSafeArea(.container, edges: .top)
                }
                .frame(idealWidth: idealContentSize?.width, idealHeight: idealContentSize?.height)

                if let controller = viewModel as? TerminalController {
                    // Umi's palette: commands, panes and files, whatever has focus (L-14–L-16).
                    UmiPaletteView(model: controller.palette, background: ghostty.config.backgroundColor)
                        .umiZoomed(umiZoom.factor)
                    // Umi: the note after an update, at the top right.
                    UmiUpdateNoteOverlay(background: ghostty.config.backgroundColor)
                } else if let surfaceView = lastFocusedSurface?.value {
                    TerminalCommandPaletteView(
                        surfaceView: surfaceView,
                        isPresented: $viewModel.commandPaletteIsShowing,
                        ghosttyConfig: ghostty.config) { action in
                        self.delegate?.performAction(action, on: surfaceView)
                    }
                }
            }
            .frame(maxWidth: .greatestFiniteMagnitude, maxHeight: .greatestFiniteMagnitude)
        }
    }
}

extension TerminalView {
    /// The split tree of terminals (and the debug-build banner).
    @ViewBuilder
    fileprivate var terminals: some View {
        VStack(spacing: 0) {
            // If we're running in debug mode we show a warning so that users
            // know that performance will be degraded.
            if Ghostty.info.mode == GHOSTTY_BUILD_MODE_DEBUG || Ghostty.info.mode == GHOSTTY_BUILD_MODE_RELEASE_SAFE {
                DebugBuildWarningView()
            }

            TerminalSplitTreeView(
                tree: viewModel.surfaceTree,
                action: { delegate?.performSplitAction($0) })
                .background(GeometryReader { geo in
                    // Umi: the panes' area, for the frames `ls` reports (L-19).
                    let controller = viewModel as? TerminalController
                    Color.clear
                        .onAppear { controller?.terminalAreaSize = geo.size }
                        .onChange(of: geo.size) { controller?.terminalAreaSize = $0 }
                })
                .onPreferenceChange(Ghostty.DraggingSurfaceKey.self) { draggingPane = $0 }
                .overlay {
                    if let controller = viewModel as? TerminalController {
                        UmiPaneTabDropTargets(controller: controller, draggingPane: draggingPane ?? draggingChip)
                    }
                }
                .environmentObject(ghostty)
                .ghosttyLastFocusedSurface(lastFocusedSurface)
                .focused($focused)
                .onAppear { self.focused = true }
                .onChange(of: focusedSurface) { newValue in
                    // We want to keep track of our last focused surface so even if
                    // we lose focus we keep this set to the last non-nil value.
                    if newValue != nil {
                        lastFocusedSurface = .init(newValue)
                        self.delegate?.focusedSurfaceDidChange(to: newValue)
                    }
                }
                .onChange(of: pwdURL) { newValue in
                    self.delegate?.pwdDidChange(to: newValue)
                }
                .onChange(of: cellSize) { newValue in
                    guard let size = newValue else { return }
                    self.delegate?.cellSizeDidChange(to: size)
                }
                .frame(idealWidth: lastFocusedSurface?.value?.initialSize?.width,
                       idealHeight: lastFocusedSurface?.value?.initialSize?.height)
        }
    }
}

struct DebugBuildWarningView: View {
    @State private var isPopover = false

    var body: some View {
        HStack {
            Spacer()

            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.yellow)

            Text("You're running a debug build of Ghostty! Performance will be degraded.")
                .padding(.all, 8)
                .popover(isPresented: $isPopover, arrowEdge: .bottom) {
                    Text("""
                    Debug builds of Ghostty are very slow and you may experience
                    performance problems. Debug builds are only recommended during
                    development.
                    """)
                    .padding(.all)
                }

            Spacer()
        }
        .background(Color(.windowBackgroundColor))
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Debug build warning")
        .accessibilityValue("Debug builds of Ghostty are very slow and you may experience performance problems. Debug builds are only recommended during development.")
        .accessibilityAddTraits(.isStaticText)
        .onTapGesture {
            isPopover = true
        }
    }
}
