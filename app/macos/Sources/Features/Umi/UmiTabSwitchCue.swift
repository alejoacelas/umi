import AppKit
import SwiftUI

/// A brief fade-in of the panes when a window shows another tab. A window switch is marked by
/// macOS bringing another window forward; a tab switch only swaps the panes in place, so without
/// this it looked the same. The fade is a layer over the panes that ignores the mouse, and
/// keyboard focus has already moved when it starts, so it never holds up input.
@MainActor
enum UmiTabSwitchCue {
    static let duration: CFTimeInterval = 0.14
    /// How much of the window's background covers the new tab's panes at the start.
    static let startOpacity: Float = 0.55

    private final class Veil: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func accessibilityIsIgnored() -> Bool { true }
    }

    static func play(in controller: TerminalController) {
        guard let window = controller.window, window.isVisible, window.occlusionState.contains(.visible),
              let content = window.contentView,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        // The panes' area: below the titlebar, right of the sidebar.
        var area = content.convert(window.contentLayoutRect, from: nil)
        if controller.sidebarVisible {
            area.origin.x += controller.sidebarWidth
            area.size.width -= controller.sidebarWidth
        }
        guard area.width > 0, area.height > 0 else { return }

        // A quick switch replaces the fade still running.
        content.subviews.filter { $0 is Veil }.forEach { $0.removeFromSuperview() }
        let veil = Veil(frame: area)
        veil.wantsLayer = true
        veil.layer?.backgroundColor = NSColor(controller.ghostty.config.backgroundColor).cgColor
        content.addSubview(veil, positioned: .above, relativeTo: nil)

        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak veil] in veil?.removeFromSuperview() }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = startOpacity
        fade.toValue = 0
        fade.duration = duration
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        veil.layer?.opacity = 0
        veil.layer?.add(fade, forKey: "fade")
        CATransaction.commit()
    }
}
