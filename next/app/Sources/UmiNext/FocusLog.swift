import AppKit

/// The focus log, in the format Umi writes (app/macos/Sources/Features/Umi/UmiActivityLog.swift),
/// so the `day` skill can read Umi next's as it reads Umi's: day files of JSON lines in
/// `<state>/logs/focus/YYYY-MM-DD.jsonl`, kept 30 days. Each line is one stretch during which a
/// pane had keyboard focus in the window while the app was active, the screen was unlocked and
/// the user had typed or clicked in the app within the last 3 minutes:
///   {pane, start, end, start_ts, end_ts, seconds, title, kind, cwd, attributes, tab, window,
///    file?, agent?: {kind, session?, title}, session?}
/// `umi-next focus-log` reads it (and asks for the open stretch, `native.focusOpen`).
///
/// Debug only (UMI_NEXT_DEBUG=1): UMI_NEXT_FOCUS_ASSUME_ACTIVE=1 counts the app as active and the
/// screen as unlocked (an offscreen test copy), UMI_NEXT_FOCUS_IDLE=SECS shortens the 3 minutes.
final class FocusLog {
    static let keepDays = 30
    private let folder = Paths.stateDir + "/logs/focus"
    private let queue = DispatchQueue(label: "umi-next.focuslog")
    private let idleAfter: TimeInterval
    private let assumeActive: Bool
    private var screenLocked = false
    private(set) var lastInput = Date()
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    /// What the focused pane shows now: set by the window controller.
    var current: () -> (pane: String, shows: [String: Any])? = { nil }
    var appCounts: () -> Bool = { NSApp.isActive }

    private struct Stretch {
        let pane: String
        let start: Date
        var shows: [String: Any]
        var shownAt = Date()
    }
    private var open: Stretch?

    init() {
        let debug = Paths.debugEnabled
        assumeActive = debug && Paths.env["UMI_NEXT_FOCUS_ASSUME_ACTIVE"] == "1"
        idleAfter = (debug ? Paths.env["UMI_NEXT_FOCUS_IDLE"].flatMap(Double.init) : nil) ?? 180
    }

    func start() {
        if let session = CGSessionCopyCurrentDictionary() as? [String: Any] {
            screenLocked = session["CGSSessionScreenIsLocked"] as? Bool ?? false
        }
        let dnc = DistributedNotificationCenter.default()
        observers.append(dnc.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in self?.setLocked(true) })
        observers.append(dnc.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in self?.setLocked(false) })
        let ws = NSWorkspace.shared.notificationCenter
        observers.append(ws.addObserver(forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: .main) { [weak self] _ in self?.setLocked(true) })
        observers.append(ws.addObserver(forName: NSWorkspace.sessionDidBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in self?.setLocked(false) })
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.update() })
        }
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            self?.end(at: Date())
            self?.queue.sync {}
        })
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.update() }
    }

    private func setLocked(_ locked: Bool) { screenLocked = locked; update() }

    /// The user typed or clicked in the window.
    func userActed() {
        lastInput = Date()
        update()
    }

    private func counting() -> (pane: String, shows: [String: Any])? {
        let active = assumeActive || (appCounts() && !screenLocked)
        guard active, Date().timeIntervalSince(lastInput) <= idleAfter else { return nil }
        return current()
    }

    /// Starts, ends or carries on the open stretch after anything that may change it.
    func update() {
        let now = counting()
        if let o = open, o.pane == now?.pane {
            if let now, Date().timeIntervalSince(o.shownAt) >= 4 { open?.shows = now.shows; open?.shownAt = Date() }
            return
        }
        if let o = open {
            let t = Date(), idleEnd = lastInput.addingTimeInterval(idleAfter)
            end(at: now == nil && idleEnd < t ? max(idleEnd, o.start) : t)
        }
        if let now { open = Stretch(pane: now.pane, start: Date(), shows: now.shows) }
    }

    private func end(at date: Date) {
        guard var s = open else { return }
        open = nil
        if let now = current(), now.pane == s.pane { s.shows = now.shows }
        let record = Self.json(s, end: date)
        let day = Self.day(s.start)
        queue.async { [folder] in Self.append(record, day: day, folder: folder) }
    }

    /// The stretch going on now (ending now, `open: true`), for `umi-next focus-log`.
    func openStretch() -> [String: Any]? {
        update()
        guard let o = open else { return nil }
        var j = Self.json(o, end: Date())
        j["open"] = true
        return j
    }

    private static func json(_ s: Stretch, end: Date) -> [String: Any] {
        var out = s.shows
        out["pane"] = s.pane
        out["start"] = iso(s.start)
        out["end"] = iso(end)
        out["start_ts"] = s.start.timeIntervalSince1970
        out["end_ts"] = end.timeIntervalSince1970
        out["seconds"] = (end.timeIntervalSince(s.start) * 10).rounded() / 10
        return out
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = .current
        return f
    }()
    static func iso(_ d: Date) -> String { isoFormatter.string(from: d) }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = .current
        return f
    }()
    static func day(_ d: Date) -> String { dayFormatter.string(from: d) }

    private static func append(_ record: [String: Any], day: String, folder: String) {
        guard let data = try? JSONSerialization.data(withJSONObject: record, options: [.withoutEscapingSlashes, .sortedKeys]) else { return }
        let fm = FileManager.default
        try? fm.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let path = folder + "/\(day).jsonl"
        let isNew = !fm.fileExists(atPath: path)
        if isNew { fm.createFile(atPath: path, contents: nil) }
        guard let h = FileHandle(forWritingAtPath: path) else { return }
        _ = try? h.seekToEnd()
        try? h.write(contentsOf: data + Data([0x0A]))
        try? h.close()
        if isNew { prune(folder: folder, today: day) }
    }

    /// Day files older than 30 days go (checked when a day's first stretch is written).
    private static func prune(folder: String, today: String) {
        guard let now = dayFormatter.date(from: today), let files = try? FileManager.default.contentsOfDirectory(atPath: folder) else { return }
        let oldest = now.addingTimeInterval(-Double(keepDays) * 86_400)
        for f in files where f.hasSuffix(".jsonl") {
            guard let d = dayFormatter.date(from: String(f.dropLast(6))), d < oldest else { continue }
            try? FileManager.default.removeItem(atPath: folder + "/" + f)
        }
    }
}
