import AppKit
import SwiftUI

/// Settings (⌘,): where shortcuts are edited (L-17). Every Umi menu shortcut and every
/// Ghostty keybinding is listed; each can be changed, cleared or reset, and changes apply at
/// once. Other settings stay in the Ghostty config file, which a button opens.
@MainActor
enum UmiSettingsWindow {
    private static var controller: NSWindowController?

    static func show() {
        if controller?.window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 600),
                                  styleMask: [.titled, .closable, .resizable, .miniaturizable],
                                  backing: .buffered, defer: false)
            window.title = "Settings"
            window.isReleasedWhenClosed = false
            window.minSize = NSSize(width: 480, height: 360)
            window.contentView = NSHostingView(rootView: UmiShortcutsEditorView())
            window.center()
            window.setFrameAutosaveName("UmiSettings")
            controller = NSWindowController(window: window)
        }
        controller?.showWindow(nil)
        controller?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    static var isVisible: Bool { controller?.window?.isVisible ?? false }
}

@MainActor
final class UmiShortcutsEditorModel: ObservableObject {
    @Published private(set) var entries: [UmiShortcutStore.Entry] = []
    @Published var query = ""
    /// The entry waiting for a key press.
    @Published private(set) var recording: String?
    /// What the last change did to other shortcuts.
    @Published private(set) var notice: String?

    private var monitor: Any?
    private var observer: NSObjectProtocol?

    init() {
        // Not during the view update that creates the model.
        DispatchQueue.main.async { [weak self] in self?.reload() }
        observer = NotificationCenter.default.addObserver(forName: UmiShortcutStore.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    func reload() { entries = UmiShortcutStore.shared.entries() }

    func filtered(_ kind: UmiShortcutStore.Entry.Kind) -> [UmiShortcutStore.Entry] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return entries.filter { entry in
            entry.kind == kind && (q.isEmpty || entry.title.lowercased().contains(q) || entry.id.lowercased().contains(q)
                                   || entry.shortcuts.contains { $0.display.lowercased().contains(q) || $0.spec.contains(q) })
        }
    }

    func record(_ id: String) {
        stopRecording()
        recording = id
        notice = nil
        UmiShortcuts.suspended = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, let id = self.recording else { return event }
                let mods = event.modifierFlags.intersection(UmiShortcut.relevant)
                if event.keyCode == 53, mods.isEmpty {          // Esc: cancel
                    self.stopRecording()
                } else if event.keyCode == 51, mods.isEmpty {   // Delete: clear
                    self.apply(id, nil)
                } else if let shortcut = UmiShortcut(event: event) {
                    self.apply(id, shortcut)
                }
                return nil
            }
        }
    }

    func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = nil
        UmiShortcuts.suspended = false
    }

    func apply(_ id: String, _ shortcut: UmiShortcut?) {
        stopRecording()
        do {
            let notes = try UmiShortcutStore.shared.set(id, to: shortcut)
            notice = notes.isEmpty ? nil : notes.joined(separator: "; ") + "."
        } catch {
            notice = "\(error)"
        }
        reload()
    }

    func reset(_ id: String?) {
        stopRecording()
        try? UmiShortcutStore.shared.reset(id)
        notice = nil
        reload()
    }
}

struct UmiShortcutsEditorView: View {
    @StateObject private var model = UmiShortcutsEditorModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search shortcuts", text: $model.query)
                    .textFieldStyle(.plain)
                    .accessibilityLabel("Search shortcuts")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider().opacity(0.5)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    section("\(UmiPaths.productName)", kind: .umi,
                            note: "Menu shortcuts. They work whatever has focus: terminal, editor, sidebar, palette.")
                    section("Terminal (Ghostty keybindings)", kind: .ghostty,
                            note: "These act on the focused terminal.")
                }
                .padding(.vertical, 6)
            }

            Divider().opacity(0.5)

            VStack(alignment: .leading, spacing: 6) {
                if let notice = model.notice {
                    Text(notice).font(.caption).foregroundStyle(.secondary)
                }
                Text("Click a shortcut, then press the new keys (Esc cancels, Delete clears). Changes apply at once and are saved in \(abbreviate(UmiShortcutStore.file)) and \(abbreviate(UmiShortcutStore.ghosttyFile)), which load after your Ghostty config. Your Ghostty config file isn't changed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Reset All") { model.reset(nil) }
                    Spacer()
                    Button("Open Ghostty Config File") { (NSApp.delegate as? AppDelegate)?.openConfig(nil) }
                }
            }
            .padding(14)
        }
        .frame(minWidth: 480, minHeight: 360)
        .onDisappear { model.stopRecording() }
    }

    @ViewBuilder
    private func section(_ title: String, kind: UmiShortcutStore.Entry.Kind, note: String) -> some View {
        let rows = model.filtered(kind)
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(note).font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 6)
            ForEach(rows, id: \.id) { entry in
                UmiShortcutRow(entry: entry, recording: model.recording == entry.id,
                                record: { model.record(entry.id) },
                                clear: { model.apply(entry.id, nil) },
                                reset: { model.reset(entry.id) })
            }
        }
    }

    private func abbreviate(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
}

private struct UmiShortcutRow: View {
    let entry: UmiShortcutStore.Entry
    let recording: Bool
    let record: () -> Void
    let clear: () -> Void
    let reset: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.title).lineLimit(1)
                if let menu = entry.menu {
                    Text(menu).font(.caption2).foregroundStyle(.tertiary)
                } else if entry.kind == .ghostty {
                    Text(entry.id.dropFirst("ghostty:".count)).font(.caption2.monospaced()).foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 8)
            if entry.changed {
                Button("Reset", action: reset)
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .help("Back to the default")
            }
            if !entry.shortcuts.isEmpty && hovering && !recording {
                Button(action: clear) { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.tertiary)
                    .help("Remove the shortcut")
                    .accessibilityLabel("Clear \(entry.title)")
            }
            Button(action: record) {
                Text(label)
                    .font(.system(size: 12, design: .rounded))
                    .foregroundStyle(recording ? Color.accentColor : (entry.shortcuts.isEmpty ? .secondary : .primary))
                    .frame(minWidth: 96, alignment: .trailing)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(recording || hovering ? 0.08 : 0.04)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Shortcut for \(entry.title)")
            .accessibilityValue(label)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }

    private var label: String {
        if recording { return "Type shortcut…" }
        if entry.shortcuts.isEmpty { return entry.triggers.isEmpty ? "None" : entry.triggers.joined(separator: ", ") }
        return entry.shortcuts.map(\.display).joined(separator: "  ")
    }
}
