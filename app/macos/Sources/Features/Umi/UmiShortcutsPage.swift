import AppKit
import SwiftUI

/// The shortcuts page (⌘/), as Warp's keybindings panel: a searchable, read-only list of every
/// Umi menu shortcut and Ghostty keybinding in effect, in a panel on the window's right. It
/// lists what `umi shortcuts` lists, which is also how they're changed.
@MainActor
final class UmiShortcutsPageModel: ObservableObject {
    struct Row: Identifiable {
        let id: String
        let title: String
        let section: String
        /// Each shortcut's keys, one box per key.
        let keys: [[String]]
        /// The shortcuts as `umi shortcuts` writes them (cmd+p).
        let specs: [String]
        /// The shortcuts, which a search by keys matches.
        let shortcuts: [UmiShortcut]

        var json: [String: Any] {
            ["id": id, "title": title, "section": section, "keys": keys.map { $0.joined() }, "specs": specs,
             "shortcuts": shortcuts.map(\.spec)]
        }
    }

    /// Warp's panel width (`RESOURCE_CENTER_WIDTH`).
    static let width: CGFloat = 361
    static let sectionOrder = ["Umi", "File", "Edit", "View", "Window", "Help", "Terminal"]

    @Published private(set) var isShown = false
    @Published var query = ""
    @Published private(set) var all: [Row] = []

    private weak var window: TerminalController?
    private weak var previousResponder: NSResponder?

    /// Open the page in the current window, or close it there.
    static func toggle() {
        guard let window = UmiTopology.currentWindow else {
            NSSound.beep()
            return
        }
        window.palette.shortcutsPage.toggle(in: window)
    }

    /// In the editor's source, ⌘/ belongs to the editor (Warp's page key works outside text
    /// editors only).
    static var editorSourceHasFocus: Bool {
        let window = NSApp.keyWindow ?? UmiTopology.currentWindow?.window
        guard let view = window?.firstResponder as? UmiEditorTextView else { return false }
        return view.isEditable
    }

    func toggle(in window: TerminalController) {
        if isShown { close() } else { open(in: window) }
    }

    func open(in window: TerminalController) {
        if window.palette.isPresented { window.palette.close(restoreFocus: false) }
        previousResponder = window.window?.firstResponder
        self.window = window
        all = Self.build()
        query = ""
        isShown = true
        UmiEvents.shared.emit("shortcuts_page.opened", ["window": window.umiIDString])
    }

    func close() {
        guard isShown else { return }
        isShown = false
        guard let nsWindow = window?.window else { return }
        let previous = previousResponder
        let pane = window?.focusedSurface
        DispatchQueue.main.async {
            if let view = previous as? NSView, view.window === nsWindow, view !== nsWindow.fieldEditor(false, for: nil) {
                nsWindow.makeFirstResponder(view)
            } else if let pane, pane.window === nsWindow {
                Ghostty.moveFocus(to: pane)
            }
        }
    }

    /// The rows the query matches: by title (fuzzy), or by keys (⌘P, cmd p, shift cmd p).
    var rows: [Row] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return all }
        let keys = Self.keystroke(in: q)
        return all.filter { row in
            UmiFuzzy.score(q, row.title) != nil
                || keys.map { keys in row.shortcuts.contains { Self.matches($0, keys) } } ?? false
        }
    }

    /// A query read as keys, as Warp's keybinding search reads it: modifier words (cmd/command,
    /// ctrl/control, alt/option/opt, shift) or symbols (⌃⌥⇧⌘) in any order, and at most one
    /// key. Nil when it isn't keys (a word that's no key, a modifier twice, nothing at all).
    static func keystroke(in query: String) -> (modifiers: NSEvent.ModifierFlags, key: String?)? {
        var modifiers: NSEvent.ModifierFlags = []
        var key: String?
        let symbols: [Character: NSEvent.ModifierFlags] = ["⌃": .control, "⌥": .option, "⇧": .shift, "⌘": .command]
        func add(_ flag: NSEvent.ModifierFlags) -> Bool {
            guard !modifiers.contains(flag) else { return false }
            modifiers.insert(flag)
            return true
        }
        let tokens = query.split(whereSeparator: { $0 == " " || $0 == "+" }).map(String.init)
        for token in tokens {
            var text = Substring(token)
            while let first = text.first, let flag = symbols[first] {
                guard add(flag) else { return nil }
                text.removeFirst()
            }
            guard !text.isEmpty else { continue }
            switch text.lowercased() {
            case "cmd", "command": guard add(.command) else { return nil }
            case "ctrl", "control": guard add(.control) else { return nil }
            case "alt", "option", "opt": guard add(.option) else { return nil }
            case "shift": guard add(.shift) else { return nil }
            default:
                guard key == nil, let shortcut = UmiShortcut(spec: String(text)), shortcut.modifiers.isEmpty else { return nil }
                key = shortcut.key
            }
        }
        guard !modifiers.isEmpty || key != nil else { return nil }
        return (modifiers, key)
    }

    /// A shortcut has every modifier the query names, and its key when it names one (Warp).
    static func matches(_ shortcut: UmiShortcut, _ keys: (modifiers: NSEvent.ModifierFlags, key: String?)) -> Bool {
        shortcut.modifiers.isSuperset(of: keys.modifiers) && (keys.key == nil || keys.key == shortcut.key)
    }

    /// Search the page (debug.shortcuts_page), listing every shortcut even while it's closed.
    func search(_ text: String) {
        if all.isEmpty { all = Self.build() }
        query = text
    }

    /// The rows by section, in Umi's menu order and then the terminal's bindings.
    var sections: [(title: String, rows: [Row])] {
        let rows = self.rows
        return Self.sectionOrder.compactMap { section in
            let inSection = rows.filter { $0.section == section }
            return inSection.isEmpty ? nil : (section, inSection)
        }
    }

    /// Every shortcut in effect, from the same list as `umi shortcuts`.
    static func build() -> [Row] {
        UmiShortcutStore.shared.entries().compactMap { entry -> Row? in
            let keys = entry.shortcuts.map(\.symbols)
            let shown = keys.isEmpty ? entry.triggers.map { [$0] } : keys
            guard !shown.isEmpty else { return nil }
            let section: String
            if entry.kind == .ghostty {
                section = "Terminal"
            } else {
                let menu = entry.menu?.components(separatedBy: " > ").first ?? "Umi"
                section = menu == "App" ? "Umi" : (sectionOrder.contains(menu) ? menu : "Umi")
            }
            let specs = entry.kind == .ghostty ? entry.triggers : entry.shortcuts.map(\.spec)
            return Row(id: entry.id, title: entry.title, section: section, keys: shown, specs: specs,
                       shortcuts: entry.shortcuts)
        }
        .sorted { a, b in a.title.localizedStandardCompare(b.title) == .orderedAscending }
    }

    var stateJSON: [String: Any] {
        ["shown": isShown, "query": query, "rows": rows.map(\.json), "sections": sections.map(\.title)]
    }
}

/// Where the page goes: at the window's right, beside the terminals (nothing when closed).
struct UmiShortcutsPageSlot: View {
    @ObservedObject var model: UmiShortcutsPageModel
    let background: Color

    var body: some View {
        if model.isShown {
            UmiShortcutsPanel(model: model, colors: UmiPaletteColors(background: background))
                .frame(width: UmiShortcutsPageModel.width)
                .transition(.move(edge: .trailing))
        }
    }
}

/// Warp's keybindings panel measures (`resource_center/section_views`): 12 px spacing, 16 pt
/// section headers on `surface_2` with a 1 px top border, 14 pt descriptions.
private struct UmiShortcutsPanel: View {
    @ObservedObject var model: UmiShortcutsPageModel
    let colors: UmiPaletteColors
    @FocusState private var focused: Bool

    private let spacing: CGFloat = 12

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            search
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    let sections = model.sections
                    if sections.isEmpty {
                        Text("No shortcuts match.")
                            .font(.system(size: 14))
                            .foregroundColor(colors.sub)
                            .padding(spacing)
                    }
                    ForEach(sections, id: \.title) { section in
                        Text(section.title)
                            .font(.system(size: 16))
                            .foregroundColor(colors.main)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(spacing)
                            .background(colors.surface)
                            .overlay(alignment: .top) { Rectangle().fill(colors.outline).frame(height: 1) }
                            .padding(.bottom, 6)
                            .accessibilityAddTraits(.isHeader)
                        ForEach(section.rows) { row in
                            HStack(spacing: 8) {
                                Text(row.title)
                                    .font(.system(size: 14))
                                    .foregroundColor(colors.sub)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                VStack(alignment: .trailing, spacing: 3) {
                                    ForEach(Array(row.keys.enumerated()), id: \.offset) { _, keys in
                                        UmiKeycaps(symbols: keys, colors: colors)
                                    }
                                }
                            }
                            .padding(.horizontal, spacing)
                            .padding(.vertical, spacing / 2)
                            .accessibilityElement(children: .combine)
                            .accessibilityLabel("\(row.title), \(row.keys.map { $0.joined() }.joined(separator: " or "))")
                        }
                        Spacer().frame(height: spacing)
                    }
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(colors.background)
        .overlay(alignment: .leading) { Rectangle().fill(colors.outline).frame(width: 1) }
        .environment(\.colorScheme, colors.light ? .light : .dark)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Keyboard Shortcuts")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: spacing) {
            if let toggle = UmiShortcuts.item(id: "help.shortcuts")?.shortcut {
                HStack(spacing: 8) {
                    UmiKeycaps(symbols: toggle.symbols, colors: colors)
                    Text("To toggle this panel").font(.system(size: 14)).foregroundColor(colors.sub)
                }
            }
            Text("Change shortcuts with `\(UmiPaths.cliName) shortcuts` in a terminal.")
                .font(.system(size: 14))
                .foregroundColor(colors.sub)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(spacing)
        .padding(.top, spacing)
    }

    private var search: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundColor(colors.sub)
                .accessibilityHidden(true)
            TextField("Search by name or by keys (ex. \"cmd d\")", text: $model.query)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundColor(colors.main)
                .focused($focused)
                .onExitCommand { model.close() }
                .onAppear { DispatchQueue.main.async { focused = true } }
                .accessibilityLabel("Search shortcuts")
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(RoundedRectangle(cornerRadius: 6).fill(colors.keycap))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(colors.outline, lineWidth: 1))
        .padding(.horizontal, spacing)
        .padding(.bottom, spacing)
    }
}
