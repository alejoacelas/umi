import Foundation

/// A small YAML reader and writer, enough for launch configurations (`UmiLaunchConfigs`):
/// block mappings and sequences (indented or not under their key), plain, single- and
/// double-quoted scalars, `|` and `>` block scalars, one-line flow collections (`[a, b]`,
/// `{k: v}`), comments, and several documents in one file separated by `---` (`documents`).
/// Anchors, aliases, tags and multi-line flow collections aren't supported; they fail with the
/// line they're on.
///
/// Parsed values are `[String: Any]`, `[Any]`, `String`, `Int`, `Double`, `Bool` or `NSNull`.
enum UmiYAML {
    struct ParseError: Error, CustomStringConvertible {
        let line: Int
        let message: String
        var description: String { "line \(line): \(message)" }
    }

    /// Every document in a file, in order: each `---` after content starts a new one, as in
    /// YAML streams. Empty documents (a leading `---`, a trailing one) are left out; a file with
    /// no content is one null document.
    static func documents(_ text: String) throws -> [Any] {
        var parser = Parser(text: text)
        var out: [Any] = []
        repeat {
            let value = try parser.document()
            if !(value is NSNull) { out.append(value) }
        } while parser.startNextDocument()
        return out.isEmpty ? [NSNull()] : out
    }

    // MARK: Reading

    private struct Line {
        let number: Int
        let indent: Int
        let text: String
    }

    private struct Parser {
        var raw: [String]
        var index = 0
        /// The rest of a `- ` line, read as a line of its own at the column it starts at.
        var pending: Line?
        /// Whether the current document has content yet: a `---` before content is a header, after
        /// it the start of the next document.
        var started = false

        init(text: String) {
            raw = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        }

        mutating func document() throws -> Any {
            guard try peek() != nil else { return NSNull() }
            let value = try block()
            if let extra = try peek() {
                throw ParseError(line: extra.number, message: "unexpected \"\(extra.text)\" (check its indentation)")
            }
            return value
        }

        /// The next line with content, without consuming it.
        mutating func peek() throws -> Line? {
            if let pending { return pending }
            while index < raw.count {
                let line = raw[index]
                let indent = line.prefix { $0 == " " }.count
                let body = Self.stripComment(String(line.dropFirst(indent)))
                let text = body.trimmingCharacters(in: .whitespaces)
                if indent == 0 && (text == "---" || text == "...") && started { return nil }
                if text.isEmpty || text == "---" || text == "..." || (indent == 0 && text.hasPrefix("%")) {
                    index += 1
                    continue
                }
                if line.dropFirst(indent).first == "\t" {
                    throw ParseError(line: index + 1, message: "indent with spaces, not tabs")
                }
                if text.hasPrefix("&") || text.hasPrefix("*") || text.hasPrefix("!") {
                    throw ParseError(line: index + 1, message: "anchors, aliases and tags aren't supported")
                }
                return Line(number: index + 1, indent: indent, text: text)
            }
            return nil
        }

        mutating func consume() {
            started = true
            if pending != nil { pending = nil } else { index += 1 }
        }

        /// Move past the `---` (or `...`) that ends the current document. False at the end of the file.
        mutating func startNextDocument() -> Bool {
            guard pending == nil, index < raw.count else { return false }
            index += 1
            started = false
            return true
        }

        static func isSequenceItem(_ text: String) -> Bool { text == "-" || text.hasPrefix("- ") }

        mutating func block() throws -> Any {
            guard let line = try peek() else { return NSNull() }
            if Self.isSequenceItem(line.text) { return try sequence(indent: line.indent) }
            if Self.splitKey(line.text) != nil { return try mapping(indent: line.indent) }
            consume()
            return try Self.scalar(line.text, line: line.number)
        }

        mutating func sequence(indent: Int) throws -> [Any] {
            var out: [Any] = []
            while let line = try peek(), line.indent == indent, Self.isSequenceItem(line.text) {
                consume()
                let afterDash = String(line.text.dropFirst())
                let rest = afterDash.trimmingCharacters(in: .whitespaces)
                let column = indent + 1 + (afterDash.count - afterDash.drop { $0 == " " }.count)
                if rest.isEmpty {
                    if let next = try peek(), next.indent > indent { out.append(try block()) } else { out.append(NSNull()) }
                } else if Self.isSequenceItem(rest) || Self.splitKey(rest) != nil {
                    pending = Line(number: line.number, indent: column, text: rest)
                    out.append(try block())
                } else {
                    out.append(try value(rest, line: line.number, parentIndent: indent))
                }
            }
            if let line = try peek(), line.indent > indent {
                throw ParseError(line: line.number, message: "unexpected \"\(line.text)\" (check its indentation)")
            }
            return out
        }

        mutating func mapping(indent: Int) throws -> [String: Any] {
            var out: [String: Any] = [:]
            while let line = try peek(), line.indent >= indent {
                guard line.indent == indent else {
                    throw ParseError(line: line.number, message: "unexpected \"\(line.text)\" (check its indentation)")
                }
                if Self.isSequenceItem(line.text) {
                    throw ParseError(line: line.number, message: "a list item where a `key: value` was expected")
                }
                guard let (key, rest) = Self.splitKey(line.text) else {
                    throw ParseError(line: line.number, message: "expected `key: value`, found \"\(line.text)\"")
                }
                consume()
                if rest.isEmpty {
                    if let next = try peek(), next.indent > indent {
                        out[key] = try block()
                    } else if let next = try peek(), next.indent == indent, Self.isSequenceItem(next.text) {
                        out[key] = try sequence(indent: indent)
                    } else {
                        out[key] = NSNull()
                    }
                } else {
                    out[key] = try value(rest, line: line.number, parentIndent: indent)
                }
            }
            return out
        }

        /// A value written after `key:` or `- `: a scalar, a one-line flow collection, or the
        /// header of a block scalar whose lines follow.
        mutating func value(_ text: String, line: Int, parentIndent: Int) throws -> Any {
            guard let first = text.first, first == "|" || first == ">" else { return try Self.scalar(text, line: line) }
            let header = text.dropFirst()
            guard header.allSatisfy({ $0 == "-" || $0 == "+" }) else {
                throw ParseError(line: line, message: "unsupported block scalar header \"\(text)\"")
            }
            let chomp = header.first
            var lines: [String] = []
            var contentIndent: Int?
            while index < raw.count {
                let rawLine = raw[index]
                let indent = rawLine.prefix { $0 == " " }.count
                let blank = rawLine.trimmingCharacters(in: .whitespaces).isEmpty
                if !blank {
                    if indent <= parentIndent { break }
                    if contentIndent == nil { contentIndent = indent }
                    if indent < contentIndent! { break }
                }
                lines.append(blank ? "" : String(rawLine.dropFirst(contentIndent!)))
                index += 1
            }
            var trailing = 0
            while let last = lines.last, last.isEmpty { lines.removeLast(); trailing += 1 }
            var body: String
            if first == "|" {
                body = lines.joined(separator: "\n")
            } else {
                body = ""
                for (i, part) in lines.enumerated() {
                    if i > 0 { body += part.isEmpty || lines[i - 1].isEmpty ? "\n" : " " }
                    body += part
                }
            }
            if lines.isEmpty { return "" }
            switch chomp {
            case "-": return body
            case "+": return body + String(repeating: "\n", count: trailing + 1)
            default: return body + "\n"
            }
        }

        /// `key: rest` (rest may be empty), or nil when the text isn't a mapping entry.
        static func splitKey(_ text: String) -> (String, String)? {
            if let first = text.first, first == "\"" || first == "'" {
                guard let (key, end) = try? quoted(text, line: 0) else { return nil }
                let after = text[end...]
                guard after.first == ":" else { return nil }
                let rest = after.dropFirst()
                guard rest.isEmpty || rest.first == " " else { return nil }
                return (key, rest.trimmingCharacters(in: .whitespaces))
            }
            if text.hasPrefix("[") || text.hasPrefix("{") || text.hasPrefix("- ") { return nil }
            if text.hasSuffix(":") && !text.dropLast().contains(": ") {
                let key = String(text.dropLast()).trimmingCharacters(in: .whitespaces)
                return key.isEmpty ? nil : (key, "")
            }
            guard let range = text.range(of: ": ") else { return nil }
            let key = text[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { return nil }
            return (key, text[range.upperBound...].trimmingCharacters(in: .whitespaces))
        }

        /// The text without a trailing comment: `#` at the start or after a space, outside quotes.
        static func stripComment(_ text: String) -> String {
            var quote: Character?
            var previous: Character = " "
            var out = ""
            var escaped = false
            for c in text {
                if let q = quote {
                    if q == "\"" && c == "\\" && !escaped { escaped = true; out.append(c); previous = c; continue }
                    if c == q && !escaped { quote = nil }
                    escaped = false
                } else if c == "#" && (previous == " " || previous == "\t") {
                    break
                } else if (c == "\"" || c == "'") && " \t[{,:-".contains(previous) {
                    quote = c
                }
                out.append(c)
                previous = c
            }
            return out
        }

        /// A quoted string at the start of `text`, and the index just after its closing quote.
        static func quoted(_ text: String, line: Int) throws -> (String, String.Index) {
            let quote = text.first!
            var out = ""
            var i = text.index(after: text.startIndex)
            while i < text.endIndex {
                let c = text[i]
                if quote == "'" {
                    if c == "'" {
                        let next = text.index(after: i)
                        if next < text.endIndex, text[next] == "'" {
                            out.append("'")
                            i = text.index(after: next)
                            continue
                        }
                        return (out, next)
                    }
                    out.append(c)
                } else if c == "\"" {
                    return (out, text.index(after: i))
                } else if c == "\\" {
                    i = text.index(after: i)
                    guard i < text.endIndex else { break }
                    switch text[i] {
                    case "n": out.append("\n")
                    case "t": out.append("\t")
                    case "r": out.append("\r")
                    case "0": out.append("\0")
                    case "\\": out.append("\\")
                    case "\"": out.append("\"")
                    case "/": out.append("/")
                    case " ": out.append(" ")
                    case "e": out.append("\u{1B}")
                    case "u", "x", "U":
                        let width = text[i] == "x" ? 2 : (text[i] == "u" ? 4 : 8)
                        var hex = ""
                        for _ in 0..<width {
                            i = text.index(after: i)
                            guard i < text.endIndex else { break }
                            hex.append(text[i])
                        }
                        guard let code = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(code) else {
                            throw ParseError(line: line, message: "bad escape \\\(hex)")
                        }
                        out.unicodeScalars.append(scalar)
                    default:
                        throw ParseError(line: line, message: "unknown escape \\\(text[i])")
                    }
                } else {
                    out.append(c)
                }
                i = text.index(after: i)
            }
            throw ParseError(line: line, message: "a quoted string isn't closed on its line (multi-line strings aren't supported)")
        }

        static func scalar(_ raw: String, line: Int) throws -> Any {
            let text = raw.trimmingCharacters(in: .whitespaces)
            guard let first = text.first else { return NSNull() }
            if first == "\"" || first == "'" {
                let (value, end) = try quoted(text, line: line)
                guard text[end...].trimmingCharacters(in: .whitespaces).isEmpty else {
                    throw ParseError(line: line, message: "unexpected text after a quoted string: \"\(text)\"")
                }
                return value
            }
            if first == "[" || first == "{" { return try flow(text, line: line) }
            if first == "&" || first == "*" || first == "!" {
                throw ParseError(line: line, message: "anchors, aliases and tags aren't supported")
            }
            return plain(text)
        }

        static func plain(_ text: String) -> Any {
            switch text {
            case "~", "null", "Null", "NULL": return NSNull()
            case "true", "True", "TRUE": return true
            case "false", "False", "FALSE": return false
            default: break
            }
            if let int = Int(text) { return int }
            if text.first.map({ $0.isNumber || $0 == "-" || $0 == "." }) == true, let double = Double(text) { return double }
            return text
        }

        /// A one-line flow collection.
        static func flow(_ text: String, line: Int) throws -> Any {
            let open = text.first!
            let close: Character = open == "[" ? "]" : "}"
            guard text.last == close else {
                throw ParseError(line: line, message: "a \(open)…\(close) list must be on one line")
            }
            let inner = String(text.dropFirst().dropLast())
            // Split at top-level commas.
            var parts: [String] = []
            var depth = 0
            var quote: Character?
            var current = ""
            for c in inner {
                if let q = quote {
                    if c == q { quote = nil }
                } else if c == "\"" || c == "'" {
                    quote = c
                } else if c == "[" || c == "{" {
                    depth += 1
                } else if c == "]" || c == "}" {
                    depth -= 1
                } else if c == "," && depth == 0 {
                    parts.append(current)
                    current = ""
                    continue
                }
                current.append(c)
            }
            if !current.trimmingCharacters(in: .whitespaces).isEmpty || !parts.isEmpty { parts.append(current) }
            let items = parts.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            if open == "[" { return try items.map { try scalar($0, line: line) } }
            var out: [String: Any] = [:]
            for item in items {
                if let (key, rest) = splitKey(item) {
                    out[key] = try scalar(rest, line: line)
                } else if item.hasSuffix(":") {
                    out[String(item.dropLast())] = NSNull()
                } else {
                    out[item] = NSNull()
                }
            }
            return out
        }
    }

    // MARK: Writing

    /// A value to write, keeping the order of mapping keys.
    indirect enum Node {
        case string(String)
        case int(Int)
        case bool(Bool)
        case list([Node])
        case map([(String, Node)])
    }

    /// Block style, lists under a key at the key's own indentation (as serde_yaml writes them).
    static func emit(_ node: Node) -> String {
        var out = ""
        write(node, indent: 0, into: &out)
        return out
    }

    private static func write(_ node: Node, indent: Int, into out: inout String) {
        let pad = String(repeating: " ", count: indent)
        switch node {
        case .map(let pairs):
            for (key, value) in pairs {
                switch value {
                case .list(let items) where items.isEmpty:
                    out += "\(pad)\(quote(key)): []\n"
                case .map(let inner) where inner.isEmpty:
                    out += "\(pad)\(quote(key)): {}\n"
                case .list:
                    out += "\(pad)\(quote(key)):\n"
                    write(value, indent: indent, into: &out)
                case .map:
                    out += "\(pad)\(quote(key)):\n"
                    write(value, indent: indent + 2, into: &out)
                default:
                    out += "\(pad)\(quote(key)): \(scalar(value))\n"
                }
            }
        case .list(let items):
            for item in items {
                switch item {
                case .map(let pairs) where !pairs.isEmpty:
                    var inner = ""
                    write(item, indent: indent + 2, into: &inner)
                    out += pad + "- " + inner.dropFirst(indent + 2)
                case .list(let nested) where !nested.isEmpty:
                    out += "\(pad)-\n"
                    write(item, indent: indent + 2, into: &out)
                case .list:
                    out += "\(pad)- []\n"
                case .map:
                    out += "\(pad)- {}\n"
                default:
                    out += "\(pad)- \(scalar(item))\n"
                }
            }
        default:
            out += pad + scalar(node) + "\n"
        }
    }

    private static func scalar(_ node: Node) -> String {
        switch node {
        case .string(let s): return quote(s)
        case .int(let i): return String(i)
        case .bool(let b): return b ? "true" : "false"
        case .list, .map: return ""
        }
    }

    /// A string as a plain scalar when it reads back as the same string, else double-quoted.
    static func quote(_ s: String) -> String {
        if needsQuotes(s) {
            var out = "\""
            for scalar in s.unicodeScalars {
                switch scalar {
                case "\"": out += "\\\""
                case "\\": out += "\\\\"
                case "\n": out += "\\n"
                case "\t": out += "\\t"
                case "\r": out += "\\r"
                default:
                    if scalar.value < 0x20 || scalar.value == 0x7F {
                        out += String(format: "\\u%04X", scalar.value)
                    } else {
                        out.unicodeScalars.append(scalar)
                    }
                }
            }
            return out + "\""
        }
        return s
    }

    private static func needsQuotes(_ s: String) -> Bool {
        guard let first = s.first, let last = s.last else { return true }
        if first == " " || last == " " || last == ":" { return true }
        if "-?:,[]{}#&*!|>'\"%@`".contains(first) { return true }
        if s.contains(": ") || s.contains(" #") { return true }
        if s.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) { return true }
        let lowered = s.lowercased()
        if ["~", "null", "true", "false", "yes", "no", "on", "off", "y", "n"].contains(lowered) { return true }
        if Int(s) != nil || Double(s) != nil { return true }
        return false
    }
}
