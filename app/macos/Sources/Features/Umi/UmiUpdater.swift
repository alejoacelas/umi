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
/// - A background check that finds a newer version asks first (I-4): a notice at the bottom
///   of every window's sidebar (Download, Later, Skip), never a dialog, and nothing is
///   downloaded until the answer is yes. "Check for Updates…" and `umi update` are a yes.
///   The answers are kept in the state directory (`update.json`), so a restart neither asks
///   again early nor forgets a yes (DECISIONS.md §18).
/// - A download is verified (signature, hash, bundle id, version, code signature) and
///   unpacked into the state directory. It installs when the app quits, or at once when
///   the user asks (`umi update --now`, or the prompt). The app never quits or closes
///   terminals by itself to install.
/// - Installing is done by a small helper that waits for the app to exit, swaps the bundle
///   and clears the download quarantine, so no Gatekeeper prompt appears.
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
    }

    /// What the sidebar shows.
    enum Notice: Equatable {
        case asking(String)
        case downloading(String)
        case ready(String)
        case failed(String, String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var latest: String?
    /// The newer version the app is asking about (nil: not asking).
    @Published private(set) var question: String?
    @Published private(set) var answers: Answers

    /// A staged, verified update waiting for the app to quit.
    private(set) var staged: (version: String, app: URL)?
    private var installOnQuit = true
    private var relaunchAfterInstall = false
    private var downloadTask: Task<Release, Error>?
    /// The version the current or last download was for.
    private var downloadVersion: String?
    private var timer: Timer?

    private init() {
        answers = Self.loadAnswers()
        // A yes or a skip for a version this build already is (or is newer than) is spent.
        if let consent = answers.consent, Self.compare(consent, UmiVersion.current) != .orderedDescending { answers.consent = nil }
        if let skipped = answers.skipped, Self.compare(skipped, UmiVersion.current) != .orderedDescending { answers.skipped = nil }
    }

    /// How often to check in the background, and how long "Later" lasts. Isolated instances
    /// (tests) may shorten them.
    private static func seconds(_ variable: String, default value: TimeInterval) -> TimeInterval {
        guard UmiPaths.isIsolated, let raw = ProcessInfo.processInfo.environment[variable],
              let seconds = TimeInterval(raw), seconds > 0 else { return value }
        return seconds
    }
    private static var checkInterval: TimeInterval { seconds("UMI_UPDATE_CHECK_SECONDS", default: 6 * 3600) }
    private static var laterInterval: TimeInterval { seconds("UMI_UPDATE_LATER_SECONDS", default: 24 * 3600) }

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

    private var publicKey: Curve25519.Signing.PublicKey? {
        guard let base64 = Bundle.main.object(forInfoDictionaryKey: "UmiUpdatePublicKey") as? String,
              let raw = Data(base64Encoded: base64) else { return nil }
        return try? Curve25519.Signing.PublicKey(rawRepresentation: raw)
    }

    private var updatesDirectory: String { UmiPaths.directory("updates") }

    /// What the sidebar shows: the question, a download the user agreed to, or a staged update.
    var notice: Notice? {
        switch phase {
        case .ready(let version): return .ready(version)
        case .downloading(let version): return .downloading(version)
        case .installing: return staged.map { .ready($0.version) }
        case .failed(let reason):
            if let version = downloadVersion, version == answers.consent { return .failed(version, reason) }
        default: break
        }
        return question.map { .asking($0) }
    }

    // MARK: The question (I-4)

    enum Answer: String { case download, later, skip }

    /// The user answered the question (the sidebar's buttons, or `umi update --later/--skip`).
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
                throw UmiError.failed("the update is already downloading or downloaded; it installs when \(UmiPaths.productName) quits")
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
                throw UmiError.failed("\(version) is already downloading or downloaded; it installs when \(UmiPaths.productName) quits")
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
        }
        return status()
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
        if answers.skipped == version || (answers.laterUntil.map { $0 > Date() } ?? false) {
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

    /// What the app knows, without checking (`umi update --status`).
    func status() -> [String: Any] {
        var out: [String: Any] = ["installed": UmiVersion.current, "latest": latest ?? NSNull(),
                                  "update_available": latest.map { Self.compare($0, UmiVersion.current) == .orderedDescending } ?? false,
                                  "background_checks": backgroundChecks, "state": state]
        if let question { out["question"] = question }
        if let staged { out["ready"] = staged.version }
        if case .downloading(let version) = phase { out["downloading"] = version }
        if case .failed(let reason) = phase { out["error"] = reason }
        if let skipped = answers.skipped { out["skipped"] = skipped }
        if let until = answers.laterUntil, until > Date() { out["later_until"] = ISO8601DateFormatter().string(from: until) }
        if let consent = answers.consent { out["consent"] = consent }
        if let feedURL { out["feed"] = feedURL.absoluteString }
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

    /// Check in the background now and then. A check that finds a newer version asks; it
    /// never downloads by itself (unless the user already said yes to that version).
    func startBackgroundChecks() {
        guard backgroundChecks else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            Task { @MainActor in await self?.backgroundCheck() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: Self.checkInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.backgroundCheck() }
        }
    }

    private func backgroundCheck() async {
        // A yes is being carried out or waits for the quit: nothing to ask meanwhile.
        guard staged == nil, downloadTask == nil else { return }
        _ = try? await check(userInitiated: false)
    }

    // MARK: Checking

    func fetchFeed() async throws -> Release {
        guard let feedURL else { throw UmiError.failed("no update feed is configured") }
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
        // Any check that finds a newer version asks (the answers so far permitting).
        if backgroundChecks && !userInitiated { considerAsking(release) }
        var out = status()
        out["latest"] = release.version
        out["update_available"] = available
        out["ready"] = staged?.version ?? ""
        return out
    }

    // MARK: Downloading

    /// The feed moved on to another version than the one the user said yes to.
    private struct FeedMoved: Error { let release: Release }

    /// Download and verify a version and stage it to install at quit. Every caller is a yes:
    /// `release` is a version already fetched (a yes remembered from before), `expected` the
    /// version the user said yes to (the sidebar's Download); with neither, the newest
    /// version (`umi update`, "Check for Updates…"). A yes to one version never downloads
    /// another: if the feed moved on, the newer version is asked about instead.
    func download(release given: Release? = nil, expected: String? = nil) async throws -> [String: Any] {
        // A development build would replace itself (the build folder's app) with a release.
        guard UmiVersion.isRelease else {
            throw UmiError.failed("this is a development build of \(UmiPaths.productName); it doesn't update itself (install a release instead)")
        }
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
                    if let target { self.agree(to: target) }
                    let release: Release
                    if let given {
                        release = given
                    } else {
                        do {
                            release = try await self.fetchFeed()
                        } catch {
                            if let target {
                                self.downloadVersion = target
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
                    if release.version != target { self.agree(to: release.version) }
                    if let staged = self.staged, staged.version == release.version { return release }
                    self.downloadVersion = release.version
                    self.phase = .downloading(release.version)
                    do {
                        let app = try await self.fetchAndVerify(release)
                        self.staged = (release.version, app)
                        self.phase = .ready(release.version)
                        UmiEvents.shared.emit("update.ready", ["version": release.version])
                    } catch {
                        // A staged older update still installs at quit.
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
        return ["installed": UmiVersion.current, "latest": release.version, "ready": release.version,
                "message": "Downloaded \(UmiPaths.productName) \(release.version). It installs when \(UmiPaths.productName) quits (or run `\(UmiPaths.cliName) update --now`)."]
    }

    /// A yes to `version`: remember it, and stop asking.
    private func agree(to version: String) {
        answers.consent = version
        if answers.skipped == version { answers.skipped = nil }
        answers.laterUntil = nil
        question = nil
        saveAnswers()
    }

    private static func reason(_ error: Error) -> String {
        (error as? UmiError)?.message ?? error.localizedDescription
    }

    private func fetchAndVerify(_ release: Release) async throws -> URL {
        guard let key = publicKey else { throw UmiError.failed("this build has no update-signing key") }
        let (temp, response) = try await URLSession.shared.download(from: release.url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw UmiError.failed("the update download answered HTTP \(http.statusCode)")
        }
        let data = try Data(contentsOf: temp, options: .mappedIfSafe)
        try? FileManager.default.removeItem(at: temp)

        // Verify before anything is unpacked.
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard digest == release.sha256 else { throw UmiError.failed("the update's checksum doesn't match the feed") }
        guard key.isValidSignature(release.signature, for: data) else {
            throw UmiError.failed("the update isn't signed with \(UmiPaths.productName)'s key")
        }

        guard Self.isValidVersion(release.version) else { throw UmiError.failed("the update feed's version isn't valid") }
        let base = URL(fileURLWithPath: updatesDirectory).standardizedFileURL.path
        let dir = (base as NSString).appendingPathComponent("staged-\(release.version)")
        guard URL(fileURLWithPath: dir).standardizedFileURL.path.hasPrefix(base + "/") else {
            throw UmiError.failed("the update feed's version isn't valid")
        }
        try? FileManager.default.removeItem(atPath: dir)
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let zip = (dir as NSString).appendingPathComponent("update.zip")
        try data.write(to: URL(fileURLWithPath: zip))
        guard Self.run("/usr/bin/ditto", ["-x", "-k", zip, dir]) == 0 else {
            throw UmiError.failed("couldn't unpack the update")
        }
        try? FileManager.default.removeItem(atPath: zip)
        guard let appName = try FileManager.default.contentsOfDirectory(atPath: dir).first(where: { $0.hasSuffix(".app") }) else {
            throw UmiError.failed("the update has no app in it")
        }
        let app = URL(fileURLWithPath: dir).appendingPathComponent(appName)
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

    // MARK: Installing

    /// Install the staged update and relaunch now (the user asked).
    func installNow(force: Bool = true) async throws -> [String: Any] {
        // An update cuts running agent turns off only if the user agrees (R-10).
        let turns = UmiAgents.shared.runningTurns()
        if turns > 0 && !force {
            throw UmiError.failed("\(turns) managed-agent turn\(turns == 1 ? " is" : "s are") running. Installing now interrupts "
                + "\(turns == 1 ? "it" : "them") (\(turns == 1 ? "it continues" : "they continue") after the relaunch): pass --force to do that, "
                + "or let the update install when \(UmiPaths.productName) quits.")
        }
        if staged == nil { _ = try await download() }
        // A turn may have started during the download.
        let turnsNow = UmiAgents.shared.runningTurns()
        if turnsNow > 0 && !force {
            throw UmiError.failed("\(turnsNow) managed-agent turn\(turnsNow == 1 ? " is" : "s are") running; the update is downloaded "
                + "and installs when \(UmiPaths.productName) quits (or pass --force to install now and interrupt them).")
        }
        guard let staged else {
            return ["installed": UmiVersion.current, "message": "\(UmiPaths.productName) \(UmiVersion.current) is up to date."]
        }
        relaunchAfterInstall = true
        phase = .installing
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            (NSApp.delegate as? AppDelegate)?.terminateForUpdate()
        }
        return ["installing": staged.version, "message": "Installing \(UmiPaths.productName) \(staged.version) and relaunching."]
    }

    /// True while quitting to install an update the user asked for (no confirmations).
    var isQuittingForUpdate: Bool { relaunchAfterInstall }

    /// Called as the app quits: hand a staged update to the installer helper.
    func installOnQuitIfStaged() {
        guard installOnQuit, let staged else { return }
        let destination = Bundle.main.bundleURL
        let script = (updatesDirectory as NSString).appendingPathComponent("install.sh")
        let log = (updatesDirectory as NSString).appendingPathComponent("install.log")
        do {
            try Self.installerScript.write(toFile: script, atomically: true, encoding: .utf8)
        } catch {
            return
        }
        // An isolated instance relaunches as itself: same state directory and feed.
        let environment = ProcessInfo.processInfo.environment
        let args = [script, String(getpid()), staged.app.path, destination.path, relaunchAfterInstall ? "1" : "0", log,
                    UmiPaths.isIsolated ? UmiPaths.stateDirectory : "",
                    UmiPaths.isIsolated ? environment["UMI_FEED_URL"] ?? "" : ""]
        Self.spawnDetached("/bin/sh", args)
    }

    /// Waits for the app to exit, swaps the bundle (rolling back on failure), clears
    /// quarantine and optionally relaunches.
    static let installerScript = """
    #!/bin/sh
    # Umi update installer: install.sh PID STAGED_APP DEST_APP RELAUNCH LOG [STATE_DIR [FEED_URL]]
    pid="$1"; staged="$2"; dest="$3"; relaunch="$4"; log="$5"; state="${6:-}"; feed="${7:-}"
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
    old="$dest.old-$$"
    if mv "$dest" "$old" && mv "$staged" "$dest"; then
        rm -rf "$old"
        /usr/bin/xattr -cr "$dest" 2>/dev/null
        echo "$(date): installed"
    else
        echo "$(date): install failed; restoring"
        [ -d "$dest" ] || mv "$old" "$dest"
        exit 1
    fi
    rmdir "$(dirname "$staged")" 2>/dev/null
    if [ "$relaunch" = "1" ]; then
        if [ -n "$state" ]; then
            # An instance with its own state directory comes back as that instance.
            set -- "UMI_STATE_DIR=$state"
            [ -n "$feed" ] && set -- "$@" "UMI_FEED_URL=$feed"
            /usr/bin/env "$@" "$dest/Contents/MacOS/umi-app" >/dev/null 2>&1 &
        else
            /usr/bin/open "$dest"
        fi
    fi
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
                alert.informativeText = "You have \(UmiVersion.current). It installs when you quit \(UmiPaths.productName); "
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
        var text = "It installs when you quit \(UmiPaths.productName). Installing now quits and relaunches \(UmiPaths.productName), which ends the programs running in its terminals."
        let turns = UmiAgents.shared.runningTurns()
        if turns > 0 {
            text += " \(turns) managed-agent turn\(turns == 1 ? " is" : "s are") running: installing now interrupts \(turns == 1 ? "it" : "them"), and \(turns == 1 ? "it continues" : "they continue") after the relaunch."
        }
        alert.informativeText = text
        alert.addButton(withTitle: "Install and Relaunch")
        alert.addButton(withTitle: "Install on Quit")
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
