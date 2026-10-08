import AppKit

/// Internal control methods (not part of the CLI contract) that drive an agent pane's UI the
/// way a person would, for scripted checks while the accessibility tree is unavailable (a
/// locked screen). `app/macos/TernTests/verify_ui_paths.py` uses them.
@MainActor
enum TernAgentDebug {
    static func handle(_ method: String, _ params: TernParams, caller: TernCaller) throws -> [String: Any] {
        let pane = try TernTopology.pane(params.string("pane"), caller: caller)
        switch method {
        case "debug.agent.pane":
            var out: [String: Any] = ["pane": pane.ternID,
                                      "showing": TernAgentUI.shared.showingTerminal.contains(pane.id) ? "terminal" : "agent"]
            guard let session = TernAgentUI.shared.session(forPane: pane.id) else {
                out["showing"] = "terminal"
                return out
            }
            out["session"] = session
            if let view = TernAgentUI.shared.composer(for: pane.id) as? TernComposerView, let owner = view.owner {
                out["in_window"] = owner.window != nil
                out["transcript"] = owner.transcript.string
                out["composer"] = view.string
                out["composer_focused"] = view.window?.firstResponder === view
                out["texts"] = texts(in: owner)
                out["buttons"] = buttons(in: owner).map(\.title)
                out["frame"] = NSStringFromRect(owner.convert(owner.bounds, to: nil))
                out["pane_frame"] = NSStringFromRect(pane.convert(pane.bounds, to: nil))
                out["header_fitting"] = NSStringFromSize(owner.subviews.first?.fittingSize ?? .zero)
                out["subviews"] = owner.subviews.map { "\(type(of: $0)) \(NSStringFromRect($0.frame))" }
                out["transcript_frame"] = NSStringFromRect(owner.transcript.frame)
                out["container_width"] = owner.transcript.textContainer?.containerSize.width ?? -1
                out["has_ambiguous"] = owner.hasAmbiguousLayout
            }
            return out
        case "debug.agent.type":
            guard let composer = TernAgentUI.shared.composer(for: pane.id) as? TernComposerView else {
                throw TernError.notFound("the pane shows no agent view")
            }
            if let text = params.string("text") {
                if params.bool("replace") ?? true { composer.string = text } else { composer.string += text }
                composer.didChangeText()
            }
            switch params.string("key") {
            case "enter": composer.doCommand(by: #selector(NSResponder.insertNewline(_:)))
            case "escape": composer.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
            default: break
            }
            return ["composer": composer.string]
        case "debug.agent.press":
            guard let composer = TernAgentUI.shared.composer(for: pane.id) as? TernComposerView, let owner = composer.owner else {
                throw TernError.notFound("the pane shows no agent view")
            }
            guard let title = params.string("title") else { throw TernError.badRequest("give a button title") }
            if let field = params.string("field_text") {
                for case let textField as NSTextField in allViews(owner) where textField.isEditable {
                    textField.stringValue = field
                }
            }
            guard let button = buttons(in: owner).first(where: { $0.title == title }) else {
                throw TernError.notFound("no button \"\(title)\" (buttons: \(buttons(in: owner).map(\.title).joined(separator: ", ")))")
            }
            button.performClick(nil)
            return ["pressed": title]
        default:
            throw TernError.badRequest("unknown method \(method)")
        }
    }

    private static func allViews(_ root: NSView) -> [NSView] {
        root.subviews.flatMap { [$0] + allViews($0) }
    }

    private static func buttons(in root: NSView) -> [NSButton] {
        allViews(root).compactMap { $0 as? NSButton }.filter { !$0.isHidden && !$0.title.isEmpty }
    }

    private static func texts(in root: NSView) -> [String] {
        allViews(root).compactMap { ($0 as? NSTextField)?.stringValue }.filter { !$0.isEmpty }
    }
}
