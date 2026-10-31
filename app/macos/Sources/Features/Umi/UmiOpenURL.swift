import AppKit
import OSLog

/// `umi://open?path=<path>` (SPEC I-6): open a file or folder under `~/best` from a link.
///
/// The path is relative to the root (`~/best`, or `$UMI_OPEN_ROOT`) and must stay inside it after
/// `..` and symlinks are resolved. Before opening, the git repository holding the path (inside the
/// root) is fetched and fast-forwarded when it is behind its upstream, because the link may name a
/// file another machine just pushed. If that fails, the local copy opens with a short notice.
/// Files open as `open FILE` does (I-3, E-10); folders as a folder dropped on Umi does.
enum UmiOpenURL {
    static let scheme = "umi"

    static var defaultRoot: String {
        if let root = ProcessInfo.processInfo.environment["UMI_OPEN_ROOT"], !root.isEmpty {
            return (root as NSString).expandingTildeInPath
        }
        return NSHomeDirectory() + "/best"
    }

    // MARK: Apple Event entry

    /// Handles `kInternetEventClass`/`kAEGetURL`. Installed in `applicationWillFinishLaunching`
    /// so a link that launches Umi reaches it too. (Implementing `application(_:open:)` instead
    /// would stop AppKit from calling `application(_:openFile:)`, which Finder's opens rely on.)
    final class EventHandler: NSObject {
        static let shared = EventHandler()

        func install() {
            NSAppleEventManager.shared().setEventHandler(
                self, andSelector: #selector(handle(_:reply:)),
                forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
        }

        @objc func handle(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
            guard let text = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
                  let url = URL(string: text) else { return }
            // After launch finishes (restored windows first), never inside the event.
            DispatchQueue.main.async { UmiOpenURL.handle(url) }
        }
    }

    /// Open a link: refuse what escapes the root, pull in the background, then show it.
    @MainActor
    static func handle(_ url: URL, root: String = defaultRoot) {
        let target: String
        do {
            target = try resolve(url, root: root)
        } catch let error as UmiError {
            refuse(url, error.message)
            return
        } catch {
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let notice = pullIfBehind(target, root: root)
            DispatchQueue.main.async {
                do {
                    _ = try show(target, root: root, notice: notice)
                } catch let error as UmiError {
                    refuse(url, error.message)
                } catch {}
            }
        }
    }

    @MainActor
    private static func refuse(_ url: URL, _ message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Can't open \(url.absoluteString)"
        alert.informativeText = message
        alert.runModal()
    }

    // MARK: Resolution

    /// The absolute path a link names, or an error when it isn't an `open` link or its path
    /// escapes the root (absolute, `..`, or a symlink pointing out). The path need not exist yet.
    static func resolve(_ url: URL, root: String) throws -> String {
        guard url.scheme?.lowercased() == scheme else { throw UmiError.badRequest("not a \(scheme):// link") }
        guard url.host?.lowercased() == "open" else {
            throw UmiError.badRequest("\(scheme):// links are \(scheme)://open?path=PATH")
        }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard let relative = items.first(where: { $0.name == "path" })?.value, !relative.isEmpty else {
            throw UmiError.badRequest("give a path: \(scheme)://open?path=PATH (relative to \(displayRoot(root)))")
        }
        return try within(root, relative)
    }

    /// `relative` joined to `root`, checked to stay inside it both as written and with symlinks
    /// resolved (as far as the path exists).
    static func within(_ root: String, _ relative: String) throws -> String {
        let outside = UmiError.badRequest("\(relative) is outside \(displayRoot(root))")
        guard !relative.hasPrefix("/"), !relative.hasPrefix("~"), !relative.contains("\0") else { throw outside }
        let base = UmiPaths.canonical(root)
        let joined = lexical(base + "/" + relative)
        guard isInside(joined, base) else { throw outside }
        guard isInside(realPath(joined), base) else { throw outside }
        return joined
    }

    /// An absolute path with `.`, `..` and repeated slashes removed, from the text alone.
    /// (`standardizedFileURL` also drops a leading `/private` when the file exists, which
    /// would make the same path compare differently before and after a pull.)
    private static func lexical(_ path: String) -> String {
        var parts: [Substring] = []
        for part in path.split(separator: "/", omittingEmptySubsequences: true) {
            if part == "." { continue }
            if part == ".." { _ = parts.popLast(); continue }
            parts.append(part)
        }
        return "/" + parts.joined(separator: "/")
    }

    private static func isInside(_ path: String, _ base: String) -> Bool {
        let trimmed = path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
        return trimmed == base || trimmed.hasPrefix(base == "/" ? "/" : base + "/")
    }

    /// The path with symlinks resolved in the part of it that exists.
    private static func realPath(_ path: String) -> String {
        var existing = path
        var rest: [String] = []
        while !existing.isEmpty, existing != "/", !FileManager.default.fileExists(atPath: existing) {
            rest.insert((existing as NSString).lastPathComponent, at: 0)
            existing = (existing as NSString).deletingLastPathComponent
        }
        // A dangling symlink doesn't "exist" but may still point out: resolve it like the rest.
        var resolved = UmiPaths.canonical(existing)
        for component in rest { resolved = (resolved as NSString).appendingPathComponent(component) }
        if let first = rest.first {
            let link = (UmiPaths.canonical(existing) as NSString).appendingPathComponent(first)
            if let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: link) {
                let absolute = destination.hasPrefix("/") ? destination
                    : ((link as NSString).deletingLastPathComponent as NSString).appendingPathComponent(destination)
                return lexical(absolute)
            }
        }
        return resolved
    }

    private static func displayRoot(_ root: String) -> String {
        let home = NSHomeDirectory()
        return root.hasPrefix(home + "/") ? "~" + root.dropFirst(home.count) : root
    }

    // MARK: Pulling

    /// Fast-forward the repository holding `path` when it is behind its upstream. Returns a short
    /// notice when that was needed and failed, nil otherwise (no repository, no upstream, up to
    /// date, or pulled). Blocks while git runs: call it off the main thread.
    static func pullIfBehind(_ path: String, root: String) -> String? {
        var dir = path
        var isDir = ObjCBool(false)
        while !(FileManager.default.fileExists(atPath: dir, isDirectory: &isDir) && isDir.boolValue) {
            let parent = (dir as NSString).deletingLastPathComponent
            if parent == dir { return nil }
            dir = parent
        }
        let base = UmiPaths.canonical(root)
        guard let top = git(["-C", dir, "rev-parse", "--show-toplevel"], timeout: 10).output,
              isInside(UmiPaths.canonical(top), base) else { return nil }
        let name = (top as NSString).lastPathComponent
        guard git(["-C", top, "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"], timeout: 10).output != nil else {
            return nil
        }
        // `git pull --ff-only`, as a fetch and a fast-forward, so an up-to-date repository is
        // left untouched.
        let fetch = git(["-C", top, "fetch", "--quiet"], timeout: 30)
        if fetch.output == nil { return notice(name, "couldn't fetch", fetch.error) }
        guard let behind = git(["-C", top, "rev-list", "--count", "HEAD..@{u}"], timeout: 10).output,
              let count = Int(behind), count > 0 else { return nil }
        let merge = git(["-C", top, "merge", "--ff-only", "--quiet", "@{u}"], timeout: 30)
        if merge.output == nil { return notice(name, "couldn't fast-forward", merge.error) }
        return nil
    }

    private static func notice(_ repo: String, _ what: String, _ detail: String) -> String {
        let line = detail.split(separator: "\n").first.map { String($0) } ?? ""
        let reason = line.replacingOccurrences(of: "fatal: ", with: "").replacingOccurrences(of: "error: ", with: "")
        return "Showing the copy on this Mac: \(what) \(repo)" + (reason.isEmpty ? "." : " (\(reason)).")
    }

    /// Run git with the login environment (its PATH and credential helpers), never prompting.
    /// `output` is the trimmed stdout on success, nil on failure or timeout.
    private static func git(_ arguments: [String], timeout: TimeInterval) -> (output: String?, error: String) {
        var env = UmiAgentEnvironment.login().env
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["GIT_OPTIONAL_LOCKS"] = "0"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + arguments
        process.environment = env
        process.standardInput = FileHandle.nullDevice
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        do { try process.run() } catch { return (nil, "git didn't start") }
        var errData = Data()
        let reading = DispatchGroup()
        reading.enter()
        DispatchQueue.global().async {
            errData = err.fileHandleForReading.readDataToEndOfFile()
            reading.leave()
        }
        var timedOut = false
        let killer = DispatchWorkItem { if process.isRunning { timedOut = true; process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        killer.cancel()
        reading.wait()
        let error = timedOut ? "timed out" : String(decoding: errData, as: UTF8.self)
        guard !timedOut, process.terminationStatus == 0 else { return (nil, error) }
        return (String(decoding: outData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines), error)
    }

    // MARK: Showing

    /// Open what the link names, after pulling. Checks the path again (a pull may have changed
    /// it). Returns what happened, for the debug method.
    @MainActor
    @discardableResult
    static func show(_ path: String, root: String, notice: String?) throws -> [String: Any] {
        let relative = String(path.dropFirst(UmiPaths.canonical(root).count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let target = try within(root, relative.isEmpty ? "." : relative)
        var isDir = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: target, isDirectory: &isDir) else {
            var message = "No such file or folder: \(displayRoot(target))"
            if let notice { message += "\n\n" + notice }
            throw UmiError.notFound(message)
        }
        let url = URL(fileURLWithPath: target)
        var result: [String: Any] = ["path": target]
        if let notice { result["notice"] = notice }
        if !isDir.boolValue, UmiEditor.handles(url) {
            // The same path as Finder's double-click and `open FILE` (I-3, E-10).
            let (window, tab) = try UmiEditor.open(url, inCurrentTab: false)
            if let notice { tab.editor.document(for: url)?.error = notice }
            result["kind"] = "file"
            result["tab"] = tab.idString
            result["window"] = window.umiIDString
            return result
        }
        if isDir.boolValue, let delegate = NSApp.delegate as? AppDelegate {
            // A folder opens as one opened on Umi from Finder: a terminal in it.
            _ = delegate.application(NSApp, openFile: target)
            result["kind"] = "folder"
        } else {
            // Not something the editor shows: reveal it rather than run it.
            NSWorkspace.shared.activateFileViewerSelecting([url])
            result["kind"] = "other"
        }
        if let notice {
            Task { try? await UmiNotify.post(title: "Opened \(url.lastPathComponent)", body: notice, pane: nil) }
        }
        return result
    }

    // MARK: Default handler

    /// The installed app answers `umi://` links, not a dev or test copy that also declares the
    /// scheme. Isolated instances never claim it.
    /// Right after an update replaces the bundle, LaunchServices may not know the new copy's
    /// schemes yet: register it first, and try again a little later if setting the default fails.
    static func claimSchemeIfNeeded() {
        guard !UmiPaths.isIsolated, let probe = URL(string: "\(scheme)://open") else { return }
        let app = Bundle.main.bundleURL
        DispatchQueue.global(qos: .utility).async {
            for attempt in 1...4 {
                if let current = NSWorkspace.shared.urlForApplication(toOpen: probe),
                   current.standardizedFileURL == app.standardizedFileURL {
                    return
                }
                LSRegisterURL(app as CFURL, true)
                let done = DispatchSemaphore(value: 0)
                var failure: Error?
                NSWorkspace.shared.setDefaultApplication(at: app, toOpenURLsWithScheme: scheme) { error in
                    failure = error
                    done.signal()
                }
                _ = done.wait(timeout: .now() + 20)
                let message = failure.map { "\($0)" } ?? "ok"
                logger.info("claiming \(scheme, privacy: .public):// (attempt \(attempt)): \(message, privacy: .public)")
                if failure == nil { return }
                sleep(UInt32(15 * attempt))
            }
        }
    }

    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "dev.umi.app", category: "links")
}
