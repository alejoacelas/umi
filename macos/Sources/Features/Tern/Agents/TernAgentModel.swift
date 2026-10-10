import Foundation

// The data a managed session keeps: its settings, its messages and their states, its
// transcript, pending requests, the worker's report and the harness's startup report.
// Everything here is a value type, touched only on `TernAgents.queue`.

enum TernAgentKind: String, Codable {
    case claude, codex
}

/// Where a message is in its life. A message is handed to the harness only when the
/// harness can take it (one at a time), so "sent" means written to the harness and not yet
/// confirmed; "delivered" means the harness reported that the model received it (Claude's
/// `command_lifecycle started` / replay, Codex's `userMessage` item with our client id).
enum TernMessageState: String, Codable {
    case queued, sent, delivered, done, interrupted, failed, error, exited, cancelled

    /// The state as `--json` shows it (`exited` is stored as such, shown as `stopped`).
    var shown: String { self == .exited ? "stopped" : rawValue }

    var isFinal: Bool {
        switch self {
        case .queued, .sent, .delivered: return false
        default: return true
        }
    }

    /// The status `agent wait` prints for a message in this state.
    var waitStatus: String {
        switch self {
        case .queued, .sent, .delivered: return "PENDING"
        case .done: return "DONE"
        case .interrupted: return "INTERRUPTED"
        case .failed: return "FAILED"
        case .error: return "ERROR"
        case .exited: return "STOPPED"
        case .cancelled: return "CANCELLED"
        }
    }
}

struct TernAgentMessage: Codable {
    let id: String
    let text: String
    let createdAt: Date
    /// Position among the session's messages and reports (a report counts for the messages
    /// before it).
    let order: Int
    var state: TernMessageState
    var reply: String?
    var error: String?
    /// The session that sent it (a parent, or a watched session's notification).
    var from: String?
    /// A note the product wrote itself (a cut-off turn's continuation). Never "the latest
    /// message" for wait or report purposes.
    var note: Bool?
    /// Messages a continuation note answers for: their turn was cut off, and the note's
    /// turn is their reply.
    var continues: [String]?
    /// Delivered, but its turn was cut off by a quit, crash or update. It continues by
    /// itself once the app runs again (R-10).
    var cutOff: Bool?
    var cutOffAt: Date?
    /// quit | crash | update
    var cutOffReason: String?
    var deliveredAt: Date?
    var finishedAt: Date?
}

struct TernTranscriptItem: Codable {
    let id: String
    var kind: String          // user | assistant | tool | request | notice | error
    var text: String
    var message: String?
    var tool: String?
    var detail: String?
    var output: String?
    var state: String?
    var at: Date
    /// Harness-side id (tool_use id, Codex item id) for updates; not shown.
    var ref: String?

    var json: [String: Any] {
        var out: [String: Any] = ["id": id, "kind": kind, "text": text, "at": TernAgentTime.iso(at)]
        if let message { out["message"] = message }
        if let tool { out["tool"] = tool }
        if let detail { out["detail"] = detail }
        if let output { out["output"] = output }
        if let state { out["state"] = state }
        return out
    }
}

struct TernAgentQuestion: Codable {
    let id: String
    let question: String
    let header: String?
    let options: [String]
    let multiSelect: Bool
}

/// Something the agent waits on: an approval or questions.
struct TernAgentRequest: Codable {
    let id: String                 // ours: r1, r2, … (stable for the session)
    let kind: String               // approval | question
    let title: String
    let detail: String
    let questions: [TernAgentQuestion]
    var url: String?
    var permissions: TernJSONValue?
    var schema: TernJSONValue?
    /// How to answer it.
    let harnessID: TernJSONValue   // Claude request_id (string), Codex JSON-RPC id
    let method: String             // can_use_tool:<tool> | Codex method
    let input: TernJSONValue?      // the tool input / request params
    /// What "allow always" remembers: tool and exact content.
    let ruleTool: String?
    let ruleContent: String?
    let createdAt: Date

    var json: [String: Any] {
        var details: [String: Any] = [:]
        if let url { details["url"] = url }
        if let permissions { details["permissions"] = permissions.any }
        if let schema { details["schema"] = schema.any }
        return [
            "id": id, "kind": kind, "title": title, "detail": detail,
            "questions": questions.map { q -> [String: Any] in
                var out: [String: Any] = ["id": q.id, "question": q.question, "options": q.options]
                if let header = q.header { out["header"] = header }
                if q.multiSelect { out["multi_select"] = true }
                return out
            },
            "details": details,
        ]
    }
}

struct TernAgentReport: Codable {
    let verdict: String            // done | blocked | failed
    let summary: String
    let at: Date
    let order: Int

    var json: [String: Any] { ["verdict": verdict, "summary": summary, "at": TernAgentTime.iso(at)] }
}

struct TernAgentStartup: Codable {
    var at: Date
    var model: String?
    var mcpServers: [[String: String]] = []
    var skills: [String]?
    var plugins: [String]?
    var agents: [String]?
    var flags: [String] = []

    var json: [String: Any] {
        var out: [String: Any] = ["at": TernAgentTime.iso(at), "flags": flags,
                                  "mcp_servers": mcpServers]
        if let model { out["model"] = model }
        if let skills { out["skills"] = skills }
        if let plugins { out["plugins"] = plugins }
        if let agents { out["agents"] = agents }
        return out
    }

    /// What failed or needs the user, in words.
    mutating func recomputeFlags(extra: [String] = []) {
        var out: [String] = []
        for server in mcpServers {
            let name = server["name"] ?? "?"
            switch server["status"] ?? "" {
            case "needs-auth", "needs_auth", "reauthenticationRequired":
                out.append("MCP server \(name) needs authentication")
            case "failed", "error", "cancelled":
                let reason = server["error"].map { ": \($0)" } ?? ""
                out.append("MCP server \(name) failed to start\(reason)")
            default:
                break
            }
        }
        flags = out + extra
    }
}

/// `agent watch SESSION --notify OTHER`: one notification when the watched turn ends, the
/// session needs input, or it exits.
struct TernAgentWatch: Codable {
    let id: String
    let notify: String
    /// The message whose turn is watched (nil: the next turn that ends).
    let message: String?
    let text: String?
    let createdAt: Date
}

/// "Allow always" for this session: an exact kind of action.
struct TernAlwaysRule: Codable, Equatable {
    let tool: String
    let content: String?
}

/// A session's settings and identity: `session.json`.
struct TernSessionRecord: Codable {
    var v: Int = 1
    let id: String
    var name: String
    let kind: TernAgentKind
    var cwd: String
    var model: String?
    var effort: String?
    var permissionMode: String?
    var fullAccess: Bool
    var profile: String?
    var env: [String: String]
    var harnessArgs: [String]
    var harnessID: String?
    var parent: String?
    var createdAt: Date
    var report: TernAgentReport?
    var startup: TernAgentStartup?
    /// Why the harness last ended unexpectedly (crash, failed resume, …).
    var lastError: String?
    /// How the harness last ended: stopped | exited | error (nil while it never ran).
    var ended: String?
    var alwaysRules: [TernAlwaysRule] = []
    var watches: [TernAgentWatch] = []
    /// A turn the harness started by itself was running (so a crash cut it off).
    var openSelfTurn: Bool = false
    var nextItem: Int = 1
    var nextOrder: Int = 1
    var nextRequest: Int = 1
    var nextWatch: Int = 1
    /// Message ids waiting for the harness, in delivery order.
    var queue: [String]?
    /// The harness's pid when it last ran (to find leftovers after a crash).
    var pid: Int32?
    /// The harness has a conversation to resume (it has taken a message).
    var conversation: Bool?
    /// When and why a self-started turn was cut off (no message records it).
    var cutOffAt: Date?
    var cutOffReason: String?

    // Headless and live (SPEC AG). The product controls a session headless; the agent's own
    // interface can run in a pane on the same conversation ("live").
    /// The agent's own interface runs (or was running when the app last stopped) in `livePane`.
    var live: Bool?
    /// The pane showing the session (read-only view or live interface), as a Tern pane id.
    var pane: String?
    /// The live interface's process (from its hooks), to end it when the session is taken back.
    var livePID: Int32?
    /// Go live in `pane` once the session settles (a launch with a placement, or after a
    /// message to a live Claude session ran headless).
    var goLiveWhenSettled: Bool?
    /// started: by `agent start`; typed: the user typed `claude`/`codex` in a pane.
    var origin: String?
    /// The session's title as its agent reports it (live Claude sets the terminal title).
    var title: String?
    /// The live interface is a client of the session's own Codex server (not its owner).
    var liveAttached: Bool?
}

/// A JSON value that survives Codable round trips (tool inputs, Codex request params).
enum TernJSONValue: Codable {
    case null, bool(Bool), number(Double), string(String), array([TernJSONValue]), object([String: TernJSONValue])

    init(_ any: Any?) {
        switch any {
        case nil, is NSNull: self = .null
        // NSNumber first: a JSON 0 or 1 also casts to Bool, and a request id of 0 must stay 0.
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() { self = .bool(n.boolValue) } else { self = .number(n.doubleValue) }
        case let b as Bool: self = .bool(b)
        case let s as String: self = .string(s)
        case let a as [Any]: self = .array(a.map { TernJSONValue($0) })
        case let d as [String: Any]: self = .object(d.mapValues { TernJSONValue($0) })
        default: self = .string("\(any!)")
        }
    }

    var any: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let b): return b
        case .number(let n): return n.rounded() == n && abs(n) < 1e15 ? Int(n) as Any : n
        case .string(let s): return s
        case .array(let a): return a.map(\.any)
        case .object(let d): return d.mapValues(\.any)
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([TernJSONValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: TernJSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n): try c.encode(n)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let d): try c.encode(d)
        }
    }
}

enum TernAgentTime {
    private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static func iso(_ date: Date) -> String { formatter.string(from: date) }

    /// "14:05 on Oct 8": what a cut-off note says (local time).
    static func clock(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm 'on' MMM d"
        return f.string(from: date)
    }
}

/// Text helpers for transcripts.
enum TernAgentText {
    /// Tool output kept in the transcript: the head and the tail of anything long (R-9:
    /// storage grows with what the user keeps, not with what tools print).
    static func clip(_ text: String, limit: Int = 16 * 1024) -> String {
        guard text.utf8.count > limit else { return text }
        let head = String(decoding: text.utf8.prefix(limit * 3 / 4), as: UTF8.self)
        let tail = String(decoding: text.utf8.suffix(limit / 4), as: UTF8.self)
        let dropped = text.utf8.count - limit
        return head + "\n… [\(dropped) bytes not kept] …\n" + tail
    }

    static func oneLine(_ text: String, max: Int = 160) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        return flat.count > max ? String(flat.prefix(max - 1)) + "…" : flat
    }
}
