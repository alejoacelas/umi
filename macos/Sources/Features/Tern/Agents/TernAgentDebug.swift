import AppKit

/// Internal control methods (not part of the CLI contract) that look at and press a session's
/// read-only view the way a person would, for scripted checks without the accessibility tree.
@MainActor
enum TernAgentDebug {
    static func handle(_ method: String, _ params: TernParams, caller: TernCaller) throws -> [String: Any] {
        let pane = try TernTopology.pane(params.string("pane"), caller: caller)
        let ui = TernAgentUI.shared
        switch method {
        case "debug.agent.pane":
            var out: [String: Any] = ["pane": pane.ternID,
                                      "showing": ui.livePanes.contains(pane.id) ? "live"
                                          : (ui.showingTerminal.contains(pane.id) ? "terminal" : "agent")]
            guard let session = ui.session(forPane: pane.id) else {
                out["showing"] = ui.livePanes.contains(pane.id) ? "live" : "terminal"
                return out
            }
            out["session"] = session
            if let view = ui.focusTarget(for: pane.id) as? TernTranscriptView, let owner = view.owner {
                out["in_window"] = owner.window != nil
                out["transcript"] = owner.transcript.string
                out["focused"] = view.window?.firstResponder === view
                out["texts"] = texts(in: owner)
                out["buttons"] = buttons(in: owner).map(\.title)
                out["frame"] = NSStringFromRect(owner.convert(owner.bounds, to: nil))
                out["pane_frame"] = NSStringFromRect(pane.convert(pane.bounds, to: nil))
            }
            return out
        case "debug.agent.press":
            guard let view = ui.focusTarget(for: pane.id) as? TernTranscriptView, let owner = view.owner else {
                throw TernError.notFound("the pane shows no session view")
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
        allViews(root).compactMap { $0 as? NSButton }.filter { !$0.isHidden && !$0.title.isEmpty && $0.isEnabled }
    }

    private static func texts(in root: NSView) -> [String] {
        allViews(root).compactMap { ($0 as? NSTextField)?.stringValue }.filter { !$0.isEmpty }
    }
}
