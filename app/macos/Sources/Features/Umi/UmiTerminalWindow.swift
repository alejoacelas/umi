import AppKit

/// Umi's window: a transparent titlebar over full-height content, so the sidebar runs from
/// the top of the window to the bottom and the chrome blends into the terminal background
/// (S-1). There's no native tab bar (Umi's tabs live in the sidebar) and no titlebar icons.
class UmiTerminalWindow: TransparentTitlebarTerminalWindow {
    override var supportsUpdateAccessory: Bool { false }

    override func awakeFromNib() {
        super.awakeFromNib()
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        styleMask.insert(.fullSizeContentView)
        tabbingMode = .disallowed
        isMovableByWindowBackground = false
        minSize = NSSize(width: 480, height: 300)
    }

    override func syncAppearance(_ surfaceConfig: Ghostty.SurfaceView.DerivedConfig) {
        super.syncAppearance(surfaceConfig)
        // The content runs under the titlebar and draws there: the sidebar's top and the pane strip
        // (attention-ui.md, "The pane strip": it sits in the title bar). Ghostty paints the titlebar
        // in the terminal's background, which would cover them, so it stays clear here.
        titlebarContainer?.firstDescendant(withClassName: "NSTitlebarView")?.layer?.backgroundColor = NSColor.clear.cgColor
        titlebarContainer?.layer?.backgroundColor = NSColor.clear.cgColor
    }

    override func addTitlebarAccessoryViewController(_ childViewController: NSTitlebarAccessoryViewController) {
        super.addTitlebarAccessoryViewController(childViewController)
        // Nothing sits in the titlebar: no tab bar, no icons on the right.
        childViewController.isHidden = true
    }
}
