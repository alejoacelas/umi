import SwiftUI

/// The header row of a file pane and a web pane (E-24, E-12; Alejo's choice of 2026-11-07): on the
/// left the drag grip and whatever names the pane (an icon and "folder / name"), on the right its
/// controls. The left part gives way first, so the controls always fit. A stack strip can host
/// the same row with its chips as the left part.
struct UmiPaneHeaderBar<Leading: View, Trailing: View>: View {
    let surfaceView: Ghostty.SurfaceView
    @ViewBuilder let leading: () -> Leading
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 6) {
            UmiPaneGrip(surfaceView: surfaceView)
            HStack(spacing: 6) { leading() }
                .layoutPriority(1)
            Spacer(minLength: 8)
            HStack(spacing: 4) { trailing() }
                .fixedSize()
        }
        .padding(.horizontal, 8)
        .frame(height: 30)
    }
}

/// The drag grip at a pane header's left edge: dragging it moves the pane.
struct UmiPaneGrip: View {
    let surfaceView: Ghostty.SurfaceView
    @State private var dragging = false
    @State private var hovering = false

    var body: some View {
        ZStack {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(hovering ? UmiTheme.textSecondary : UmiTheme.textTertiary)
            Ghostty.SurfaceDragSource(surfaceView: surfaceView, isDragging: $dragging, isHovering: $hovering)
        }
        .frame(width: 22, height: 18)
        .help("Drag to move this pane")
    }
}

/// "folder / name", left-aligned: the parent folder's name muted, the file's name in the primary
/// color, an 8-point dot 4 points before the name while there are unsaved changes. When the row is
/// too narrow the folder shortens first, then the name (from its start, so the extension stays).
struct UmiPathTitle: View {
    let folder: String?
    let name: String
    var dirty = false
    /// The tooltip: the full path or address.
    let help: String

    var body: some View {
        HStack(spacing: 0) {
            if let folder, !folder.isEmpty {
                Text(folder + " / ")
                    .font(.system(size: 12, weight: .regular))
                    .foregroundColor(UmiTheme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            HStack(spacing: 4) {
                if dirty {
                    Circle().fill(UmiTheme.textSecondary).frame(width: 8, height: 8)
                        .accessibilityLabel("Unsaved changes")
                }
                Text(name)
                    .font(UmiTheme.uiFont)
                    .foregroundColor(UmiTheme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            .layoutPriority(1)
        }
        .help(help)
    }

    /// The folder and name of a slash-separated path ("desk/AGENTS.md" → "desk", "AGENTS.md").
    static func split(_ path: String) -> (folder: String?, name: String) {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard let name = parts.last else { return (nil, path) }
        return (parts.count > 1 ? parts[parts.count - 2] : nil, name)
    }
}

/// The Preview / Source switch (E-2), the same in a file pane's header and a hosted page's.
struct UmiPreviewSourceSwitch: View {
    let isPreview: Bool
    let select: (_ preview: Bool) -> Void

    var body: some View {
        HStack(spacing: 1) {
            segment("Preview", on: isPreview) { select(true) }
            segment("Source", on: !isPreview) { select(false) }
        }
        .help("Toggle preview / source (⌘E or ⇧⌘M)")
    }

    private func segment(_ title: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(UmiTheme.uiFontSmall)
                .foregroundColor(on ? UmiTheme.textPrimary : UmiTheme.textTertiary)
                .padding(.horizontal, 7)
                .frame(height: 20)
                .background(RoundedRectangle(cornerRadius: 5).fill(on ? UmiTheme.selectedFill : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// A small icon button in a pane header (reload, Open in Browser, GitHub, close).
struct UmiPaneHeaderButton: View {
    let symbol: String
    let help: String
    let label: String
    var size: CGFloat = 10
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: size, weight: .bold)).frame(width: 16, height: 16)
        }
        .buttonStyle(.plain)
        .foregroundColor(UmiTheme.textTertiary)
        .help(help)
        .accessibilityLabel(label)
    }
}
