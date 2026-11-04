import Foundation

/// Previews for data files: JSON as a collapsible tree, CSV/TSV as a table. Rendered to static
/// HTML (the preview runs with JavaScript off), so folding uses <details>.
enum UmiDataPreview {
    static let extensions: Set<String> = ["json", "csv", "tsv"]

    static func handles(_ url: URL) -> Bool { extensions.contains(url.pathExtension.lowercased()) }

    static func html(for url: URL, text: String) -> String {
        switch url.pathExtension.lowercased() {
        case "json": return json(text)
        case "csv": return table(text, separator: ",")
        case "tsv": return table(text, separator: "\t")
        default: return "<pre>\(UmiMarkdown.escape(text))</pre>"
        }
    }

    // MARK: JSON

    static func json(_ text: String) -> String {
        var parser = JSONParser(Array(text.unicodeScalars))
        do {
            let value = try parser.parseDocument()
            return style + "<div class=\"json\">" + render(value, key: nil, depth: 0) + "</div>"
        } catch {
            let message = (error as? JSONParser.Failure)?.message ?? "invalid JSON"
            return style + "<p class=\"err\">Can't show a tree: \(UmiMarkdown.escape(message)). Switch to Source to fix it.</p>"
        }
    }

    indirect enum Value {
        case object([(String, Value)]), array([Value]), string(String), number(String), bool(Bool), null
    }

    private static func render(_ value: Value, key: String?, depth: Int) -> String {
        let label = key.map { "<span class=\"k\">\(UmiMarkdown.escape($0))</span><span class=\"p\">: </span>" } ?? ""
        switch value {
        case .object(let members):
            let inner = members.map { "<li>" + render($0.1, key: $0.0, depth: depth + 1) + "</li>" }.joined()
            return container(label, open: "{", close: "}", count: members.count, noun: "key", inner: inner, depth: depth)
        case .array(let items):
            let inner = items.enumerated().map { "<li>" + render($0.element, key: "\($0.offset)", depth: depth + 1) + "</li>" }.joined()
            return container(label, open: "[", close: "]", count: items.count, noun: "item", inner: inner, depth: depth)
        case .string(let s): return label + "<span class=\"s\">\"\(UmiMarkdown.escape(s))\"</span>"
        case .number(let n): return label + "<span class=\"n\">\(n)</span>"
        case .bool(let b): return label + "<span class=\"b\">\(b)</span>"
        case .null: return label + "<span class=\"z\">null</span>"
        }
    }

    private static func container(_ label: String, open: String, close: String, count: Int, noun: String, inner: String, depth: Int) -> String {
        if count == 0 { return label + "<span class=\"p\">\(open)\(close)</span>" }
        let summary = "\(count) \(noun)\(count == 1 ? "" : "s")"
        return "<details\(depth < 3 ? " open" : "")><summary>\(label)<span class=\"p\">\(open)</span>"
            + "<span class=\"c\"> \(summary) </span><span class=\"p fold\">\(close)</span></summary>"
            + "<ul>\(inner)</ul><span class=\"p\">\(close)</span></details>"
    }

    /// A small parser that keeps object keys in file order (JSONSerialization doesn't).
    struct JSONParser {
        struct Failure: Error { let message: String }
        let s: [Unicode.Scalar]
        var i = 0
        init(_ s: [Unicode.Scalar]) { self.s = s }

        mutating func parseDocument() throws -> Value {
            let v = try parse()
            skip()
            if i < s.count { throw fail("unexpected text after the value") }
            return v
        }

        private func fail(_ m: String) -> Failure {
            let line = s[..<min(i, s.count)].filter { $0 == "\n" }.count + 1
            return Failure(message: "\(m) on line \(line)")
        }

        private mutating func skip() { while i < s.count, [" ", "\n", "\r", "\t"].contains(s[i]) { i += 1 } }

        private mutating func parse() throws -> Value {
            skip()
            guard i < s.count else { throw fail("unexpected end") }
            switch s[i] {
            case "{":
                i += 1; var members: [(String, Value)] = []
                skip(); if i < s.count, s[i] == "}" { i += 1; return .object(members) }
                while true {
                    skip(); guard i < s.count, s[i] == "\"" else { throw fail("expected a key") }
                    let k = try string(); skip()
                    guard i < s.count, s[i] == ":" else { throw fail("expected ':'") }
                    i += 1; members.append((k, try parse())); skip()
                    guard i < s.count else { throw fail("unexpected end") }
                    if s[i] == "," { i += 1; continue }
                    if s[i] == "}" { i += 1; return .object(members) }
                    throw fail("expected ',' or '}'")
                }
            case "[":
                i += 1; var items: [Value] = []
                skip(); if i < s.count, s[i] == "]" { i += 1; return .array(items) }
                while true {
                    items.append(try parse()); skip()
                    guard i < s.count else { throw fail("unexpected end") }
                    if s[i] == "," { i += 1; continue }
                    if s[i] == "]" { i += 1; return .array(items) }
                    throw fail("expected ',' or ']'")
                }
            case "\"": return .string(try string())
            case "t": return try word("true", .bool(true))
            case "f": return try word("false", .bool(false))
            case "n": return try word("null", .null)
            default:
                let start = i
                while i < s.count, "+-0123456789.eE".unicodeScalars.contains(s[i]) { i += 1 }
                guard i > start else { throw fail("unexpected character") }
                return .number(String(String.UnicodeScalarView(s[start..<i])))
            }
        }

        private mutating func word(_ w: String, _ v: Value) throws -> Value {
            let scalars = Array(w.unicodeScalars)
            guard i + scalars.count <= s.count, Array(s[i..<i + scalars.count]) == scalars else { throw fail("unexpected word") }
            i += scalars.count; return v
        }

        private mutating func string() throws -> String {
            i += 1; var out = String.UnicodeScalarView()
            while i < s.count {
                let c = s[i]; i += 1
                if c == "\"" { return String(out) }
                if c == "\\", i < s.count {
                    let e = s[i]; i += 1
                    switch e {
                    case "n": out.append("\n"); case "t": out.append("\t"); case "r": out.append("\r")
                    case "b": out.append("\u{8}"); case "f": out.append("\u{c}")
                    case "u":
                        guard i + 4 <= s.count, let code = UInt32(String(String.UnicodeScalarView(s[i..<i + 4])), radix: 16) else { throw fail("bad \\u escape") }
                        i += 4; if let u = Unicode.Scalar(code) { out.append(u) }
                    default: out.append(e)
                    }
                } else { out.append(c) }
            }
            throw fail("unterminated string")
        }
    }

    // MARK: CSV

    static func rows(_ text: String, separator: Character) -> [[String]] {
        var rows: [[String]] = [], row: [String] = [], field = "", quoted = false
        var it = Array(text).makeIterator(), pending: Character? = nil
        func next() -> Character? { if let p = pending { pending = nil; return p }; return it.next() }
        while let c = next() {
            if quoted {
                if c == "\"" {
                    if let n = next() { if n == "\"" { field.append("\"") } else { quoted = false; pending = n } } else { quoted = false }
                } else { field.append(c) }
            } else if c == "\"" { quoted = true }
            else if c == separator { row.append(field); field = "" }
            else if c == "\n" || c == "\r\n" { row.append(field); rows.append(row); row = []; field = "" }
            else if c != "\r" { field.append(c) }
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        return rows
    }

    static func table(_ text: String, separator: Character) -> String {
        let all = rows(text, separator: separator)
        guard let header = all.first else { return style + "<p class=\"c\">Empty file.</p>" }
        let body = all.dropFirst()
        let columns = all.map(\.count).max() ?? 0
        // A column is numeric when every non-empty cell parses as a number: right-align it.
        let numeric = (0..<columns).map { col in
            body.allSatisfy { col >= $0.count || $0[col].isEmpty || Double($0[col]) != nil }
        }
        func cells(_ r: [String], tag: String) -> String {
            (0..<columns).map { col in
                let v = col < r.count ? r[col] : ""
                return "<\(tag)\(numeric[col] ? " class=\"num\"" : "")>\(UmiMarkdown.escape(v))</\(tag)>"
            }.joined()
        }
        return style
            + "<p class=\"c\">\(body.count) rows × \(columns) columns</p>"
            + "<table class=\"grid\"><thead><tr><th class=\"rn\"></th>\(cells(header, tag: "th"))</tr></thead><tbody>"
            + body.enumerated().map { "<tr><td class=\"rn\">\($0.offset + 1)</td>\(cells($0.element, tag: "td"))</tr>" }.joined()
            + "</tbody></table>"
    }

    // MARK: Style (on top of UmiMarkdown.page's)

    private static let style = """
    <style>
    body { max-width: none; }
    .json { font: 12.5px/1.7 "SF Mono", Menlo, monospace; }
    .json ul { list-style: none; margin: 0; padding-left: 1.4em; border-left: 1px solid rgba(128,128,128,0.15); }
    .json li { margin: 0; }
    .json details > summary { cursor: pointer; list-style: none; }
    .json details > summary::-webkit-details-marker { display: none; }
    .json details > summary::before { content: "▸"; display: inline-block; width: 1em; margin-left: -1em; opacity: 0.5; }
    .json details[open] > summary::before { content: "▾"; }
    .json details[open] > summary .c, .json details[open] > summary .fold { display: none; }
    .k { color: #7aa2f7; } .s { color: #9ece6a; } .n { color: #e0af68; } .b, .z { color: #bb9af7; }
    .p { opacity: 0.6; } .c { opacity: 0.55; font-size: 12px; }
    .err { color: #f7768e; }
    table.grid { font: 12.5px/1.4 "SF Mono", Menlo, monospace; border-collapse: collapse; }
    table.grid th { position: sticky; top: 0; background: rgba(128,128,128,0.15); backdrop-filter: blur(8px); }
    table.grid th, table.grid td { padding: 5px 12px; border: 1px solid rgba(128,128,128,0.15); white-space: nowrap; }
    table.grid tbody tr:nth-child(even) { background: rgba(128,128,128,0.05); }
    table.grid .num { text-align: right; font-variant-numeric: tabular-nums; }
    table.grid .rn { opacity: 0.4; text-align: right; }
    </style>
    """
}
