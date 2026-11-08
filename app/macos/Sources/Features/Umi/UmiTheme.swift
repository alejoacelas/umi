import AppKit
import SwiftUI

/// Umi's look: Warp-like chrome that blends into the terminal background (no boxes or
/// borders), a single cyan accent, and ink that adapts to light and dark backgrounds.
enum UmiTheme {
    static let accent = Color(red: 0x19 / 255, green: 0xAA / 255, blue: 0xD8 / 255)
    static let accentNSColor = NSColor(red: 0x19 / 255, green: 0xAA / 255, blue: 0xD8 / 255, alpha: 1)
    /// Warp's mark for synchronized input (`TAB_INDICATOR_SYNCED_COLOR`, #4A93FF).
    static let syncedInput = Color(red: 0x4A / 255, green: 0x93 / 255, blue: 0xFF / 255)

    /// The chrome sits on the terminal's configured background, so its ink is white on dark
    /// backgrounds and black on light ones (S-5).
    nonisolated(unsafe) private(set) static var isLight = false
    private static var ink: Color { isLight ? .black : .white }

    static var textPrimary: Color { ink.opacity(isLight ? 0.86 : 0.92) }
    static var textSecondary: Color { ink.opacity(isLight ? 0.64 : 0.60) }
    static var textTertiary: Color { ink.opacity(isLight ? 0.50 : 0.42) }

    static var chromeFill: Color { ink.opacity(0.035) }
    /// The sidebar's fill: ink at 5% over the window background, as Warp paints its vertical
    /// tabs panel (`fg_overlay_1`; #121212 over the default Dark theme's #050505).
    static var sidebarFill: Color { ink.opacity(0.05) }
    static var hoverFill: Color { ink.opacity(0.06) }
    static var selectedFill: Color { ink.opacity(isLight ? 0.07 : 0.085) }
    static var hairline: Color { ink.opacity(0.07) }

    /// Text color for AppKit text views.
    static var textNSColor: NSColor {
        isLight ? NSColor.black.withAlphaComponent(0.86) : NSColor.white.withAlphaComponent(0.9)
    }

    /// The terminal's configured background (Warp's `theme.background()`), as last adopted.
    nonisolated(unsafe) private(set) static var terminalBackground: Color = .black

    /// Follow the configured background (called when a terminal view renders).
    @MainActor
    static func adopt(background: Color) {
        terminalBackground = background
        let color = NSColor(background).usingColorSpace(.sRGB) ?? .black
        let luminance = 0.2126 * color.redComponent + 0.7152 * color.greenComponent + 0.0722 * color.blueComponent
        let light = luminance > 0.55
        guard light != isLight else { return }
        isLight = light
        UmiState.shared.layoutDidChange()
    }

    // MARK: Warp's vertical tabs (S-3, S-4)

    /// Warp's `fg_overlay_*` steps: ink at 5%, 10% and 15% over the background.
    static var overlay1: Color { ink.opacity(0.05) }
    static var overlay2: Color { ink.opacity(0.10) }
    static var overlay3: Color { ink.opacity(0.15) }
    /// A row's title (Warp's main text) and second line (its sub text).
    static var rowTitle: Color { ink.opacity(0.90) }
    static var rowSubtitle: Color { ink.opacity(0.60) }
    /// The 1 px line between the sidebar and the panes (foreground 10%).
    static var sidebarDivider: Color { ink.opacity(0.10) }
    /// Warp's error red (`ui_error_color`, #BC362A): the failed-command triangle.
    static let errorRed = Color(red: 188 / 255, green: 54 / 255, blue: 42 / 255)

    /// The terminal's 16 ANSI colors as configured (Warp's tab colors come from them).
    nonisolated(unsafe) private(set) static var ansiPalette: [NSColor]?

    /// Follow the configured palette (called when a terminal view renders).
    @MainActor
    static func adopt(palette: [NSColor]?) {
        guard let palette, palette != ansiPalette else { return }
        ansiPalette = palette
        UmiState.shared.layoutDidChange()
    }

    /// The sidebar's default width (Warp's 248); each window's can be dragged between the
    /// limits (S-8).
    static let sidebarWidth: CGFloat = 248
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

    /// Umi's colors, shipped as a Ghostty theme so a user's own `theme` replaces them
    /// entirely (explicit colors would otherwise override it). They are Warp's built-in Dark
    /// theme (Warp's `themes/default_themes.rs`): background #050505, white text, the cyan accent
    /// as the cursor, its selection (blue at 40% over the text, which keeps its colors) and its 16
    /// terminal colors (S-5).
    static let themeConfig = """
    background = #050505
    foreground = #ffffff
    cursor-color = #19aad8
    selection-background = #76a7fa
    selection-background-opacity = 0.4
    selection-foreground = cell-foreground
    split-divider-color = #262626
    unfocused-split-fill = #050505
    palette = 0=#616161
    palette = 1=#ff8272
    palette = 2=#b4fa72
    palette = 3=#fefdc2
    palette = 4=#a5d5fe
    palette = 5=#ff8ffd
    palette = 6=#d0d1fe
    palette = 7=#f1f1f1
    palette = 8=#8e8e8e
    palette = 9=#ffc4bd
    palette = 10=#d6fcb9
    palette = 11=#fefdd5
    palette = 12=#c1e3fe
    palette = 13=#ffb1fe
    palette = 14=#e5e6fe
    palette = 15=#feffff
    """

    /// Configuration Umi loads before the user's config file (`~/.config/umi/config`), so every
    /// value here can be overridden there (S-5).
    static func defaultsConfig(themePath: String) -> String {
        """
        # Umi defaults. Loaded before ~/.config/umi/config; anything you set there
        # (including `theme`) overrides these values.
        macos-titlebar-style = transparent
        macos-titlebar-proxy-icon = hidden
        theme = \(themePath)

        # Warp's terminal (Warp parity): Hack 13 (bundled; the default when no font-family is
        # set), rows 1.2× the font size, no ligatures, a 3-point bar cursor with round ends,
        # 16 points either side, 20 below the prompt, none for full-screen programs.
        cursor-style = bar
        font-size = 13
        adjust-cell-height = 3%
        adjust-cursor-height = 3%
        font-feature = -calt
        font-feature = -liga
        font-feature = -dlig
        window-padding-x = 16
        window-padding-y = 10,20
        window-padding-balance = bottom
        window-padding-alternate-screen = false
        window-padding-color = extend
        unfocused-split-opacity = 1
        mouse-hide-while-typing = true

        # Warp's contrast rule (named colors raised to 4.5:1) and its silent bell (no sound,
        # no Dock bounce, no bell in the title).
        minimum-contrast = 4.5
        minimum-contrast-colors = named
        bell-features = no-system,no-audio,no-attention,no-title,no-border

        # ⌃⌘ and the arrows move the pane (UmiPaneMove); splits aren't resized from the keyboard.
        keybind = super+ctrl+arrow_left=unbind
        keybind = super+ctrl+arrow_right=unbind
        keybind = super+ctrl+arrow_up=unbind
        keybind = super+ctrl+arrow_down=unbind
        # ⌃⇧↑ / ⌃⇧↓ move the tab up and down; jump to prompt keeps ⇧⌘↑ / ⇧⌘↓.
        keybind = ctrl+shift+arrow_up=unbind
        keybind = ctrl+shift+arrow_down=unbind

        # ⇧⌘T reopens the last closed pane, tab or window (File menu), not Undo.
        keybind = super+shift+t=unbind
        # Tab switching, the palettes and Settings are Umi menu items that work whatever
        # has focus (terminal, editor, sidebar, palette): ⇧⌘[ ⇧⌘] ⌘1–9 ⌃Tab ⌃⇧Tab ⇧⌘P ⌘,.
        keybind = super+[=unbind
        keybind = super+]=unbind
        keybind = super+shift+[=unbind
        keybind = super+shift+]=unbind
        keybind = ctrl+tab=unbind
        keybind = ctrl+shift+tab=unbind
        keybind = super+shift+p=unbind
        keybind = super+,=unbind
        # ⇧⌘F opens global search in the sidebar (as in Warp); Esc still ends a terminal search.
        keybind = super+shift+f=unbind
        # ⌥⌘I and ⌥⇧⌘I synchronize input (Window ▸ Synchronize Input), as in Warp; the
        # terminal inspector moves to ⌃⌥⌘I.
        keybind = super+alt+i=unbind
        keybind = super+alt+ctrl+i=inspector:toggle
        # ⌘= ⌘- ⌘0 zoom the whole interface (View menu), as in Warp; the terminals' font size
        # is ⌥⇧> and ⌥⇧<.
        keybind = super+==unbind
        keybind = super++=unbind
        keybind = super+-=unbind
        keybind = super+0=unbind
        \(digitUnbinds)
        """
    }

    /// ⌘1–⌘9: Ghostty binds both the digit keys and the characters.
    private static var digitUnbinds: String {
        (1...9).flatMap { ["keybind = super+digit_\($0)=unbind", "keybind = super+\($0)=unbind"] }
            .joined(separator: "\n")
    }

    /// Ghostty keybindings changed with `umi shortcuts`, loaded after the user's own
    /// config files (nil when there are none).
    static func keybindingsConfigPath() -> String? {
        let path = UmiShortcutStore.ghosttyFile
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }

    /// Write the defaults (and theme) files into the state directory and return the path.
    static func defaultsConfigPath() -> String? {
        let dir = UmiPaths.stateDirectory
        let themePath = dir + "/themes/Umi Dark"
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
struct UmiIconButtonStyle: ButtonStyle {
    var active: Bool = false
    var size: CGFloat = 24
    var radius: CGFloat = 6

    func makeBody(configuration: Configuration) -> some View {
        UmiIconButtonBody(configuration: configuration, active: active, size: size, radius: radius)
    }
}

private struct UmiIconButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let active: Bool
    let size: CGFloat
    var radius: CGFloat = 6
    @State private var hovering = false

    var body: some View {
        configuration.label
            .foregroundColor(active ? UmiTheme.textPrimary : (hovering ? UmiTheme.textSecondary : UmiTheme.textTertiary))
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(active ? UmiTheme.selectedFill : (configuration.isPressed || hovering ? UmiTheme.hoverFill : .clear))
            )
            .onHover { hovering = $0 }
    }
}
