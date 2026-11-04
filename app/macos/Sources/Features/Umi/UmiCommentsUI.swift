import AppKit
import WebKit

/// What a document's view does when the user asks to comment (⌥⌘M, Edit ▸ Add Comment).
@MainActor
protocol UmiCommentTarget: AnyObject {
    func startComment()
}

// MARK: - Changing a document's comments

extension UmiDocument {
    /// Apply a change to the comments (E-11). It goes to the file right away, whatever else is
    /// unsaved: the file on disk gets the change on its own text, and the editor's text (with any
    /// unsaved edits) gets it too, so the edits stay unsaved and nothing else is written.
    func changeComments(_ action: String, _ change: (String) throws -> String) throws {
        let disk = try UmiTextFile.read(url)
        let updated = try change(disk.text)
        try UmiTextFile.write(updated, to: url, encoding: disk.encoding, bom: disk.bom)
        let mine = isDirty ? ((try? change(text)) ?? text) : updated
        adoptSaved(updated, encoding: disk.encoding, bom: disk.bom)
        text = mine
        UmiEvents.shared.emit("comments.changed", ["path": url.path, "action": action])
    }

    /// Add a comment on `range` of `base` (the text the user saw). Returns its id.
    @discardableResult
    func addComment(_ body: String, on range: NSRange, base: String) throws -> String {
        var id = ""
        try changeComments("added") { current in
            guard let moved = UmiComments.relocate(range, from: base, to: current) else {
                throw UmiComments.Failure("that text changed in the file meanwhile; select it again")
            }
            let result = try UmiComments.adding(body, on: moved, in: current, by: UmiComments.userAuthor)
            id = result.id
            return result.text
        }
        return id
    }

    var commentThreads: [UmiComments.Thread] { UmiComments.Document(text).threads }
}

extension UmiComments.Failure: LocalizedError {
    var errorDescription: String? { message }
}

// MARK: - The preview's side

@MainActor
enum UmiCommentsUI {
    /// The content world the margin's script runs in, apart from the page.
    static let world = WKContentWorld.world(name: "umi-comments")

    /// Every open document for `path`, in any tab.
    static func documents(at path: String) -> [UmiDocument] {
        let target = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        return TerminalController.all.flatMap { $0.tabs }.compactMap { $0.editor.document(for: target) }
    }

    /// Agents waiting on a file's review changed (`umi comments wait`).
    static func waitersChanged() {
        for window in TerminalController.all {
            for tab in window.tabs {
                for doc in tab.editor.documents {
                    let count = UmiEvents.shared.waiters(on: doc.url.path)
                    if doc.reviewWaiters != count { doc.reviewWaiters = count }
                }
            }
        }
    }

    /// The user pressed Done on a document's comments.
    static func reviewDone(_ doc: UmiDocument) -> String {
        let waiting = UmiEvents.shared.waiters(on: doc.url.path)
        let open = doc.commentThreads.filter(\.isOpen).count
        UmiEvents.shared.emit("comments.done", ["path": doc.url.path, "open": open])
        if waiting > 0 {
            return waiting == 1 ? "Sent: the agent waiting on this file has your comments." : "Sent to the \(waiting) agents waiting on this file."
        }
        return "No agent is waiting on this file. Your comments are saved in it; an agent can read them with `umi comments`."
    }

    /// Ask for a comment's text (the source view has no margin).
    static func prompt(quote: String, window: NSWindow?, done: @escaping (String) -> Void) {
        let alert = NSAlert()
        alert.messageText = "Comment"
        let shown = quote.count > 120 ? String(quote.prefix(117)) + "…" : quote
        alert.informativeText = "On “\(shown)”"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 64))
        field.placeholderString = "Comment…"
        field.cell?.wraps = true
        field.cell?.isScrollable = false
        alert.accessoryView = field
        alert.addButton(withTitle: "Comment")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        let handle: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .alertFirstButtonReturn else { return }
            let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { done(text) }
        }
        if let window { alert.beginSheetModal(for: window, completionHandler: handle) } else { handle(alert.runModal()) }
    }

    static func show(_ error: Error, for doc: UmiDocument) {
        doc.error = (error as? UmiError)?.message ?? (error as? UmiComments.Failure)?.message ?? error.localizedDescription
        NSSound.beep()
    }

    // MARK: Tests (`debug.ui.comments`)

    /// Drive the margin as the user would, through its script: select words, press Comment, type,
    /// submit, click a control; or read its state.
    static func debug(_ params: UmiParams) async throws -> [String: Any] {
        guard let path = params.string("path") else { throw UmiError.badRequest("give a path") }
        guard let doc = documents(at: path).first else { throw UmiError.notFound("\(path) isn't open") }
        let action = params.string("action") ?? "state"
        if action == "shortcut" {
            // What ⌥⌘M (Edit ▸ Add Comment) does.
            guard let target = doc.commentTarget else { throw UmiError.badRequest("the document isn't shown") }
            target.startComment()
            return ["started": true]
        }
        guard let preview = doc.commentTarget as? UmiMarkdownPreview.Coordinator, let web = preview.web else {
            throw UmiError.badRequest("the document isn't shown in preview")
        }
        let call: String
        var arguments: [String: Any] = [:]
        switch action {
        case "state": call = "return umiComments.state()"
        case "select":
            call = "return umiComments.selectText(text, nth)"
            arguments = ["text": params.string("text") ?? "", "nth": params.int("nth") ?? 0]
        case "add": call = "return umiComments.clickAdd()"
        case "type":
            call = "return umiComments.type(text)"
            arguments = ["text": params.string("text") ?? ""]
        case "submit": call = "return umiComments.submit()"
        case "click":
            call = "return umiComments.click(selector)"
            arguments = ["selector": params.string("selector") ?? ""]
        case "mark":
            call = "return umiComments.clickMark(id)"
            arguments = ["id": params.string("id") ?? ""]
        case "thread":
            call = "return umiComments.select(id)"
            arguments = ["id": params.string("id") ?? ""]
        default: throw UmiError.badRequest("action is state, select, add, type, submit, click, mark, thread or shortcut")
        }
        let result = try await web.callAsyncJavaScript(call, arguments: arguments, in: nil, contentWorld: world)
        if let object = result as? [String: Any] { return object }
        return ["result": result ?? NSNull()]
    }
}

/// Holds the message handler weakly (WebKit keeps its handlers alive).
final class UmiScriptHandlerProxy: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ target: WKScriptMessageHandler) { self.target = target }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}
