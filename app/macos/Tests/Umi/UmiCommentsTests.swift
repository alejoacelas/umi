import Foundation
import Testing
@testable import Ghostty

/// E-11: comments stored in the document (Roughdraft Flavored Markdown). The acceptance suite checks
/// the editor's margin and `umi comments` end to end (tests/test_comments.py).
struct UmiCommentsTests {
    private let doc = """
    # Plan

    We will ship the **new parser** on Friday.

    - one item
    - two items

    ```
    {==not a comment==}{>>literal<<}
    ```

    """

    private func range(of text: String, in doc: String) -> NSRange { (doc as NSString).range(of: text) }

    @Test func addingThenDeletingGivesBackTheFile() throws {
        let a = try UmiComments.adding("Why Friday?", on: range(of: "new parser", in: doc), in: doc, by: "user", at: "2026-11-04T10:00:00.000Z")
        #expect(a.id == "c1")
        #expect(a.text.contains("**{==new parser==}{>>Why Friday?<<}{#c1}**"))
        #expect(a.text.hasSuffix("""
        ---
        comments:
          c1:
            by: user
            at: "2026-11-04T10:00:00.000Z"
            umi-quote: new parser
            umi-body: "Why Friday?"

        """))
        let r = try UmiComments.replying(to: "c1", "The release train.\nSecond line.", in: a.text, by: "AI")
        #expect(r.id == "c2")
        let threads = UmiComments.Document(r.text).threads
        #expect(threads.count == 1)
        #expect(threads[0].quote == "new parser" && threads[0].line == 3 && threads[0].by == "user")
        #expect(threads[0].replies.map(\.body) == ["The release train.\nSecond line."])
        #expect(try UmiComments.deleting("c1", in: r.text) == doc)
    }

    @Test func markupInCodeIsLiteral() {
        #expect(UmiComments.Document(doc).threads.isEmpty)
        #expect(UmiComments.Document("Use `{==x==}{>>y<<}` to comment.\n").threads.isEmpty)
    }

    @Test func resolvingAndReopening() throws {
        let a = try UmiComments.adding("Three?", on: range(of: "two items", in: doc), in: doc, by: "user")
        let resolved = try UmiComments.resolving(a.id, true, note: "made it three", in: a.text)
        let thread = try #require(UmiComments.Document(resolved).threads.first)
        #expect(thread.resolved && thread.resolvedNote == "made it three")
        #expect(resolved.contains("status: resolved"))
        let reopened = try UmiComments.resolving(a.id, false, in: resolved)
        #expect(reopened == a.text)
    }

    @Test func editingARootKeepsItsCopyInStep() throws {
        let a = try UmiComments.adding("First", on: range(of: "one item", in: doc), in: doc, by: "user")
        let edited = try UmiComments.editing(a.id, to: "Second", in: a.text)
        #expect(edited.contains("{>>Second<<}{#c1}") && edited.contains("umi-body: Second"))
    }

    /// An edit that drops the inline markup leaves the comment detached, not lost.
    @Test func aCommentWhoseMarkupIsGoneIsDetached() throws {
        let a = try UmiComments.adding("Stronger verb", on: range(of: "ship", in: doc), in: doc, by: "user")
        let rewritten = a.text.replacingOccurrences(of: "{==ship==}{>>Stronger verb<<}{#c1}", with: "release")
        let thread = try #require(UmiComments.Document(rewritten).threads.first)
        #expect(thread.detached && thread.body == "Stronger verb" && thread.quote == "ship" && thread.line == nil)
        // Deleting it cleans the endmatter up entirely.
        #expect(try UmiComments.deleting("c1", in: rewritten) == doc.replacingOccurrences(of: "ship", with: "release"))
    }

    @Test func wordsDeletedUnderAnAnchor() throws {
        let thread = try #require(UmiComments.Document("One {====}{>>gone<<}{#c1} here.\n").threads.first)
        #expect(thread.anchorDeleted && !thread.detached && thread.body == "gone")
    }

    /// Roughdraft's own files: attribute blocks, comments without ids, replies and suggestions.
    @Test func readsAndAnswersRoughdraftFiles() throws {
        let file = """
        Please revisit {==this sentence==}{>>Needs a source<<}{id="c1" by="user" at="2026-06-14T06:38:34.897Z"} and {==that==}{>>no id<<}.
        Add {++one example++}{#s1}.

        ---
        comments:
          c2:
            body: I can add one.
            by: AI
            at: "2026-04-28T12:05:00.000Z"
            re: c1
        suggestions:
          s1:
            by: AI
            at: "2026-04-28T12:10:00.000Z"

        """
        let threads = UmiComments.Document(file).threads
        #expect(threads.map(\.quote) == ["this sentence", "that"])
        #expect(threads[0].by == "user" && threads[0].replies.map(\.id) == ["c2"])
        let noID = threads[1].id
        #expect(noID.hasPrefix("@"))
        let answered = try UmiComments.replying(to: noID, "ok", in: file, by: "AI")
        #expect(answered.text.contains("{==that==}{>>no id<<}{#c3}"))
        #expect(answered.text.contains("suggestions:\n  s1:\n    by: AI"))
        #expect(UmiComments.Document(answered.text).threads[1].replies.map(\.body) == ["ok"])
    }

    @Test func blockScalarsAndQuotesInTheEndmatter() {
        let file = "Hi {==there==}{>>x<<}{#c1}.\n\n---\ncomments:\n  c1:\n    by: user\n  c2:\n    body: |\n      line one\n      line two\n    by: 'A''s agent'\n    re: c1\n"
        let reply = UmiComments.Document(file).threads.first?.replies.first
        #expect(reply?.body == "line one\nline two")
        #expect(reply?.by == "A's agent")
    }

    @Test func windowsLineEndingsStayWindows() throws {
        let crlf = "Line one.\r\nLine two.\r\n"
        let a = try UmiComments.adding("Why?", on: range(of: "two", in: crlf), in: crlf, by: "user")
        #expect(!a.text.replacingOccurrences(of: "\r\n", with: "").contains("\n"))
        #expect(UmiComments.Document(a.text).threads.count == 1)
        #expect(try UmiComments.deleting(a.id, in: a.text) == crlf)
    }

    @Test func placementStaysInOneBlockAndOutOfOtherComments() throws {
        // Across two list items: cut at the end of the first.
        let across = (doc as NSString).range(of: "one item\n- two")
        let a = try UmiComments.adding("x", on: across, in: doc, by: "user")
        #expect(a.text.contains("- {==one item==}{>>x<<}{#c1}\n- two items"))
        // Overlapping an existing comment is refused; the same words get a second comment.
        #expect(throws: UmiComments.Failure.self) {
            try UmiComments.adding("y", on: (a.text as NSString).range(of: "item==}"), in: a.text, by: "user")
        }
        let b = try UmiComments.adding("y", on: (a.text as NSString).range(of: "one item"), in: a.text, by: "user")
        #expect(b.text.contains("{==one item==}{>>x<<}{#c1}{>>y<<}{#c2}"))
        // A code block is refused; a code span is taken whole.
        #expect(throws: UmiComments.Failure.self) {
            try UmiComments.adding("z", on: (doc as NSString).range(of: "not a comment"), in: doc, by: "user")
        }
        let span = "Run `make all` now.\n"
        let c = try UmiComments.adding("z", on: (span as NSString).range(of: "all"), in: span, by: "user")
        #expect(c.text.hasPrefix("Run {==`make all`==}"))
        #expect(throws: UmiComments.Failure.self) { try UmiComments.adding("has <<} in it", on: range(of: "ship", in: doc), in: doc, by: "user") }
    }

    @Test func relocatingAfterAnEditElsewhere() {
        let old = "alpha beta gamma beta delta"
        let r = NSRange(location: 17, length: 4) // the second "beta"
        let new = "intro. alpha beta gamma beta delta"
        #expect(UmiComments.relocate(r, from: old, to: new) == NSRange(location: 24, length: 4))
        #expect(UmiComments.relocate(r, from: old, to: "alpha gamma delta") == nil)
    }

    /// The preview's text runs say where they came from in the file.
    @Test func previewRunsMapBackToTheFile() throws {
        let a = try UmiComments.adding("Why?", on: range(of: "new parser", in: doc), in: doc, by: "user")
        let preview = UmiComments.preview(a.text, resolvedIDs: [])
        #expect(!preview.source.contains("comments:"))
        #expect(preview.source.contains("<mark class=\"umi-c\" data-ids=\"c1\">new parser</mark>"))
        let html = UmiMarkdown.html(from: preview.source, baseURL: nil, positions: preview.fileOffset(of:))
        let file = a.text as NSString
        let regex = try NSRegularExpression(pattern: #"<span data-s="(\d+)">([^<]*)</span>"#)
        let ns = html as NSString
        let spans = regex.matches(in: html, range: NSRange(location: 0, length: ns.length))
        #expect(spans.count >= 5)
        for match in spans {
            let offset = Int(ns.substring(with: match.range(at: 1)))!
            let text = ns.substring(with: match.range(at: 2)).replacingOccurrences(of: "&lt;", with: "<")
                .replacingOccurrences(of: "&gt;", with: ">").replacingOccurrences(of: "&quot;", with: "\"")
                .replacingOccurrences(of: "&amp;", with: "&")
            #expect(file.substring(with: NSRange(location: offset, length: (text as NSString).length)) == text)
        }
    }

    @Test func taskListsKeepTheirOffsets() {
        let text = "- [ ] buy milk\n"
        let html = UmiMarkdown.html(from: text, baseURL: nil, positions: { $0.location })
        #expect(html.contains("<input type=\"checkbox\" disabled> <span data-s=\"6\">buy milk</span>"))
    }

    /// A comment from the margin goes to the file at once; unsaved edits stay unsaved.
    @MainActor @Test func aCommentKeepsUnsavedEditsUnsaved() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("umi-comments-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("doc.md")
        try "Hello brave world.\n".write(to: url, atomically: true, encoding: .utf8)
        let document = try UmiDocument(url: url)
        document.text = "Intro.\n\nHello brave world.\n"
        #expect(document.isDirty)
        let id = try document.addComment("Why brave?", on: ("Intro.\n\nHello brave world.\n" as NSString).range(of: "brave"),
                                         base: document.text)
        let disk = try String(contentsOf: url, encoding: .utf8)
        #expect(disk.hasPrefix("Hello {==brave==}{>>Why brave?<<}{#\(id)} world.\n"))
        #expect(document.text.hasPrefix("Intro.\n\nHello {==brave==}"))
        #expect(document.isDirty)
    }
}
