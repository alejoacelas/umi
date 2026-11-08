import AppKit
import Combine
import SwiftUI

/// The pane indicator (attention-ui.md, "The pane indicator"; prototypes/pane-indicator.html): one
/// small mark per pane, at its bottom right, that says whether the pane's agent is working, needs
/// the user, or finished while the pane wasn't looked at. The same mark shows on the pane's strip
/// chip, and a tab's sidebar row shows the mark of the pane `tab.summary` picks.
///
/// Focus: the focused pane's mark is a little larger and brighter, and the focused pane of a split is
/// lifted a little (the `indicator.focus` slot, default 3%). An idle focused pane of a split gets a
/// grey mark, so focus still shows without the cyan line it replaces. Colours come from the
/// `indicator.<state>` slots; nothing animates.
@MainActor
final class UmiIndicator: ObservableObject {
    static let shared = UmiIndicator()

    enum State: String {
        case working, needsYou = "needs_you", finished, none
    }

    /// What the slots say, read again whenever the config changes.
    struct Style: Equatable {
        var working: NSColor?
        var needsYou: NSColor?
        var finished: NSColor?
        /// How much the focused pane of a split is lifted (white over it, 0–0.2).
        var focus: Double
    }

    /// How one mark is drawn.
    struct Look: Equatable {
        let color: NSColor
        let size: CGFloat
        let opacity: Double
    }

    // The quiet palette (prototypes/pane-indicator.html, section 3, "Quiet, no motion").
    static let named: [String: NSColor] = [
        "amber": hex(0xE0A93E),
        "green": hex(0x6CC28A),
        "violet": hex(0xA78BFA),
        "grey": hex(0x8A8A8A),
        "gray": hex(0x8A8A8A),
    ]
    /// `muted`: each state's quiet colour.
    static let muted: [State: NSColor] = [
        .working: hex(0x6F7F76),
        .needsYou: hex(0x8C7A52),
        .finished: hex(0xBDBDBD),
    ]
    /// The focused pane's mark when it has no state (in a split).
    static let idleFocus = hex(0x6A6A6A)

    static let size: CGFloat = 7
    static let focusedSize: CGFloat = 9
    /// The marks of panes without focus are a little dimmer; "needs you" stays in full colour.
    static let unfocusedOpacity = 0.7
    static let defaultFocus = 0.03

    @Published private(set) var style: Style
    private var timer: Timer?

    private init() {
        style = Self.readStyle()
    }

    /// Follow the config file (its slots), checked every second.
    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated { UmiIndicator.shared.reload() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func reload() {
        UmiConfig.shared.refresh()
        let new = Self.readStyle()
        if new != style { style = new }
    }

    // MARK: State

    /// A pane's state, from its agent's status: working; `needs_input` or `error` need you; `idle`
    /// and `stopped` are finished while the pane is unseen, then nothing.
    static func state(of pane: Ghostty.SurfaceView) -> State {
        guard let agent = UmiAttention.shared.agent(forPane: pane.id) else { return .none }
        switch agent.status {
        case .working: return .working
        case .needsInput, .error: return .needsYou
        case .idle, .stopped:
            return UmiAttributes.shared.computedValue("unseen", of: pane) == "true" ? .finished : .none
        }
    }

    // MARK: Look

    func color(_ state: State) -> NSColor? {
        switch state {
        case .working: return style.working
        case .needsYou: return style.needsYou
        case .finished: return style.finished
        case .none: return nil
        }
    }

    /// How a mark is drawn: nil for none. `focused`: the pane has focus in its tab; `split`: its tab
    /// shows more than one pane (an idle focused pane gets a grey mark there).
    func look(_ state: State, focused: Bool, split: Bool) -> Look? {
        if let color = color(state) {
            return Look(color: color, size: focused ? Self.focusedSize : Self.size,
                        opacity: focused || state == .needsYou ? 1 : Self.unfocusedOpacity)
        }
        if state == .none, focused, split { return Look(color: Self.idleFocus, size: Self.focusedSize, opacity: 1) }
        return nil
    }

    /// How much the focused pane of a split is lifted.
    var focusLift: Double { style.focus }

    // MARK: Slots

    private static func readStyle() -> Style {
        let config = UmiConfig.shared
        // A value that doesn't read falls back to the slot's default (`slot ls` shows the error).
        func colour(_ slot: String, _ state: State) -> NSColor? {
            do { return try parseColour(config.slot(slot), state: state) } catch {
                return (try? parseColour(defaultValue(slot), state: state)) ?? nil
            }
        }
        let focus = (try? parseAmount(config.slot("indicator.focus"))) ?? defaultFocus
        return Style(working: colour("indicator.working", .working),
                     needsYou: colour("indicator.needs_you", .needsYou),
                     finished: colour("indicator.finished", .finished),
                     focus: focus)
    }

    private static func defaultValue(_ slot: String) -> String {
        UmiConfig.slots.first { $0.name == slot }?.defaultValue ?? "none"
    }

    struct BadValue: Error, CustomStringConvertible {
        let description: String
    }

    /// An `indicator.<state>` value: `muted` (the state's quiet colour), `amber`, `green`, `violet`,
    /// `grey`, `#RRGGBB`, or `none` (no mark in that state). Nil: no mark.
    static func parseColour(_ text: String, state: State) throws -> NSColor? {
        let value = text.trimmingCharacters(in: .whitespaces).lowercased()
        if value == "none" { return nil }
        if value == "muted" { return muted[state] }
        if let color = named[value] { return color }
        if value.hasPrefix("#"), value.count == 7, let n = Int(value.dropFirst(), radix: 16) { return hex(n) }
        throw BadValue(description: "\"\(text)\" isn't a colour: muted, amber, green, violet, grey, #RRGGBB or none")
    }

    /// `indicator.focus`: a percentage (`3%`) or a fraction (`0.03`), from 0 to 20%.
    static func parseAmount(_ text: String) throws -> Double {
        var value = text.trimmingCharacters(in: .whitespaces)
        let percent = value.hasSuffix("%")
        if percent { value.removeLast() }
        guard var n = Double(value.trimmingCharacters(in: .whitespaces)), n >= 0 else {
            throw BadValue(description: "\"\(text)\" isn't an amount: a percentage such as 3%, or 0 for none")
        }
        if percent || n > 1 { n /= 100 }
        guard n <= 0.2 else { throw BadValue(description: "\"\(text)\" is more than 20%") }
        return n
    }

    /// What's wrong with an indicator slot's value, for `slot ls`.
    static func slotError(_ name: String, _ value: String) -> String? {
        do {
            switch name {
            case "indicator.working": _ = try parseColour(value, state: .working)
            case "indicator.needs_you": _ = try parseColour(value, state: .needsYou)
            case "indicator.finished": _ = try parseColour(value, state: .finished)
            case "indicator.focus": _ = try parseAmount(value)
            default: return nil
            }
        } catch {
            return "\(error)"
        }
        return nil
    }

    static func hex(_ n: Int) -> NSColor {
        NSColor(srgbRed: CGFloat((n >> 16) & 0xFF) / 255, green: CGFloat((n >> 8) & 0xFF) / 255,
                blue: CGFloat(n & 0xFF) / 255, alpha: 1)
    }

    static func hexString(_ color: NSColor) -> String {
        let c = color.usingColorSpace(.sRGB) ?? color
        return String(format: "#%02x%02x%02x", Int(round(c.redComponent * 255)), Int(round(c.greenComponent * 255)),
                      Int(round(c.blueComponent * 255)))
    }

    // MARK: Where things are (for views and scripted checks)

    /// The pane has focus in its tab, and how many panes its tab shows.
    static func placement(of pane: Ghostty.SurfaceView) -> (focused: Bool, split: Bool) {
        guard let location = UmiTopology.locate(pane) else { return (false, false) }
        // A drawer pane stands alone; its mark grows while it has focus.
        if location.inDrawer {
            return (location.window.drawer.showing === pane && UmiDrawer.hasFocus(pane, in: location.window), false)
        }
        let tab = location.tab
        let shown = location.window.tree(of: tab).root?.leaves() ?? []
        let focused = !tab.isHidden(pane) && tab.effectiveFocusedSurface === pane
        return (focused, shown.count > 1)
    }

    /// Draw a pane's lift and mark into the current graphics context, as `UmiPaneIndicatorOverlay`
    /// draws them on screen (for `screenshot`, where terminals are drawn from their own images).
    func draw(over frame: NSRect, of pane: Ghostty.SurfaceView, flipped: Bool) {
        let place = Self.placement(of: pane)
        if place.focused && place.split && focusLift > 0 {
            NSColor.white.withAlphaComponent(focusLift).setFill()
            frame.fill(using: .sourceOver)
        }
        guard let look = look(Self.state(of: pane), focused: place.focused, split: place.split) else { return }
        let inset = UmiPaneIndicatorOverlay.inset
        let cx = frame.maxX - inset.width
        let cy = flipped ? frame.maxY - inset.height : frame.minY + inset.height
        look.color.withAlphaComponent(look.opacity).setFill()
        NSBezierPath(ovalIn: NSRect(x: cx - look.size / 2, y: cy - look.size / 2, width: look.size, height: look.size)).fill()
    }

    /// One pane's mark as drawn on the pane (`debug.ui.indicator`).
    func json(_ pane: Ghostty.SurfaceView) -> [String: Any] {
        let state = Self.state(of: pane)
        let place = Self.placement(of: pane)
        var out: [String: Any] = ["pane": pane.umiID, "state": state.rawValue, "focused": place.focused,
                                  "split": place.split,
                                  "lift": place.focused && place.split ? focusLift : 0]
        if let look = look(state, focused: place.focused, split: place.split) {
            out["mark"] = ["color": Self.hexString(look.color), "size": Double(look.size), "opacity": look.opacity]
        }
        return out
    }
}

// MARK: - Views

/// A mark: a dot of the look's size and colour.
struct UmiIndicatorDot: View {
    let look: UmiIndicator.Look

    var body: some View {
        Circle()
            .fill(Color(nsColor: look.color))
            .opacity(look.opacity)
            .frame(width: look.size, height: look.size)
    }
}

/// What a pane in a split shows over itself: its mark at the bottom right, by the prompt, and the lift
/// of the focused pane. Never takes clicks.
struct UmiPaneIndicatorOverlay: View {
    let pane: Ghostty.SurfaceView
    @ObservedObject private var indicator = UmiIndicator.shared
    @ObservedObject private var attention = UmiAttention.shared
    @ObservedObject private var state = UmiState.shared

    /// The mark's centre, from the pane's bottom-right corner: in the terminal's right padding (16
    /// points), level with the bottom padding under the prompt line (20 points).
    static let inset = CGSize(width: 8, height: 10)

    var body: some View {
        let _ = attention.revision
        let _ = state.revision
        let place = UmiIndicator.placement(of: pane)
        let look = indicator.look(UmiIndicator.state(of: pane), focused: place.focused, split: place.split)
        ZStack(alignment: .bottomTrailing) {
            if place.focused && place.split && indicator.focusLift > 0 {
                Rectangle().fill(Color.white.opacity(indicator.focusLift))
            }
            if let look {
                UmiIndicatorDot(look: look)
                    .padding(.trailing, Self.inset.width - look.size / 2)
                    .padding(.bottom, Self.inset.height - look.size / 2)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
