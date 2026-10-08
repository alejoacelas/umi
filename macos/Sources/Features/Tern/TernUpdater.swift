import AppKit
import CryptoKit
import Foundation

/// Tern's updater (I-4, P-2). It replaces the updater Ghostty ships with, which points at
/// Ghostty's own feed: Tern only ever looks at its own release feed and only installs builds
/// signed with its own key.
///
/// - The feed is a small JSON file (`appcast.json`) published with each release. It names
///   the version, the zip's URL, its SHA-256 and an Ed25519 signature of the zip.
/// - A download is verified (signature, hash, bundle id, version, code signature) and
///   unpacked into the state directory. It installs when the app quits, or at once when
///   the user asks (`tern update --now`, or the prompt). The app never quits or closes
///   terminals by itself to install.
/// - Installing is done by a small helper that waits for the app to exit, swaps the bundle
///   and clears the download quarantine, so no Gatekeeper prompt appears.
@MainActor
final class TernUpdater: ObservableObject {
    static let shared = TernUpdater()

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

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var latest: String?

    /// A staged, verified update waiting for the app to quit.
    private(set) var staged: (version: String, app: URL)?
    private var installOnQuit = true
    private var relaunchAfterInstall = false
    private var downloadTask: Task<Release, Error>?
    private var timer: Timer?

    var feedURL: URL? {
        if let override = ProcessInfo.processInfo.environment["TERN_FEED_URL"], !override.isEmpty {
            return URL(string: override)
        }
        // Stored without its scheme: Info.plist is run through the C preprocessor, which
        // would take "//" for a comment.
        guard var raw = Bundle.main.object(forInfoDictionaryKey: "TernUpdateFeedURL") as? String else { return nil }
        if !raw.contains("://") { raw = "https://" + raw }
        return URL(string: raw)
    }

    private var publicKey: Curve25519.Signing.PublicKey? {
        guard let base64 = Bundle.main.object(forInfoDictionaryKey: "TernUpdatePublicKey") as? String,
              let raw = Data(base64Encoded: base64) else { return nil }
        return try? Curve25519.Signing.PublicKey(rawRepresentation: raw)
    }

    private var updatesDirectory: String { TernPaths.directory("updates") }

    /// What the sidebar says when an update is waiting.
    var sidebarNotice: String? {
        if case .ready(let version) = phase {
            return "\(TernPaths.productName) \(version) is ready. It installs when you quit (click to install now)."
        }
        return nil
    }

    // MARK: Background checks

    /// Check in the background now and then. Only release builds update themselves, and an
    /// isolated instance only when pointed at a feed explicitly.
    func startBackgroundChecks() {
        guard TernVersion.isRelease else { return }
        if TernPaths.isIsolated && ProcessInfo.processInfo.environment["TERN_FEED_URL"] == nil { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            Task { @MainActor in await self?.backgroundCheck() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.backgroundCheck() }
        }
    }

    private func backgroundCheck() async {
        guard staged == nil, downloadTask == nil else { return }
        guard let result = try? await check(userInitiated: false),
              result["update_available"] as? Bool == true else { return }
        _ = try? await download()
    }

    // MARK: Checking

    func fetchFeed() async throws -> Release {
        guard let feedURL else { throw TernError.failed("no update feed is configured") }
        var request = URLRequest(url: feedURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.setValue("Tern/\(TernVersion.current)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw TernError.failed("the update feed answered HTTP \(http.statusCode)")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = json["version"] as? String,
              let urlString = json["url"] as? String,
              let url = URL(string: urlString, relativeTo: feedURL)?.absoluteURL,
              let sha = json["sha256"] as? String,
              let signatureString = json["signature"] as? String,
              let signature = Data(base64Encoded: signatureString) else {
            throw TernError.failed("the update feed isn't valid")
        }
        if let product = json["product"] as? String, product != TernPaths.productName {
            throw TernError.failed("the update feed is for another product (\(product))")
        }
        // The version isn't covered by the signature and names a folder on disk: only plain
        // dotted numbers are accepted.
        guard Self.isValidVersion(version) else { throw TernError.failed("the update feed's version isn't valid") }
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
        } catch let error as TernError {
            throw error
        } catch {
            throw TernError.failed("couldn't check for updates: \(error.localizedDescription)")
        }
        latest = release.version
        let available = Self.compare(release.version, TernVersion.current) == .orderedDescending
        TernEvents.shared.emit("update.checked", ["installed": TernVersion.current, "latest": release.version,
                                                  "update_available": available])
        return ["installed": TernVersion.current, "latest": release.version, "update_available": available,
                "feed": feedURL?.absoluteString ?? "", "ready": staged?.version ?? ""]
    }

    // MARK: Downloading

    /// Download and verify the newest version and stage it to install at quit.
    func download() async throws -> [String: Any] {
        // A development build would replace itself (the build folder's app) with a release.
        guard TernVersion.isRelease else {
            throw TernError.failed("this is a development build of \(TernPaths.productName); it doesn't update itself (install a release instead)")
        }
        let release: Release
        if let downloadTask {
            release = try await downloadTask.value
        } else {
            let task = Task { @MainActor () throws -> Release in
                let release = try await self.fetchFeed()
                self.latest = release.version
                guard Self.compare(release.version, TernVersion.current) == .orderedDescending else {
                    return release
                }
                if let staged = self.staged, staged.version == release.version { return release }
                self.phase = .downloading(release.version)
                do {
                    let app = try await self.fetchAndVerify(release)
                    self.staged = (release.version, app)
                    self.phase = .ready(release.version)
                    TernEvents.shared.emit("update.ready", ["version": release.version])
                } catch {
                    self.phase = .failed((error as? TernError)?.message ?? error.localizedDescription)
                    throw error
                }
                return release
            }
            downloadTask = task
            defer { downloadTask = nil }
            release = try await task.value
        }
        if Self.compare(release.version, TernVersion.current) != .orderedDescending {
            return ["installed": TernVersion.current, "latest": release.version, "update_available": false,
                    "message": "\(TernPaths.productName) \(TernVersion.current) is up to date."]
        }
        return ["installed": TernVersion.current, "latest": release.version, "ready": release.version,
                "message": "Downloaded \(TernPaths.productName) \(release.version). It installs when \(TernPaths.productName) quits (or run `\(TernPaths.cliName) update --now`)."]
    }

    private func fetchAndVerify(_ release: Release) async throws -> URL {
        guard let key = publicKey else { throw TernError.failed("this build has no update-signing key") }
        let (temp, response) = try await URLSession.shared.download(from: release.url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw TernError.failed("the update download answered HTTP \(http.statusCode)")
        }
        let data = try Data(contentsOf: temp, options: .mappedIfSafe)
        try? FileManager.default.removeItem(at: temp)

        // Verify before anything is unpacked.
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard digest == release.sha256 else { throw TernError.failed("the update's checksum doesn't match the feed") }
        guard key.isValidSignature(release.signature, for: data) else {
            throw TernError.failed("the update isn't signed with \(TernPaths.productName)'s key")
        }

        guard Self.isValidVersion(release.version) else { throw TernError.failed("the update feed's version isn't valid") }
        let base = URL(fileURLWithPath: updatesDirectory).standardizedFileURL.path
        let dir = (base as NSString).appendingPathComponent("staged-\(release.version)")
        guard URL(fileURLWithPath: dir).standardizedFileURL.path.hasPrefix(base + "/") else {
            throw TernError.failed("the update feed's version isn't valid")
        }
        try? FileManager.default.removeItem(atPath: dir)
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let zip = (dir as NSString).appendingPathComponent("update.zip")
        try data.write(to: URL(fileURLWithPath: zip))
        guard Self.run("/usr/bin/ditto", ["-x", "-k", zip, dir]) == 0 else {
            throw TernError.failed("couldn't unpack the update")
        }
        try? FileManager.default.removeItem(atPath: zip)
        guard let appName = try FileManager.default.contentsOfDirectory(atPath: dir).first(where: { $0.hasSuffix(".app") }) else {
            throw TernError.failed("the update has no app in it")
        }
        let app = URL(fileURLWithPath: dir).appendingPathComponent(appName)
        guard let bundle = Bundle(url: app),
              bundle.bundleIdentifier == Bundle.main.bundleIdentifier else {
            throw TernError.failed("the update is a different app")
        }
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        guard version == release.version else { throw TernError.failed("the update's version doesn't match the feed") }
        _ = Self.run("/usr/bin/xattr", ["-cr", app.path])
        guard Self.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path]) == 0 else {
            throw TernError.failed("the update's code signature doesn't verify")
        }
        return app
    }

    // MARK: Installing

    /// Install the staged update and relaunch now (the user asked).
    func installNow() async throws -> [String: Any] {
        if staged == nil { _ = try await download() }
        guard let staged else {
            return ["installed": TernVersion.current, "message": "\(TernPaths.productName) \(TernVersion.current) is up to date."]
        }
        relaunchAfterInstall = true
        phase = .installing
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            (NSApp.delegate as? AppDelegate)?.terminateForUpdate()
        }
        return ["installing": staged.version, "message": "Installing \(TernPaths.productName) \(staged.version) and relaunching."]
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
        let args = [script, String(getpid()), staged.app.path, destination.path, relaunchAfterInstall ? "1" : "0", log]
        Self.spawnDetached("/bin/sh", args)
    }

    /// Waits for the app to exit, swaps the bundle (rolling back on failure), clears
    /// quarantine and optionally relaunches.
    static let installerScript = """
    #!/bin/sh
    # Tern update installer: install.sh PID STAGED_APP DEST_APP RELAUNCH LOG
    pid="$1"; staged="$2"; dest="$3"; relaunch="$4"; log="$5"
    exec >>"$log" 2>&1
    echo "$(date): installing $staged over $dest (waiting for pid $pid)"
    i=0
    while kill -0 "$pid" 2>/dev/null; do
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
    if [ "$relaunch" = "1" ]; then /usr/bin/open "$dest"; fi
    """

    // MARK: Prompts (Check for Updates…)

    func checkFromMenu() {
        Task { @MainActor in
            do {
                let result = try await check(userInitiated: true)
                let latest = result["latest"] as? String ?? "?"
                if result["update_available"] as? Bool == true {
                    if case .ready = phase {
                        presentReadyPrompt()
                        return
                    }
                    let alert = NSAlert()
                    alert.messageText = "\(TernPaths.productName) \(latest) is available"
                    alert.informativeText = "You have \(TernVersion.current). The update downloads in the background and installs when you quit \(TernPaths.productName)."
                    alert.addButton(withTitle: "Download")
                    alert.addButton(withTitle: "Later")
                    if alert.runModal() == .alertFirstButtonReturn {
                        _ = try await download()
                        presentReadyPrompt()
                    }
                } else {
                    let alert = NSAlert()
                    alert.messageText = "\(TernPaths.productName) is up to date"
                    alert.informativeText = "Version \(TernVersion.current) is the newest version."
                    alert.runModal()
                }
            } catch {
                let alert = NSAlert()
                alert.messageText = "Couldn't check for updates"
                alert.informativeText = (error as? TernError)?.message ?? error.localizedDescription
                alert.runModal()
            }
        }
    }

    func presentReadyPrompt() {
        guard case .ready(let version) = phase else { return }
        let alert = NSAlert()
        alert.messageText = "\(TernPaths.productName) \(version) is ready to install"
        alert.informativeText = "It installs when you quit \(TernPaths.productName). Installing now quits and relaunches \(TernPaths.productName), which ends the programs running in its terminals."
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
