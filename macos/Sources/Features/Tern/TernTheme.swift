import AppKit
import SwiftUI

/// Tern's look: Warp-like chrome that blends into the terminal background (no boxes or
/// borders), a single cyan accent, and ink that adapts to light and dark backgrounds.
enum TernTheme {
    static let accent = Color(red: 0x19 / 255, green: 0xAA / 255, blue: 0xD8 / 255)
    static let accentNSColor = NSColor(red: 0x19 / 255, green: 0xAA / 255, blue: 0xD8 / 255, alpha: 1)

    /// The chrome sits on the terminal's configured background, so its ink is white on dark
    /// backgrounds and black on light ones (S-5).
    nonisolated(unsafe) private(set) static var isLight = false
    private static var ink: Color { isLight ? .black : .white }

    static var textPrimary: Color { ink.opacity(isLight ? 0.86 : 0.92) }
    static var textSecondary: Color { ink.opacity(isLight ? 0.64 : 0.60) }
    static var textTertiary: Color { ink.opacity(isLight ? 0.50 : 0.42) }

    static var chromeFill: Color { ink.opacity(0.035) }
    static var hoverFill: Color { ink.opacity(0.06) }
    static var selectedFill: Color { ink.opacity(isLight ? 0.07 : 0.085) }
    static var hairline: Color { ink.opacity(0.07) }

    /// Text color for AppKit text views.
    static var textNSColor: NSColor {
        isLight ? NSColor.black.withAlphaComponent(0.86) : NSColor.white.withAlphaComponent(0.9)
    }

    /// Follow the configured background (called when a terminal view renders).
    @MainActor
    static func adopt(background: Color) {
        let color = NSColor(background).usingColorSpace(.sRGB) ?? .black
        let luminance = 0.2126 * color.redComponent + 0.7152 * color.greenComponent + 0.0722 * color.blueComponent
        let light = luminance > 0.55
        guard light != isLight else { return }
        isLight = light
        TernState.shared.layoutDidChange()
    }

    /// The sidebar's default width; each window's can be dragged between the limits (S-8).
    static let sidebarWidth: CGFloat = 252
    static let sidebarMinWidth: CGFloat = 180
    static let sidebarMaxWidth: CGFloat = 600

    /// A sidebar width within the limits and, when the window's width is given, no more than
    /// half of it.
    static func clampSidebarWidth(_ width: CGFloat, windowWidth: CGFloat? = nil) -> CGFloat {
        var upper = sidebarMaxWidth
        if let windowWidth, windowWidth > 0 { upper = min(upper, max(sidebarMinWidth, (windowWidth / 2).rounded(.down))) }
        return min(max(width.rounded(), sidebarMinWidth), upper)
    }

    /// The smallest content area a window gets (M-5).
    static let minimumContentSize = CGSize(width: 640, height: 380)

    /// Room the chrome takes around the terminal inside a window's content area: the
    /// sidebar when shown. Added to a terminal's size so it keeps its columns and rows.
    static func chromeSize(sidebar: Bool, width: CGFloat = sidebarWidth) -> CGSize {
        CGSize(width: sidebar ? width : 0, height: 0)
    }

    static let uiFont = Font.system(size: 12, weight: .medium)
    static let uiFontSmall = Font.system(size: 11, weight: .regular)
    static let monoSmall = Font.system(size: 11, weight: .regular, design: .monospaced)

    // MARK: Default terminal configuration

    /// Tern's colors, shipped as a Ghostty theme so a user's own `theme` replaces them
    /// entirely (explicit colors would otherwise override it).
    static let themeConfig = """
    background = #111214
    foreground = #e6e6e6
    cursor-color = #19aad8
    selection-background = #24435c
    selection-foreground = #ffffff
    split-divider-color = #222327
    unfocused-split-fill = #0c0c0d
    palette = 0=#2b2b2b
    palette = 1=#cd3131
    palette = 2=#0dbc79
    palette = 3=#e5e510
    palette = 4=#2472c8
    palette = 5=#bc3fbc
    palette = 6=#11a8cd
    palette = 7=#e5e5e5
    palette = 8=#666666
    palette = 9=#f14c4c
    palette = 10=#23d18b
    palette = 11=#f5f543
    palette = 12=#3b8eea
    palette = 13=#d670d6
    palette = 14=#29b8db
    palette = 15=#ffffff
    """

    /// Configuration Tern loads before the user's Ghostty config files, so every value here
    /// can be overridden there (S-5).
    static func defaultsConfig(themePath: String) -> String {
        """
        # Tern defaults. Loaded before your Ghostty config; anything you set there
        # (including `theme`) overrides these values.
        macos-titlebar-style = transparent
        macos-titlebar-proxy-icon = hidden
        theme = \(themePath)

        cursor-style = bar
        font-size = 13
        adjust-cell-height = 15%
        window-padding-x = 14
        window-padding-y = 10
        window-padding-balance = true
        window-padding-color = extend
        unfocused-split-opacity = 0.8
        mouse-hide-while-typing = true

        # ⌃⌘← / ⌃⌘→ move the pane into the previous or next tab.
        keybind = super+ctrl+arrow_left=unbind
        keybind = super+ctrl+arrow_right=unbind

        # ⇧⌘T reopens the last closed pane, tab or window (File menu), not Undo.
        keybind = super+shift+t=unbind
        """
    }

    /// Write the defaults (and theme) files into the state directory and return the path.
    static func defaultsConfigPath() -> String? {
        let dir = TernPaths.stateDirectory
        let themePath = dir + "/themes/Tern Dark"
        let path = dir + "/defaults.conf"
        do {
            try FileManager.default.createDirectory(atPath: dir + "/themes", withIntermediateDirectories: true)
            try writeIfChanged(themeConfig + "\n", to: themePath)
            try writeIfChanged(defaultsConfig(themePath: themePath) + "\n", to: path)
            return path
        } catch {
            return nil
        }
    }

    private static func writeIfChanged(_ contents: String, to path: String) throws {
        if (try? String(contentsOfFile: path, encoding: .utf8)) == contents { return }
        try contents.write(toFile: path, atomically: true, encoding: .utf8)
    }
}

/// Buttons in the chrome: no borders, a tint on hover and when active.
struct TernIconButtonStyle: ButtonStyle {
    var active: Bool = false
    var size: CGFloat = 24

    func makeBody(configuration: Configuration) -> some View {
        TernIconButtonBody(configuration: configuration, active: active, size: size)
    }
}

private struct TernIconButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let active: Bool
    let size: CGFloat
    @State private var hovering = false

    var body: some View {
        configuration.label
            .foregroundColor(active ? TernTheme.textPrimary : (hovering ? TernTheme.textSecondary : TernTheme.textTertiary))
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(active ? TernTheme.selectedFill : (configuration.isPressed || hovering ? TernTheme.hoverFill : .clear))
            )
            .onHover { hovering = $0 }
    }
}
