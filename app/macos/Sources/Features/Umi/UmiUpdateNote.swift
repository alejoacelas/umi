import AppKit
import SwiftUI

/// After an update installs, the relaunched app says so once, inside the window: "Umi updated to
/// X.Y.Z" with that release's notes from the feed (Warp's "Warp updated!" toast; SPEC I-4). It
/// stays until ⌃⌘U (View ▸ Dismiss Update Note) dismisses it.
@MainActor
final class UmiUpdateNote: ObservableObject {
    static let shared = UmiUpdateNote()

    struct Note: Equatable {
        let version: String
        let notes: String
    }

    @Published private(set) var note: Note?

    /// After an update installed (UmiUpdater, once).
    func show(version: String, notes: String?) {
        let text = notes?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        note = Note(version: version, notes: text.isEmpty ? "See what changed in the release notes." : text)
        UmiEvents.shared.emit("update.note", ["version": version])
    }

    var isShowing: Bool { note != nil }

    func dismiss() {
        guard note != nil else { return }
        note = nil
        UmiEvents.shared.emit("update.note_dismissed", [:])
    }

    /// The note drawn on its own, for `umi screenshot` (the terminals draw with Metal, so the
    /// window's cached image has them over the note: it goes on top again, as the palette does).
    func capturedImage(in content: NSView, background: Color) -> (image: NSImage, frame: NSRect)? {
        guard note != nil else { return nil }
        let bounds = content.bounds
        let host = NSHostingView(rootView: UmiUpdateNoteOverlay(background: background)
            .frame(width: bounds.width, height: bounds.height))
        host.frame = NSRect(origin: .zero, size: bounds.size)
        host.appearance = content.window?.effectiveAppearance
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.cacheDisplay(in: host.bounds, to: rep)
        let image = NSImage(size: bounds.size)
        image.addRepresentation(rep)
        return (image, bounds)
    }

    /// `debug.ui.update_note`: what it shows.
    var report: [String: Any] {
        ["update_note": note.map { ["version": $0.version, "notes": $0.notes] as [String: Any] } ?? NSNull()]
    }
}

/// The note at the window's top right, over the panes.
struct UmiUpdateNoteOverlay: View {
    let background: Color
    @ObservedObject private var model = UmiUpdateNote.shared

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            if let note = model.note {
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
                .frame(width: 360, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous).fill(background)
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(UmiTheme.selectedFill))
                )
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(UmiTheme.hairline.opacity(2), lineWidth: 1))
                .shadow(color: .black.opacity(0.35), radius: 14, x: 0, y: 6)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Umi updated to \(note.version)")
                .accessibilityValue(note.notes)
            }
        }
        .padding(.top, 10)
        .padding(.trailing, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .allowsHitTesting(model.note != nil)
    }
}
