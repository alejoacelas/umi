import AppKit
import CryptoKit
import Foundation
import UserNotifications

/// Umi's updater (I-4, P-2). It replaces the updater Ghostty ships with, which points at
/// Ghostty's own feed: Umi only ever looks at its own release feed and only installs builds
/// signed with its own key.
///
/// - The feed is a small JSON file (`appcast.json`) published with each release. It names
///   the version, the zip's URL, its SHA-256 and an Ed25519 signature of the zip.
/// - How an update arrives is the config's `auto-update` (DECISIONS.md §78):
///   - `install` (the default): a check that finds a newer version downloads and verifies it
///     without asking, then installs it at the first quiet moment (`UmiQuiet`): a notice in
///     the sidebar counts down 30 seconds (Not now, Install now), then Umi quits, installs and
///     relaunches, and everything comes back as after a quit. Anything the user does during
///     the countdown stops it until the next quiet moment.
///   - `check`: a check that finds a newer version asks first, with a notice in the sidebar
///     (Download, Later, Skip), never a dialog; nothing is downloaded until the answer is yes.
///     "Check for Updates…" and `umi update` are a yes. The answers are kept in the state
///     directory (`update.json`), so a restart neither asks again early nor forgets a yes
///     (§18). It installs when the app quits, or when the user asks.
///   - `download`: downloads without asking; installs when the app quits, or when asked.
///   - `off`: checks only when asked.
/// - A download is verified (signature, hash, bundle id, version, code signature) and
///   unpacked into the state directory. Its zip is kept after it installs, with the zip of the
///   version it replaced, so `umi update --rollback` can go back.
/// - Installing is done by a small helper that waits for the app to exit, swaps the bundle
///   (rolling back on failure) and clears the download quarantine, so no Gatekeeper prompt
///   appears. An isolated instance (its own state directory) never replaces the user's
///   installed app.
@MainActor
final class UmiUpdater: ObservableObject {
    static let shared = UmiUpdater()

    struct Release {
        let version: String
        let url: URL
        let sha256: String
        let signature: Data
        let size: Int?
        let notes: String?
    }

    enum Phase: Equatable {
        case idle
        case checking
        case downloading(String)
        case ready(String)
        case installing
        case failed(String)
    }

    /// How updates arrive (the config's `auto-update`).
    enum Mode: String {
        case install, download, check, off
    }

    /// The user's answers to the update question, kept across restarts.
    struct Answers: Codable, Equatable {
        /// "Skip This Version": never ask about this version again.
        var skipped: String?
        /// "Later": don't ask again before this time.
        var laterUntil: Date?
        /// A yes (Download, "Check for Updates…", `umi update`): this version may be
        /// downloaded and installed without asking again, even after a restart.
        var consent: String?
        /// The version a desktop notification was posted for (once per version).
        var notified: String?
        /// "Not now" on the notice before installing: not before this time.
        var notNowUntil: Date?
        /// `update --rollback` went back from this version: it (and anything older) never
        /// installs by itself again.
        var rolledBackFrom: String?
        /// Installing this version failed: it doesn't install by itself again.
        var failedInstall: String?
    }

    /// What the sidebar shows.
    enum Notice: Equatable {
        case asking(String)
        case downloading(String)
        case ready(String)
        case failed(String, String)
        /// Installing at this quiet moment in so many seconds (Not now, Install now).
        case updating(String, Int)
        /// Installing at the next quiet moment (a countdown was stopped).
        case waiting(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var latest: String?
    /// The newer version the app is asking about (nil: not asking).
    @Published private(set) var question: String?
    @Published private(set) var answers: Answers
    /// Seconds left before installing at this quiet moment (nil: no countdown).
    @Published private(set) var countdown: Int?
    /// A countdown was stopped by something the user did: the notice stays, saying the update
    /// waits for the next quiet moment.
    @Published private(set) var interrupted = false

    /// A staged, verified update waiting to install.
    private(set) var staged: (version: String, app: URL)?
    private var installOnQuit = true
    private var relaunchAfterInstall = false
    /// Relaunch without coming to the front (the app wasn't in front when it quit to install).
    private var relaunchInBackground = false
    private var downloadTask: Task<Release, Error>?
    /// The version the current or last download was for.
    private var downloadVersion: String?
    /// The current or last download was started by a check, not by the user.
    private var automaticDownload = false
    /// A release that downloaded but failed verification (its zip's SHA-256): checks don't fetch
    /// the same file again every 15 minutes (the user still can).
    private var rejected: String?
    private var timer: Timer?
    private var quietTimer: Timer?
    private var countdownDeadline: Date?
    /// Why the version running now can't be rolled back to later (nil: its zip is kept).
    private var rollbackProblem: String?
    /// The zip of the version running now is being fetched to keep (the install waits for it).
    private var keepingArchive: Task<Void, Never>?
    /// The last install of this copy, from the attempt the previous run left (`attempt.json`).
    private var lastAttempt: (version: String, from: String, ok: Bool)?

    private init() {
        answers = Self.loadAnswers()
        // A yes, a skip or a rollback mark for a version this build already is (or is newer
        // than) is spent.
        if let consent = answers.consent, Self.compare(consent, UmiVersion.current) != .orderedDescending { answers.consent = nil }
        if let skipped = answers.skipped, Self.compare(skipped, UmiVersion.current) != .orderedDescending { answers.skipped = nil }
        if let from = answers.rolledBackFrom, Self.compare(from, UmiVersion.current) != .orderedDescending { answers.rolledBackFrom = nil }
        if let failed = answers.failedInstall, Self.compare(failed, UmiVersion.current) != .orderedDescending { answers.failedInstall = nil }
        readLastAttempt()
    }

    /// How often to check in the background, how long "Later" and "Not now" last and how long
    /// the countdown is. Isolated instances (tests) may shorten them.
    static func seconds(_ variable: String, default value: TimeInterval) -> TimeInterval {
        guard UmiPaths.isIsolated, let raw = ProcessInfo.processInfo.environment[variable],
              let seconds = TimeInterval(raw), seconds > 0 else { return value }
        return seconds
    }
    private static var checkInterval: TimeInterval { seconds("UMI_UPDATE_CHECK_SECONDS", default: 15 * 60) }
    private static var laterInterval: TimeInterval { seconds("UMI_UPDATE_LATER_SECONDS", default: 24 * 3600) }
    private static var notNowInterval: TimeInterval { seconds("UMI_UPDATE_NOT_NOW_SECONDS", default: 3600) }
    private static var noticeInterval: TimeInterval { seconds("UMI_UPDATE_NOTICE_SECONDS", default: 30) }

    /// The config's `auto-update` (unset: install at a quiet moment).
    var mode: Mode {
        switch UmiLayout.ghostty?.config.autoUpdate {
        case .off: return .off
        case .check: return .check
        case .download: return .download
        case .install, nil: return .install
        }
    }

    var feedURL: URL? {
        if let override = ProcessInfo.processInfo.environment["UMI_FEED_URL"], !override.isEmpty {
            return URL(string: override)
        }
        // Stored without its scheme: Info.plist is run through the C preprocessor, which
        // would take "//" for a comment.
        guard var raw = Bundle.main.object(forInfoDictionaryKey: "UmiUpdateFeedURL") as? String else { return nil }
        if !raw.contains("://") { raw = "https://" + raw }
        return URL(string: raw)
    }

    /// The feed of the release this build is (stamped by release.sh): where its own zip is
    /// found again, to keep for a rollback.
    private var ownReleaseFeedURL: URL? {
        guard var raw = Bundle.main.object(forInfoDictionaryKey: "UmiReleaseFeedURL") as? String, !raw.isEmpty else { return nil }
        if !raw.contains("://") { raw = "https://" + raw }
        return URL(string: raw)
    }

    private var publicKey: Curve25519.Signing.PublicKey? {
        guard let base64 = Bundle.main.object(forInfoDictionaryKey: "UmiUpdatePublicKey") as? String,
              let raw = Data(base64Encoded: base64) else { return nil }
        return try? Curve25519.Signing.PublicKey(rawRepresentation: raw)
    }

    private var updatesDirectory: String { UmiPaths.directory("updates") }
    /// Verified zips of the installed version and the one before it (for `--rollback`).
    private var keptDirectory: String { (updatesDirectory as NSString).appendingPathComponent("kept") }

    /// What the sidebar shows: the question, a download the user asked for, the countdown
    /// before installing, or a staged update.
    var notice: Notice? {
        switch phase {
        case .ready(let version):
            guard mode == .install else { return .ready(version) }
            if let countdown { return .updating(version, countdown) }
            if interrupted, !notNow { return .waiting(version) }
            return nil
        case .downloading(let version):
            if automaticDownload { return nil }
            return .downloading(version)
        case .installing:
            guard let staged else { return nil }
            return mode == .install ? .updating(staged.version, 0) : .ready(staged.version)
        case .failed(let reason):
            if let version = downloadVersion, version == answers.consent, !automaticDownload { return .failed(version, reason) }
        default: break
        }
        return question.map { .asking($0) }
    }

    private var notNow: Bool { answers.notNowUntil.map { $0 > UmiQuiet.now } ?? false }

    // MARK: The question (I-4)

    enum Answer: String {
        case download, later, skip
        /// The notice before installing at a quiet moment.
        case notNow = "not_now", installNow = "install_now"
    }

    /// The user answered (the sidebar's buttons, or `umi update --later/--skip`).
    func answer(_ answer: Answer) async throws -> [String: Any] {
        switch answer {
        case .download:
            // Download (the question) or Try Again (a failed download): a yes to that version.
            var expected = question
            if expected == nil, case .failed = phase, let version = downloadVersion, version == answers.consent {
                expected = version
            }
            return try await download(expected: expected)
        case .later:
            if downloadTask != nil || staged != nil {
                throw UmiError.failed("the update is already downloading or downloaded; it installs \(installsWhen)")
            }
            let newer = latest.map { Self.compare($0, UmiVersion.current) == .orderedDescending } ?? false
            guard question != nil || newer else {
                throw UmiError.failed("there's nothing to answer: no newer version is known (`\(UmiPaths.cliName) update --check` looks)")
            }
            answers.laterUntil = Date().addingTimeInterval(Self.laterInterval)
            // The latest answer counts: "Later" replaces an earlier Skip, and withdraws a yes
            // whose download failed (it isn't retried until asked again).
            answers.skipped = nil
            answers.consent = nil
            if case .failed = phase { phase = .idle }
            question = nil
            saveAnswers()
            UmiEvents.shared.emit("update.answered", ["answer": "later", "version": latest ?? ""])
        case .skip:
            var version = question ?? latest.flatMap { Self.compare($0, UmiVersion.current) == .orderedDescending ? $0 : nil }
            if version == nil {
                let result = try await check(userInitiated: true)
                if result["update_available"] as? Bool == true { version = result["latest"] as? String }
            }
            guard let version else {
                throw UmiError.failed("\(UmiPaths.productName) \(UmiVersion.current) is up to date: there's no version to skip")
            }
            if downloadTask != nil || staged?.version == version {
                throw UmiError.failed("\(version) is already downloading or downloaded; it installs \(installsWhen)")
            }
            answers.skipped = version
            // The latest answer counts: a Skip replaces an earlier Later (a newer version is
            // asked about as soon as it's out).
            answers.laterUntil = nil
            if answers.consent == version { answers.consent = nil }
            if case .failed = phase { phase = .idle }
            question = nil
            saveAnswers()
            UmiEvents.shared.emit("update.answered", ["answer": "skip", "version": version])
        case .notNow:
            guard let staged else { throw UmiError.failed("no update is waiting to install") }
            answers.notNowUntil = UmiQuiet.now.addingTimeInterval(Self.notNowInterval)
            saveAnswers()
            stopCountdown()
            interrupted = false
            UmiEvents.shared.emit("update.answered", ["answer": "not_now", "version": staged.version])
        case .installNow:
            guard staged != nil else { throw UmiError.failed("no update is waiting to install") }
            // Only what the user does right now may stand in the way: Install Now never cuts off
            // anything running without saying so (the sidebar asks first, with a dialog).
            try refuseUnlessQuietExceptInput()
            return try await installNow(force: false, quietExceptInput: true)
        }
        return status()
    }

    /// When a staged update installs, in words.
    private var installsWhen: String {
        mode == .install ? "at the next quiet moment" : "when \(UmiPaths.productName) quits"
    }

    /// After a check found `release`: ask about it, unless the user already answered.
    private func considerAsking(_ release: Release) {
        let version = release.version
        guard Self.compare(version, UmiVersion.current) == .orderedDescending else {
            question = nil
            return
        }
        // A yes is under way or done: nothing to ask (a newer version is asked about after
        // the staged one installs).
        if downloadTask != nil || staged != nil { return }
        // A failed install or a rollback holds the version back even from a remembered yes: only a
        // new yes (`umi update`) installs it.
        if heldBack(version) != nil {
            question = nil
            return
        }
        if answers.consent == version {
            // The user already said yes to this version (before a restart, or a download
            // that failed): carry on without asking again.
            question = nil
            guard UmiVersion.isRelease else { return }
            // Exactly that release: a yes to it is no yes to whatever the feed says later. An
            // answer given before this runs (Later, Skip) wins over the remembered yes.
            Task { @MainActor in
                guard self.answers.consent == version, self.downloadTask == nil, self.staged == nil else { return }
                _ = try? await self.download(release: release)
            }
            return
        }
        if answers.skipped == version || (answers.laterUntil.map { $0 > Date() } ?? false) || heldBack(version) != nil {
            question = nil
            return
        }
        if question != version {
            question = version
            // A failed download of an older version gives way to the question about this one.
            if case .failed = phase { phase = .idle }
            UmiEvents.shared.emit("update.asked", ["installed": UmiVersion.current, "version": version])
        }
        notifyOnce(version)
    }

    /// After a check found `release` (modes install and download): download it without asking,
    /// unless the user held it back.
    private func considerDownloading(_ release: Release) {
        let version = release.version
        question = nil
        guard Self.compare(version, UmiVersion.current) == .orderedDescending, UmiVersion.isRelease,
              installTargetProblem == nil, downloadTask == nil else { return }
        if let staged, Self.compare(staged.version, version) != .orderedAscending { return }
        if answers.skipped == version || (answers.laterUntil.map { $0 > Date() } ?? false) || heldBack(version) != nil { return }
        if rejected == release.sha256 { return }
        Task { @MainActor in
            guard self.downloadTask == nil else { return }
            _ = try? await self.download(release: release, automatic: true)
        }
    }

    /// Why a version doesn't install by itself (nil: it does, the answers permitting).
    func heldBack(_ version: String) -> String? {
        if let from = answers.rolledBackFrom, Self.compare(version, from) != .orderedDescending {
            return "you rolled back from \(from)"
        }
        if answers.failedInstall == version {
            return "installing it failed (\(UmiPaths.directory("updates"))/install.log)"
        }
        return nil
    }

    /// One desktop notification per version, pointing at the question (never in test instances).
    private func notifyOnce(_ version: String) {
        guard answers.notified != version else { return }
        answers.notified = version
        saveAnswers()
        guard !UmiPaths.isIsolated || ProcessInfo.processInfo.environment["UMI_UPDATE_NOTIFICATIONS"] == "1" else { return }
        let content = UNMutableNotificationContent()
        content.title = "\(UmiPaths.productName) \(version) is available"
        content.body = "Nothing is downloaded until you say so: Download in the sidebar, or run `\(UmiPaths.cliName) update`."
        content.userInfo = ["umi_update": version]
        let request = UNNotificationRequest(identifier: "umi-update-\(version)", content: content, trigger: nil)
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert]) { granted, _ in
            guard granted else { return }
            center.add(request) { _ in }
        }
    }

    /// The update notification was clicked: show the question.
    static func handleNotification(userInfo: [AnyHashable: Any]) -> Bool {
        guard userInfo["umi_update"] != nil else { return false }
        // The question is in every window's sidebar: open a window if none is left.
        if TerminalController.all.isEmpty {
            _ = try? UmiLayout.newWindow(.init(), tabName: nil, focus: true)
        }
        UmiState.shared.sidebarVisible = true
        return true
    }

    /// What the app knows, without checking (`umi update --status`): also what a staged update
    /// waits for.
    func status() -> [String: Any] {
        var out: [String: Any] = ["installed": UmiVersion.current, "latest": latest ?? NSNull(),
                                  "update_available": latest.map { Self.compare($0, UmiVersion.current) == .orderedDescending } ?? false,
                                  "background_checks": backgroundChecks && mode != .off, "state": state, "mode": mode.rawValue]
        if let question { out["question"] = question }
        if let staged {
            out["ready"] = staged.version
            out["installs"] = mode == .install ? "quiet" : "quit"
        }
        if case .downloading(let version) = phase { out["downloading"] = version }
        if case .failed(let reason) = phase { out["error"] = reason }
        if let skipped = answers.skipped { out["skipped"] = skipped }
        if let until = answers.laterUntil, until > Date() { out["later_until"] = ISO8601DateFormatter().string(from: until) }
        if let until = answers.notNowUntil, until > UmiQuiet.now { out["not_now_until"] = ISO8601DateFormatter().string(from: until) }
        if let consent = answers.consent { out["consent"] = consent }
        if let from = answers.rolledBackFrom { out["rolled_back_from"] = from }
        if let failed = answers.failedInstall { out["failed_install"] = failed }
        if let latest, Self.compare(latest, UmiVersion.current) == .orderedDescending, let reason = heldBack(latest) {
            out["held_back"] = reason
        }
        if let countdown { out["countdown"] = countdown }
        if let previous = rollbackVersion { out["rollback"] = previous }
        if let rollbackProblem { out["rollback_problem"] = rollbackProblem }
        if let problem = installTargetProblem { out["install_problem"] = problem }
        if let attempt = lastAttempt {
            out["last_install"] = ["version": attempt.version, "from": attempt.from, "ok": attempt.ok]
        }
        if let feedURL { out["feed"] = feedURL.absoluteString }
        out["quiet"] = UmiQuiet.report()
        return out
    }

    /// One word for where the update stands.
    var state: String {
        switch phase {
        case .installing: return "installing"
        case .ready: return "ready"
        case .downloading: return "downloading"
        case .failed: if downloadVersion != nil && downloadVersion == answers.consent { return "failed" }
        default: break
        }
        guard let latest else { return "unknown" }
        guard Self.compare(latest, UmiVersion.current) == .orderedDescending else { return "up_to_date" }
        if question == latest { return "asking" }
        if answers.consent == latest { return "agreed" }
        if answers.skipped == latest { return "skipped" }
        if let until = answers.laterUntil, until > Date() { return "later" }
        if heldBack(latest) != nil { return "held_back" }
        return "available"
    }

    private static var answersPath: String { UmiPaths.path("update.json") }

    private static func loadAnswers() -> Answers {
        guard let data = FileManager.default.contents(atPath: answersPath) else { return Answers() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(Answers.self, from: data)) ?? Answers()
    }

    private func saveAnswers() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(answers) else { return }
        try? data.write(to: URL(fileURLWithPath: Self.answersPath), options: .atomic)
    }

    // MARK: Background checks

    /// Whether this copy checks in the background: only release builds update themselves, and
    /// an isolated instance only when pointed at a feed explicitly.
    var backgroundChecks: Bool {
        guard UmiVersion.isRelease else { return false }
        return !(UmiPaths.isIsolated && ProcessInfo.processInfo.environment["UMI_FEED_URL"] == nil)
    }

    /// Check in the background now and then (unless `auto-update = off`).
    func startBackgroundChecks() {
        recordInstalledApp()
        guard backgroundChecks else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            Task { @MainActor in await self?.backgroundCheck() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: Self.checkInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.backgroundCheck() }
        }
    }

    private func backgroundCheck() async {
        guard mode != .off, downloadTask == nil else { return }
        // In mode check, a yes waiting for the quit leaves nothing to ask meanwhile.
        if mode == .check && staged != nil { return }
        _ = try? await check(userInitiated: false)
    }

    // MARK: Checking

    func fetchFeed(_ url: URL? = nil) async throws -> Release {
        guard let feedURL = url ?? feedURL else { throw UmiError.failed("no update feed is configured") }
        var request = URLRequest(url: feedURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.setValue("Umi/\(UmiVersion.current)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw UmiError.failed("the update feed answered HTTP \(http.statusCode)")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = json["version"] as? String,
              let urlString = json["url"] as? String,
              let url = URL(string: urlString, relativeTo: feedURL)?.absoluteURL,
              let sha = json["sha256"] as? String,
              let signatureString = json["signature"] as? String,
              let signature = Data(base64Encoded: signatureString) else {
            throw UmiError.failed("the update feed isn't valid")
        }
        if let product = json["product"] as? String, product != UmiPaths.productName {
            throw UmiError.failed("the update feed is for another product (\(product))")
        }
        // The version isn't covered by the signature and names a folder on disk: only plain
        // dotted numbers are accepted.
        guard Self.isValidVersion(version) else { throw UmiError.failed("the update feed's version isn't valid") }
        return Release(version: version, url: url, sha256: sha.lowercased(), signature: signature,
                       size: json["size"] as? Int, notes: json["notes"] as? String)
    }

    func check(userInitiated: Bool) async throws -> [String: Any] {
        let previous = phase
        if case .idle = phase { phase = .checking }
        defer { if case .checking = phase { phase = previous == .checking ? .idle : previous } }
        let release: Release
        do {
            release = try await fetchFeed()
        } catch let error as UmiError {
            throw error
        } catch {
            throw UmiError.failed("couldn't check for updates: \(error.localizedDescription)")
        }
        latest = release.version
        let available = Self.compare(release.version, UmiVersion.current) == .orderedDescending
        UmiEvents.shared.emit("update.checked", ["installed": UmiVersion.current, "latest": release.version,
                                                  "update_available": available])
        // Any check that finds a newer version asks, or downloads it (the answers permitting).
        if backgroundChecks && !userInitiated {
            switch mode {
            case .check: considerAsking(release)
            case .install, .download: considerDownloading(release)
            case .off: break
            }
        }
        var out = status()
        out["latest"] = release.version
        out["update_available"] = available
        out["ready"] = staged?.version ?? ""
        return out
    }

    // MARK: Downloading

    /// The feed moved on to another version than the one the user said yes to.
    private struct FeedMoved: Error { let release: Release }

    /// Download and verify a version and stage it. `release` is a version already fetched (a
    /// check found it, or a yes remembered from before), `expected` the version the user said
    /// yes to (the sidebar's Download); with neither, the newest version (`umi update`,
    /// "Check for Updates…"). Every caller but a check (`automatic`) is a yes. A yes to one
    /// version never downloads another: if the feed moved on, the newer version is asked
    /// about instead.
    func download(release given: Release? = nil, expected: String? = nil, automatic: Bool = false) async throws -> [String: Any] {
        // A development build would replace itself (the build folder's app) with a release.
        guard UmiVersion.isRelease else {
            throw UmiError.failed("this is a development build of \(UmiPaths.productName); it doesn't update itself (install a release instead)")
        }
        if let problem = installTargetProblem { throw UmiError.failed(problem) }
        let release: Release
        do {
            if let downloadTask {
                release = try await downloadTask.value
            } else {
                let task = Task { @MainActor () throws -> Release in
                    // The yes is remembered before anything can fail, so a failure shows (and is
                    // retried) as that version's.
                    let target = given?.version ?? expected
                        ?? self.latest.flatMap { Self.compare($0, UmiVersion.current) == .orderedDescending ? $0 : nil }
                    if let target, !automatic { self.agree(to: target) }
                    let release: Release
                    if let given {
                        release = given
                    } else {
                        do {
                            release = try await self.fetchFeed()
                        } catch {
                            if let target {
                                self.downloadVersion = target
                                self.automaticDownload = automatic
                                if self.staged == nil { self.phase = .failed(Self.reason(error)) }
                            }
                            throw error
                        }
                    }
                    self.latest = release.version
                    guard Self.compare(release.version, UmiVersion.current) == .orderedDescending else {
                        self.question = nil
                        return release
                    }
                    if let expected, release.version != expected { throw FeedMoved(release: release) }
                    // `umi update` and the menu item are a yes to the newest version.
                    if release.version != target, !automatic { self.agree(to: release.version) }
                    if let staged = self.staged, staged.version == release.version { return release }
                    self.downloadVersion = release.version
                    self.automaticDownload = automatic
                    self.phase = .downloading(release.version)
                    do {
                        let app = try await self.fetchAndVerify(release)
                        self.staged = (release.version, app)
                        self.phase = .ready(release.version)
                        self.interrupted = false
                        UmiEvents.shared.emit("update.ready", ["version": release.version, "installs": self.mode == .install ? "quiet" : "quit"])
                        self.watchForQuiet()
                    } catch {
                        // A staged older update still installs.
                        self.phase = self.staged.map { .ready($0.version) } ?? .failed(Self.reason(error))
                        throw error
                    }
                    return release
                }
                downloadTask = task
                defer { downloadTask = nil }
                release = try await task.value
            }
        } catch let moved as FeedMoved {
            // Withdraw the yes to the old version and ask about the new one.
            if answers.consent == expected { answers.consent = nil }
            if case .failed = phase { phase = .idle }
            saveAnswers()
            considerAsking(moved.release)
            throw UmiError.failed("\(UmiPaths.productName) \(moved.release.version) is out now, not \(expected ?? "the version you said yes to"); "
                + "\(UmiPaths.productName) asks about it instead")
        }
        if Self.compare(release.version, UmiVersion.current) != .orderedDescending {
            return ["installed": UmiVersion.current, "latest": release.version, "update_available": false,
                    "message": "\(UmiPaths.productName) \(UmiVersion.current) is up to date."]
        }
        // A new yes (not one remembered from before) overrides what held this version back.
        if !automatic && given == nil { clearHolds(for: release.version) }
        if keepingArchive == nil {
            keepingArchive = Task { @MainActor in
                await self.keepRollbackArchive()
                self.keepingArchive = nil
            }
        }
        let when = mode == .install
            ? "It installs at the next quiet moment (`\(UmiPaths.cliName) update --status` says what it waits for; `\(UmiPaths.cliName) update --now` installs it now)."
            : "It installs when \(UmiPaths.productName) quits (or run `\(UmiPaths.cliName) update --now`)."
        return ["installed": UmiVersion.current, "latest": release.version, "ready": release.version,
                "message": "Downloaded \(UmiPaths.productName) \(release.version). \(when)"]
    }

    /// A yes to `version`: remember it, and stop asking.
    private func agree(to version: String) {
        answers.consent = version
        if answers.skipped == version { answers.skipped = nil }
        answers.laterUntil = nil
        question = nil
        saveAnswers()
    }

    /// The user asked for this version: a rollback or a failed install no longer hold it back.
    private func clearHolds(for version: String) {
        var changed = false
        if let from = answers.rolledBackFrom, Self.compare(version, from) != .orderedDescending { answers.rolledBackFrom = nil; changed = true }
        if answers.failedInstall == version { answers.failedInstall = nil; changed = true }
        if changed { saveAnswers() }
    }

    private static func reason(_ error: Error) -> String {
        (error as? UmiError)?.message ?? error.localizedDescription
    }

    /// Download a release and check it is what the feed says, signed with Umi's key. A file that
    /// fails the checks isn't fetched again by a check (a network failure is retried).
    private func fetchVerified(_ release: Release) async throws -> Data {
        guard let key = publicKey else { throw UmiError.failed("this build has no update-signing key") }
        // In memory (a few tens of MB): a download cut off by a quit leaves no temporary file.
        let (data, response) = try await URLSession.shared.data(from: release.url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw UmiError.failed("the update download answered HTTP \(http.statusCode)")
        }
        do {
            try Self.verify(data, sha256: release.sha256, signature: release.signature, key: key)
        } catch {
            rejected = release.sha256
            throw error
        }
        return data
    }

    private static func verify(_ data: Data, sha256: String, signature: Data, key: Curve25519.Signing.PublicKey) throws {
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard digest == sha256 else { throw UmiError.failed("the update's checksum doesn't match the feed") }
        guard key.isValidSignature(signature, for: data) else {
            throw UmiError.failed("the update isn't signed with \(UmiPaths.productName)'s key")
        }
    }

    private func fetchAndVerify(_ release: Release) async throws -> URL {
        let data = try await fetchVerified(release)
        do {
            return try stage(data, release: release)
        } catch {
            rejected = release.sha256
            throw error
        }
    }

    /// Unpack a verified zip into `staged-VERSION` and check the app in it: bundle id, version
    /// and code signature. The zip stays there with what it was verified against, so the
    /// installer keeps it (for a later rollback).
    private func stage(_ data: Data, release: Release) throws -> URL {
        guard Self.isValidVersion(release.version) else { throw UmiError.failed("the update feed's version isn't valid") }
        let base = URL(fileURLWithPath: updatesDirectory).standardizedFileURL.path
        let dir = (base as NSString).appendingPathComponent("staged-\(release.version)")
        guard URL(fileURLWithPath: dir).standardizedFileURL.path.hasPrefix(base + "/") else {
            throw UmiError.failed("the update feed's version isn't valid")
        }
        try? FileManager.default.removeItem(atPath: dir)
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let unpacked = (dir as NSString).appendingPathComponent("app")
        let zip = (dir as NSString).appendingPathComponent("update.zip")
        try data.write(to: URL(fileURLWithPath: zip))
        try Self.writeRecord(release, to: (dir as NSString).appendingPathComponent("release.json"))
        guard Self.run("/usr/bin/ditto", ["-x", "-k", zip, unpacked]) == 0 else {
            throw UmiError.failed("couldn't unpack the update")
        }
        guard let appName = try FileManager.default.contentsOfDirectory(atPath: unpacked).first(where: { $0.hasSuffix(".app") }) else {
            throw UmiError.failed("the update has no app in it")
        }
        let app = URL(fileURLWithPath: unpacked).appendingPathComponent(appName)
        guard let bundle = Bundle(url: app),
              bundle.bundleIdentifier == Bundle.main.bundleIdentifier else {
            throw UmiError.failed("the update is a different app")
        }
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        guard version == release.version else { throw UmiError.failed("the update's version doesn't match the feed") }
        _ = Self.run("/usr/bin/xattr", ["-cr", app.path])
        guard Self.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path]) == 0 else {
            throw UmiError.failed("the update's code signature doesn't verify")
        }
        // Earlier downloads, this build's or an older build's, are never installed now: only
        // the one just verified is. (No installer helper can still be using them: one runs
        // only after the app that staged it has quit, which was before this app started.)
        for name in (try? FileManager.default.contentsOfDirectory(atPath: base)) ?? []
        where name.hasPrefix("staged-") && name != "staged-\(release.version)" {
            try? FileManager.default.removeItem(atPath: (base as NSString).appendingPathComponent(name))
        }
        return app
    }

    private static func writeRecord(_ release: Release, to path: String) throws {
        let json: [String: Any] = ["version": release.version, "url": release.url.absoluteString, "sha256": release.sha256,
                                   "signature": release.signature.base64EncodedString()]
        let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    private static func readRecord(_ path: String) -> Release? {
        guard let data = FileManager.default.contents(atPath: path),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let version = json["version"] as? String, isValidVersion(version),
              let url = (json["url"] as? String).flatMap(URL.init(string:)),
              let sha = json["sha256"] as? String,
              let signature = (json["signature"] as? String).flatMap({ Data(base64Encoded: $0) }) else { return nil }
        return Release(version: version, url: url, sha256: sha, signature: signature, size: nil, notes: nil)
    }

    // MARK: Rollback (`update --rollback`)

    /// The version installed before this one, if its verified zip is kept.
    var rollbackVersion: String? {
        let marker = (keptDirectory as NSString).appendingPathComponent("previous")
        guard let raw = try? String(contentsOfFile: marker, encoding: .utf8) else { return nil }
        let version = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isValidVersion(version), version != UmiVersion.current,
              FileManager.default.fileExists(atPath: "\(keptDirectory)/\(version)/update.zip") else { return nil }
        return version
    }

    /// Keep the verified zip of the version running now, so a rollback can come back to it
    /// after the next update. The updater kept it when it installed this version; otherwise
    /// (installed by install.sh, or by an older updater) it's downloaded again from this
    /// version's own release and verified like an update.
    private func keepRollbackArchive() async {
        let version = UmiVersion.current
        let dir = (keptDirectory as NSString).appendingPathComponent(version)
        if FileManager.default.fileExists(atPath: dir + "/update.zip") { rollbackProblem = nil; return }
        guard let url = ownReleaseFeedURL else {
            rollbackProblem = "this build doesn't say where its release is, so \(version) can't be gone back to"
            return
        }
        do {
            let release = try await fetchFeed(url)
            guard release.version == version else { throw UmiError.failed("its release feed is for \(release.version)") }
            let data = try await fetchVerified(release)
            let temp = dir + ".partial"
            try? FileManager.default.removeItem(atPath: temp)
            try FileManager.default.createDirectory(atPath: temp, withIntermediateDirectories: true)
            try data.write(to: URL(fileURLWithPath: temp + "/update.zip"))
            try Self.writeRecord(release, to: temp + "/release.json")
            try? FileManager.default.removeItem(atPath: dir)
            try FileManager.default.moveItem(atPath: temp, toPath: dir)
            rollbackProblem = nil
        } catch {
            rollbackProblem = "couldn't keep \(version)'s release for a rollback: \(Self.reason(error))"
        }
    }

    /// Install the version installed before this one, from its kept zip (verified again like an
    /// update), and relaunch. The version gone back from never installs by itself again.
    func rollback(force: Bool) async throws -> [String: Any] {
        guard UmiVersion.isRelease else {
            throw UmiError.failed("this is a development build of \(UmiPaths.productName); it doesn't update itself")
        }
        if let problem = installTargetProblem { throw UmiError.failed(problem) }
        guard downloadTask == nil else { throw UmiError.failed("an update is downloading; try again once it's done") }
        guard let target = rollbackVersion else {
            throw UmiError.failed("there's no earlier version to go back to: \(UmiPaths.productName) keeps the version it replaced "
                + "when it installs an update (\(rollbackProblem ?? "none is kept yet"))")
        }
        try refuseWhileTurnsRun(force: force, doing: "Going back now")
        let dir = (keptDirectory as NSString).appendingPathComponent(target)
        guard let release = Self.readRecord(dir + "/release.json"), release.version == target,
              let data = FileManager.default.contents(atPath: dir + "/update.zip") else {
            throw UmiError.failed("the kept copy of \(target) is incomplete")
        }
        guard let key = publicKey else { throw UmiError.failed("this build has no update-signing key") }
        try Self.verify(data, sha256: release.sha256, signature: release.signature, key: key)
        let app = try stage(data, release: release)
        let from = UmiVersion.current
        staged = (target, app)
        answers.rolledBackFrom = from
        answers.notNowUntil = nil
        saveAnswers()
        UmiEvents.shared.emit("update.installing", ["version": target, "why": "rollback"])
        beginInstall(check: force ? .none : .noTurns)
        return ["installing": target, "rollback": true,
                "message": "Going back to \(UmiPaths.productName) \(target) and relaunching. \(from) won't install by itself again "
                    + "(`\(UmiPaths.cliName) update` installs it)."]
    }

    // MARK: Installing

    /// Why this copy may not replace its own app (nil: it may). An isolated instance (its own
    /// state directory: a test, a second copy) never replaces the user's installed app: the
    /// standard places, the copy the user's own instance last ran from (it records it at each
    /// launch, wherever it was installed) and the one it runs from now. Paths are compared after
    /// resolving links.
    var installTargetProblem: String? {
        // (A development build never updates itself at all.)
        guard UmiPaths.isIsolated, UmiVersion.isRelease else { return nil }
        let bundle = Self.canonical(Bundle.main.bundleURL.path)
        var installed = ["/Applications", NSHomeDirectory() + "/Applications"].map { "\($0)/\(UmiPaths.productName).app" }
        if let recorded = try? String(contentsOfFile: Self.userStatePath("installed-app"), encoding: .utf8) {
            installed.append(recorded.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if let main = Self.defaultInstanceBundle() { installed.append(main) }
        // Tests stand a copy of their own in for the user's (it only ever adds protection).
        if let protected = ProcessInfo.processInfo.environment["UMI_UPDATE_PROTECTED_APP"], !protected.isEmpty {
            installed.append(protected)
        }
        if installed.contains(where: { !$0.isEmpty && Self.canonical($0) == bundle }) {
            return "this is an isolated instance (UMI_STATE_DIR) running from the installed \(UmiPaths.productName) "
                + "(\(bundle)); it never updates that copy"
        }
        // Anywhere else, only a copy that is positively disposable: one in a temporary folder
        // (where the tests install theirs). The user's app may have been installed anywhere.
        let temporary = [NSTemporaryDirectory(), "/tmp", "/private/tmp", "/private/var/folders"].map { Self.canonical($0) + "/" }
        guard temporary.contains(where: { bundle.hasPrefix($0) }) else {
            return "this is an isolated instance (UMI_STATE_DIR); it only updates a copy in a temporary folder, "
                + "and this one runs from \(bundle), which may be the installed \(UmiPaths.productName)"
        }
        return nil
    }

    private static func canonical(_ path: String) -> String {
        URL(fileURLWithPath: UmiPaths.canonical(path)).standardizedFileURL.path
    }

    /// A file in the user's own state directory (not an isolated instance's).
    private static func userStatePath(_ name: String) -> String {
        NSHomeDirectory() + "/Library/Application Support/\(UmiPaths.productName)/\(name)"
    }

    /// The user's own instance records where it runs from, so an isolated instance can tell the
    /// user's app wherever it was installed.
    private func recordInstalledApp() {
        guard !UmiPaths.isIsolated, UmiVersion.isRelease else { return }
        try? (Self.canonical(Bundle.main.bundleURL.path) + "\n")
            .write(toFile: UmiPaths.path("installed-app"), atomically: true, encoding: .utf8)
    }

    /// The bundle the user's own instance (the default state directory) runs from, if it runs.
    private static func defaultInstanceBundle() -> String? {
        guard let data = FileManager.default.contents(atPath: userStatePath("instance.json")),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let pid = (json["pid"] as? NSNumber)?.int32Value, pid > 0, kill(pid, 0) == 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        let executable = String(cString: buffer)
        guard let range = executable.range(of: ".app/Contents/MacOS/") else { return nil }
        return String(executable[..<range.lowerBound]) + ".app"
    }

    private func refuseWhileTurnsRun(force: Bool, doing: String = "Installing now") throws {
        // An update cuts running agent turns off only if the user agrees (AG-22).
        let turns = UmiAgents.shared.runningTurns()
        guard turns > 0 && !force else { return }
        throw UmiError.failed("\(turns) managed-agent turn\(turns == 1 ? " is" : "s are") running. \(doing) interrupts "
            + "\(turns == 1 ? "it" : "them") (\(turns == 1 ? "it continues" : "they continue") after the relaunch): pass --force to do that, "
            + "or let the update install \(installsWhen).")
    }

    /// Install the staged update and relaunch now (the user asked). `quietExceptInput`: the
    /// sidebar's Install now, which never interrupts anything without asking.
    func installNow(force: Bool = true, quietExceptInput: Bool = false) async throws -> [String: Any] {
        try refuseWhileTurnsRun(force: force)
        if let problem = installTargetProblem { throw UmiError.failed(problem) }
        if staged == nil { _ = try await download() }
        // A turn may have started during the download.
        let turnsNow = UmiAgents.shared.runningTurns()
        if turnsNow > 0 && !force {
            throw UmiError.failed("\(turnsNow) managed-agent turn\(turnsNow == 1 ? " is" : "s are") running; the update is downloaded "
                + "and installs \(installsWhen) (or pass --force to install now and interrupt them).")
        }
        guard let staged else {
            return ["installed": UmiVersion.current, "message": "\(UmiPaths.productName) \(UmiVersion.current) is up to date."]
        }
        // The running version's own zip, kept for a rollback, first (at most a minute and a half).
        let deadline = Date().addingTimeInterval(90)
        while keepingArchive != nil, Date() < deadline { try? await Task.sleep(nanoseconds: 200_000_000) }
        guard self.staged?.version == staged.version, phase != .installing else {
            throw UmiError.failed("the update changed meanwhile; run `\(UmiPaths.cliName) update --now` again")
        }
        // Things may have started during the waits: ask again.
        try refuseWhileTurnsRun(force: force)
        if quietExceptInput { try refuseUnlessQuietExceptInput() }
        clearHolds(for: staged.version)
        UmiEvents.shared.emit("update.installing", ["version": staged.version, "why": "now"])
        beginInstall(check: quietExceptInput ? .quietExceptInput : (force ? .none : .noTurns))
        return ["installing": staged.version, "message": "Installing \(UmiPaths.productName) \(staged.version) and relaunching."]
    }

    private func refuseUnlessQuietExceptInput() throws {
        let blockers = UmiQuiet.reasons().filter { $0.kind != .input }
        guard blockers.isEmpty else {
            throw UmiError.failed("installing now would interrupt: " + blockers.map(\.line).joined(separator: "; ")
                + " (`\(UmiPaths.cliName) update --now` installs anyway)")
        }
    }

    /// What a last look just before quitting requires (things may have started since).
    enum LastCheck { case none, noTurns, quietExceptInput, quiet }

    /// Quit to install the staged update, then relaunch: in front if the app was in front. A
    /// last look just before quitting stands the install down if something started meanwhile
    /// that it may not interrupt.
    private func beginInstall(check: LastCheck = .none) {
        stopCountdown()
        relaunchAfterInstall = true
        relaunchInBackground = !NSApp.isActive
        phase = .installing
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self else { return }
            let blocked: Bool
            switch check {
            case .none: blocked = false
            case .noTurns: blocked = UmiAgents.shared.runningTurns() > 0
            case .quietExceptInput: blocked = UmiQuiet.reasons().contains { $0.kind != .input }
            case .quiet: blocked = !UmiQuiet.reasons().isEmpty
            }
            if blocked, let staged = self.staged {
                self.relaunchAfterInstall = false
                UmiEvents.shared.emit("update.countdown", ["version": staged.version, "stopped": "something started"])
                if Self.compare(staged.version, UmiVersion.current) != .orderedDescending {
                    // A rollback stood down: it never goes ahead later by itself.
                    self.staged = nil
                    self.answers.rolledBackFrom = nil
                    self.saveAnswers()
                    self.phase = .idle
                    return
                }
                self.phase = .ready(staged.version)
                self.interrupted = true
                return
            }
            (NSApp.delegate as? AppDelegate)?.terminateForUpdate()
        }
    }

    /// True while quitting to install an update (no confirmations).
    var isQuittingForUpdate: Bool { relaunchAfterInstall }

    /// This launch is the relaunch after an update installed while another app was in front:
    /// windows come back behind it, and the app doesn't come to the front (read once; the
    /// installer leaves `updates/relaunch-background` just before it relaunches).
    nonisolated static let launchedInBackground: Bool = {
        let marker = (UmiPaths.directory("updates") as NSString).appendingPathComponent("relaunch-background")
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: marker) else { return false }
        try? FileManager.default.removeItem(atPath: marker)
        let made = attributes[.modificationDate] as? Date ?? .distantPast
        return Date().timeIntervalSince(made) < 300
    }()

    // MARK: Installing at a quiet moment

    /// Something the user did (typing, clicking): a countdown stops until the next quiet moment.
    func userActed() {
        guard countdownDeadline != nil else { return }
        stopCountdown()
        interrupted = true
        UmiEvents.shared.emit("update.countdown", ["version": staged?.version ?? "", "stopped": "activity"])
    }

    /// Look for a quiet moment every second while an update waits to install.
    private func watchForQuiet() {
        guard quietTimer == nil else { return }
        quietTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.quietTick() }
        }
    }

    private func stopCountdown() {
        countdownDeadline = nil
        countdown = nil
    }

    private func quietTick() {
        guard let staged, case .ready = phase, downloadTask == nil, keepingArchive == nil else {
            // (While installing it keeps going: a last look may still stand the install down.)
            if staged == nil { quietTimer?.invalidate(); quietTimer = nil }
            if phase != .installing { stopCountdown() }
            return
        }
        guard mode == .install, Self.compare(staged.version, UmiVersion.current) == .orderedDescending,
              installTargetProblem == nil, heldBack(staged.version) == nil, !notNow else {
            stopCountdown()
            return
        }
        if answers.notNowUntil != nil {
            // Not now is over: the next quiet moment shows the countdown again.
            answers.notNowUntil = nil
            saveAnswers()
        }
        let reasons = UmiQuiet.reasons()
        guard reasons.isEmpty else {
            if countdownDeadline != nil {
                stopCountdown()
                interrupted = true
                UmiEvents.shared.emit("update.countdown", ["version": staged.version, "stopped": reasons.first?.line ?? ""])
            }
            return
        }
        let now = UmiQuiet.now
        if countdownDeadline == nil {
            countdownDeadline = now.addingTimeInterval(Self.noticeInterval)
            UmiEvents.shared.emit("update.countdown", ["version": staged.version, "seconds": Int(Self.noticeInterval)])
        }
        guard let deadline = countdownDeadline else { return }
        let left = deadline.timeIntervalSince(now)
        if left > 0 {
            countdown = Int(left.rounded(.up))
            return
        }
        UmiEvents.shared.emit("update.installing", ["version": staged.version, "why": "quiet"])
        beginInstall(check: .quiet)
    }

    // MARK: The installer

    private var attemptPath: String { (updatesDirectory as NSString).appendingPathComponent("attempt.json") }

    /// What the previous run tried to install: if this build isn't that version, the install
    /// failed, and that version doesn't install by itself again (no update loop).
    private func readLastAttempt() {
        guard let data = FileManager.default.contents(atPath: attemptPath),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let version = json["version"] as? String else { return }
        try? FileManager.default.removeItem(atPath: attemptPath)
        let from = json["from"] as? String ?? "?"
        let ok = version == UmiVersion.current
        lastAttempt = (version, from, ok)
        if ok {
            if answers.failedInstall == version { answers.failedInstall = nil; saveAnswers() }
        } else if from == UmiVersion.current {
            answers.failedInstall = version
            saveAnswers()
        }
    }

    /// Called as the app quits: hand a staged update to the installer helper.
    func installOnQuitIfStaged() {
        guard installOnQuit, let staged else { return }
        // An isolated instance never replaces the user's installed app.
        guard installTargetProblem == nil else { return }
        // A quit while this version's own zip is still being fetched (for a rollback) leaves the
        // update for the next run, which fetches both again: going back stays possible. (Installs
        // Umi starts itself wait for it.)
        guard keepingArchive == nil || relaunchAfterInstall else { return }
        let destination = Bundle.main.bundleURL
        let script = (updatesDirectory as NSString).appendingPathComponent("install.sh")
        let log = (updatesDirectory as NSString).appendingPathComponent("install.log")
        let again = (updatesDirectory as NSString).appendingPathComponent("relaunch.sh")
        do {
            try Self.installerScript.write(toFile: script, atomically: true, encoding: .utf8)
            if UmiPaths.isIsolated { try relaunchScript().write(toFile: again, atomically: true, encoding: .utf8) }
            let attempt = try JSONSerialization.data(withJSONObject: ["version": staged.version, "from": UmiVersion.current,
                                                                      "at": ISO8601DateFormatter().string(from: Date())])
            try attempt.write(to: URL(fileURLWithPath: attemptPath), options: .atomic)
        } catch {
            return
        }
        let relaunch = !relaunchAfterInstall ? "0" : (relaunchInBackground ? "bg" : "1")
        let stagedDir = staged.app.deletingLastPathComponent().deletingLastPathComponent().path
        let args = [script, String(getpid()), staged.app.path, destination.path, relaunch, log,
                    UmiPaths.isIsolated ? again : "", stagedDir, keptDirectory, UmiVersion.current, staged.version]
        Self.spawnDetached("/bin/sh", args)
    }

    /// How an isolated instance comes back as itself: its environment (state directory, feed,
    /// the agents it runs) and its arguments. `$1` is the installed app.
    private func relaunchScript() -> String {
        func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let env = ProcessInfo.processInfo.environment
            .filter { !$0.key.hasPrefix("__") && !$0.key.contains("=") }
            .sorted { $0.key < $1.key }
            .map { quote("\($0.key)=\($0.value)") }
            .joined(separator: " \\\n    ")
        let executable = Bundle.main.executableURL?.lastPathComponent ?? "umi-app"
        let args = CommandLine.arguments.dropFirst().map(quote).joined(separator: " ")
        return """
        #!/bin/sh
        # Relaunch this isolated instance as itself after an update (written by the app).
        exec /usr/bin/env -i \\
            \(env) \\
            "$1/Contents/MacOS/\(executable)" \(args)
        """
    }

    /// Waits for the app to exit, swaps the bundle (rolling back on failure), clears
    /// quarantine, keeps the installed zip and the previous version's for a rollback, and
    /// optionally relaunches.
    static let installerScript = """
    #!/bin/sh
    # Umi update installer:
    #   install.sh PID STAGED_APP DEST_APP RELAUNCH LOG [RELAUNCH_SCRIPT [STAGED_DIR KEPT_DIR FROM TO]]
    # RELAUNCH: 0 (don't), 1 (open it in front), bg (open it behind the app in front).
    pid="$1"; staged="$2"; dest="$3"; relaunch="$4"; log="$5"; again="${6:-}"
    stageddir="${7:-}"; kept="${8:-}"; from="${9:-}"; to="${10:-}"
    exec >>"$log" 2>&1
    echo "$(date): installing $staged over $dest (waiting for pid $pid)"
    i=0
    while kill -0 "$pid" 2>/dev/null; do
        # An exited app its parent hasn't reaped yet is done too.
        case "$(/bin/ps -o stat= -p "$pid" 2>/dev/null)" in Z*) break ;; esac
        i=$((i+1)); [ "$i" -gt 600 ] && { echo "app didn't exit; giving up"; exit 1; }
        sleep 0.2
    done
    [ -d "$staged" ] || { echo "staged app missing"; exit 1; }
    old="$(dirname "$dest")/.$(basename "$dest").old-$$"
    if mv "$dest" "$old" && mv "$staged" "$dest"; then
        rm -rf "$old"
        /usr/bin/xattr -cr "$dest" 2>/dev/null
        echo "$(date): installed $to"
        # Keep the verified zip of what was installed and remember what it replaced, for
        # `update --rollback`; zips of other versions go.
        if [ -n "$kept" ] && [ -n "$to" ]; then
            mkdir -p "$kept"
            if [ -f "$stageddir/update.zip" ] && [ -f "$stageddir/release.json" ]; then
                rm -rf "$kept/$to.new" && mkdir -p "$kept/$to.new" \\
                    && mv "$stageddir/update.zip" "$stageddir/release.json" "$kept/$to.new/" \\
                    && rm -rf "$kept/$to" && mv "$kept/$to.new" "$kept/$to"
            fi
            [ -n "$from" ] && printf '%s\\n' "$from" > "$kept/previous"
            for d in "$kept"/*; do
                [ -d "$d" ] || continue
                v="$(basename "$d")"
                [ "$v" = "$to" ] || [ "$v" = "$from" ] || rm -rf "$d"
            done
        fi
    else
        echo "$(date): install failed; restoring"
        [ -d "$dest" ] || mv "$old" "$dest"
        exit 1
    fi
    [ -n "$stageddir" ] && rm -rf "$stageddir"
    case "$relaunch" in
        0) ;;
        *)
            # Behind the app in front: the relaunched app reads this and stays in the back.
            [ "$relaunch" = "bg" ] && : > "$(dirname "$log")/relaunch-background"
            if [ -n "$again" ]; then
                # An isolated instance comes back as itself (its environment and arguments).
                /bin/sh "$again" "$dest" >/dev/null 2>&1 &
            elif [ "$relaunch" = "bg" ]; then
                /usr/bin/open -g "$dest"
            else
                /usr/bin/open "$dest"
            fi
            ;;
    esac
    """

    // MARK: Prompts (Check for Updates…)

    /// "Check for Updates…": the user asked, so a newer version is a yes (I-4). It downloads
    /// in the background; the sidebar shows when it's ready.
    func checkFromMenu() {
        Task { @MainActor in
            do {
                let result = try await check(userInitiated: true)
                let latest = result["latest"] as? String ?? "?"
                guard result["update_available"] as? Bool == true else {
                    let alert = NSAlert()
                    alert.messageText = "\(UmiPaths.productName) is up to date"
                    alert.informativeText = "Version \(UmiVersion.current) is the newest version."
                    alert.runModal()
                    return
                }
                if case .ready(let ready) = phase, ready == latest {
                    presentReadyPrompt()
                    return
                }
                let alert = NSAlert()
                guard UmiVersion.isRelease else {
                    alert.messageText = "\(UmiPaths.productName) \(latest) is available"
                    alert.informativeText = "This is a development build of \(UmiPaths.productName), which doesn't update itself. Install a release instead."
                    alert.runModal()
                    return
                }
                Task { @MainActor in
                    do {
                        _ = try await self.download()
                    } catch {
                        // The user just asked: say so (the sidebar also shows it, with Try Again).
                        let failed = NSAlert()
                        failed.messageText = "Couldn't download \(UmiPaths.productName) \(latest)"
                        failed.informativeText = Self.reason(error)
                        failed.runModal()
                    }
                }
                alert.messageText = "Downloading \(UmiPaths.productName) \(latest)"
                alert.informativeText = mode == .install
                    ? "You have \(UmiVersion.current). It installs by itself at the next quiet moment (nothing running, nothing unsaved, "
                        + "nobody typing), after a notice in the sidebar, and \(UmiPaths.productName) comes back as it was."
                    : "You have \(UmiVersion.current). It installs when you quit \(UmiPaths.productName); "
                        + "the sidebar shows when it's ready, and lets you install it at once."
                alert.runModal()
            } catch {
                let alert = NSAlert()
                alert.messageText = "Couldn't check for updates"
                alert.informativeText = (error as? UmiError)?.message ?? error.localizedDescription
                alert.runModal()
            }
        }
    }

    func presentReadyPrompt() {
        guard case .ready(let version) = phase else { return }
        let alert = NSAlert()
        alert.messageText = "\(UmiPaths.productName) \(version) is ready to install"
        var text = mode == .install
            ? "It installs by itself at the next quiet moment. Installing now quits and relaunches \(UmiPaths.productName), which ends the programs running in its terminals."
            : "It installs when you quit \(UmiPaths.productName). Installing now quits and relaunches \(UmiPaths.productName), which ends the programs running in its terminals."
        let blockers = UmiQuiet.reasons().filter { $0.kind != .input }
        if !blockers.isEmpty {
            text += "\n\nRight now: " + blockers.prefix(5).map(\.line).joined(separator: "; ") + "."
        }
        let turns = UmiAgents.shared.runningTurns()
        if turns > 0 {
            text += " \(turns) managed-agent turn\(turns == 1 ? " is" : "s are") running: installing now interrupts \(turns == 1 ? "it" : "them"), and \(turns == 1 ? "it continues" : "they continue") after the relaunch."
        }
        alert.informativeText = text
        alert.addButton(withTitle: "Install and Relaunch")
        alert.addButton(withTitle: mode == .install ? "Wait for a Quiet Moment" : "Install on Quit")
        if alert.runModal() == .alertFirstButtonReturn {
            Task { @MainActor in _ = try? await installNow() }
        }
    }

    // MARK: Helpers

    /// Compare dotted versions numerically ("10.0" > "9.1").
    /// "1", "1.2", "1.2.3" or "1.2.3.4": what release.sh publishes.
    nonisolated static func isValidVersion(_ version: String) -> Bool {
        version.range(of: #"^[0-9]{1,6}(\.[0-9]{1,6}){0,3}$"#, options: .regularExpression) != nil
    }

    nonisolated static func compare(_ a: String, _ b: String) -> ComparisonResult {
        func parts(_ v: String) -> [Int] {
            v.split(whereSeparator: { !$0.isNumber }).map { Int($0) ?? 0 }
        }
        let pa = parts(a), pb = parts(b)
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x < y ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }

    @discardableResult
    nonisolated static func run(_ tool: String, _ args: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = args
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return -1 }
        process.waitUntilExit()
        return process.terminationStatus
    }

    /// Start a process that outlives the app (its own session, no inherited descriptors).
    nonisolated static func spawnDetached(_ tool: String, _ args: [String]) {
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT))
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)
        // Children get default signal handlers whatever the app ignores.
        var allSignals = sigset_t()
        sigfillset(&allSignals)
        posix_spawnattr_setsigdefault(&attributes, &allSignals)
        var noSignals = sigset_t()
        sigemptyset(&noSignals)
        posix_spawnattr_setsigmask(&attributes, &noSignals)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
        let argStrings: [String] = [tool] + args
        let envStrings: [String] = ["PATH=/usr/bin:/bin:/usr/sbin:/sbin", "HOME=\(NSHomeDirectory())"]
        let argv: [UnsafeMutablePointer<CChar>?] = argStrings.map { strdup($0) } + [nil]
        let env: [UnsafeMutablePointer<CChar>?] = envStrings.map { strdup($0) } + [nil]
        var pid: pid_t = 0
        _ = posix_spawn(&pid, tool, &actions, &attributes, argv, env)
        argv.forEach { free($0) }
        env.forEach { free($0) }
        posix_spawn_file_actions_destroy(&actions)
        posix_spawnattr_destroy(&attributes)
    }
}
