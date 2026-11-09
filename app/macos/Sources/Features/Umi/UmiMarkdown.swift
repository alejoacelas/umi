import Foundation

/// Markdown → HTML for the editor's preview (and, later, agent replies), built on
/// Foundation's CommonMark/GFM parser (`AttributedString(markdown:)` with full syntax).
/// Block structure comes from each run's `presentationIntent`, inline styling from
/// `inlinePresentationIntent`, links and images from their attributes.
///
/// The page it produces is meant for a WKWebView with JavaScript turned off and a
/// Content-Security-Policy that allows no scripts: raw HTML in a document can show images
/// but never run code (E-7).
enum UmiMarkdown {
    /// `positions` (for comments, E-11) maps a stretch of `markdown` to the file offset it was
    /// copied from; when given, each run of text is wrapped in `<span data-s="offset">`, so a
    /// selection in the preview can be traced back to the file.
    static func html(from markdown: String, baseURL: URL?, positions: ((NSRange) -> Int?)? = nil) -> String {
        if let front = frontMatter(markdown) {
            let rest = (markdown as NSString).substring(from: front.end)
            let shifted = positions.map { positions in
                { (range: NSRange) in positions(NSRange(location: range.location + front.end, length: range.length)) }
            }
            return frontMatterHTML(markdown, yaml: front.yaml) + html(from: rest, baseURL: baseURL, positions: shifted)
        }
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: false,
            interpretedSyntax: .full,
            failurePolicy: .returnPartiallyParsedIfPossible)
        let source = linkedImagesAsHTML(markdown)
        guard let doc = try? AttributedString(markdown: source, options: options, baseURL: baseURL) else {
            return "<pre><code>\(escape(markdown))</code></pre>"
        }
        // Runs are found in the source in order: their text is copied from it, except for
        // escapes and entities, whose runs go unmarked. (An NSString of the code units: searching
        // the Swift string itself walks to each offset.)
        let ns = UmiComments.utf16(source).ns
        var cursor = 0
        let tracing = positions != nil && source == markdown
        func offset(of text: String) -> Int? {
            guard tracing, !text.isEmpty, cursor < ns.length else { return nil }
            let window = NSRange(location: cursor, length: min(ns.length - cursor, (text as NSString).length + 4000))
            let found = ns.range(of: text, options: [], range: window)
            guard found.location != NSNotFound else { return nil }
            cursor = NSMaxRange(found)
            return positions?(found)
        }
        func marked(_ html: String, _ offset: Int?) -> String {
            offset.map { "<span data-s=\"\($0)\">\(html)</span>" } ?? html
        }

        var html = ""
        // Currently open blocks, outermost first.
        var open: [PresentationIntent.IntentType] = []

        for run in doc.runs {
            // Components are innermost → outermost; we want outermost first.
            let path = Array((run.presentationIntent?.components ?? []).reversed())
            var common = 0
            while common < open.count, common < path.count, open[common].identity == path[common].identity {
                common += 1
            }
            for block in open[common...].reversed() { html += closeTag(block, parents: open) }
            open.removeSubrange(common...)
            for block in path[common...] {
                html += openTag(block, parents: open)
                open.append(block)
            }

            let text = String(doc[run.range].characters)
            if open.contains(where: { if case .thematicBreak = $0.kind { return true }; return false }) {
                continue
            }
            if open.contains(where: { if case .codeBlock = $0.kind { return true }; return false }) {
                html += marked(escape(text), offset(of: text))
                continue
            }
            let intent = run.inlinePresentationIntent ?? []
            if intent.contains(.softBreak) || intent.contains(.lineBreak) || run.imageURL != nil {
                html += inline(text, run: run, baseURL: baseURL, offset: nil)
            } else if intent.contains(.blockHTML) || intent.contains(.inlineHTML) {
                _ = offset(of: text)
                html += inline(text, run: run, baseURL: baseURL, offset: nil)
            } else {
                html += inline(text, run: run, baseURL: baseURL, offset: offset(of: text))
            }
        }
        for block in open.reversed() { html += closeTag(block, parents: open) }
        return headingAnchors(taskLists(html))
    }

    // MARK: Front matter

    /// YAML front matter: a `---` line at the very start of the file, closed by a `---` or `...`
    /// line. `yaml` is the text between the fences; `end` is where the Markdown starts.
    static func frontMatter(_ markdown: String) -> (yaml: NSRange, end: Int)? {
        let ns = markdown as NSString
        func lineEnd(_ start: Int) -> (content: Int, next: Int) {
            let line = ns.lineRange(for: NSRange(location: start, length: 0))
            var content = NSMaxRange(line)
            while content > start, let scalar = UnicodeScalar(ns.character(at: content - 1)),
                  CharacterSet.newlines.contains(scalar) {
                content -= 1
            }
            return (content, NSMaxRange(line))
        }
        func line(_ start: Int, _ end: Int) -> String {
            ns.substring(with: NSRange(location: start, length: end - start))
                .trimmingCharacters(in: .whitespaces)
        }
        guard ns.hasPrefix("---") else { return nil }
        let first = lineEnd(0)
        guard line(0, first.content) == "---", first.next > first.content else { return nil }
        var start = first.next
        while start < ns.length {
            let (content, next) = lineEnd(start)
            let text = line(start, content)
            if text == "---" || text == "..." {
                return (NSRange(location: first.next, length: start - first.next), next)
            }
            start = next
        }
        return nil
    }

    /// Front matter as a table of its top-level keys. A value spread over several lines (a
    /// list, a nested map, a block string) shows as written. YAML whose top level isn't a map
    /// shows as a code block. Its text carries no file offsets, so comments can't anchor in it:
    /// review markup there would break the YAML for other tools.
    private static func frontMatterHTML(_ markdown: String, yaml: NSRange) -> String {
        let ns = markdown as NSString
        func marked(_ range: NSRange) -> String { escape(ns.substring(with: range)) }
        func trimmed(_ range: NSRange) -> NSRange {
            var start = range.location, end = NSMaxRange(range)
            let space = CharacterSet.whitespacesAndNewlines
            while start < end, let s = UnicodeScalar(ns.character(at: start)), space.contains(s) { start += 1 }
            while end > start, let s = UnicodeScalar(ns.character(at: end - 1)), space.contains(s) { end -= 1 }
            return NSRange(location: start, length: end - start)
        }

        // Each entry: its key, the value on the key's line, and the lines under it.
        var entries: [(key: NSRange, inline: NSRange, block: NSRange?)] = []
        var cursor = yaml.location
        var isMap = true
        while cursor < NSMaxRange(yaml) {
            let line = ns.lineRange(for: NSRange(location: cursor, length: 0))
            let lineText = ns.substring(with: line)
            let content = lineText.trimmingCharacters(in: .whitespacesAndNewlines)
            defer { cursor = NSMaxRange(line) }
            if content.isEmpty || content.hasPrefix("#") && lineText.first == "#" { continue }
            if let first = lineText.unicodeScalars.first, CharacterSet.whitespaces.contains(first) || lineText.hasPrefix("- ") || lineText == "-\n" {
                guard let last = entries.popLast() else { isMap = false; break }
                let blockStart = last.block?.location ?? line.location
                entries.append((last.key, last.inline, NSRange(location: blockStart, length: NSMaxRange(line) - blockStart)))
                continue
            }
            let colon = (lineText as NSString).range(of: ":(\\s|$)", options: .regularExpression)
            guard colon.location != NSNotFound, colon.location > 0 else { isMap = false; break }
            let key = NSRange(location: line.location, length: colon.location)
            let valueStart = line.location + colon.location + 1
            entries.append((key, trimmed(NSRange(location: valueStart, length: NSMaxRange(line) - valueStart)), nil))
        }
        guard isMap else {
            return "<pre class=\"front-matter\"><code>\(marked(yaml))</code></pre>"
        }
        guard !entries.isEmpty else { return "" }
        var rows = ""
        for entry in entries {
            var value = entry.inline.length > 0 ? marked(entry.inline) : ""
            if let block = entry.block {
                // A block string's `|` or `>` marker says how to read the lines under it.
                if value.range(of: "^[|>][-+0-9]*$", options: .regularExpression) != nil { value = "" }
                // Trailing blank lines belong to the gap before the next key.
                var end = NSMaxRange(block)
                while end > block.location, let s = UnicodeScalar(ns.character(at: end - 1)),
                      CharacterSet.whitespacesAndNewlines.contains(s) { end -= 1 }
                let lines = ns.substring(with: NSRange(location: block.location, length: end - block.location))
                    .components(separatedBy: "\n").map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
                let indent = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                    .map { $0.prefix { $0 == " " }.count }.min() ?? 0
                value += "<pre>\(escape(lines.map { String($0.dropFirst(min(indent, $0.prefix { $0 == " " }.count))) }.joined(separator: "\n")))</pre>"
            }
            rows += "<tr><th>\(marked(trimmed(entry.key)))</th><td>\(value)</td></tr>"
        }
        return "<table class=\"front-matter\">\(rows)</table>"
    }

    /// Give headings GitHub-style ids (`-1`, `-2` for repeats) so
    /// `#section` links work.
    private static func headingAnchors(_ html: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: "<h([1-6])>(.*?)</h\\1>", options: [.dotMatchesLineSeparators]) else {
            return html
        }
        let ns = html as NSString
        let matches = regex.matches(in: html, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return html }

        // Slugs in document order.
        var used: [String: Int] = [:]
        var emitted: Set<String> = []
        let slugs: [String] = matches.map { match in
            let inner = ns.substring(with: match.range(at: 2))
            let text = inner.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                .replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&lt;", with: "<")
                .replacingOccurrences(of: "&gt;", with: ">").replacingOccurrences(of: "&quot;", with: "\"")
            var slug = text.lowercased().unicodeScalars.map { scalar -> String in
                if CharacterSet.alphanumerics.contains(scalar) || scalar == "-" || scalar == "_" { return String(scalar) }
                return scalar == " " ? "-" : ""
            }.joined()
            if slug.isEmpty { slug = "section" }
            // Unique against every id emitted so far, including generated
            // suffixes ("Section", "Section", "Section-1").
            var candidate = slug
            var n = used[slug, default: 0]
            while emitted.contains(candidate) {
                n += 1
                candidate = "\(slug)-\(n)"
            }
            used[slug] = n
            emitted.insert(candidate)
            return candidate
        }

        var result = ""
        var cursor = 0
        for (match, slug) in zip(matches, slugs) {
            result += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            let level = ns.substring(with: match.range(at: 1))
            let inner = ns.substring(with: match.range(at: 2))
            result += "<h\(level) id=\"\(escape(slug))\">\(inner)</h\(level)>"
            cursor = match.range.location + match.range.length
        }
        result += ns.substring(from: cursor)
        return result
    }

    // MARK: Blocks

    private static func isHeaderRow(_ parents: [PresentationIntent.IntentType]) -> Bool {
        parents.contains { if case .tableHeaderRow = $0.kind { return true }; return false }
    }

    private static func openTag(_ block: PresentationIntent.IntentType, parents: [PresentationIntent.IntentType]) -> String {
        switch block.kind {
        case .paragraph: return "<p>"
        case .header(let level): return "<h\(max(1, min(level, 6)))>"
        case .orderedList: return "<ol>"
        case .unorderedList: return "<ul>"
        case .listItem(let ordinal):
            // Keep the source numbering of ordered lists (e.g. starting at 3).
            let ordered = parents.last.map { if case .orderedList = $0.kind { return true }; return false } ?? false
            return ordered ? "<li value=\"\(ordinal)\">" : "<li>"
        case .codeBlock(let language):
            // A bordered block with a footer naming the language, where the preview's script
            // adds Copy, Run in terminal (shell blocks) and the diagram (Mermaid), as Warp does.
            let code = CodeLanguage(language)
            let cls = code.id.isEmpty ? "" : " class=\"language-\(escape(code.id))\""
            let kind = code.kind.map { " umi-\($0)" } ?? ""
            return "<div class=\"umi-code\(kind)\" data-lang=\"\(escape(code.id))\"><pre><code\(cls)>"
        case .blockQuote: return "<blockquote>"
        case .thematicBreak: return "<hr>"
        // In a box of its own, which scrolls sideways when the table is wider than the pane.
        case .table: return "<div class=\"umi-table\"><table>"
        case .tableHeaderRow: return "<thead><tr>"
        case .tableRow: return "<tr>"
        case .tableCell(let column):
            let align = alignment(of: column, in: parents)
            let style = align.map { " style=\"text-align:\($0)\"" } ?? ""
            return isHeaderRow(parents) ? "<th\(style)>" : "<td\(style)>"
        @unknown default: return "<div>"
        }
    }

    private static func closeTag(_ block: PresentationIntent.IntentType, parents: [PresentationIntent.IntentType]) -> String {
        switch block.kind {
        case .paragraph: return "</p>\n"
        case .header(let level): return "</h\(max(1, min(level, 6)))>\n"
        case .orderedList: return "</ol>\n"
        case .unorderedList: return "</ul>\n"
        case .listItem: return "</li>\n"
        case .codeBlock(let language):
            return "</code></pre><div class=\"umi-code-footer\" data-label=\"\(escape(CodeLanguage(language).label))\"></div></div>\n"
        case .blockQuote: return "</blockquote>\n"
        case .thematicBreak: return "\n"
        case .table: return "</tbody></table></div>\n"
        case .tableHeaderRow: return "</tr></thead><tbody>\n"
        case .tableRow: return "</tr>\n"
        case .tableCell: return isHeaderRow(parents) ? "</th>" : "</td>"
        @unknown default: return "</div>"
        }
    }

    /// A fenced block's language as Warp reads it: the info string's first word, lowercased.
    /// Shell languages get Run in terminal, `mermaid` a diagram; the footer names the language
    /// as Warp's does.
    struct CodeLanguage {
        static let shell: Set<String> = ["sh", "shell", "bash", "fish", "zsh", "warp-runnable-command"]
        let id: String

        init(_ info: String?) {
            id = (info ?? "").split(whereSeparator: \.isWhitespace).first.map { $0.lowercased() } ?? ""
        }

        var kind: String? {
            if Self.shell.contains(id) { return "shell" }
            if id == "mermaid" { return "mermaid" }
            return nil
        }

        var label: String {
            if Self.shell.contains(id) { return "Shell" }
            switch id {
            case "", "text": return "Code"
            case "mermaid": return "Mermaid"
            case "go", "golang": return "Go"
            case "c++", "cpp": return "C++"
            case "c#", "csharp", "cs": return "C#"
            case "java", "groovy": return "Java"
            case "javascript", "jsx", "js": return "JavaScript"
            case "python", "py": return "Python"
            case "ruby on rails", "ruby": return "Ruby on Rails"
            case "rust": return "Rust"
            case "sql": return "SQL"
            case "yaml": return "YAML"
            case "json": return "JSON"
            case "php": return "PHP"
            case "toml": return "TOML"
            case "swift": return "Swift"
            case "kotlin": return "Kotlin"
            case "powershell": return "PowerShell"
            default: return id
            }
        }
    }

    private static func alignment(of column: Int, in parents: [PresentationIntent.IntentType]) -> String? {
        for parent in parents {
            if case .table(let columns) = parent.kind, column < columns.count {
                switch columns[column].alignment {
                case .left: return "left"
                case .center: return "center"
                case .right: return "right"
                @unknown default: return nil
                }
            }
        }
        return nil
    }

    // MARK: Inline

    private static func inline(_ text: String, run: AttributedString.Runs.Run, baseURL: URL?, offset: Int?) -> String {
        let intent = run.inlinePresentationIntent ?? []
        if intent.contains(.blockHTML) || intent.contains(.inlineHTML) {
            // Raw HTML from the document (the preview disables JavaScript),
            // with relative URLs resolved against the document's folder.
            return resolvingURLs(inHTML: text, baseURL: baseURL)
        }
        if intent.contains(.softBreak) { return "\n" }
        if intent.contains(.lineBreak) { return "<br>\n" }

        // Bare URLs in plain text are links, as in Warp (not in code, nor inside a link already).
        let plain = intent.contains(.code) || run.link != nil || run.imageURL != nil ? escape(text) : linkified(text)
        var out = offset.map { "<span data-s=\"\($0)\">\(plain)</span>" } ?? plain
        if intent.contains(.code) { out = "<code>\(out)</code>" }
        if intent.contains(.stronglyEmphasized) { out = "<strong>\(out)</strong>" }
        if intent.contains(.emphasized) { out = "<em>\(out)</em>" }
        if intent.contains(.strikethrough) { out = "<del>\(out)</del>" }

        if let image = run.imageURL {
            return "<img src=\"\(escape(imageSource(image)))\" alt=\"\(escape(text))\">"
        }
        if let link = run.link {
            // `[x](#section)` resolves against the base directory; keep it a
            // same-document anchor.
            if let fragment = link.fragment, link.isFileURL, let baseURL,
               link.standardizedFileURL.path == baseURL.standardizedFileURL.path {
                return "<a href=\"#\(escape(fragment))\">\(out)</a>"
            }
            return "<a href=\"\(escape(link.absoluteString))\">\(out)</a>"
        }
        return out
    }

    /// `[![alt](image)](link)` as HTML: Foundation's parser drops an image
    /// nested in a link (README badges). Skips fenced and inline code.
    private static func linkedImagesAsHTML(_ markdown: String) -> String {
        guard markdown.contains("[!["),
              let regex = try? NSRegularExpression(
                pattern: #"\[!\[([^\]]*)\]\(\s*<?([^)\s>]+)>?(?:\s+"[^"]*")?\s*\)\]\(\s*<?([^)\s>]+)>?(?:\s+"[^"]*")?\s*\)"#)
        else { return markdown }
        var inFence = false
        let lines = markdown.components(separatedBy: "\n").map { line -> String in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                inFence.toggle()
                return line
            }
            guard !inFence, line.contains("[![") else { return line }
            // Only outside `inline code` (even segments between backticks).
            var parts = line.components(separatedBy: "`")
            for index in stride(from: 0, to: parts.count, by: 2) {
                let part = parts[index] as NSString
                var rebuilt = ""
                var cursor = 0
                for match in regex.matches(in: parts[index], range: NSRange(location: 0, length: part.length)) {
                    rebuilt += part.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
                    let alt = part.substring(with: match.range(at: 1))
                    let image = part.substring(with: match.range(at: 2))
                    let link = part.substring(with: match.range(at: 3))
                    rebuilt += "<a href=\"\(escape(link))\"><img src=\"\(escape(image))\" alt=\"\(escape(alt))\"></a>"
                    cursor = match.range.location + match.range.length
                }
                rebuilt += part.substring(from: cursor)
                parts[index] = rebuilt
            }
            return parts.joined(separator: "`")
        }
        return lines.joined(separator: "\n")
    }

    /// Resolve relative `src`/`href` values in raw HTML against the
    /// document's folder; local images become data URIs.
    private static func resolvingURLs(inHTML html: String, baseURL: URL?) -> String {
        guard let regex = try? NSRegularExpression(
            pattern: #"\b(src|href)\s*=\s*(?:"([^"]*)"|'([^']*)')"#, options: [.caseInsensitive]) else { return html }
        let ns = html as NSString
        var result = ""
        var cursor = 0
        for match in regex.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            let attribute = ns.substring(with: match.range(at: 1))
            let valueRange = match.range(at: 2).location != NSNotFound ? match.range(at: 2) : match.range(at: 3)
            let value = ns.substring(with: valueRange)
            result += "\(attribute)=\"\(escape(resolve(value, isImage: attribute.lowercased() == "src", baseURL: baseURL)))\""
            cursor = match.range.location + match.range.length
        }
        result += ns.substring(from: cursor)
        return result
    }

    private static func resolve(_ value: String, isImage: Bool, baseURL: URL?) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "&amp;", with: "&")
        if trimmed.isEmpty || trimmed.hasPrefix("#") { return trimmed }
        if let url = URL(string: trimmed), url.scheme != nil {
            return isImage && url.isFileURL ? imageSource(url) : trimmed
        }
        guard let baseURL, let url = URL(string: trimmed, relativeTo: baseURL)?.absoluteURL else { return trimmed }
        return isImage ? imageSource(url) : url.absoluteString
    }

    /// Local images are inlined as data URIs so the preview needs no file access.
    private static func imageSource(_ url: URL) -> String {
        guard url.isFileURL else { return url.absoluteString }
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber, size.intValue < 8 * 1024 * 1024,
              let data = try? Data(contentsOf: url) else { return "" }
        let mime: String
        switch url.pathExtension.lowercased() {
        case "png": mime = "image/png"
        case "jpg", "jpeg": mime = "image/jpeg"
        case "gif": mime = "image/gif"
        case "svg": mime = "image/svg+xml"
        case "webp": mime = "image/webp"
        default: mime = "application/octet-stream"
        }
        return "data:\(mime);base64,\(data.base64EncodedString())"
    }

    /// GitHub-style task list items.
    private static func taskLists(_ html: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"<li><p>(<span data-s="(\d+)">)?\[([ xX])\] "#) else { return html }
        let ns = html as NSString
        var result = ""
        var cursor = 0
        for match in regex.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            let checked = ns.substring(with: match.range(at: 3)) != " "
            result += "<li class=\"task\"><p><input type=\"checkbox\"\(checked ? " checked" : "") disabled> "
            // The run's text now starts four characters later in the file.
            if match.range(at: 2).location != NSNotFound, let start = Int(ns.substring(with: match.range(at: 2))) {
                result += "<span data-s=\"\(start + 4)\">"
            }
            cursor = NSMaxRange(match.range)
        }
        result += ns.substring(from: cursor)
        return result
    }

    private static let bareURL = try? NSRegularExpression(pattern: #"\b(?:https?://|www\.)[^\s<>"'`]+"#, options: [.caseInsensitive])

    /// Plain text, escaped, with its bare URLs (`https://…`, `www.…`) made links. Trailing
    /// punctuation and an unmatched closing bracket stay text, as in GitHub's autolinks.
    static func linkified(_ text: String) -> String {
        guard let bareURL, text.contains("http") || text.contains("www.") || text.contains("HTTP") || text.contains("WWW.") else {
            return escape(text)
        }
        let ns = text as NSString
        var out = ""
        var cursor = 0
        for match in bareURL.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            var url = ns.substring(with: match.range)
            while let last = url.last, ".,;:!?*_~".contains(last) || (last == ")" && url.filter { $0 == "(" }.count < url.filter { $0 == ")" }.count) {
                url.removeLast()
            }
            guard !url.isEmpty else { continue }
            out += escape(ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor)))
            let href = url.lowercased().hasPrefix("www.") ? "https://" + url : url
            out += "<a href=\"\(escape(href))\">\(escape(url))</a>"
            cursor = match.range.location + (url as NSString).length
        }
        out += escape(ns.substring(from: cursor))
        return out
    }

    static func escape(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        for ch in text {
            switch ch {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            default: out.append(ch)
            }
        }
        return out
    }

    // MARK: Page

    /// `markdown`: a Markdown document, drawn as Warp draws Markdown files (Warp parity,
    /// 2026-11-05); otherwise a data preview (JSON, CSV) in the editor's earlier style.
    static func page(body: String, background: String, light: Bool = false, head: String = "", markdown: Bool = false,
                     fontSize: Double = 13) -> String {
        if markdown {
            return """
            <!doctype html><html><head><meta charset="utf-8">
            <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'none'; img-src data: https: http:; style-src 'unsafe-inline'; font-src data:;">
            <meta name="umi-markdown" content="1">
            <style>\(UmiMarkdownStyle.fonts)\n\(UmiMarkdownStyle.css(light: light, background: background, fontSize: fontSize))</style>\(head)</head><body class="umi-md">\(body)</body></html>
            """
        }
        // Light and dark palettes: text, headings, muted text, code/rule tints.
        let (fg, heading, muted, tint, scheme) = light
            ? ("#24292f", "#111111", "#57606a", "0,0,0", "light")
            : ("#e2e2e2", "#f2f2f2", "#a8a8a8", "255,255,255", "dark")
        return """
        <!doctype html><html><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'none'; img-src data: https: http:; style-src 'unsafe-inline';">
        <style>
        :root { color-scheme: \(scheme); }
        html, body { margin: 0; background: \(background); }
        body { color: \(fg); font: 14px/1.65 -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif;
               padding: 22px 28px 60px; max-width: 860px; -webkit-font-smoothing: antialiased; }
        h1, h2, h3, h4, h5, h6 { color: \(heading); font-weight: 600; line-height: 1.3; margin: 1.6em 0 0.6em; }
        h1 { font-size: 1.9em; } h2 { font-size: 1.45em; } h3 { font-size: 1.2em; } h4, h5, h6 { font-size: 1em; }
        body > :first-child { margin-top: 0; }
        p, ul, ol, blockquote, pre, table { margin: 0 0 1em; }
        a { color: #19aad8; text-decoration: none; } a:hover { text-decoration: underline; }
        code { font: 12.5px/1.5 "SF Mono", Menlo, monospace; background: rgba(\(tint),0.06);
               padding: 0.1em 0.35em; border-radius: 4px; }
        pre { background: rgba(\(tint),0.04); padding: 12px 14px; border-radius: 8px; overflow-x: auto; }
        pre code { background: none; padding: 0; }
        blockquote { margin-left: 0; padding: 0 0 0 14px; border-left: 2px solid rgba(\(tint),0.15); color: \(muted); }
        hr { border: none; height: 1px; background: rgba(\(tint),0.1); margin: 1.6em 0; }
        ul, ol { padding-left: 1.5em; } li > p { margin: 0.15em 0; } li.task { list-style: none; margin-left: -1.3em; }
        table { border-collapse: collapse; } th, td { padding: 6px 12px; border-bottom: 1px solid rgba(\(tint),0.08); }
        th { text-align: left; color: \(heading); font-weight: 600; }
        img { max-width: 100%; }
        .front-matter { font-size: 12.5px; color: \(muted); margin: 0 0 1.6em; }
        table.front-matter { width: 100%; border-top: 1px solid rgba(\(tint),0.08); }
        table.front-matter th, table.front-matter td { padding: 4px 12px 4px 0; vertical-align: top; font-weight: 400; }
        table.front-matter th { color: \(muted); width: 1%; white-space: nowrap; font: 12px/1.6 "SF Mono", Menlo, monospace; }
        table.front-matter td { color: \(fg); }
        table.front-matter pre { margin: 0; padding: 0; background: none; font: 12px/1.6 "SF Mono", Menlo, monospace; white-space: pre-wrap; }
        </style>\(head)</head><body>\(body)</body></html>
        """
    }
}
