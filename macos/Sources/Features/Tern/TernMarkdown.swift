import Foundation

/// Markdown → HTML for the editor's preview (and, later, agent replies), built on
/// Foundation's CommonMark/GFM parser (`AttributedString(markdown:)` with full syntax).
/// Block structure comes from each run's `presentationIntent`, inline styling from
/// `inlinePresentationIntent`, links and images from their attributes.
///
/// The page it produces is meant for a WKWebView with JavaScript turned off and a
/// Content-Security-Policy that allows no scripts: raw HTML in a document can show images
/// but never run code (E-7).
enum TernMarkdown {
    static func html(from markdown: String, baseURL: URL?) -> String {
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: false,
            interpretedSyntax: .full,
            failurePolicy: .returnPartiallyParsedIfPossible)
        let source = linkedImagesAsHTML(markdown)
        guard let doc = try? AttributedString(markdown: source, options: options, baseURL: baseURL) else {
            return "<pre><code>\(escape(markdown))</code></pre>"
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
                html += escape(text)
                continue
            }
            html += inline(text, run: run, baseURL: baseURL)
        }
        for block in open.reversed() { html += closeTag(block, parents: open) }
        return headingAnchors(taskLists(html))
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
            let cls = language.map { " class=\"language-\(escape($0))\"" } ?? ""
            return "<pre><code\(cls)>"
        case .blockQuote: return "<blockquote>"
        case .thematicBreak: return "<hr>"
        case .table: return "<table>"
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
        case .codeBlock: return "</code></pre>\n"
        case .blockQuote: return "</blockquote>\n"
        case .thematicBreak: return "\n"
        case .table: return "</tbody></table>\n"
        case .tableHeaderRow: return "</tr></thead><tbody>\n"
        case .tableRow: return "</tr>\n"
        case .tableCell: return isHeaderRow(parents) ? "</th>" : "</td>"
        @unknown default: return "</div>"
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

    private static func inline(_ text: String, run: AttributedString.Runs.Run, baseURL: URL?) -> String {
        let intent = run.inlinePresentationIntent ?? []
        if intent.contains(.blockHTML) || intent.contains(.inlineHTML) {
            // Raw HTML from the document (the preview disables JavaScript),
            // with relative URLs resolved against the document's folder.
            return resolvingURLs(inHTML: text, baseURL: baseURL)
        }
        if intent.contains(.softBreak) { return "\n" }
        if intent.contains(.lineBreak) { return "<br>\n" }

        var out = escape(text)
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
        html
            .replacingOccurrences(of: "<li><p>[ ] ", with: "<li class=\"task\"><p><input type=\"checkbox\" disabled> ")
            .replacingOccurrences(of: "<li><p>[x] ", with: "<li class=\"task\"><p><input type=\"checkbox\" checked disabled> ")
            .replacingOccurrences(of: "<li><p>[X] ", with: "<li class=\"task\"><p><input type=\"checkbox\" checked disabled> ")
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

    static func page(body: String, background: String, light: Bool = false) -> String {
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
        </style></head><body>\(body)</body></html>
        """
    }
}
