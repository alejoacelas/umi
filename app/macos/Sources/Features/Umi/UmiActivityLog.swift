import AppKit

/// Day files of JSON lines in the state directory, kept 30 days (design/cli.md, choice 9): the
/// activity log's events and the focus log's stretches. Writing happens on a queue of its own, so
/// recording never holds up the app; reading waits for what was written before it.
final class UmiDayLog: @unchecked Sendable {
    static let keepDays = 30

    let folder: String
    private let queue: DispatchQueue
    private var handle: FileHandle?
    private var handleDay: String?
    private var pruned: String?

    init(folder name: String) {
        folder = UmiPaths.path("logs/\(name)")
        queue = DispatchQueue(label: "dev.umi.log.\(name)")
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = .current
        return f
    }()
    private static let formatterLock = NSLock()

    static func day(_ date: Date) -> String {
        formatterLock.lock()
        defer { formatterLock.unlock() }
        return dayFormatter.string(from: date)
    }

    static func date(ofDay day: String) -> Date? {
        formatterLock.lock()
        defer { formatterLock.unlock() }
        return dayFormatter.date(from: day)
    }

    /// Add one record to the file of the day `at` falls on.
    func append(_ record: [String: Any], at date: Date) {
        guard let data = try? JSONSerialization.data(withJSONObject: UmiJSON.sanitize(record),
                                                     options: [.withoutEscapingSlashes, .sortedKeys]) else { return }
        let day = Self.day(date)
        queue.async { [self] in
            write(data, day: day)
        }
    }

    /// The same, finished before returning (at quit).
    func appendNow(_ record: [String: Any], at date: Date) {
        append(record, at: date)
        queue.sync {}
    }

    private func write(_ data: Data, day: String) {
        if handleDay != day {
            try? handle?.close()
            handle = nil
            try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            let path = (folder as NSString).appendingPathComponent("\(day).jsonl")
            if !FileManager.default.fileExists(atPath: path) { FileManager.default.createFile(atPath: path, contents: nil) }
            handle = FileHandle(forWritingAtPath: path)
            _ = try? handle?.seekToEnd()
            handleDay = day
            if pruned != day { prune(today: day) }
        }
        var line = data
        line.append(0x0A)
        try? handle?.write(contentsOf: line)
    }

    /// Day files older than 30 days go (checked once a day, when the first record of the day is written).
    private func prune(today: String) {
        pruned = today
        guard let now = Self.date(ofDay: today),
              let files = try? FileManager.default.contentsOfDirectory(atPath: folder) else { return }
        let oldest = now.addingTimeInterval(-Double(Self.keepDays) * 86_400)
        for file in files where file.hasSuffix(".jsonl") {
            guard let date = Self.date(ofDay: String(file.dropLast(".jsonl".count))), date < oldest else { continue }
            try? FileManager.default.removeItem(atPath: (folder as NSString).appendingPathComponent(file))
        }
    }

    /// Every record in the day files from `since`'s day to `until`'s day, in the order written.
    func read(since: Date?, until: Date?) -> [[String: Any]] {
        queue.sync {
            try? handle?.synchronize()
            guard let files = try? FileManager.default.contentsOfDirectory(atPath: folder) else { return [] }
            let first = since.map(Self.day)
            let last = until.map(Self.day)
            var out: [[String: Any]] = []
            for file in files.sorted() where file.hasSuffix(".jsonl") {
                let day = String(file.dropLast(".jsonl".count))
                if let first, day < first { continue }
                if let last, day > last { continue }
                guard let data = FileManager.default.contents(atPath: (folder as NSString).appendingPathComponent(file)) else { continue }
                for line in data.split(separator: 0x0A) where !line.isEmpty {
                    if let record = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] { out.append(record) }
                }
            }
            return out
        }
    }
}

/// The activity log (design/primitives.md, "Logs"): every event, with its cause, as `umi events`
/// streams them. `umi log` reads it; `umi events --since` replays it first.
@MainActor
final class UmiActivityLog {
    static let shared = UmiActivityLog()

    private let log = UmiDayLog(folder: "activity")

    func append(_ event: [String: Any]) {
        let at = (event["ts"] as? Double).map { Date(timeIntervalSince1970: $0) } ?? Date()
        log.append(event, at: at)
    }

    /// Events from `since` to `until`, oldest first, whose name starts with one of `filters` (all
    /// without filters) and, with `pane`, about that pane.
    func events(since: Date?, until: Date?, filters: [String], pane: String?) -> [[String: Any]] {
        log.read(since: since, until: until).filter { event in
            let ts = event["ts"] as? Double ?? 0
            if let since, ts < since.timeIntervalSince1970 { return false }
            if let until, ts > until.timeIntervalSince1970 { return false }
            guard UmiEvents.matches(event["event"] as? String ?? "", filters: filters) else { return false }
            if let pane { return UmiEvents.isAbout(event["data"] as? [String: Any] ?? [:], pane: pane) }
            return true
        }
    }
}

/// The focus log (design/primitives.md, "Logs"): each stretch during which a pane had keyboard
/// focus in Umi's front window while Umi was the active app, the screen was unlocked and the user
/// had typed or clicked in Umi within the last 3 minutes (design/cli.md, choice 9), with what the
/// pane showed. It measures keyboard focus, not where the user looked.
@MainActor
final class UmiFocusLog {
    static let shared = UmiFocusLog()

    private let log = UmiDayLog(folder: "focus")

    /// How long without typing or clicking ends a stretch: 3 minutes (`debug.focus_log` shortens
    /// it in isolated instances).
    var idleAfter: TimeInterval = 180
    /// The screen is locked (or the session is in the background).
    private var screenLocked = false
    /// Scripted checks: the screen counts as locked whatever it is (`debug.focus_log`).
    var assumeLocked = false
    /// When the user last typed or clicked in Umi.
    private(set) var lastInput = Date()

    private struct Stretch {
        let pane: UUID
        let start: Date
        /// What the pane showed, refreshed while the stretch lasts (at most every few seconds).
        var shows: [String: Any]
        var shownAt = Date()
    }

    private var open: Stretch?
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []

    func start() {
        guard timer == nil else { return }
        lastInput = Date()
        if let session = CGSessionCopyCurrentDictionary() as? [String: Any] {
            screenLocked = session["CGSSessionScreenIsLocked"] as? Bool ?? false
        }
        let distributed = DistributedNotificationCenter.default()
        observers.append(distributed.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { UmiFocusLog.shared.setLocked(true) }
        })
        observers.append(distributed.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { UmiFocusLog.shared.setLocked(false) }
        })
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append(workspace.addObserver(forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { UmiFocusLog.shared.setLocked(true) }
        })
        observers.append(workspace.addObserver(forName: NSWorkspace.sessionDidBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { UmiFocusLog.shared.setLocked(false) }
        })
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { UmiFocusLog.shared.update() }
            })
        }
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { UmiFocusLog.shared.end(at: Date(), now: true) }
        })
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
            MainActor.assumeIsolated { UmiFocusLog.shared.update() }
        }
    }

    private func setLocked(_ locked: Bool) {
        screenLocked = locked
        update()
    }

    /// Someone typed or clicked in Umi.
    func userActed() {
        lastInput = Date()
        update()
    }

    /// The pane that counts now: the pane looked at (UmiLooking), with the screen unlocked and the
    /// user active within `idleAfter`. Scripted checks that count the app as active
    /// (`debug.ui.assume_active`) count the screen as unlocked too.
    private var counting: Ghostty.SurfaceView? {
        let locked = assumeLocked || (screenLocked && !UmiLooking.assumeActive)
        guard !locked, Date().timeIntervalSince(lastInput) <= idleAfter else { return nil }
        return UmiLooking.lookedAt
    }

    /// Start, end or carry on the open stretch after anything that may change it.
    func update() {
        let pane = counting
        if let open, open.pane == pane?.id {
            if let pane, Date().timeIntervalSince(open.shownAt) >= 4 {
                self.open?.shows = Self.shows(pane)
                self.open?.shownAt = Date()
            }
            return
        }
        if open != nil {
            // It ended when the user stopped (the idle limit passed), else now.
            let now = Date()
            let idleEnd = lastInput.addingTimeInterval(idleAfter)
            end(at: pane == nil && idleEnd < now ? max(idleEnd, open!.start) : now)
        }
        if let pane { open = Stretch(pane: pane.id, start: Date(), shows: Self.shows(pane)) }
    }

    private func end(at date: Date, now: Bool = false) {
        guard let stretch = open else { return }
        open = nil
        if let pane = UmiTopology.allSurfaces.first(where: { $0.id == stretch.pane }) {
            var refreshed = stretch
            refreshed.shows = Self.shows(pane)
            record(refreshed, end: date, write: now)
        } else {
            record(stretch, end: date, write: now)
        }
    }

    private func record(_ stretch: Stretch, end: Date, write now: Bool) {
        let json = Self.json(stretch, end: end)
        if now { log.appendNow(json, at: stretch.start) } else { log.append(json, at: stretch.start) }
    }

    private static func json(_ stretch: Stretch, end: Date) -> [String: Any] {
        var out = stretch.shows
        out["pane"] = stretch.pane.uuidString.lowercased()
        out["start"] = UmiTime.iso(stretch.start)
        out["end"] = UmiTime.iso(end)
        out["start_ts"] = stretch.start.timeIntervalSince1970
        out["end_ts"] = end.timeIntervalSince1970
        out["seconds"] = (end.timeIntervalSince(stretch.start) * 10).rounded() / 10
        return out
    }

    /// What a pane shows: its tab and window, title, kind, folder, file or page, agent, attributes.
    private static func shows(_ pane: Ghostty.SurfaceView) -> [String: Any] {
        let json = UmiTopology.paneJSON(pane, focused: true, zoomed: false)
        var out: [String: Any] = ["title": json["title"] ?? "", "kind": json["kind"] ?? "terminal",
                                  "cwd": json["cwd"] ?? "", "attributes": json["attributes"] ?? [:]]
        if let file = json["file"] { out["file"] = file }
        if let url = json["url"] { out["url"] = url }
        if let location = UmiTopology.locate(pane) {
            out["tab"] = location.tab.idString
            out["window"] = location.window.umiIDString
        }
        if let agent = UmiAttention.shared.agent(forPane: pane.id) {
            var info: [String: Any] = ["kind": agent.kind.rawValue, "title": agent.title]
            if let session = agent.session { info["session"] = session }
            out["agent"] = info
        }
        return out
    }

    /// Stretches overlapping `since`…`until`, oldest first, the open one last (ending now, `open`).
    func stretches(since: Date?, until: Date?, pane: String?) -> [[String: Any]] {
        update()
        var all = log.read(since: since.map { $0.addingTimeInterval(-86_400) }, until: until)
        if let open { all.append(Self.json(open, end: Date()).merging(["open": true]) { _, new in new }) }
        return all.filter { stretch in
            let start = stretch["start_ts"] as? Double ?? 0
            let end = stretch["end_ts"] as? Double ?? 0
            if let since, end < since.timeIntervalSince1970 { return false }
            if let until, start > until.timeIntervalSince1970 { return false }
            if let pane { return UmiEvents.isAbout(stretch, pane: pane) }
            return true
        }.sorted { ($0["start_ts"] as? Double ?? 0) < ($1["start_ts"] as? Double ?? 0) }
    }
}
