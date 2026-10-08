import Foundation

/// Sessions on disk, in the state directory:
///
///     sessions/<id>/session.json   settings, identity, report, startup (rewritten atomically)
///     sessions/<id>/log.jsonl      messages and transcript items, append-only
///
/// The log is replayed at launch. A crash can leave a partial last line, which is skipped.
/// Nothing is fsynced: what was written survives the app being killed (the kernel holds it),
/// which is the failure the product has to survive (R-2); a power cut can lose the tail.
/// Removing a session deletes its folder, so disk use follows what the user keeps (R-9).
enum TernAgentStore {
    static var root: String {
        let dir = TernPaths.directory("sessions")
        chmod(dir, 0o700)
        return dir
    }

    static func folder(_ id: String) -> String { (root as NSString).appendingPathComponent(id) }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }()

    struct Loaded {
        var record: TernSessionRecord
        var messages: [TernAgentMessage]
        var items: [TernTranscriptItem]
    }

    // MARK: Loading

    static func loadAll() -> [Loaded] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: root) else { return [] }
        var out: [Loaded] = []
        for name in names where !name.hasPrefix(".") {
            if let loaded = load(name) { out.append(loaded) }
        }
        return out.sorted { $0.record.createdAt < $1.record.createdAt }
    }

    static func load(_ id: String) -> Loaded? {
        let dir = folder(id)
        guard let data = FileManager.default.contents(atPath: (dir as NSString).appendingPathComponent("session.json")),
              let record = try? decoder.decode(TernSessionRecord.self, from: data) else { return nil }
        var messages: [TernAgentMessage] = []
        var messageIndex: [String: Int] = [:]
        var items: [TernTranscriptItem] = []
        var itemIndex: [String: Int] = [:]
        let logPath = (dir as NSString).appendingPathComponent("log.jsonl")
        if let log = FileManager.default.contents(atPath: logPath) {
            // A crash can leave a partial last line: cut it off, so the next entry starts on a
            // line of its own.
            if let last = log.last, last != 0x0A {
                let keep = (log.lastIndex(of: 0x0A).map { $0 + 1 }) ?? 0
                truncate(logPath, off_t(keep))
            }
            for line in log.split(separator: 0x0A) where !line.isEmpty {
                guard let entry = try? decoder.decode(LogEntry.self, from: Data(line)) else { continue }
                if let message = entry.m {
                    if let index = messageIndex[message.id] {
                        messages[index] = message
                    } else {
                        messageIndex[message.id] = messages.count
                        messages.append(message)
                    }
                }
                if let item = entry.i {
                    if let index = itemIndex[item.id] {
                        items[index] = item
                    } else {
                        itemIndex[item.id] = items.count
                        items.append(item)
                    }
                }
            }
        }
        var fixed = record
        // Counters never go backwards, even if session.json lagged the log.
        let maxItem = items.compactMap { Int($0.id.split(separator: "-").last ?? "") }.max() ?? 0
        fixed.nextItem = max(fixed.nextItem, maxItem + 1)
        let maxOrder = messages.map(\.order).max() ?? 0
        fixed.nextOrder = max(fixed.nextOrder, maxOrder + 1, (record.report?.order ?? 0) + 1)
        return Loaded(record: fixed, messages: messages, items: items)
    }

    // MARK: Writing

    struct LogEntry: Codable {
        var m: TernAgentMessage?
        var i: TernTranscriptItem?
    }

    static func saveRecord(_ record: TernSessionRecord) {
        let dir = folder(record.id)
        // Owner-only: `--env` values (tokens, say) are stored here.
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        guard let data = try? encoder.encode(record) else { return }
        let path = (dir as NSString).appendingPathComponent("session.json")
        let tmp = path + ".tmp"
        if FileManager.default.createFile(atPath: tmp, contents: data, attributes: [.posixPermissions: 0o600]) {
            _ = rename(tmp, path)
        }
    }

    static func append(_ id: String, message: TernAgentMessage? = nil, item: TernTranscriptItem? = nil) {
        guard var data = try? encoder.encode(LogEntry(m: message, i: item)) else { return }
        data.append(0x0A)
        let dir = folder(id)
        let path = (dir as NSString).appendingPathComponent("log.jsonl")
        let fd = open(path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o600)
        if fd < 0 {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            let retry = open(path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o600)
            guard retry >= 0 else { return }
            write(retry, data)
            close(retry)
            return
        }
        write(fd, data)
        close(fd)
    }

    private static func write(_ fd: Int32, _ data: Data) {
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = Darwin.write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if n < 0 {
                    if errno == EINTR { continue }
                    return
                }
                offset += n
            }
        }
    }

    static func remove(_ id: String) {
        try? FileManager.default.removeItem(atPath: folder(id))
    }

    /// Rewrite a log that has many superseded entries (compaction at load).
    static func compact(_ id: String, messages: [TernAgentMessage], items: [TernTranscriptItem]) {
        let dir = folder(id)
        let path = (dir as NSString).appendingPathComponent("log.jsonl")
        var data = Data()
        for message in messages {
            if let line = try? encoder.encode(LogEntry(m: message, i: nil)) { data.append(line); data.append(0x0A) }
        }
        for item in items {
            if let line = try? encoder.encode(LogEntry(m: nil, i: item)) { data.append(line); data.append(0x0A) }
        }
        let tmp = path + ".tmp"
        if FileManager.default.createFile(atPath: tmp, contents: data, attributes: [.posixPermissions: 0o600]) {
            _ = rename(tmp, path)
        }
    }

    static func logSize(_ id: String) -> Int {
        let path = (folder(id) as NSString).appendingPathComponent("log.jsonl")
        return (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
    }
}
