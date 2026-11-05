import AppKit
import SwiftUI

// MARK: - Status badges

/// The status badge on an agent's mark (Warp parity, 2026-11-05): Warp's states and colors on
/// its default Dark theme (its terminal magenta, green, yellow and red; grey for cancelled),
/// 57% of the icon's size, its bottom-right corner on the icon's. The mark stays monochrome.
struct UmiAgentStatusBadge: View {
    let badge: UmiAttention.Badge
    /// The icon's size; the badge is 57% of it and its glyph 34%, as Warp's.
    let total: CGFloat

    static func color(_ badge: UmiAttention.Badge) -> Color {
        switch badge {
        case .working: return Color(red: 0xFF / 255, green: 0x8F / 255, blue: 0xFD / 255)
        case .done: return Color(red: 0xB4 / 255, green: 0xFA / 255, blue: 0x72 / 255)
        case .needsYou: return Color(red: 0xFE / 255, green: 0xFD / 255, blue: 0xC2 / 255)
        case .error: return Color(red: 0xFF / 255, green: 0x82 / 255, blue: 0x72 / 255)
        case .cancelled, .none: return UmiTheme.textTertiary
        }
    }

    static func symbol(_ badge: UmiAttention.Badge) -> String? {
        switch badge {
        case .working: return "clock.fill"
        case .done: return "checkmark.circle.fill"
        case .needsYou, .cancelled: return "stop.circle.fill"
        case .error: return "exclamationmark.triangle.fill"
        case .none: return nil
        }
    }

    var body: some View {
        if let symbol = Self.symbol(badge) {
            ZStack {
                // The cutout ring: the background around the glyph.
                Circle().fill(UmiTheme.isLight ? Color.white : Color.black)
                    .frame(width: total * 0.57, height: total * 0.57)
                Image(systemName: symbol)
                    .resizable()
                    .scaledToFit()
                    .foregroundColor(Self.color(badge))
                    .frame(width: max(total * 0.34, 4), height: max(total * 0.34, 4))
            }
            .frame(width: total * 0.57, height: total * 0.57)
            .accessibilityHidden(true)
        }
    }
}

extension View {
    /// Put an agent's status badge on this icon, its bottom-right corner on the icon's (the view
    /// is `total` points square).
    func umiStatusBadge(_ badge: UmiAttention.Badge, total: CGFloat) -> some View {
        frame(width: total, height: total)
            .overlay(alignment: .bottomTrailing) { UmiAgentStatusBadge(badge: badge, total: total) }
    }
}

/// An agent's icon in the inbox and toasts: its monochrome mark in a quiet circle (76% of the
/// size, as Warp's brand circle) with the status badge.
struct UmiAgentIcon: View {
    let kind: UmiAttention.Kind
    let badge: UmiAttention.Badge
    var size: CGFloat = 32

    var body: some View {
        ZStack {
            Circle().fill(UmiTheme.selectedFill)
                .frame(width: size * 0.76, height: size * 0.76)
            UmiAgentMark(kind: kind)
                .foregroundColor(UmiTheme.textSecondary)
                .frame(width: size * 0.43, height: size * 0.43)
        }
        .frame(width: size * 0.76, height: size * 0.76)
        .frame(width: size, height: size, alignment: .topLeading)
        .umiStatusBadge(badge, total: size)
    }
}

// MARK: - The inbox and toasts over a window

/// The inbox panel (⇧⌘U) and the toasts, at the window's top right, over the panes.
struct UmiInboxOverlay: View {
    @ObservedObject var controller: TerminalController
    let background: Color
    @ObservedObject private var inbox = UmiInbox.shared

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            if inbox.isOpen(in: controller) {
                UmiInboxPanel(background: background)
            } else {
                if let note = inbox.updateNote {
                    UmiUpdateNoteCard(note: note, background: background)
                }
                ForEach(inbox.toasts(in: controller)) { item in
                    UmiInboxToast(item: item, background: background)
                }
            }
        }
        .padding(.top, 10)
        .padding(.trailing, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .animation(.easeOut(duration: 0.15), value: inbox.toasts)
    }
}

/// A floating card: a quiet surface over the terminal background, a hairline border and an
/// 8-point radius, as Warp's toasts and mailbox.
private struct UmiCard: ViewModifier {
    let background: Color
    let width: CGFloat

    func body(content: Content) -> some View {
        content
            .frame(width: width, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous).fill(background)
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(UmiTheme.selectedFill))
            )
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(UmiTheme.hairline.opacity(2), lineWidth: 1))
            .shadow(color: .black.opacity(0.35), radius: 14, x: 0, y: 6)
    }
}

private struct UmiInboxItemContent: View {
    let item: UmiInbox.Item
    var showTime = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            UmiAgentIcon(kind: item.kind, badge: item.badge, size: 32)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(item.title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(UmiTheme.textPrimary)
                        .lineLimit(2)
                    Spacer(minLength: 4)
                    if showTime {
                        Text(Self.ago(item.at))
                            .font(.system(size: 11))
                            .foregroundColor(UmiTheme.textTertiary)
                        if !item.read {
                            Circle().fill(UmiTheme.accent).frame(width: 6, height: 6)
                                .accessibilityLabel("unread")
                        }
                    }
                }
                Text(item.message)
                    .font(.system(size: 12))
                    .foregroundColor(UmiTheme.textSecondary)
                    .lineLimit(3)
            }
        }
    }

    static func ago(_ date: Date) -> String {
        let seconds = Int(Date().timeIntervalSince(date))
        if seconds < 60 { return "now" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        if seconds < 86400 { return "\(seconds / 3600)h" }
        return "\(seconds / 86400)d"
    }
}

private struct UmiInboxToast: View {
    let item: UmiInbox.Item
    let background: Color

    var body: some View {
        UmiInboxItemContent(item: item)
            .padding(12)
            .modifier(UmiCard(background: background, width: 360))
            .contentShape(Rectangle())
            .onTapGesture { UmiInbox.shared.activate(item.id) }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Toast: \(item.title)")
            .accessibilityValue(item.message)
    }
}

private struct UmiUpdateNoteCard: View {
    let note: UmiInbox.UpdateNote
    let background: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Umi updated to \(note.version)")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(UmiTheme.textPrimary)
            ScrollView(.vertical, showsIndicators: false) {
                Text(note.notes)
                    .font(.system(size: 12))
                    .foregroundColor(UmiTheme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: 160)
            .fixedSize(horizontal: false, vertical: true)
            Text("⌃⌘U to dismiss")
                .font(.system(size: 11))
                .foregroundColor(UmiTheme.textTertiary)
        }
        .padding(12)
        .modifier(UmiCard(background: background, width: 360))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Umi updated to \(note.version)")
        .accessibilityValue(note.notes)
    }
}

/// The inbox: Warp's notification mailbox, 420 points wide and at most 500 tall. ↑ ↓ choose,
/// Return goes to the session, Tab or Shift-Tab change the filter, Escape closes.
private struct UmiInboxPanel: View {
    let background: Color
    @ObservedObject private var inbox = UmiInbox.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Notifications")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(UmiTheme.textPrimary)
                Spacer()
                Text("esc")
                    .font(.system(size: 11))
                    .foregroundColor(UmiTheme.textTertiary)
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 6)

            HStack(spacing: 4) {
                ForEach(inbox.visibleFilters, id: \.self) { filter in
                    let count = inbox.count(filter)
                    Button { inbox.setFilter(filter) } label: {
                        Text(count == 0 ? filter.label : "\(filter.label) (\(count))")
                            .font(.system(size: 11.5, weight: inbox.filter == filter ? .semibold : .regular))
                            .foregroundColor(inbox.filter == filter ? UmiTheme.textPrimary : UmiTheme.textTertiary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(RoundedRectangle(cornerRadius: 5)
                                .fill(inbox.filter == filter ? UmiTheme.selectedFill : .clear))
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
                if inbox.count(.unread) > 0 {
                    Button("Mark all as read") { inbox.markAllRead() }
                        .buttonStyle(.plain)
                        .font(.system(size: 11))
                        .foregroundColor(UmiTheme.textTertiary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 6)

            Rectangle().fill(UmiTheme.hairline).frame(height: 1)

            let shown = inbox.shown
            if shown.isEmpty {
                Text("No notifications")
                    .font(.system(size: 12))
                    .foregroundColor(UmiTheme.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 24)
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(spacing: 0) {
                            ForEach(Array(shown.enumerated()), id: \.element.id) { index, item in
                                UmiInboxItemContent(item: item, showTime: true)
                                    .padding(12)
                                    .background(RoundedRectangle(cornerRadius: 6)
                                        .fill(inbox.selected == index ? UmiTheme.selectedFill : .clear))
                                    .contentShape(Rectangle())
                                    .onTapGesture { inbox.activate(item.id) }
                                    .id(item.id)
                                    .accessibilityElement(children: .combine)
                                    .accessibilityLabel(item.title)
                                    .accessibilityValue(item.message)
                                    .accessibilityAddTraits(inbox.selected == index ? [.isSelected, .isButton] : .isButton)
                            }
                        }
                        .padding(4)
                    }
                    .frame(maxHeight: 440)
                    .fixedSize(horizontal: false, vertical: true)
                    .onChange(of: inbox.selected) { index in
                        guard let index, shown.indices.contains(index) else { return }
                        proxy.scrollTo(shown[index].id)
                    }
                }
            }
        }
        .modifier(UmiCard(background: background, width: 420))
        .frame(maxHeight: 500)
        .background(UmiInboxPanelMarker())
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Notifications")
    }
}

/// An empty view the size of the open panel: UmiInbox asks it whether a click fell inside.
private struct UmiInboxPanelMarker: NSViewRepresentable {
    /// Never the target of a click itself.
    final class Marker: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    func makeNSView(context: Context) -> NSView {
        let view = Marker()
        UmiInbox.shared.panelView = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        UmiInbox.shared.panelView = view
    }
}
