import Foundation

/// Queries: pick and order panes by their attributes (design/primitives.md, "Queries and lists";
/// design/cli.md, "Queries").
///
/// ```
/// QUERY  := PART [ "then" PART ]…
/// PART   := EXPR [ "|" "sort" KEY ["," KEY]… ] [ "|" "limit" N ]
/// EXPR   := TERM | EXPR "and" EXPR | EXPR "or" EXPR | "not" EXPR | "(" EXPR ")"
/// TERM   := KEY OP VALUE | KEY | "@" LIST
/// OP     := "=" | "!=" | "<" | "<=" | ">" | ">="
/// ```
///
/// `then` joins parts: the panes of the first part, then those of the next that aren't listed yet
/// (how `jump` is "needs you, then unseen").
///
/// Parsing is pure; evaluating takes the panes as `UmiQuery.Item`s, whose attribute values are
/// read on demand, so a query reads only the attributes it names.
enum UmiQuery {
    struct ParseError: Error, CustomStringConvertible {
        /// 1-based character position in the query.
        let position: Int
        let message: String
        var description: String { "can't read the query at character \(position): \(message)" }
    }

    enum Op: String { case eq = "=", ne = "!=", lt = "<", le = "<=", gt = ">", ge = ">=" }

    indirect enum Expr: Equatable {
        case compare(String, Op, String)
        case has(String)
        case list(String)
        case not(Expr)
        case and(Expr, Expr)
        case or(Expr, Expr)
    }

    struct SortKey: Equatable {
        let key: String
        let descending: Bool
    }

    struct Part: Equatable {
        var expr: Expr
        var sort: [SortKey] = []
        var limit: Int?
    }

    struct Query: Equatable {
        let text: String
        var parts: [Part]

        /// The lists it names with `@`, directly.
        var lists: [String] {
            var out: [String] = []
            func walk(_ e: Expr) {
                switch e {
                case .list(let name): out.append(name)
                case .not(let a): walk(a)
                case .and(let a, let b), .or(let a, let b): walk(a); walk(b)
                case .compare, .has: break
                }
            }
            for part in parts { walk(part.expr) }
            return out
        }
    }

    // MARK: Telling queries from other selectors

    /// A selector is a query when it contains `=`, `<`, `>`, `|`, `@`, ` and `, ` or ` or `not `
    /// (design/cli.md, "Selectors"); anything else is an id, a name, `.` or `#N`.
    static func looksLikeQuery(_ selector: String) -> Bool {
        if selector.contains(where: { "=<>|@".contains($0) }) { return true }
        let padded = " " + selector + " "
        return padded.contains(" and ") || padded.contains(" or ") || padded.contains(" not ")
            || padded.contains(" then ") || selector.hasPrefix("not ") || selector.hasPrefix("(not ")
    }

    // MARK: Parsing

    private enum Token: Equatable {
        case word(String)       // a key, a value, a keyword
        case quoted(String)     // "text"
        case op(Op)
        case at(String)         // @name
        case lparen, rparen, pipe, comma
    }

    private struct Lexed {
        let token: Token
        let position: Int
    }

    private static let keywords: Set<String> = ["and", "or", "not", "sort", "limit", "then"]

    private static func lex(_ text: String) throws -> [Lexed] {
        var out: [Lexed] = []
        let chars = Array(text)
        var i = 0
        func isWordChar(_ c: Character) -> Bool {
            !(c.isWhitespace || "()|,\"=!<>@".contains(c))
        }
        while i < chars.count {
            let c = chars[i]
            let position = i + 1
            if c.isWhitespace { i += 1; continue }
            switch c {
            case "(": out.append(Lexed(token: .lparen, position: position)); i += 1
            case ")": out.append(Lexed(token: .rparen, position: position)); i += 1
            case "|": out.append(Lexed(token: .pipe, position: position)); i += 1
            case ",": out.append(Lexed(token: .comma, position: position)); i += 1
            case "=": out.append(Lexed(token: .op(.eq), position: position)); i += 1
            case "!":
                guard i + 1 < chars.count, chars[i + 1] == "=" else {
                    throw ParseError(position: position, message: "\"!\" goes with \"=\" (!=); use `not` to negate")
                }
                out.append(Lexed(token: .op(.ne), position: position)); i += 2
            case "<", ">":
                let equal = i + 1 < chars.count && chars[i + 1] == "="
                let op: Op = c == "<" ? (equal ? .le : .lt) : (equal ? .ge : .gt)
                out.append(Lexed(token: .op(op), position: position)); i += equal ? 2 : 1
            case "\"":
                var value = ""
                var j = i + 1
                var closed = false
                while j < chars.count {
                    if chars[j] == "\\", j + 1 < chars.count { value.append(chars[j + 1]); j += 2; continue }
                    if chars[j] == "\"" { closed = true; break }
                    value.append(chars[j])
                    j += 1
                }
                guard closed else { throw ParseError(position: position, message: "the quoted text isn't closed") }
                out.append(Lexed(token: .quoted(value), position: position))
                i = j + 1
            case "@":
                var j = i + 1
                var name = ""
                while j < chars.count, isWordChar(chars[j]) { name.append(chars[j]); j += 1 }
                guard !name.isEmpty else { throw ParseError(position: position, message: "@ needs a list name") }
                out.append(Lexed(token: .at(name), position: position))
                i = j
            default:
                var j = i
                var word = ""
                while j < chars.count, isWordChar(chars[j]) { word.append(chars[j]); j += 1 }
                out.append(Lexed(token: .word(word), position: position))
                i = j
            }
        }
        return out
    }

    static func parse(_ text: String) throws -> Query {
        var parser = Parser(tokens: try lex(text), end: text.count + 1)
        let query = Query(text: text, parts: try parser.query())
        return query
    }

    private struct Parser {
        let tokens: [Lexed]
        let end: Int
        var index = 0

        var peek: Token? { index < tokens.count ? tokens[index].token : nil }
        var position: Int { index < tokens.count ? tokens[index].position : end }

        func fail(_ message: String) -> ParseError { ParseError(position: position, message: message) }

        mutating func next() -> Token? {
            defer { index += 1 }
            return peek
        }

        func isKeyword(_ word: String) -> Bool { peek == .word(word) }

        mutating func query() throws -> [Part] {
            guard peek != nil else { throw fail("the query is empty") }
            var parts = [try part()]
            while isKeyword("then") {
                index += 1
                parts.append(try part())
            }
            if peek != nil { throw fail("expected `and`, `or`, `then` or `|` here") }
            return parts
        }

        mutating func part() throws -> Part {
            var part = Part(expr: try orExpr())
            var sawLimit = false
            while peek == .pipe {
                index += 1
                guard case .word(let word)? = peek else { throw fail("expected `sort` or `limit` after |") }
                if word == "sort" {
                    guard !sawLimit, part.sort.isEmpty else { throw fail("`sort` comes once, before `limit`") }
                    index += 1
                    repeat {
                        if peek == .comma { index += 1 }
                        guard case .word(var key)? = peek, !UmiQuery.keywords.contains(key) else {
                            throw fail("expected a key to sort by")
                        }
                        var descending = false
                        if key.hasPrefix("-") { descending = true; key.removeFirst() }
                        guard UmiAttributes.isValidKey(key) else { throw fail("\"\(key)\" isn't an attribute name") }
                        index += 1
                        part.sort.append(SortKey(key: key, descending: descending))
                    } while peek == .comma
                } else if word == "limit" {
                    guard !sawLimit else { throw fail("`limit` comes once") }
                    index += 1
                    guard case .word(let n)? = peek, let count = Int(n), count >= 0 else {
                        throw fail("`limit` takes a number")
                    }
                    index += 1
                    part.limit = count
                    sawLimit = true
                } else {
                    throw fail("expected `sort` or `limit` after |")
                }
            }
            return part
        }

        mutating func orExpr() throws -> Expr {
            var left = try andExpr()
            while isKeyword("or") {
                index += 1
                left = .or(left, try andExpr())
            }
            return left
        }

        mutating func andExpr() throws -> Expr {
            var left = try notExpr()
            while isKeyword("and") {
                index += 1
                left = .and(left, try notExpr())
            }
            return left
        }

        mutating func notExpr() throws -> Expr {
            if isKeyword("not") {
                index += 1
                return .not(try notExpr())
            }
            return try term()
        }

        mutating func term() throws -> Expr {
            switch peek {
            case .lparen?:
                index += 1
                let inner = try orExpr()
                guard peek == .rparen else { throw fail("expected )") }
                index += 1
                return inner
            case .at(let name)?:
                index += 1
                return .list(name)
            case .word(let key)?:
                guard !UmiQuery.keywords.contains(key) else { throw fail("expected a key, `not`, `@LIST` or (") }
                guard UmiAttributes.isValidKey(key) else { throw fail("\"\(key)\" isn't an attribute name") }
                index += 1
                guard case .op(let op)? = peek else { return .has(key) }
                index += 1
                switch peek {
                case .word(let value)?:
                    index += 1
                    return .compare(key, op, value)
                case .quoted(let value)?:
                    index += 1
                    return .compare(key, op, value)
                default:
                    throw fail("expected a value after \(op.rawValue)")
                }
            case nil:
                throw fail("the query ends too early")
            default:
                throw fail("expected a key, `not`, `@LIST` or (")
            }
        }
    }

    // MARK: Values

    /// A duration in seconds: `90s`, `5m`, `2h`, `3d`, `1w`, or several (`1h30m`).
    static func duration(_ text: String) -> Double? {
        let units: [Character: Double] = ["s": 1, "m": 60, "h": 3600, "d": 86_400, "w": 604_800]
        var total = 0.0
        var number = ""
        var sawUnit = false
        for c in text {
            if c.isNumber || c == "." {
                number.append(c)
            } else if let scale = units[c], let amount = Double(number) {
                total += amount * scale
                number = ""
                sawUnit = true
            } else {
                return nil
            }
        }
        return sawUnit && number.isEmpty ? total : nil
    }

    private static let isoFormatters: [ISO8601DateFormatter] = {
        let all: [ISO8601DateFormatter.Options] = [[.withInternetDateTime, .withFractionalSeconds], [.withInternetDateTime]]
        return all.map { options in
            let f = ISO8601DateFormatter()
            f.formatOptions = options
            return f
        }
    }()

    /// An ISO 8601 time.
    static func isoTime(_ text: String) -> Date? {
        guard text.count >= 10, text.first?.isNumber == true, text.contains("-") else { return nil }
        for formatter in isoFormatters { if let date = formatter.date(from: text) { return date } }
        let local = DateFormatter()
        local.locale = Locale(identifier: "en_US_POSIX")
        local.timeZone = .current
        for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd"] {
            local.dateFormat = format
            if let date = local.date(from: text) { return date }
        }
        return nil
    }

    /// A time on the right of a comparison: ISO 8601, a clock time today (`9am`, `14:30`), or a
    /// duration back from now (`10m`).
    static func timeValue(_ text: String, now: Date) -> Date? {
        if let seconds = duration(text) { return now.addingTimeInterval(-seconds) }
        if let date = isoTime(text) { return date }
        let word = text.lowercased()
        guard let match = word.range(of: #"^(\d{1,2})(?::(\d{2}))?\s*(am|pm)?$"#, options: .regularExpression) else { return nil }
        _ = match
        let meridiem = word.hasSuffix("am") ? "am" : word.hasSuffix("pm") ? "pm" : nil
        let digits = meridiem != nil ? String(word.dropLast(2)) : word
        let pieces: [Int?] = digits.split(separator: ":").map { piece in Int(piece.trimmingCharacters(in: .whitespaces)) }
        guard var hour = pieces.first ?? nil else { return nil }
        let minute = pieces.count > 1 ? (pieces[1] ?? -1) : 0
        guard meridiem != nil || pieces.count > 1, (0..<60).contains(minute) else { return nil }
        if let meridiem {
            guard (1...12).contains(hour) else { return nil }
            if meridiem == "am" && hour == 12 { hour = 0 }
            if meridiem == "pm" && hour != 12 { hour += 12 }
        }
        guard hour < 24 else { return nil }
        return Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: now)
    }

    /// How two values order (design/cli.md choice 1): as numbers when both read as numbers, as
    /// durations when both read as durations (a bare number beside a duration is seconds), as times
    /// when the left one is a time and the right one a time or a duration back from now, otherwise
    /// as text.
    static func order(_ lhs: String, _ rhs: String, now: Date = Date()) -> ComparisonResult {
        func cmp<T: Comparable>(_ a: T, _ b: T) -> ComparisonResult { a < b ? .orderedAscending : (a > b ? .orderedDescending : .orderedSame) }
        let ln = Double(lhs), rn = Double(rhs)
        if let ln, let rn { return cmp(ln, rn) }
        let ld = duration(lhs), rd = duration(rhs)
        if let ld, let rd { return cmp(ld, rd) }
        if let ld, let rn { return cmp(ld, rn) }
        if let ln, let rd { return cmp(ln, rd) }
        if let lt = isoTime(lhs), let rt = timeValue(rhs, now: now) { return cmp(lt, rt) }
        return cmp(lhs, rhs)
    }

    static func holds(_ value: String?, _ op: Op, _ target: String, now: Date) -> Bool {
        guard let value else {
            // A pane without the key differs from every value.
            return op == .ne
        }
        switch op {
        case .eq: return value == target || (Double(value) != nil && order(value, target, now: now) == .orderedSame && Double(target) != nil)
        case .ne: return !(value == target || (Double(value) != nil && Double(target) != nil && order(value, target, now: now) == .orderedSame))
        case .lt: return order(value, target, now: now) == .orderedAscending
        case .le: return order(value, target, now: now) != .orderedDescending
        case .gt: return order(value, target, now: now) == .orderedDescending
        case .ge: return order(value, target, now: now) != .orderedAscending
        }
    }

    // MARK: Evaluating

    /// One pane as a query sees it: its attributes, read once each on demand.
    final class Item {
        let id: UUID
        /// Its place in `ls` order, for stable sorting.
        let order: Int
        private let read: (String) -> String?
        private var cache: [String: String?] = [:]
        /// What the caller attached (the pane view, its tab and window).
        let payload: Any?

        init(id: UUID, order: Int, payload: Any? = nil, read: @escaping (String) -> String?) {
            self.id = id
            self.order = order
            self.payload = payload
            self.read = read
        }

        convenience init(id: UUID = UUID(), order: Int, attributes: [String: String]) {
            self.init(id: id, order: order) { attributes[$0] }
        }

        func value(_ key: String) -> String? {
            if let cached = cache[key] { return cached }
            let value = read(key)
            cache[key] = value
            return value
        }
    }

    /// Runs queries over a set of panes; `@NAME` reads the lists `lists` gives.
    final class Evaluator {
        let items: [Item]
        let now: Date
        private let lists: (String) -> Query?
        /// Where `@NAME` was evaluated already (and being evaluated, against cycles).
        private var listMembers: [String: Set<UUID>] = [:]
        private var evaluating: Set<String> = []
        private(set) var unknownLists: Set<String> = []

        init(items: [Item], now: Date = Date(), lists: @escaping (String) -> Query?) {
            self.items = items
            self.now = now
            self.lists = lists
        }

        /// The matching panes, in the query's order.
        func run(_ query: Query) -> [Item] {
            var out: [Item] = []
            var listed = Set<UUID>()
            for part in query.parts {
                var matched = items.filter { matches(part.expr, $0) }
                if !part.sort.isEmpty {
                    matched = matched.enumerated().sorted { a, b in
                        for key in part.sort {
                            let va = a.element.value(key.key), vb = b.element.value(key.key)
                            switch (va, vb) {
                            case (nil, nil): continue
                            case (nil, _): return false     // missing sorts last
                            case (_, nil): return true
                            case let (x?, y?):
                                let result = UmiQuery.sortOrder(x, y)
                                if result == .orderedSame { continue }
                                return key.descending ? result == .orderedDescending : result == .orderedAscending
                            }
                        }
                        return a.offset < b.offset
                    }.map(\.element)
                }
                if let limit = part.limit { matched = Array(matched.prefix(limit)) }
                for item in matched where listed.insert(item.id).inserted { out.append(item) }
            }
            return out
        }

        func matches(_ expr: Expr, _ item: Item) -> Bool {
            switch expr {
            case .compare(let key, let op, let value): return UmiQuery.holds(item.value(key), op, value, now: now)
            case .has(let key):
                guard let value = item.value(key) else { return false }
                return value != "false"
            case .list(let name): return members(of: name).contains(item.id)
            case .not(let inner): return !matches(inner, item)
            case .and(let a, let b): return matches(a, item) && matches(b, item)
            case .or(let a, let b): return matches(a, item) || matches(b, item)
            }
        }

        private func members(of name: String) -> Set<UUID> {
            if let known = listMembers[name] { return known }
            guard !evaluating.contains(name), let query = lists(name) else {
                if lists(name) == nil { unknownLists.insert(name) }
                return []
            }
            evaluating.insert(name)
            let ids = Set(run(query).map(\.id))
            evaluating.remove(name)
            listMembers[name] = ids
            return ids
        }
    }

    /// How two values sort: the same rules as comparisons, with times compared as times.
    static func sortOrder(_ a: String, _ b: String) -> ComparisonResult {
        if let ta = isoTime(a), let tb = isoTime(b) {
            return ta < tb ? .orderedAscending : (ta > tb ? .orderedDescending : .orderedSame)
        }
        return order(a, b)
    }

    // MARK: Templates

    /// A template such as `{agent.title or command or cwd}`: each `{…}` is the first of its keys
    /// that is set and not empty (else nothing); text outside braces is kept.
    static func render(_ template: String, _ value: (String) -> String?) -> String {
        var out = ""
        var rest = Substring(template)
        while let open = rest.firstIndex(of: "{") {
            out += rest[..<open]
            guard let close = rest[open...].firstIndex(of: "}") else {
                out += rest[open...]
                return out
            }
            let keys = rest[rest.index(after: open)..<close]
                .components(separatedBy: " or ").map { $0.trimmingCharacters(in: .whitespaces) }
            for key in keys {
                if let v = value(key), !v.isEmpty { out += v; break }
            }
            rest = rest[rest.index(after: close)...]
        }
        return out + rest
    }
}
