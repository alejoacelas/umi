import Foundation

// Comments on Markdown documents (E-11), stored in the document itself in Roughdraft Flavored
// Markdown (github.com/Lex-Inc/roughdraft, docs/spec/roughdraft-flavored-markdown.md): CriticMarkup
// anchors in the text and YAML endmatter at the end of the file for who wrote what, when, replies
// and resolved state.
//
//     Please revisit {==this sentence==}{>>Needs a source.<<}{#c1}.
//
//     ---
//     comments:
//       c1:
//         by: user
//         at: "2026-11-04T10:31:00.000Z"
//         umi-quote: "this sentence"
//         umi-body: "Needs a source."
//       c2:
//         body: "I can add one from the intro."
//         by: AI
//         at: "2026-11-04T10:35:00.000Z"
//         re: c1
//
// A root comment's text stays inline, beside the words it's about, so any reader of the file sees
// both; replies live in the endmatter (`re` names the parent). Umi also keeps a copy of a root's
// anchor and text in the endmatter (`umi-quote`, `umi-body`, keys other readers ignore), so a
// comment whose inline markup an edit removed still shows ("detached") instead of vanishing.
//
// This file is Foundation-only and lives with the CLI (`UmiCLI/`, built on its own by build.sh), so
// agents can read and answer comments with Umi not running; the app compiles it through a link in
// Sources/Features/Umi.

enum UmiComments {
    /// Who Umi's editor writes comments as, and who agents are by default (Roughdraft's labels).
    static let userAuthor = "user"
    static let agentAuthor = "AI"

    struct Failure: Error, CustomStringConvertible {
        let message: String
        init(_ message: String) { self.message = message }
        var description: String { message }
    }

    // MARK: Model

    struct Comment {
        var id: String
        var body: String
        var by: String
        var at: String
    }

    struct Thread {
        /// The root comment's id. Inline comments written without one get `@<offset>`, a stand-in
        /// that writing replaces with a real id.
        var id: String
        var body: String
        var by: String
        var at: String
        var resolved: Bool
        /// A short note left when resolving.
        var resolvedNote: String?
        /// The anchored text as it is in the file (Markdown), "" for a comment on a point.
        var quote: String
        /// 1-based line of the anchor (nil when detached).
        var line: Int?
        /// The inline markup is gone; what's shown comes from the endmatter copy.
        var detached: Bool
        /// The markup is there but the words it was on were deleted (`{====}`).
        var anchorDeleted = false
        var replies: [Comment]

        var isOpen: Bool { !resolved }
    }

    /// One inline review token (a comment, highlight or suggestion) and where it is, in UTF-16
    /// offsets of the text.
    struct InlineComment {
        var id: String?
        var body: String
        /// The comment token `{>>…<<}` plus its reference or attribute block.
        var range: NSRange
        /// Attributes from an inline `{id="…" by="…"}` block (older Roughdraft files).
        var attributes: [String: String]
    }

    struct Anchor {
        /// The whole group: `{==` … `==}` plus its comment tokens (or just the comments for a point).
        var range: NSRange
        /// The anchored text inside `{==…==}`; location only (length 0) for a point comment.
        var textRange: NSRange
        var highlighted: Bool
        var comments: [InlineComment]
    }

    // MARK: Parsing a document

    struct Document {
        var text: String
        /// Where the endmatter starts (the blank line before `---`), or the text's length.
        var bodyEnd: Int
        var anchors: [Anchor]
        var endmatter: Endmatter

        var body: String { (text as NSString).substring(to: bodyEnd) }

        init(_ text: String) {
            self.text = text
            let split = Endmatter.split(text)
            bodyEnd = split.bodyEnd
            endmatter = split.endmatter
            anchors = UmiComments.scanAnchors((text as NSString).substring(to: split.bodyEnd))
        }

        /// Every thread, in document order, then the detached ones.
        var threads: [Thread] {
            let ns = text as NSString
            var result: [Thread] = []
            var seen: Set<String> = []
            for anchor in anchors {
                let quote = anchor.highlighted ? ns.substring(with: anchor.textRange) : ""
                let line = UmiComments.line(of: anchor.range.location, in: ns)
                for comment in anchor.comments {
                    let id = comment.id ?? "@\(comment.range.location)"
                    seen.insert(id)
                    let meta = endmatter.comments[id] ?? [:]
                    result.append(Thread(
                        id: id, body: comment.body,
                        by: meta["by"] ?? comment.attributes["by"] ?? "",
                        at: meta["at"] ?? comment.attributes["at"] ?? "",
                        resolved: (meta["status"] ?? comment.attributes["status"]) == "resolved",
                        resolvedNote: meta["resolved"] ?? comment.attributes["resolved"],
                        quote: quote, line: line, detached: false,
                        anchorDeleted: anchor.highlighted && anchor.textRange.length == 0, replies: []))
                }
            }
            // Endmatter roots with no inline token: detached.
            for id in endmatter.order where !seen.contains(id) {
                guard let meta = endmatter.comments[id], meta["re"] == nil else { continue }
                result.append(Thread(
                    id: id, body: meta["umi-body"] ?? meta["body"] ?? "", by: meta["by"] ?? "", at: meta["at"] ?? "",
                    resolved: meta["status"] == "resolved", resolvedNote: meta["resolved"],
                    quote: meta["umi-quote"] ?? "", line: nil, detached: true, replies: []))
                seen.insert(id)
            }
            // Replies, under their root (a reply to a reply goes under the same root). A reply whose
            // parent is missing is shown as a detached thread of its own (Roughdraft: "treated as a
            // top-level comment").
            let ids = Set(result.map(\.id))
            func root(of id: String, depth: Int = 0) -> String? {
                if ids.contains(id) { return id }
                guard depth < 32, let parent = endmatter.comments[id]?["re"], parent != id else { return nil }
                return root(of: parent, depth: depth + 1)
            }
            for id in endmatter.order {
                guard let meta = endmatter.comments[id], let parent = meta["re"], !ids.contains(id) else { continue }
                let reply = Comment(id: id, body: meta["body"] ?? "", by: meta["by"] ?? "", at: meta["at"] ?? "")
                if parent != id, let rootID = root(of: parent), let index = result.firstIndex(where: { $0.id == rootID }) {
                    result[index].replies.append(reply)
                } else {
                    result.append(Thread(id: id, body: reply.body, by: reply.by, at: reply.at,
                                         resolved: meta["status"] == "resolved", resolvedNote: meta["resolved"],
                                         quote: "", line: nil, detached: true, replies: []))
                }
            }
            return result
        }

        func thread(_ id: String) -> Thread? { threads.first { $0.id == id || $0.replies.contains { $0.id == id } } }

        /// The anchor holding comment `id`, and the comment's index in it.
        func inline(_ id: String) -> (anchor: Int, comment: Int)? {
            for (a, anchor) in anchors.enumerated() {
                if let c = anchor.comments.firstIndex(where: { ($0.id ?? "@\($0.range.location)") == id }) { return (a, c) }
            }
            return nil
        }

        /// The next free `cN`.
        var nextID: String {
            var used = Set(endmatter.order)
            for anchor in anchors { for comment in anchor.comments { if let id = comment.id { used.insert(id) } } }
            var highest = 0
            for id in used where id.hasPrefix("c") { if let n = Int(id.dropFirst()) { highest = max(highest, n) } }
            var n = highest + 1
            while used.contains("c\(n)") { n += 1 }
            return "c\(n)"
        }
    }

    static func line(of offset: Int, in text: NSString) -> Int {
        var line = 1
        var index = 0
        let limit = min(offset, text.length)
        while index < limit {
            if text.character(at: index) == 0x0A { line += 1 }
            index += 1
        }
        return line
    }

    // MARK: Scanning inline markup

    /// The parts of `body` that are code (fenced blocks and inline code spans), where review markup
    /// is literal text.
    static func codeRanges(_ body: String) -> [NSRange] {
        let ns = body as NSString
        var ranges: [NSRange] = []
        var fence: (char: unichar, count: Int, start: Int)?
        var lineStart = 0
        var proseStart = 0
        func spans(_ range: NSRange) {
            // Backtick code spans in prose: a run of N backticks up to the next run of exactly N.
            var i = range.location
            let end = NSMaxRange(range)
            while i < end {
                guard ns.character(at: i) == 0x60 else { i += 1; continue }
                var n = 0
                while i + n < end, ns.character(at: i + n) == 0x60 { n += 1 }
                var j = i + n
                var closed: Int?
                while j < end {
                    if ns.character(at: j) == 0x60 {
                        var m = 0
                        while j + m < end, ns.character(at: j + m) == 0x60 { m += 1 }
                        if m == n { closed = j + m; break }
                        j += m
                    } else {
                        // A code span doesn't cross a blank line.
                        if ns.character(at: j) == 0x0A, j + 1 < end, ns.character(at: j + 1) == 0x0A { break }
                        j += 1
                    }
                }
                if let closed {
                    ranges.append(NSRange(location: i, length: closed - i))
                    i = closed
                } else {
                    i += n
                }
            }
        }
        while lineStart <= ns.length {
            let lineRange = ns.lineRange(for: NSRange(location: min(lineStart, ns.length), length: 0))
            let line = ns.substring(with: lineRange)
            let trimmed = line.drop { $0 == " " }
            let indent = line.count - trimmed.count
            if indent < 4, let first = trimmed.first, first == "`" || first == "~" {
                let char: unichar = first == "`" ? 0x60 : 0x7E
                let count = trimmed.prefix { $0 == first }.count
                if count >= 3 {
                    if let open = fence {
                        if open.char == char, count >= open.count,
                           trimmed.dropFirst(count).allSatisfy({ $0 == " " || $0 == "\n" || $0 == "\r" }) {
                            ranges.append(NSRange(location: open.start, length: NSMaxRange(lineRange) - open.start))
                            fence = nil
                            proseStart = NSMaxRange(lineRange)
                        }
                    } else {
                        spans(NSRange(location: proseStart, length: lineRange.location - proseStart))
                        fence = (char, count, lineRange.location)
                    }
                }
            }
            if NSMaxRange(lineRange) >= ns.length { break }
            lineStart = NSMaxRange(lineRange)
        }
        if let open = fence {
            ranges.append(NSRange(location: open.start, length: ns.length - open.start))
        } else {
            spans(NSRange(location: proseStart, length: ns.length - proseStart))
        }
        return ranges.sorted { $0.location < $1.location }
    }

    static func inCode(_ offset: Int, _ code: [NSRange]) -> Bool {
        code.contains { NSLocationInRange(offset, $0) }
    }

    /// `{#id}` or `{id="…" by="…"}` right at `at`: its attributes and where it ends.
    static func metadata(_ ns: NSString, at: Int) -> (attributes: [String: String], end: Int)? {
        guard at + 2 < ns.length, ns.character(at: at) == 0x7B else { return nil }
        if ns.character(at: at + 1) == 0x23 { // {#id}
            var i = at + 2
            while i < ns.length, let scalar = Unicode.Scalar(ns.character(at: i)),
                  CharacterSet.alphanumerics.contains(scalar) || scalar == "_" || scalar == "-" { i += 1 }
            guard i > at + 2, i < ns.length, ns.character(at: i) == 0x7D else { return nil }
            return (["id": ns.substring(with: NSRange(location: at + 2, length: i - at - 2))], i + 1)
        }
        // {name="value" …}
        var i = at + 1
        var attributes: [String: String] = [:]
        func skipSpaces() { while i < ns.length, ns.character(at: i) == 0x20 { i += 1 } }
        skipSpaces()
        while i < ns.length, ns.character(at: i) != 0x7D {
            let nameStart = i
            while i < ns.length, let scalar = Unicode.Scalar(ns.character(at: i)),
                  CharacterSet.alphanumerics.contains(scalar) || scalar == "_" || scalar == "-" { i += 1 }
            guard i > nameStart, i + 1 < ns.length, ns.character(at: i) == 0x3D, ns.character(at: i + 1) == 0x22 else { return nil }
            let name = ns.substring(with: NSRange(location: nameStart, length: i - nameStart))
            i += 2
            var value = ""
            var closed = false
            while i < ns.length {
                let c = ns.character(at: i)
                if c == 0x5C, i + 1 < ns.length { // backslash escape
                    value += ns.substring(with: NSRange(location: i + 1, length: 1))
                    i += 2
                    continue
                }
                if c == 0x22 { closed = true; i += 1; break }
                if c == 0x0A { return nil }
                value += ns.substring(with: NSRange(location: i, length: 1))
                i += 1
            }
            guard closed else { return nil }
            attributes[name] = value
            skipSpaces()
        }
        guard i < ns.length, !attributes.isEmpty else { return nil }
        return (attributes, i + 1)
    }

    /// Where `close` next occurs at or after `from`, on the same paragraph (no blank line between).
    static func find(_ close: String, in ns: NSString, from: Int) -> Int? {
        let range = ns.range(of: close, options: [], range: NSRange(location: from, length: ns.length - from))
        guard range.location != NSNotFound else { return nil }
        let between = ns.range(of: "\n\n", options: [], range: NSRange(location: from, length: range.location - from))
        return between.location == NSNotFound ? range.location : nil
    }

    /// `{>>body<<}` plus its metadata at `at`.
    static func commentToken(_ ns: NSString, at: Int) -> InlineComment? {
        guard ns.length >= at + 3, ns.substring(with: NSRange(location: at, length: 3)) == "{>>",
              let close = find("<<}", in: ns, from: at + 3) else { return nil }
        let body = ns.substring(with: NSRange(location: at + 3, length: close - at - 3))
        var end = close + 3
        var attributes: [String: String] = [:]
        if let meta = metadata(ns, at: end) {
            attributes = meta.attributes
            end = meta.end
        }
        return InlineComment(id: attributes["id"], body: body, range: NSRange(location: at, length: end - at),
                             attributes: attributes)
    }

    /// Anchors: `{==text==}` followed by comments, and comments on their own. Suggestions
    /// (`{++ ++}`, `{-- --}`, `{~~ ~> ~~}`) followed by comments anchor them too.
    static func scanAnchors(_ body: String) -> [Anchor] {
        let ns = body as NSString
        let code = codeRanges(body)
        var anchors: [Anchor] = []
        var i = 0
        func comments(after start: Int) -> (list: [InlineComment], end: Int) {
            var list: [InlineComment] = []
            var at = start
            while let token = commentToken(ns, at: at) {
                list.append(token)
                at = NSMaxRange(token.range)
            }
            return (list, at)
        }
        while i < ns.length {
            let c = ns.character(at: i)
            guard c == 0x7B, i + 2 < ns.length, !inCode(i, code) else { i += 1; continue }
            let opener = ns.substring(with: NSRange(location: i, length: 3))
            switch opener {
            case "{==":
                guard let close = find("==}", in: ns, from: i + 3) else { i += 3; continue }
                var after = close + 3
                if let meta = metadata(ns, at: after) { after = meta.end }
                let following = comments(after: after)
                if !following.list.isEmpty {
                    anchors.append(Anchor(range: NSRange(location: i, length: following.end - i),
                                          textRange: NSRange(location: i + 3, length: close - i - 3),
                                          highlighted: true, comments: following.list))
                }
                i = following.end
            case "{>>":
                let following = comments(after: i)
                guard !following.list.isEmpty else { i += 3; continue }
                anchors.append(Anchor(range: NSRange(location: i, length: following.end - i),
                                      textRange: NSRange(location: i, length: 0), highlighted: false,
                                      comments: following.list))
                i = following.end
            case "{++", "{--", "{~~":
                let closer = opener == "{++" ? "++}" : opener == "{--" ? "--}" : "~~}"
                guard let close = find(closer, in: ns, from: i + 3) else { i += 3; continue }
                var after = close + 3
                if let meta = metadata(ns, at: after) { after = meta.end }
                let following = comments(after: after)
                if !following.list.isEmpty {
                    anchors.append(Anchor(range: NSRange(location: i, length: following.end - i),
                                          textRange: NSRange(location: i, length: close + 3 - i),
                                          highlighted: true, comments: following.list))
                }
                i = following.end
            default:
                i += 1
            }
        }
        return anchors
    }

    // MARK: Changing a document

    /// Today's time the way Roughdraft writes it.
    static func now() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: Date())
    }

    /// A root comment's text goes inline: one line, and never the closing delimiter.
    static func inlineBody(_ text: String) throws -> String {
        let flat = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: " ")
        guard !flat.isEmpty else { throw Failure("the comment is empty") }
        guard !flat.contains("<<}") else { throw Failure("a comment can't contain <<}") }
        return flat
    }

    static func replyBody(_ text: String) throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw Failure("the reply is empty") }
        return trimmed
    }

    /// Give an inline comment written without an id (`@offset`) a real one, so it can be
    /// answered or resolved. Returns the new text and id.
    static func ensuringID(_ id: String, in text: String) throws -> (text: String, id: String) {
        guard id.hasPrefix("@") else { return (text, id) }
        let doc = Document(text)
        guard let (a, c) = doc.inline(id) else { throw Failure("no comment \(id)") }
        let comment = doc.anchors[a].comments[c]
        let newID = doc.nextID
        let ns = text as NSString
        // Put `{#cN}` right after `<<}`, dropping an attribute block (its values move to the endmatter).
        let closeEnd = comment.range.location + 3 + (comment.body as NSString).length + 3
        let replaced = ns.replacingCharacters(in: NSRange(location: closeEnd, length: NSMaxRange(comment.range) - closeEnd),
                                              with: "{#\(newID)}")
        var updated = Document(replaced)
        var meta: [String: String] = [:]
        for key in ["by", "at", "status", "resolved"] { if let v = comment.attributes[key] { meta[key] = v } }
        if meta["by"] == nil { meta["by"] = "unknown" }
        if meta["at"] == nil { meta["at"] = now() }
        updated.endmatter.set(newID, meta)
        return (updated.render(), newID)
    }

    /// Add a comment on `range` of `text` (UTF-16 offsets; empty for a point). Returns the new
    /// text and the comment's id.
    static func adding(_ body: String, on range: NSRange, in text: String, by author: String,
                       at time: String = now()) throws -> (text: String, id: String) {
        let inline = try inlineBody(body)
        let doc = Document(text)
        var range = try placeable(range, in: doc)
        let ns = text as NSString
        let id = doc.nextID
        let token = "{>>\(inline)<<}{#\(id)}"
        var newText: String
        if let existing = doc.anchors.first(where: { $0.highlighted && NSEqualRanges($0.textRange, range) }) {
            // The same words already carry comments: one more on that anchor.
            newText = ns.replacingCharacters(in: NSRange(location: NSMaxRange(existing.range), length: 0), with: token)
            range = existing.textRange
        } else {
            let quote = ns.substring(with: range)
            newText = ns.replacingCharacters(in: range, with: range.length == 0 ? token : "{==\(quote)==}\(token)")
        }
        var updated = Document(newText)
        let quote = range.length == 0 ? "" : ns.substring(with: range)
        updated.endmatter.set(id, ["by": author, "at": time, "umi-quote": quote, "umi-body": inline])
        return (updated.render(), id)
    }

    /// Check (and adjust) a range for a new anchor: within one paragraph, not inside code, not
    /// across other review markup. Whitespace at its ends is left out.
    static func placeable(_ range: NSRange, in doc: Document) throws -> NSRange {
        let ns = doc.text as NSString
        guard range.location >= 0, NSMaxRange(range) <= doc.bodyEnd else { throw Failure("that text isn't in the document any more") }
        var start = range.location
        var end = NSMaxRange(range)
        let whitespace = CharacterSet.whitespacesAndNewlines
        func isSpace(_ i: Int) -> Bool { Unicode.Scalar(ns.character(at: i)).map { whitespace.contains($0) } ?? false }
        while start < end, isSpace(start) { start += 1 }
        while end > start, isSpace(end - 1) { end -= 1 }
        // One block: stop before a blank line or a line that starts another block.
        var i = start
        while i < end {
            if ns.character(at: i) == 0x0A {
                let rest = ns.substring(with: NSRange(location: i + 1, length: min(ns.length - i - 1, 12)))
                let trimmed = rest.drop { $0 == " " || $0 == "\t" }
                let startsBlock = trimmed.isEmpty || trimmed.first == "\n" || trimmed.hasPrefix("#") || trimmed.hasPrefix(">")
                    || trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") || trimmed.hasPrefix("|")
                    || trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~")
                    || trimmed.range(of: #"^\d+[.)] "#, options: .regularExpression) != nil
                if startsBlock {
                    end = i
                    while end > start, isSpace(end - 1) { end -= 1 }
                    break
                }
            }
            i += 1
        }
        // A table row (a line starting with `|`): one cell.
        let line = ns.lineRange(for: NSRange(location: start, length: 0))
        if ns.substring(with: line).trimmingCharacters(in: .whitespaces).hasPrefix("|") {
            let pipe = ns.range(of: "|", options: [], range: NSRange(location: start, length: end - start))
            if pipe.location != NSNotFound {
                end = pipe.location
                while end > start, isSpace(end - 1) { end -= 1 }
            }
        }
        guard end > start || range.length == 0 else { throw Failure("select some text to comment on") }
        // In code the markup would be literal: a code span is taken whole; code blocks are refused.
        for block in codeRanges(doc.body) {
            let touches = NSLocationInRange(start, block) || (end > start && NSLocationInRange(end - 1, block))
                || (start <= block.location && end >= NSMaxRange(block))
            guard touches else { continue }
            let opening = ns.substring(with: block).drop { $0 == " " }
            if opening.hasPrefix("```") || opening.hasPrefix("~~~") {
                throw Failure("comments on code blocks aren't supported; comment on the text around it")
            }
            start = min(start, block.location)
            end = max(end, NSMaxRange(block))
        }
        // A link only partly selected: take all of it.
        if let links = try? NSRegularExpression(pattern: #"!?\[[^\]\n]*\]\([^)\n]*\)"#) {
            for match in links.matches(in: doc.body, range: NSRange(location: 0, length: doc.bodyEnd)) {
                let r = match.range
                let startInside = start > r.location && start < NSMaxRange(r)
                let endInside = end > r.location && end < NSMaxRange(r)
                if startInside != endInside {
                    start = min(start, r.location)
                    end = max(end, NSMaxRange(r))
                }
            }
        }
        let result = NSRange(location: start, length: end - start)
        for anchor in doc.anchors {
            if anchor.highlighted, NSEqualRanges(anchor.textRange, result) { return result }
            let overlaps = NSIntersectionRange(anchor.range, result).length > 0
                || (result.length == 0 && start > anchor.range.location && start < NSMaxRange(anchor.range))
            if overlaps {
                throw Failure("that text overlaps another comment; select text outside it, or reply to that comment")
            }
        }
        for marker in ["{==", "==}", "{>>", "<<}", "{++", "++}", "{--", "--}", "{~~", "~~}"]
        where ns.range(of: marker, options: [], range: result).location != NSNotFound {
            throw Failure("that text has review markup in it; select text outside it")
        }
        return result
    }

    static func replying(to id: String, _ body: String, in text: String, by author: String,
                         at time: String = now()) throws -> (text: String, id: String) {
        let reply = try replyBody(body)
        var (text, rootID) = try ensuringID(id, in: text)
        var doc = Document(text)
        guard let thread = doc.thread(rootID) else { throw Failure("no comment \(id)") }
        let newID = doc.nextID
        doc.endmatter.set(newID, ["body": reply, "by": author, "at": time, "re": thread.id])
        text = doc.render()
        return (text, newID)
    }

    static func editing(_ id: String, to body: String, in text: String) throws -> String {
        var (text, id) = try ensuringID(id, in: text)
        var doc = Document(text)
        if let (a, c) = doc.inline(id) {
            let inline = try inlineBody(body)
            let token = doc.anchors[a].comments[c].range
            let ns = text as NSString
            let bodyRange = NSRange(location: token.location + 3, length: (doc.anchors[a].comments[c].body as NSString).length)
            text = ns.replacingCharacters(in: bodyRange, with: inline)
            doc = Document(text)
            if doc.endmatter.comments[id] != nil { doc.endmatter.update(id, ["umi-body": inline]) }
            return doc.render()
        }
        guard let meta = doc.endmatter.comments[id] else { throw Failure("no comment \(id)") }
        if meta["re"] != nil {
            doc.endmatter.update(id, ["body": try replyBody(body)])
        } else {
            doc.endmatter.update(id, ["umi-body": try inlineBody(body)])
        }
        return doc.render()
    }

    static func resolving(_ id: String, _ resolved: Bool, note: String? = nil, in text: String) throws -> String {
        var (text, id) = try ensuringID(id, in: text)
        var doc = Document(text)
        guard let thread = doc.thread(id) else { throw Failure("no comment \(id)") }
        id = thread.id
        if doc.endmatter.comments[id] == nil { doc.endmatter.set(id, ["by": thread.by.isEmpty ? "unknown" : thread.by, "at": thread.at.isEmpty ? now() : thread.at]) }
        if resolved {
            var fields: [String: String?] = ["status": "resolved"]
            fields["resolved"] = note.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
            doc.endmatter.update(id, fields)
        } else {
            doc.endmatter.update(id, ["status": nil, "resolved": nil])
        }
        text = doc.render()
        return text
    }

    /// Delete a comment. A root takes its replies with it, and its anchor's markup goes when no
    /// comment is left on it (the anchored words stay).
    static func deleting(_ id: String, in text: String) throws -> String {
        var doc = Document(text)
        guard doc.thread(id) != nil else { throw Failure("no comment \(id)") }
        var gone: Set<String> = [id]
        var text = text
        if let (a, c) = doc.inline(id) {
            let anchor = doc.anchors[a]
            let ns = text as NSString
            if anchor.comments.count == 1 {
                let keep = anchor.highlighted ? ns.substring(with: anchor.textRange) : ""
                // A suggestion keeps its own markup; only the comment goes.
                let isSuggestion = anchor.highlighted && !ns.substring(with: NSRange(location: anchor.range.location, length: 3)).hasPrefix("{==")
                if isSuggestion {
                    text = ns.replacingCharacters(in: anchor.comments[c].range, with: "")
                } else {
                    text = ns.replacingCharacters(in: anchor.range, with: keep)
                }
            } else {
                text = ns.replacingCharacters(in: anchor.comments[c].range, with: "")
            }
            doc = Document(text)
        }
        // Replies to anything gone, transitively.
        var changed = true
        while changed {
            changed = false
            for (key, meta) in doc.endmatter.comments where !gone.contains(key) {
                if let parent = meta["re"], gone.contains(parent) { gone.insert(key); changed = true }
            }
        }
        for key in gone { doc.endmatter.remove(key) }
        return doc.render()
    }

    /// Move a range of `old` to the same words in `new` (after an edit elsewhere): the occurrence
    /// whose surroundings match best. Nil when the words are gone.
    static func relocate(_ range: NSRange, from old: String, to new: String) -> NSRange? {
        if old == new { return range }
        let o = old as NSString, n = new as NSString
        guard NSMaxRange(range) <= o.length else { return nil }
        let quote = o.substring(with: range)
        let before = o.substring(with: NSRange(location: max(0, range.location - 48), length: min(48, range.location)))
        let after = o.substring(with: NSRange(location: NSMaxRange(range), length: min(48, o.length - NSMaxRange(range))))
        func score(_ r: NSRange) -> Int {
            let b = n.substring(with: NSRange(location: max(0, r.location - 48), length: min(48, r.location)))
            let a = n.substring(with: NSRange(location: NSMaxRange(r), length: min(48, n.length - NSMaxRange(r))))
            return commonSuffix(b, before) + commonPrefix(a, after)
        }
        var best: (NSRange, Int)?
        var from = 0
        if quote.isEmpty {
            // A point: where its surroundings meet.
            let found = n.range(of: before + after)
            return found.location == NSNotFound ? nil : NSRange(location: found.location + (before as NSString).length, length: 0)
        }
        while from < n.length {
            let r = n.range(of: quote, options: [], range: NSRange(location: from, length: n.length - from))
            if r.location == NSNotFound { break }
            let s = score(r)
            if best == nil || s > best!.1 { best = (r, s) }
            from = r.location + 1
        }
        return best?.0
    }

    private static func commonPrefix(_ a: String, _ b: String) -> Int { zip(a, b).prefix { $0 == $1 }.count }
    private static func commonSuffix(_ a: String, _ b: String) -> Int { zip(a.reversed(), b.reversed()).prefix { $0 == $1 }.count }

    // MARK: Endmatter

    /// The YAML block at the end of the file: `comments:` (parsed), anything else kept as it was.
    struct Endmatter {
        /// Comment ids in file order.
        var order: [String] = []
        var comments: [String: [String: String]] = [:]
        /// Each comment's keys in file order (unknown keys are kept).
        var keyOrder: [String: [String]] = [:]
        /// Other top-level sections (`suggestions:` …), verbatim.
        var otherSections: [String] = []
        /// The text before `---` ended with a newline we must keep exactly.
        var isEmpty: Bool { order.isEmpty && otherSections.isEmpty }

        mutating func set(_ id: String, _ fields: [String: String]) {
            if comments[id] == nil { order.append(id) }
            comments[id] = fields
            let preferred = ["body", "by", "at", "re", "status", "resolved", "umi-quote", "umi-body"]
            keyOrder[id] = preferred.filter { fields[$0] != nil } + fields.keys.filter { !preferred.contains($0) }.sorted()
        }

        mutating func update(_ id: String, _ fields: [String: String?]) {
            var meta = comments[id] ?? [:]
            var keys = keyOrder[id] ?? []
            if comments[id] == nil { order.append(id) }
            for (key, value) in fields.sorted(by: { $0.key < $1.key }) {
                if let value {
                    if meta[key] == nil { keys.append(key) }
                    meta[key] = value
                } else {
                    meta.removeValue(forKey: key)
                    keys.removeAll { $0 == key }
                }
            }
            comments[id] = meta
            keyOrder[id] = keys
        }

        mutating func remove(_ id: String) {
            comments.removeValue(forKey: id)
            keyOrder.removeValue(forKey: id)
            order.removeAll { $0 == id }
        }

        /// Split a document into its body and endmatter. The endmatter is the last `---` line,
        /// after a blank line (so it isn't a setext heading), followed only by YAML whose
        /// top-level keys include `comments` or `suggestions`.
        static func split(_ text: String) -> (bodyEnd: Int, endmatter: Endmatter) {
            let ns = text as NSString
            let none = (ns.length, Endmatter())
            // The last `---` after a blank line, or a file that is nothing but endmatter.
            var marker = ns.range(of: "\n\n---\n", options: .backwards)
            if marker.location == NSNotFound { marker = ns.range(of: "\n\r\n---\r\n", options: .backwards) }
            let yamlStart: Int
            let bodyEnd: Int
            if marker.location != NSNotFound {
                yamlStart = NSMaxRange(marker)
                // The body ends with the newline before the blank line.
                bodyEnd = marker.location + 1
            } else if text.hasPrefix("---\n") || text.hasPrefix("---\r\n") {
                yamlStart = text.hasPrefix("---\n") ? 4 : 5
                bodyEnd = 0
            } else {
                return none
            }
            guard let parsed = parse(ns.substring(from: yamlStart)) else { return none }
            return (bodyEnd, parsed)
        }

        static func parse(_ yaml: String) -> Endmatter? {
            var result = Endmatter()
            let lines = yaml.components(separatedBy: "\n").map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
            var index = 0
            var sawKnown = false
            func indentation(_ line: String) -> Int { line.prefix { $0 == " " }.count }
            while index < lines.count {
                let line = lines[index]
                if line.trimmingCharacters(in: .whitespaces).isEmpty { index += 1; continue }
                guard indentation(line) == 0, line.hasSuffix(":") || line.contains(":") else { return nil }
                let key = String(line.prefix { $0 != ":" })
                guard !key.isEmpty, key.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }) else { return nil }
                // The section's lines: everything indented after it.
                var end = index + 1
                while end < lines.count, lines[end].isEmpty || indentation(lines[end]) > 0 { end += 1 }
                let section = Array(lines[index..<end])
                if key == "comments" {
                    sawKnown = true
                    guard parseComments(Array(section.dropFirst()), into: &result) else { return nil }
                } else {
                    if key == "suggestions" { sawKnown = true }
                    var kept = section
                    while let last = kept.last, last.trimmingCharacters(in: .whitespaces).isEmpty { kept.removeLast() }
                    result.otherSections.append(kept.joined(separator: "\n"))
                }
                index = end
            }
            return sawKnown ? result : nil
        }

        private static func parseComments(_ lines: [String], into result: inout Endmatter) -> Bool {
            var index = 0
            var current: String?
            func indentation(_ line: String) -> Int { line.prefix { $0 == " " }.count }
            while index < lines.count {
                let line = lines[index]
                if line.trimmingCharacters(in: .whitespaces).isEmpty { index += 1; continue }
                let indent = indentation(line)
                let content = line.dropFirst(indent)
                guard let colon = content.firstIndex(of: ":") else { return false }
                let key = String(content[..<colon])
                var value = String(content[content.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                if current == nil || indent <= 2 {
                    // An id.
                    guard value.isEmpty, !key.isEmpty else { return false }
                    current = unquote(key)
                    if result.comments[current!] == nil { result.order.append(current!) }
                    result.comments[current!] = result.comments[current!] ?? [:]
                    index += 1
                    continue
                }
                guard let id = current else { return false }
                index += 1
                if value == "|" || value == "|-" || value == ">" || value == ">-" || value == "|+" {
                    // A block scalar: the following more-indented lines.
                    var block: [String] = []
                    var blockIndent: Int?
                    while index < lines.count {
                        let next = lines[index]
                        if next.trimmingCharacters(in: .whitespaces).isEmpty { block.append(""); index += 1; continue }
                        let ni = indentation(next)
                        guard ni > indent else { break }
                        if blockIndent == nil { blockIndent = ni }
                        block.append(String(next.dropFirst(min(ni, blockIndent!))))
                        index += 1
                    }
                    while let last = block.last, last.isEmpty { block.removeLast() }
                    value = value.hasPrefix(">") ? block.joined(separator: " ") : block.joined(separator: "\n")
                } else {
                    // A quoted value may continue on following lines (folded).
                    if (value.hasPrefix("\"") && !closesDoubleQuote(value)) {
                        while index < lines.count, !closesDoubleQuote(value) {
                            value += " " + lines[index].trimmingCharacters(in: .whitespaces)
                            index += 1
                        }
                    }
                    value = unquote(value)
                }
                if result.comments[id]?[key] == nil { result.keyOrder[id, default: []].append(key) }
                result.comments[id]?[key] = value
            }
            return true
        }

        private static func closesDoubleQuote(_ value: String) -> Bool {
            guard value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") else { return false }
            // The final quote isn't escaped.
            var backslashes = 0
            var i = value.index(before: value.index(before: value.endIndex))
            while i > value.startIndex, value[i] == "\\" { backslashes += 1; i = value.index(before: i) }
            return backslashes % 2 == 0
        }

        static func unquote(_ value: String) -> String {
            if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
                // YAML double-quoted: JSON's escapes, plus a few of its own.
                let inner = String(value.dropFirst().dropLast())
                var out = ""
                var iterator = inner.makeIterator()
                while let c = iterator.next() {
                    guard c == "\\" else { out.append(c); continue }
                    guard let e = iterator.next() else { break }
                    switch e {
                    case "n": out.append("\n")
                    case "t": out.append("\t")
                    case "r": out.append("\r")
                    case "\"": out.append("\"")
                    case "\\": out.append("\\")
                    case "/": out.append("/")
                    case "0": out.append("\0")
                    case "u":
                        var hex = ""
                        for _ in 0..<4 { if let h = iterator.next() { hex.append(h) } }
                        if let code = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(code) { out.unicodeScalars.append(scalar) }
                    default: out.append(e)
                    }
                }
                return out
            }
            if value.count >= 2, value.hasPrefix("'"), value.hasSuffix("'") {
                return String(value.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
            }
            return value
        }

        /// A value as YAML: plain when that's unambiguous, else double-quoted.
        static func quote(_ value: String) -> String {
            let plain = value.range(of: #"^[A-Za-z0-9][A-Za-z0-9 _./+-]*$"#, options: .regularExpression) != nil
                && !value.hasSuffix(" ") && !["true", "false", "yes", "no", "null", "on", "off", "~"].contains(value.lowercased())
                && Double(value) == nil
            if plain { return value }
            var out = "\""
            for scalar in value.unicodeScalars {
                switch scalar {
                case "\"": out += "\\\""
                case "\\": out += "\\\\"
                case "\n": out += "\\n"
                case "\t": out += "\\t"
                case "\r": out += "\\r"
                default:
                    if scalar.value < 0x20 { out += String(format: "\\u%04x", scalar.value) } else { out.unicodeScalars.append(scalar) }
                }
            }
            return out + "\""
        }

        func render() -> String {
            var sections: [String] = []
            if !order.isEmpty {
                var lines = ["comments:"]
                for id in order {
                    guard let meta = comments[id] else { continue }
                    lines.append("  \(Self.quote(id)):")
                    let keys = (keyOrder[id] ?? []).filter { meta[$0] != nil } + meta.keys.filter { !(keyOrder[id] ?? []).contains($0) }.sorted()
                    for key in keys { lines.append("    \(key): \(Self.quote(meta[key]!))") }
                }
                sections.append(lines.joined(separator: "\n"))
            }
            sections += otherSections
            return sections.joined(separator: "\n") + "\n"
        }
    }
}

extension UmiComments.Document {
    /// The document with its endmatter written back (none when it's empty), in the document's
    /// own line endings.
    func render() -> String {
        var body = self.body
        if endmatter.isEmpty { return body }
        let newline = text.contains("\r\n") ? "\r\n" : "\n"
        // Scalars: "\r\n" is one Character, so `hasSuffix("\n")` would miss it.
        if !body.isEmpty && body.unicodeScalars.last != "\n" { body += newline }
        let separator = body.isEmpty ? "" : newline
        var yaml = endmatter.render()
        if newline == "\r\n" { yaml = yaml.replacingOccurrences(of: "\n", with: "\r\n") }
        return body + separator + "---" + newline + yaml
    }
}

// MARK: - JSON for the CLI, the RPC and the preview

extension UmiComments.Thread {
    var json: [String: Any] {
        var out: [String: Any] = [
            "id": id, "body": body, "by": by, "at": at, "status": resolved ? "resolved" : "open",
            "quote": quote, "detached": detached, "anchor_deleted": anchorDeleted,
            "replies": replies.map { ["id": $0.id, "body": $0.body, "by": $0.by, "at": $0.at] },
        ]
        if let line { out["line"] = line }
        if let resolvedNote { out["resolved_note"] = resolvedNote }
        return out
    }
}

// MARK: - The preview

extension UmiComments {
    /// The Markdown the preview renders: the body without its endmatter, review markup turned into
    /// HTML (`<mark data-ids>` on commented words, an empty `<span data-ids>` for a comment on a
    /// point, `<ins>`/`<del>` for suggestions), and a map from its offsets back to the file's.
    struct Preview {
        var source: String
        /// Copied stretches: (offset in `source`, offset in the file, length), in order.
        var segments: [(preview: Int, file: Int, length: Int)]

        /// The file offset of a stretch of `source`, when all of it was copied from the file.
        func fileOffset(of range: NSRange) -> Int? {
            // Segments are sorted; a binary search finds the one holding the start.
            var low = 0, high = segments.count - 1
            while low <= high {
                let mid = (low + high) / 2
                let s = segments[mid]
                if range.location < s.preview { high = mid - 1 }
                else if range.location >= s.preview + s.length { low = mid + 1 }
                else {
                    guard NSMaxRange(range) <= s.preview + s.length else { return nil }
                    return s.file + range.location - s.preview
                }
            }
            return nil
        }
    }

    static func preview(_ text: String, resolvedIDs: Set<String>) -> Preview {
        let doc = Document(text)
        let ns = text as NSString
        let body = doc.bodyEnd
        var out = ""
        var outLength = 0
        var segments: [(Int, Int, Int)] = []
        func copy(_ from: Int, _ to: Int) {
            guard to > from else { return }
            let piece = ns.substring(with: NSRange(location: from, length: to - from))
            segments.append((outLength, from, to - from))
            out += piece
            outLength += to - from
        }
        func emit(_ html: String) {
            out += html
            outLength += (html as NSString).length
        }
        func attribute(_ ids: [String]) -> String { UmiComments.escapeHTML(ids.joined(separator: " ")) }
        let code = codeRanges(doc.body)
        var cursor = 0
        /// Text inside an anchor: a suggestion's parts, or the words themselves.
        func renderSuggestionOrText(_ range: NSRange) {
            let text = ns.substring(with: range)
            if text.hasPrefix("{++"), text.hasSuffix("++}") {
                emit("<ins>"); copy(range.location + 3, NSMaxRange(range) - 3); emit("</ins>")
            } else if text.hasPrefix("{--"), text.hasSuffix("--}") {
                emit("<del>"); copy(range.location + 3, NSMaxRange(range) - 3); emit("</del>")
            } else if text.hasPrefix("{~~"), text.hasSuffix("~~}") {
                let inner = NSRange(location: range.location + 3, length: range.length - 6)
                let arrow = ns.range(of: "~>", options: [], range: inner)
                if arrow.location != NSNotFound {
                    emit("<del>"); copy(inner.location, arrow.location); emit("</del><ins>")
                    copy(NSMaxRange(arrow), NSMaxRange(inner)); emit("</ins>")
                } else {
                    copy(range.location, NSMaxRange(range))
                }
            } else {
                copy(range.location, NSMaxRange(range))
            }
        }
        // Suggestions and lone highlights outside anchors, then anchors, in order.
        var marks: [(range: NSRange, render: () -> Void)] = []
        for anchor in doc.anchors {
            let ids = anchor.comments.map { $0.id ?? "@\($0.range.location)" }
            let open = ids.contains { !resolvedIDs.contains($0) }
            marks.append((anchor.range, {
                if anchor.highlighted {
                    let cls = open ? "umi-c" : "umi-c umi-resolved"
                    emit("<mark class=\"\(cls)\" data-ids=\"\(attribute(ids))\">")
                    renderSuggestionOrText(anchor.textRange)
                    emit("</mark>")
                } else {
                    emit("<span class=\"umi-pin\(open ? "" : " umi-resolved")\" data-ids=\"\(attribute(ids))\"></span>")
                }
            }))
        }
        // Lone review markup (no comments): highlights and suggestions with their `{#id}`.
        if let regex = try? NSRegularExpression(pattern: #"\{==(.*?)==\}|\{\+\+(.*?)\+\+\}|\{--(.*?)--\}|\{~~(.*?)~~\}"#,
                                                options: []) {
            for match in regex.matches(in: doc.body, range: NSRange(location: 0, length: body)) {
                let r = match.range
                guard !inCode(r.location, code), !doc.anchors.contains(where: { NSIntersectionRange($0.range, r).length > 0 }) else { continue }
                var whole = r
                if let meta = metadata(ns, at: NSMaxRange(r)) { whole.length = meta.end - r.location }
                marks.append((whole, {
                    let opener = ns.substring(with: NSRange(location: r.location, length: 3))
                    if opener == "{==" {
                        emit("<mark class=\"umi-hl\">"); copy(r.location + 3, NSMaxRange(r) - 3); emit("</mark>")
                    } else {
                        renderSuggestionOrText(r)
                    }
                }))
            }
        }
        marks.sort { $0.range.location < $1.range.location }
        for mark in marks where mark.range.location >= cursor {
            copy(cursor, mark.range.location)
            mark.render()
            cursor = NSMaxRange(mark.range)
        }
        copy(cursor, body)
        return Preview(source: out, segments: segments)
    }

    static func escapeHTML(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
}
