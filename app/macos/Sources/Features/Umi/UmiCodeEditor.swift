import AppKit
import Combine
import GhosttyKit
import SwiftUI
import UmiSyntax

// MARK: - The terminal's look, for the editor

/// What the source editor takes from the terminal, as Warp's editor does: the terminal's font and
/// size, and its ANSI palette for syntax colors and diff marks.
@MainActor
enum UmiCodeLook {
    /// A pane's terminal font: the primary face at the configured size (whatever `font-family`
    /// says, including the font built into the terminal). Before the pane has a terminal, the
    /// system monospaced font at the configured size.
    static func font(of pane: Ghostty.SurfaceView?) -> NSFont {
        if let surface = pane?.surface, let raw = ghostty_surface_quicklook_font(surface) {
            // The function returns a copy of the font, owned by the caller.
            let font = Unmanaged<CTFont>.fromOpaque(raw).takeRetainedValue()
            return font as NSFont
        }
        return NSFont.monospacedSystemFont(ofSize: CGFloat(configFloat("font-size") ?? 13), weight: .regular)
    }

    private static var config: ghostty_config_t? { UmiLayout.ghostty?.config.config }

    private static func configFloat(_ key: String) -> Float? {
        guard let config else { return nil }
        var value: Float = 0
        return ghostty_config_get(config, &value, key, UInt(key.lengthOfBytes(using: .utf8))) ? value : nil
    }

    private static func configColor(_ key: String) -> NSColor? {
        guard let config else { return nil }
        var color = ghostty_config_color_s()
        guard ghostty_config_get(config, &color, key, UInt(key.lengthOfBytes(using: .utf8))) else { return nil }
        return NSColor(srgbRed: CGFloat(color.r) / 255, green: CGFloat(color.g) / 255, blue: CGFloat(color.b) / 255, alpha: 1)
    }

    /// The 16 ANSI colors (Umi's defaults, which are Warp Dark's, when the config can't be read).
    static func palette() -> [NSColor] {
        if let config {
            var palette = ghostty_config_palette_s()
            let key = "palette"
            if ghostty_config_get(config, &palette, key, UInt(key.lengthOfBytes(using: .utf8))) {
                // 256 colors of three bytes (r, g, b) each.
                let bytes: [UInt8] = withUnsafeBytes(of: &palette) { Array($0.prefix(16 * 3)) }
                return (0..<16).map { i -> NSColor in
                    let r = CGFloat(bytes[i * 3]) / 255
                    let g = CGFloat(bytes[i * 3 + 1]) / 255
                    let b = CGFloat(bytes[i * 3 + 2]) / 255
                    return NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
                }
            }
        }
        return defaultPalette
    }

    private static let defaultHex: [Int] = [
        0x616161, 0xff8272, 0xb4fa72, 0xfefdc2, 0xa5d5fe, 0xff8ffd, 0xd0d1fe, 0xf1f1f1,
        0x8e8e8e, 0xffc4bd, 0xd6fcb9, 0xfefdd5, 0xc1e3fe, 0xffb1fe, 0xe5e6fe, 0xfeffff,
    ]
    private static let defaultPalette: [NSColor] = defaultHex.map { (value: Int) -> NSColor in
        let r = CGFloat(value >> 16) / 255
        let g = CGFloat((value >> 8) & 0xff) / 255
        let b = CGFloat(value & 0xff) / 255
        return NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
    }

    static var background: NSColor { configColor("background") ?? .black }
    static var foreground: NSColor { configColor("foreground") ?? .white }

    /// The background with the foreground over it at `amount`: Warp's surfaces (5%, 10%, 15%).
    static func surface(_ amount: CGFloat) -> NSColor {
        background.blended(withFraction: amount, of: foreground) ?? background
    }

    /// Warp's syntax colors (W: `syntax_highlighting_color_map`), from the normal ANSI colors.
    static func color(for role: UmiSyntax.Role, in palette: [NSColor]) -> NSColor {
        switch role {
        case .keyword: return palette[5]
        case .function: return palette[4]
        case .string, .number: return palette[2]
        case .type, .tag: return palette[1]
        case .comment: return palette[3]
        case .property: return palette[6]
        }
    }

    static func hex(_ color: NSColor) -> String {
        let c = color.usingColorSpace(.sRGB) ?? color
        return String(format: "#%02x%02x%02x", Int((c.redComponent * 255).rounded()),
                      Int((c.greenComponent * 255).rounded()), Int((c.blueComponent * 255).rounded()))
    }
}

// MARK: - Git marks

/// How a line differs from the file's last commit (W: `code/editor/diff.rs`).
enum UmiDiffMark: String {
    case added, changed, removed

    /// Green, yellow, red from the terminal's normal colors.
    @MainActor func color(_ palette: [NSColor]) -> NSColor {
        switch self {
        case .added: return palette[2]
        case .changed: return palette[3]
        case .removed: return palette[1]
        }
    }
}

enum UmiGitDiff {
    /// The file as of HEAD, or nil when it isn't tracked (or isn't in a repository).
    static func headText(of url: URL, encoding: String.Encoding) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", url.deletingLastPathComponent().path, "show", "HEAD:./\(url.lastPathComponent)"]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: encoding) ?? String(decoding: data, as: UTF8.self)
    }

    /// Marks by 0-based line of `text`: added and changed lines, and a removal mark on the line
    /// after lines that were deleted.
    static func marks(base: String, text: String) -> [Int: UmiDiffMark] {
        let old = base.split(separator: "\n", omittingEmptySubsequences: false)
        let new = text.split(separator: "\n", omittingEmptySubsequences: false)
        let difference = new.difference(from: old)
        var removed = Set<Int>()
        var inserted = Set<Int>()
        for change in difference {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        var marks: [Int: UmiDiffMark] = [:]
        var i = 0
        var j = 0
        while i < old.count || j < new.count {
            guard removed.contains(i) || inserted.contains(j) else {
                i += 1
                j += 1
                continue
            }
            let start = j
            var removedCount = 0
            while removed.contains(i) || inserted.contains(j) {
                while removed.contains(i) { i += 1; removedCount += 1 }
                while inserted.contains(j) { j += 1 }
            }
            if j == start {
                marks[min(start, max(new.count - 1, 0))] = .removed
            } else {
                for line in start..<j { marks[line] = removedCount == 0 ? .added : .changed }
            }
        }
        return marks
    }
}

// MARK: - Find

/// The find bar's state (W: `code/editor/find/view.rs`).
@MainActor
final class UmiFindModel: ObservableObject {
    @Published var isOpen = false
    @Published var query = ""
    @Published var replacement = ""
    @Published var regex = false
    @Published var caseSensitive = false
    @Published var preserveCase = false
    @Published var replaceOpen = false
    @Published private(set) var matches: [NSRange] = []
    @Published private(set) var selected: Int?

    /// Warp's "n/N": the selected match (1-based, "?" when none) over the count.
    var countLabel: String { "\(selected.map { String($0 + 1) } ?? "?")/\(matches.count)" }

    static let limit = 10_000

    /// Find the query in `text`; select the first match at or after `from` (or keep the one
    /// selected, when `keep`).
    func search(_ text: String, from location: Int, keep: Bool = false) {
        let previous = selected.flatMap { matches.indices.contains($0) ? matches[$0] : nil }
        matches = Self.matches(of: query, in: text, regex: regex, caseSensitive: caseSensitive)
        guard !matches.isEmpty else {
            selected = nil
            return
        }
        if keep, let previous, let same = matches.firstIndex(where: { $0.location >= previous.location }) {
            selected = same
        } else {
            selected = matches.firstIndex(where: { $0.location >= location }) ?? 0
        }
    }

    static func matches(of query: String, in text: String, regex: Bool, caseSensitive: Bool) -> [NSRange] {
        guard !query.isEmpty else { return [] }
        let ns = text as NSString
        let all = NSRange(location: 0, length: ns.length)
        if regex {
            let options: NSRegularExpression.Options = caseSensitive ? [.anchorsMatchLines] : [.anchorsMatchLines, .caseInsensitive]
            guard let expression = try? NSRegularExpression(pattern: query, options: options) else { return [] }
            var found: [NSRange] = []
            expression.enumerateMatches(in: text, range: all) { result, _, stop in
                guard let range = result?.range, range.length > 0 else { return }
                found.append(range)
                if found.count >= limit { stop.pointee = true }
            }
            return found
        }
        let options: NSString.CompareOptions = caseSensitive ? [.literal] : [.literal, .caseInsensitive]
        var found: [NSRange] = []
        var start = 0
        while start < ns.length, found.count < limit {
            let range = ns.range(of: query, options: options, range: NSRange(location: start, length: ns.length - start))
            guard range.location != NSNotFound, range.length > 0 else { break }
            found.append(range)
            start = NSMaxRange(range)
        }
        return found
    }

    func step(_ offset: Int) {
        guard !matches.isEmpty else { return }
        selected = ((selected ?? (offset > 0 ? -1 : 0)) + offset + matches.count) % matches.count
    }

    func select(_ index: Int?) { selected = index }

    /// The replacement for a match: regex templates ($1) expand, and "preserve case" follows the
    /// matched text's case (all upper, all lower, or capitalized).
    func replacement(for range: NSRange, in text: String) -> String {
        var result = replacement
        if regex {
            let options: NSRegularExpression.Options = caseSensitive ? [.anchorsMatchLines] : [.anchorsMatchLines, .caseInsensitive]
            if let expression = try? NSRegularExpression(pattern: query, options: options),
               let match = expression.firstMatch(in: text, range: range) {
                result = expression.replacementString(for: match, in: text, offset: 0, template: replacement)
            }
        }
        guard preserveCase else { return result }
        let matched = (text as NSString).substring(with: range)
        let letters = matched.filter(\.isLetter)
        guard !letters.isEmpty else { return result }
        if letters.allSatisfy(\.isUppercase) && letters.count > 1 { return result.uppercased() }
        if letters.allSatisfy(\.isLowercase) { return result.lowercased() }
        if let first = letters.first, first.isUppercase {
            return result.prefix(1).uppercased() + result.dropFirst()
        }
        return result
    }
}

/// A find or go-to-line text field: Enter, Shift-Enter, Escape and Tab go to the editor.
struct UmiBoxField: NSViewRepresentable {
    let label: String
    let placeholder: String
    @Binding var text: String
    var onEnter: (_ shift: Bool) -> Void = { _ in }
    var onEscape: () -> Void = {}
    var onTab: (() -> Void)?
    var register: (NSTextField) -> Void = { _ in }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 12)
        field.textColor = UmiTheme.textNSColor
        field.placeholderAttributedString = NSAttributedString(
            string: placeholder,
            attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: UmiTheme.textNSColor.withAlphaComponent(0.4)])
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.lineBreakMode = .byClipping
        field.stringValue = text
        field.delegate = context.coordinator
        field.setAccessibilityLabel(label)
        register(field)
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: UmiBoxField
        init(_ parent: UmiBoxField) { self.parent = parent }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
                parent.onEnter(NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false)
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                parent.onEscape()
                return true
            case #selector(NSResponder.insertTab(_:)), #selector(NSResponder.insertBacktab(_:)):
                guard let onTab = parent.onTab else { return false }
                onTab()
                return true
            default:
                return false
            }
        }
    }
}

/// Warp's find bar, floating at the top right of the editor: next/previous, the count, close; the
/// query with regex and case toggles and Select all; the replacement with preserve case and
/// Replace all.
struct UmiFindBar: View {
    @ObservedObject var model: UmiFindModel
    let editor: UmiCodeEditor

    private let row: CGFloat = 24

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                icon("arrow.down", "Next match") { editor.findStep(1) }
                icon("arrow.up", "Previous match") { editor.findStep(-1) }
                Rectangle().fill(Color(UmiCodeLook.surface(0.15))).frame(width: 1, height: row)
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundColor(UmiTheme.textSecondary)
                    .frame(width: row, height: row)
                Spacer(minLength: 0)
                Text(model.countLabel)
                    .font(.system(size: 12))
                    .foregroundColor(UmiTheme.textSecondary)
                    .accessibilityLabel("Matches")
                    .accessibilityValue(model.countLabel)
                icon("xmark", "Close find") { editor.closeFind() }
            }
            HStack(spacing: 0) {
                icon(model.replaceOpen ? "chevron.down" : "chevron.right", "Toggle replace") {
                    model.replaceOpen.toggle()
                    if model.replaceOpen { editor.focusReplaceField() }
                }
                .padding(.horizontal, 4)
                HStack(spacing: 0) {
                    UmiBoxField(label: "Find", placeholder: "Find", text: $model.query,
                                onEnter: { shift in editor.findStep(shift ? -1 : 1) },
                                onEscape: { editor.closeFind() },
                                onTab: { if model.replaceOpen { editor.focusReplaceField() } },
                                register: { editor.findField = $0 })
                        .frame(height: row)
                    toggle(".*", "Regex toggle", on: $model.regex)
                    toggle("Aa", "Case sensitive search", on: $model.caseSensitive)
                }
                .padding(.leading, 8)
                .padding(.trailing, 4)
                .background(field)
                .padding(.trailing, 8)
                textButton("Select all") { editor.selectAllMatches() }
            }
            if model.replaceOpen {
                HStack(spacing: 0) {
                    HStack(spacing: 0) {
                        UmiBoxField(label: "Replace", placeholder: "Replace", text: $model.replacement,
                                    onEnter: { _ in editor.replaceCurrent() },
                                    onEscape: { editor.closeFind() },
                                    onTab: { editor.focusFindField() },
                                    register: { editor.replaceField = $0 })
                            .frame(height: row)
                        toggle("AB", "Preserve case", on: $model.preserveCase)
                    }
                    .padding(.leading, 8)
                    .padding(.trailing, 4)
                    .background(field)
                    .padding(.leading, 2 * 4 + row + 8 - 8)
                    .padding(.trailing, 8)
                    textButton("Replace all") { editor.replaceAll() }
                }
                .padding(.top, 4)
            }
        }
        .padding(4)
        .frame(width: 500)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(UmiCodeLook.surface(0.10))))
        .shadow(color: .black.opacity(0.35), radius: 6, y: 2)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Find bar")
    }

    private var field: some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(Color(UmiCodeLook.surface(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(UmiCodeLook.surface(0.15)), lineWidth: 1))
    }

    private func icon(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11, weight: .medium)).frame(width: row, height: row)
                .contentShape(Rectangle())
        }
        .buttonStyle(UmiIconButtonStyle(size: row))
        .help(label)
        .accessibilityLabel(label)
    }

    private func toggle(_ glyph: String, _ label: String, on: Binding<Bool>) -> some View {
        Button { on.wrappedValue.toggle() } label: {
            Text(glyph)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundColor(on.wrappedValue ? UmiTheme.textPrimary : UmiTheme.textSecondary)
                .frame(width: row - 4, height: row - 4)
                .background(RoundedRectangle(cornerRadius: 4).fill(on.wrappedValue ? UmiTheme.accent.opacity(0.25) : .clear))
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(on.wrappedValue ? UmiTheme.accent : .clear, lineWidth: 1))
                .padding(2)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
        .accessibilityValue(on.wrappedValue ? "on" : "off")
        .accessibilityAddTraits(on.wrappedValue ? .isSelected : [])
    }

    private func textButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 12)).foregroundColor(UmiTheme.textPrimary)
                .frame(width: 72, height: row)
                .background(RoundedRectangle(cornerRadius: 4).fill(Color(UmiCodeLook.surface(0.15))))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}

// MARK: - Go to line

@MainActor
final class UmiGoToLineModel: ObservableObject {
    @Published var isOpen = false
    @Published var input = ""
    @Published var error: String?
}

/// Warp's "Go to line" box (W: `code/editor/goto_line/view.rs`): top centre, 300 wide.
struct UmiGoToLineBox: View {
    @ObservedObject var model: UmiGoToLineModel
    let editor: UmiCodeEditor

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Go to line").font(.system(size: 12)).foregroundColor(UmiTheme.textPrimary)
            UmiBoxField(label: "Go to line", placeholder: "Line number:Column", text: $model.input,
                        onEnter: { _ in editor.confirmGoToLine() },
                        onEscape: { editor.closeGoToLine() },
                        register: { editor.goToField = $0 })
                .frame(height: 16)
                .padding(.leading, 8)
                .padding(.trailing, 4)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color(UmiCodeLook.surface(0.05)))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(UmiCodeLook.surface(0.15)), lineWidth: 1)))
            if let error = model.error {
                Text(error).font(.system(size: 11)).foregroundColor(Color(UmiCodeLook.palette()[1]))
                    .accessibilityLabel(error)
            }
        }
        .padding(4)
        .frame(width: 300)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(UmiCodeLook.surface(0.10))))
        .shadow(color: .black.opacity(0.35), radius: 6, y: 2)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Go to line")
    }
}

// MARK: - The gutter

/// Line numbers, centred in Warp's 94-point gutter, in the terminal's font: the current line's at
/// 90% of the text color, the others at 60%. Git marks are 3-point bars along its left edge.
final class UmiGutterView: NSRulerView {
    static let width: CGFloat = 94
    weak var editor: UmiCodeEditor?

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override var requiredThickness: CGFloat { Self.width }

    override func draw(_ dirtyRect: NSRect) {
        MainActor.assumeIsolated { editor?.drawGutter(in: self, rect: dirtyRect) }
    }
}

// MARK: - The source editor

/// The parts of a file pane's source view beyond plain text: the terminal's font with no soft
/// wrap, line numbers and git marks, the current line, syntax colors, find and replace, go to
/// line and toggle comment (SPEC E-13 to E-16).
@MainActor
final class UmiCodeEditor: NSObject, NSTextStorageDelegate {
    weak var doc: UmiDocument?
    weak var textView: UmiEditorTextView?
    weak var scroll: NSScrollView?
    weak var container: NSView?
    weak var pane: Ghostty.SurfaceView?
    let gutter: UmiGutterView
    let find = UmiFindModel()
    let goTo = UmiGoToLineModel()
    let language: UmiSyntax.Language?

    weak var findField: NSTextField?
    weak var replaceField: NSTextField?
    weak var goToField: NSTextField?
    private var findHost: NSView?
    private var goToHost: NSView?

    private(set) var font: NSFont
    private var palette: [NSColor] = UmiCodeLook.palette()
    private(set) var baseColor: NSColor = UmiTheme.textNSColor
    /// Where each line starts (UTF-16 offsets).
    private var lineStarts: [Int] = [0]
    private var version = 0
    private var highlightWork: DispatchWorkItem?
    private(set) var spans: [UmiSyntax.Span] = []
    private var diffBase: String??
    private var diffWork: DispatchWorkItem?
    private(set) var diffMarks: [Int: UmiDiffMark] = [:]
    private var observers: [NSObjectProtocol] = []
    private var cancellables: Set<AnyCancellable> = []

    /// Files longer than this aren't colored (the editor holds files up to 16 MB).
    static let highlightLimit = 2_000_000

    init(doc: UmiDocument, textView: UmiEditorTextView, scroll: NSScrollView, container: NSView,
         pane: Ghostty.SurfaceView?) {
        self.doc = doc
        self.textView = textView
        self.scroll = scroll
        self.container = container
        self.pane = pane
        self.language = UmiSyntax.language(forFileName: doc.url.lastPathComponent)
        self.font = UmiCodeLook.font(of: pane)
        self.gutter = UmiGutterView(scrollView: scroll, orientation: .verticalRuler)
        super.init()
        gutter.editor = self
        gutter.clientView = textView
        gutter.ruleThickness = UmiGutterView.width
        gutter.reservedThicknessForMarkers = 0
        gutter.reservedThicknessForAccessoryView = 0
        scroll.verticalRulerView = gutter
        scroll.hasVerticalRuler = true
        scroll.rulersVisible = true
        textView.code = self
        textView.textStorage?.delegate = self
        applyFont()
        textChanged()
        observers.append(NotificationCenter.default.addObserver(
            forName: NSTextView.didChangeSelectionNotification, object: textView, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.selectionChanged() }
            })
        observers.append(NotificationCenter.default.addObserver(
            forName: .ghosttyConfigDidChange, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.lookChanged() }
            })
        find.$query.dropFirst().sink { [weak self] _ in DispatchQueue.main.async { self?.refind(fromSelection: true) } }
            .store(in: &cancellables)
        Publishers.Merge(find.$regex.dropFirst(), find.$caseSensitive.dropFirst())
            .sink { [weak self] _ in DispatchQueue.main.async { self?.refind(fromSelection: true) } }
            .store(in: &cancellables)
        reloadDiffBase()
    }

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    /// A new text view for code: TextKit 1 (for the gutter and match colors), no soft wrap, long
    /// lines scroll sideways.
    static func makeScrollView() -> (NSScrollView, UmiEditorTextView) {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = false
        container.heightTracksTextView = false
        layout.addTextContainer(container)
        let size = scroll.contentSize
        let textView = UmiEditorTextView(frame: NSRect(origin: .zero, size: size), textContainer: container)
        textView.minSize = NSSize(width: 0, height: size.height)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = true
        textView.autoresizingMask = [.width]
        scroll.documentView = textView
        return (scroll, textView)
    }

    var wraps: Bool { textView?.textContainer?.widthTracksTextView ?? true }

    // MARK: Look

    private func applyFont() {
        guard let textView else { return }
        baseColor = UmiTheme.textNSColor
        textView.font = font
        textView.typingAttributes = [.font: font, .foregroundColor: baseColor]
        textView.textStorage?.addAttribute(.font, value: font, range: NSRange(location: 0, length: textView.textStorage?.length ?? 0))
        gutter.needsDisplay = true
    }

    /// The terminal's config changed (font, colors) or the theme went light/dark.
    func lookChanged() {
        font = UmiCodeLook.font(of: pane)
        palette = UmiCodeLook.palette()
        applyFont()
        applyHighlights()
        textView?.needsDisplay = true
    }

    // MARK: Edits

    nonisolated func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions,
                                 range editedRange: NSRange, changeInLength delta: Int) {
        guard editedMask.contains(.editedCharacters) else { return }
        MainActor.assumeIsolated {
            // After the edit is processed (attributes can't change while it is).
            DispatchQueue.main.async { [weak self] in self?.textChanged() }
        }
    }

    private func textChanged() {
        guard let textView else { return }
        version &+= 1
        lineStarts = Self.lineStarts(of: textView.string)
        // Text set as a whole (a reload) comes in without the code font.
        if baseColor != UmiTheme.textNSColor || (textView.textStorage?.length ?? 0 > 0
            && textView.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont != font) {
            applyFont()
        }
        scheduleHighlight()
        scheduleDiff()
        if find.isOpen { refind(fromSelection: false, keep: true) }
        gutter.needsDisplay = true
    }

    static func lineStarts(of text: String) -> [Int] {
        var starts = [0]
        let utf16 = text.utf16
        var offset = 0
        for unit in utf16 {
            offset += 1
            if unit == 10 { starts.append(offset) }
        }
        return starts
    }

    /// The 0-based line holding a UTF-16 offset.
    func line(at offset: Int) -> Int {
        var low = 0
        var high = lineStarts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if lineStarts[mid] <= offset { low = mid } else { high = mid - 1 }
        }
        return low
    }

    var lineCount: Int { lineStarts.count }
    var currentLine: Int { line(at: textView?.selectedRange().location ?? 0) }

    private func selectionChanged() {
        guard let textView else { return }
        textView.setNeedsDisplay(textView.visibleRect)
        gutter.needsDisplay = true
    }

    // MARK: Syntax colors

    private func scheduleHighlight() {
        guard let language, let textView else { return }
        highlightWork?.cancel()
        let text = textView.string
        guard (text as NSString).length <= Self.highlightLimit else {
            spans = []
            return
        }
        let version = self.version
        let id = language.id
        let work = DispatchWorkItem {
            let spans = UmiSyntax.highlights(in: text, language: id)
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.version == version else { return }
                    self.spans = spans
                    self.applyHighlights()
                }
            }
        }
        highlightWork = work
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + (spans.isEmpty ? 0 : 0.05), execute: work)
    }

    private func applyHighlights() {
        guard let storage = textView?.textStorage else { return }
        let length = storage.length
        storage.beginEditing()
        storage.addAttribute(.foregroundColor, value: baseColor, range: NSRange(location: 0, length: length))
        for span in spans where NSMaxRange(span.range) <= length {
            storage.addAttribute(.foregroundColor, value: UmiCodeLook.color(for: span.role, in: palette), range: span.range)
        }
        storage.endEditing()
    }

    /// The color shown at a UTF-16 offset (for checks).
    func color(at offset: Int) -> NSColor? {
        guard let storage = textView?.textStorage, offset < storage.length else { return nil }
        return storage.attribute(.foregroundColor, at: offset, effectiveRange: nil) as? NSColor
    }

    // MARK: Git marks

    /// Read the file as of the last commit again (on open, save, reload and focus).
    func reloadDiffBase() {
        guard let doc else { return }
        let url = doc.url
        let encoding = doc.encoding
        DispatchQueue.global(qos: .utility).async {
            let base = UmiGitDiff.headText(of: url, encoding: encoding)
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.diffBase = .some(base)
                    self.scheduleDiff(now: true)
                }
            }
        }
    }

    private func scheduleDiff(now: Bool = false) {
        guard let textView, case .some(let base) = diffBase else { return }
        diffWork?.cancel()
        guard let base else {
            if !diffMarks.isEmpty {
                diffMarks = [:]
                gutter.needsDisplay = true
            }
            return
        }
        let text = textView.string
        let version = self.version
        let work = DispatchWorkItem {
            let marks = UmiGitDiff.marks(base: base, text: text)
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.version == version else { return }
                    self.diffMarks = marks
                    self.gutter.needsDisplay = true
                }
            }
        }
        diffWork = work
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + (now ? 0 : 0.3), execute: work)
    }

    // MARK: Drawing

    /// Fill the caret's line with the surface color (Warp's current-line highlight), only while
    /// nothing is selected.
    func drawCurrentLine(in rect: NSRect) {
        guard let textView, let layout = textView.layoutManager, let container = textView.textContainer,
              textView.selectedRanges.count == 1, textView.selectedRange().length == 0 else { return }
        let caret = textView.selectedRange().location
        var lineRect: NSRect
        if caret >= (textView.string as NSString).length, !layout.extraLineFragmentRect.isEmpty {
            lineRect = layout.extraLineFragmentRect
        } else {
            layout.ensureLayout(for: container)
            let glyph = layout.glyphIndexForCharacter(at: min(caret, max((textView.string as NSString).length - 1, 0)))
            lineRect = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        }
        lineRect.origin.x = 0
        lineRect.origin.y += textView.textContainerOrigin.y
        lineRect.size.width = max(textView.bounds.width, textView.visibleRect.maxX)
        guard lineRect.intersects(rect) else { return }
        UmiCodeLook.foreground.withAlphaComponent(0.10).setFill()
        lineRect.fill(using: .sourceOver)
    }

    fileprivate func drawGutter(in ruler: NSRulerView, rect: NSRect) {
        guard let textView, let layout = textView.layoutManager, let container = textView.textContainer else { return }
        let text = textView.string as NSString
        let visible = textView.visibleRect
        let glyphs = layout.glyphRange(forBoundingRect: visible, in: container)
        let chars = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        let numberFont = font
        let current = currentLine
        let dim = baseColor.withAlphaComponent(0.6)
        let bright = baseColor.withAlphaComponent(0.9)
        let origin = textView.textContainerOrigin.y
        var lineIndex = line(at: chars.location)

        func draw(line: Int, fragment: NSRect) {
            let y = ruler.convert(NSPoint(x: 0, y: fragment.minY + origin), from: textView).y
            guard y + fragment.height >= rect.minY, y <= rect.maxY else { return }
            let label = "\(line + 1)" as NSString
            let attributes: [NSAttributedString.Key: Any] = [.font: numberFont, .foregroundColor: line == current ? bright : dim]
            let size = label.size(withAttributes: attributes)
            label.draw(at: NSPoint(x: (UmiGutterView.width - size.width) / 2, y: y + (fragment.height - size.height) / 2),
                       withAttributes: attributes)
            if let mark = diffMarks[line] {
                mark.color(palette).setFill()
                let height = mark == .removed ? min(4, fragment.height) : fragment.height
                NSRect(x: 0, y: y, width: 3, height: height).fill()
            }
        }

        while lineIndex < lineStarts.count, lineStarts[lineIndex] <= NSMaxRange(chars) {
            let start = lineStarts[lineIndex]
            if start < text.length {
                let glyph = layout.glyphIndexForCharacter(at: start)
                draw(line: lineIndex, fragment: layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil))
            } else if !layout.extraLineFragmentRect.isEmpty {
                draw(line: lineIndex, fragment: layout.extraLineFragmentRect)
            } else if text.length == 0 {
                draw(line: 0, fragment: NSRect(x: 0, y: 0, width: 1, height: font.ascender - font.descender + font.leading))
            }
            lineIndex += 1
        }
    }

    // MARK: Find

    private func host<V: View>(_ view: V) -> NSView {
        let hosting = NSHostingView(rootView: view)
        hosting.translatesAutoresizingMaskIntoConstraints = false
        hosting.sizingOptions = [.intrinsicContentSize]
        return hosting
    }

    /// ⌘F: open the find bar with the selection as the query (one line of it), its field focused.
    func openFind(replace: Bool = false) {
        guard let container, let textView else { return }
        closeGoToLine(focusEditor: false)
        let selection = textView.selectedRange()
        if selection.length > 0, selection.length < 500 {
            let selected = (textView.string as NSString).substring(with: selection)
            if !selected.contains("\n") { find.query = selected }
        }
        if replace { find.replaceOpen = true }
        if findHost == nil {
            let hosting = host(UmiFindBar(model: find, editor: self))
            container.addSubview(hosting)
            NSLayoutConstraint.activate([
                hosting.topAnchor.constraint(equalTo: container.topAnchor, constant: 10),
                hosting.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            ])
            findHost = hosting
        }
        find.isOpen = true
        findHost?.isHidden = false
        refind(fromSelection: true)
        DispatchQueue.main.async { [weak self] in
            if replace { self?.focusReplaceField() } else { self?.focusFindField() }
        }
    }

    func focusFindField() {
        guard let field = findField, let window = field.window else { return }
        window.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    func focusReplaceField() {
        DispatchQueue.main.async { [weak self] in
            guard let field = self?.replaceField, let window = field.window else { return }
            window.makeFirstResponder(field)
            field.currentEditor()?.selectAll(nil)
        }
    }

    /// Esc: close the bar and go back to the text.
    func closeFind(focusEditor: Bool = true) {
        guard find.isOpen else { return }
        find.isOpen = false
        findHost?.isHidden = true
        clearMatchColors()
        if focusEditor, let textView { textView.window?.makeFirstResponder(textView) }
    }

    /// ⌘G / ⇧⌘G and Enter / Shift-Enter: the next or previous match, selected in the text.
    func findStep(_ offset: Int) {
        if !find.isOpen { openFind() }
        guard !find.matches.isEmpty else {
            NSSound.beep()
            return
        }
        find.step(offset)
        showSelectedMatch()
    }

    private func refind(fromSelection: Bool, keep: Bool = false) {
        guard let textView, find.isOpen else { return }
        find.search(textView.string, from: textView.selectedRange().location, keep: keep && !fromSelection)
        if fromSelection { showSelectedMatch() } else { colorMatches() }
    }

    private func showSelectedMatch() {
        guard let textView, let index = find.selected, find.matches.indices.contains(index) else {
            colorMatches()
            return
        }
        let range = find.matches[index]
        textView.setSelectedRange(range)
        textView.scrollRangeToVisible(range)
        colorMatches()
    }

    /// Warp's match colors: yellow for every match, orange for the selected one.
    private func colorMatches() {
        guard let layout = textView?.layoutManager, let length = textView?.textStorage?.length else { return }
        layout.removeTemporaryAttribute(.backgroundColor, forCharacterRange: NSRange(location: 0, length: length))
        guard find.isOpen else { return }
        let match = NSColor(srgbRed: 255 / 255, green: 254 / 255, blue: 61 / 255, alpha: 180 / 255)
        let selected = NSColor(srgbRed: 238 / 255, green: 146 / 255, blue: 59 / 255, alpha: 180 / 255)
        for (index, range) in find.matches.enumerated() where NSMaxRange(range) <= length {
            layout.addTemporaryAttribute(.backgroundColor, value: index == find.selected ? selected : match, forCharacterRange: range)
        }
    }

    private func clearMatchColors() {
        guard let layout = textView?.layoutManager, let length = textView?.textStorage?.length else { return }
        layout.removeTemporaryAttribute(.backgroundColor, forCharacterRange: NSRange(location: 0, length: length))
    }

    /// Enter in the replacement: replace the selected match and go to the next one.
    func replaceCurrent() {
        guard let textView, let index = find.selected, find.matches.indices.contains(index) else {
            NSSound.beep()
            return
        }
        let range = find.matches[index]
        let replacement = find.replacement(for: range, in: textView.string)
        guard textView.shouldChangeText(in: range, replacementString: replacement) else { return }
        textView.textStorage?.replaceCharacters(in: range, with: replacement)
        textView.didChangeText()
        textView.undoManager?.setActionName("Replace")
        let after = range.location + (replacement as NSString).length
        textView.setSelectedRange(NSRange(location: after, length: 0))
        find.search(textView.string, from: after)
        showSelectedMatch()
    }

    /// Replace every match, as one undo step.
    func replaceAll() {
        guard let textView, !find.matches.isEmpty else {
            NSSound.beep()
            return
        }
        let text = textView.string
        let result = NSMutableString(string: text)
        for range in find.matches.reversed() {
            result.replaceCharacters(in: range, with: find.replacement(for: range, in: text))
        }
        let all = NSRange(location: 0, length: (text as NSString).length)
        let first = find.matches[0].location
        guard textView.shouldChangeText(in: all, replacementString: result as String) else { return }
        textView.textStorage?.replaceCharacters(in: all, with: result as String)
        textView.didChangeText()
        textView.undoManager?.setActionName("Replace All")
        textView.setSelectedRange(NSRange(location: min(first, result.length), length: 0))
        find.search(textView.string, from: first)
        colorMatches()
    }

    /// Select every match in the text and go back to it.
    func selectAllMatches() {
        guard let textView, !find.matches.isEmpty else {
            NSSound.beep()
            return
        }
        let ranges = find.matches.map { NSValue(range: $0) }
        closeFind(focusEditor: true)
        textView.selectedRanges = ranges
    }

    // MARK: Go to line

    /// ⌃G: the "Line number:Column" box.
    func openGoToLine() {
        guard let container else { return }
        closeFind(focusEditor: false)
        goTo.input = ""
        goTo.error = nil
        if goToHost == nil {
            let hosting = host(UmiGoToLineBox(model: goTo, editor: self))
            container.addSubview(hosting)
            NSLayoutConstraint.activate([
                hosting.topAnchor.constraint(equalTo: container.topAnchor),
                hosting.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            ])
            goToHost = hosting
        }
        goTo.isOpen = true
        goToHost?.isHidden = false
        DispatchQueue.main.async { [weak self] in
            guard let field = self?.goToField, let window = field.window else { return }
            window.makeFirstResponder(field)
        }
    }

    func closeGoToLine(focusEditor: Bool = true) {
        guard goTo.isOpen else { return }
        goTo.isOpen = false
        goToHost?.isHidden = true
        if focusEditor, let textView { textView.window?.makeFirstResponder(textView) }
    }

    /// Enter: go to "line" or "line:column" (both 1-based), or say what's wrong (Warp's messages).
    func confirmGoToLine() {
        let input = goTo.input.trimmingCharacters(in: .whitespaces)
        guard !input.isEmpty else {
            goTo.error = "Please enter a line number"
            return
        }
        let parts = input.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard let line = Int(parts[0]), line >= 1 else {
            goTo.error = "Please enter a valid line number"
            return
        }
        var column: Int?
        if parts.count > 1, !parts[1].isEmpty {
            guard let value = Int(parts[1]) else {
                goTo.error = "Please enter a valid column number"
                return
            }
            column = value
        }
        jump(line: line, column: column)
        closeGoToLine()
    }

    /// Put the caret on a line (past the end: the last line) and column, and show it.
    func jump(line: Int, column: Int?) {
        guard let textView else { return }
        let text = textView.string as NSString
        let index = min(max(line, 1), lineStarts.count) - 1
        let start = lineStarts[index]
        let end = index + 1 < lineStarts.count ? lineStarts[index + 1] - 1 : text.length
        let location = min(start + max((column ?? 1) - 1, 0), end)
        let target = NSRange(location: location, length: 0)
        textView.setSelectedRange(target)
        textView.scrollRangeToVisible(target)
    }

    // MARK: Toggle comment

    /// ⌘/: comment or uncomment the selected lines with the language's prefix, after each line's
    /// indentation (W: `toggle_comments`): uncomment when every non-blank line has it.
    func toggleComment() {
        guard let textView, let prefix = language?.commentPrefix else {
            NSSound.beep()
            return
        }
        // XML's prefix needs its closing half.
        let suffix = prefix == "<!--" ? " -->" : ""
        let text = textView.string as NSString
        let selection = textView.selectedRange()
        var probe = selection
        if probe.length > 0, text.character(at: NSMaxRange(probe) - 1) == 10 { probe.length -= 1 }
        let range = text.lineRange(for: probe)
        let block = text.substring(with: range)
        let endsWithNewline = block.hasSuffix("\n")
        var lines = block.components(separatedBy: "\n")
        if endsWithNewline { lines.removeLast() }
        func split(_ line: String) -> (indent: Substring, rest: Substring) {
            let indent = line.prefix(while: { $0 == " " || $0 == "\t" })
            return (indent, line[indent.endIndex...])
        }
        let nonBlank = lines.filter { !split($0).rest.isEmpty }
        guard !nonBlank.isEmpty else {
            NSSound.beep()
            return
        }
        let uncomment = nonBlank.allSatisfy { split($0).rest.hasPrefix(prefix) }
        let changed = lines.map { line -> String in
            let (indent, rest) = split(line)
            guard !rest.isEmpty else { return line }
            if uncomment {
                var body = rest.dropFirst(prefix.count)
                if body.hasPrefix(" ") { body = body.dropFirst() }
                if !suffix.isEmpty, body.hasSuffix(suffix) { body = body.dropLast(suffix.count) }
                return String(indent) + body
            }
            return String(indent) + prefix + " " + rest + suffix
        }
        let replacement = changed.joined(separator: "\n") + (endsWithNewline ? "\n" : "")
        guard textView.shouldChangeText(in: range, replacementString: replacement) else { return }
        textView.textStorage?.replaceCharacters(in: range, with: replacement)
        textView.didChangeText()
        textView.undoManager?.setActionName("Toggle Comment")
        let newLength = (replacement as NSString).length
        if selection.length > 0 {
            textView.setSelectedRange(NSRange(location: range.location, length: newLength - (endsWithNewline ? 1 : 0)))
        } else {
            let delta = newLength - range.length
            let caret = selection.location + (lines.count == 1 ? delta : 0)
            textView.setSelectedRange(NSRange(location: min(max(caret, range.location), range.location + newLength), length: 0))
        }
    }

    // MARK: Escape

    /// Esc in the text: close the go-to box or the find bar.
    func escape() -> Bool {
        if goTo.isOpen {
            closeGoToLine()
            return true
        }
        if find.isOpen {
            closeFind()
            return true
        }
        return false
    }

    // MARK: Checks

    /// The editor's state for scripted checks (`debug.ui.editor`).
    func debugState() -> [String: Any] {
        var state: [String: Any] = [
            "font": font.fontName, "font_family": font.familyName ?? "", "font_size": Double(font.pointSize),
            "wraps": wraps, "gutter_width": Double(gutter.ruleThickness), "line_numbers": scroll?.rulersVisible ?? false,
            "line_count": lineCount, "current_line": currentLine + 1,
            "language": language?.id ?? "", "highlighted": !spans.isEmpty, "spans": spans.count,
            "diff_marks": Dictionary(uniqueKeysWithValues: diffMarks.map { (String($0.key + 1), $0.value.rawValue) }),
            "selection": textView.map { [$0.selectedRange().location, $0.selectedRange().length] } ?? [],
            "selections": textView?.selectedRanges.count ?? 0,
            "find": [
                "open": find.isOpen, "query": find.query, "replacement": find.replacement, "regex": find.regex,
                "case_sensitive": find.caseSensitive, "preserve_case": find.preserveCase, "replace_open": find.replaceOpen,
                "count": find.countLabel, "matches": find.matches.count, "selected": find.selected.map { $0 + 1 } ?? 0,
                "focused": findField.map { $0.currentEditor() != nil } ?? false,
            ] as [String: Any],
            "go_to_line": ["open": goTo.isOpen, "error": goTo.error ?? "",
                           "focused": goToField.map { $0.currentEditor() != nil } ?? false] as [String: Any],
            "editor_focused": textView.map { $0.window?.firstResponder === $0 } ?? false,
        ]
        state["palette"] = palette.prefix(8).map(UmiCodeLook.hex)
        state["text_color"] = UmiCodeLook.hex(baseColor)
        return state
    }

    /// The color at a 1-based line and column, as "#rrggbb" (for checks).
    func colorHex(line: Int, column: Int) -> String? {
        guard line >= 1, line <= lineStarts.count else { return nil }
        return color(at: lineStarts[line - 1] + column - 1).map(UmiCodeLook.hex)
    }
}

/// `debug.ui.editor` (internal, not the CLI contract): a file pane's editor as the checks see it,
/// and its header menu run by title, through the same code the UI runs.
@MainActor
enum UmiEditorDebug {
    static func handle(_ params: UmiParams, caller: UmiCaller) throws -> [String: Any] {
        let pane = try UmiTopology.pane(params.string("pane"), caller: caller)
        guard let doc = UmiFilePanes.shared.document(of: pane) else { throw UmiError.notFound("that pane shows no file") }
        let menu = UmiFilePaneMenu.items(for: pane, doc: doc)
        if let title = params.string("menu_item") {
            guard let item = menu.first(where: { $0.title == title }) else { throw UmiError.notFound("no menu item \(title)") }
            guard item.enabled else { throw UmiError.badRequest("\(title) is disabled") }
            item.action()
        }
        if let path = params.string("save_as") {
            try UmiEditor.saveAs(doc, to: URL(fileURLWithPath: path), pane: pane)
        }
        var state = doc.code?.debugState() ?? [:]
        if let line = params.int("line"), let column = params.int("column") {
            state["color_at"] = doc.code?.colorHex(line: line, column: column) ?? ""
        }
        state["path"] = (UmiFilePanes.shared.document(of: pane) ?? doc).url.path
        state["mode"] = doc.mode.rawValue
        state["dirty"] = doc.isDirty
        state["changed_on_disk"] = doc.changedOnDisk
        state["menu"] = UmiFilePaneMenu.items(for: pane, doc: doc).map { ["title": $0.title, "enabled": $0.enabled] }
        state["toast"] = UmiToast.last?.text ?? ""
        state["toast_showing"] = UmiToast.isShowing
        return state
    }
}
