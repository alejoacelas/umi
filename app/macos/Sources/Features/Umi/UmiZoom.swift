import AppKit
import GhosttyKit
import SwiftUI

/// The interface's zoom and the terminals' font size, as Warp's (L-23). ⌘= / ⌘- step through
/// Warp's zoom levels and ⌘0 goes back to 100%: the sidebar, the palette, the editor, the
/// Markdown preview and the terminals' text all scale. ⌥⇧> / ⌥⇧< change the terminals' font
/// size by a point (5–25, as Warp), whatever the zoom; the terminals show it times the zoom.
/// Both are kept in the state directory (`zoom.json`) and apply to every window.
@MainActor
final class UmiZoom: ObservableObject {
    static let shared = UmiZoom()

    /// Warp's zoom levels, in percent (`ZoomLevel::VALUES`).
    static let levels = [50, 60, 70, 80, 90, 100, 110, 125, 150, 175, 200, 225, 250, 300, 350]
    /// Warp's font size limits and step (`MIN_FONT_SIZE`, `MAX_FONT_SIZE`, `FONT_SIZE_INCREMENT`).
    static let fontSizes: ClosedRange<Float> = 5...25
    static let fontStep: Float = 1

    /// The zoom level, in percent.
    @Published private(set) var level = 100
    /// The terminals' font size the user chose with ⌥⇧> / ⌥⇧<; nil: the config's `font-size`.
    @Published private(set) var fontSize: Float?

    var factor: CGFloat { CGFloat(level) / 100 }

    /// The font size each pane was given, so a pane gets it once (and back to the config's).
    private var applied: [UUID: Float] = [:]

    private var file: String { UmiPaths.path("zoom.json") }

    private init() {
        if let data = FileManager.default.contents(atPath: file),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let level = json["level"] as? Int, Self.levels.contains(level) { self.level = level }
            if let size = json["font_size"] as? Double { fontSize = Self.clamped(Float(size)) }
        }
        NotificationCenter.default.addObserver(forName: .ghosttyConfigDidChange, object: nil, queue: .main) { note in
            guard note.object == nil else { return }
            MainActor.assumeIsolated {
                // The config's font size may have changed: give every pane its size again.
                UmiZoom.shared.applied = [:]
                UmiZoom.shared.apply()
            }
        }
    }

    // MARK: Changes

    /// ⌘= (1) and ⌘- (-1): the next of Warp's levels. False at either end.
    @discardableResult
    func step(_ delta: Int) -> Bool {
        let index = Self.levels.firstIndex(of: level) ?? Self.levels.firstIndex(of: 100)!
        let next = min(max(index + delta, 0), Self.levels.count - 1)
        guard Self.levels[next] != level else { return false }
        set(level: Self.levels[next])
        return true
    }

    /// ⌘0.
    func reset() { set(level: 100) }

    func set(level: Int) {
        guard Self.levels.contains(level) else { return }
        self.level = level
        changed()
    }

    /// ⌥⇧> (1) and ⌥⇧< (-1). False at either limit.
    @discardableResult
    func stepFontSize(_ delta: Float) -> Bool {
        let next = Self.clamped(baseFontSize + delta * Self.fontStep)
        guard next != baseFontSize else { return false }
        fontSize = next
        changed()
        return true
    }

    func resetFontSize() {
        fontSize = nil
        changed()
    }

    private static func clamped(_ size: Float) -> Float {
        min(max(size, fontSizes.lowerBound), fontSizes.upperBound)
    }

    private func changed() {
        save()
        apply()
        UmiState.shared.layoutDidChange()
        UmiEvents.shared.emit("view.zoom", ["level": level, "font_size": Double(baseFontSize)])
    }

    private func save() {
        var json: [String: Any] = ["level": level]
        if let fontSize { json["font_size"] = Double(fontSize) }
        guard let data = try? JSONSerialization.data(withJSONObject: json) else { return }
        FileManager.default.createFile(atPath: file, contents: data)
    }

    // MARK: Terminals

    /// The config's `font-size`.
    var configFontSize: Float {
        guard let config = UmiLayout.ghostty?.config.config else { return 13 }
        var value: Float = 0
        let key = "font-size"
        guard ghostty_config_get(config, &value, key, UInt(key.lengthOfBytes(using: .utf8))), value > 0 else { return 13 }
        return value
    }

    /// The font size before zoom: the user's choice, else the config's.
    var baseFontSize: Float { fontSize ?? configFontSize }

    /// What the terminals show.
    var terminalFontSize: Float { (baseFontSize * Float(level) / 100 * 100).rounded() / 100 }

    /// Give every pane the font size in effect (called after changes and whenever the layout
    /// changes, so new panes get it too). At 100% with the config's size, panes go back to
    /// the config's own.
    func apply() {
        let natural = level == 100 && fontSize == nil
        let target = terminalFontSize
        for window in UmiTopology.windows {
            for tab in window.tabs {
                for pane in UmiTopology.panes(of: tab, in: window) {
                    guard let surface = pane.surface else { continue }
                    if natural {
                        guard applied.removeValue(forKey: pane.id) != nil else { continue }
                        Self.binding("reset_font_size", surface)
                    } else if applied[pane.id] != target {
                        applied[pane.id] = target
                        Self.binding("set_font_size:\(target)", surface)
                    }
                }
            }
        }
    }

    private static func binding(_ action: String, _ surface: ghostty_surface_t) {
        _ = ghostty_surface_binding_action(surface, action, UInt(action.lengthOfBytes(using: .utf8)))
    }
}

/// Lays a view out at 1/zoom of its space and scales it up to fill it, so all of it (text,
/// icons, padding) grows with the zoom.
struct UmiZoomed: ViewModifier {
    let factor: CGFloat

    func body(content: Content) -> some View {
        GeometryReader { geometry in
            content
                .frame(width: geometry.size.width / factor, height: geometry.size.height / factor)
                .scaleEffect(factor, anchor: .topLeading)
        }
    }
}

extension View {
    func umiZoomed(_ factor: CGFloat) -> some View { modifier(UmiZoomed(factor: factor)) }
}
