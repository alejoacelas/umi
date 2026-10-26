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

    override func addTitlebarAccessoryViewController(_ childViewController: NSTitlebarAccessoryViewController) {
        super.addTitlebarAccessoryViewController(childViewController)
        // Nothing sits in the titlebar: no tab bar, no icons on the right.
        childViewController.isHidden = true
    }
}
