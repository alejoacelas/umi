import AppKit
import Foundation

/// Session links (SPEC AG-20): `umi://open?task=URL` opens an agent session in a new tab, named
/// after the task, in front. URL must come from an origin in `umi-web-origin`; Umi fetches the task
/// (JSON) from there and runs only what it builds from that task: the agent in the task's folder
/// on this Mac, or `ssh -t HOST sudo -iu USER umi-link attach ID` for a task that runs on the
/// server (or whose folder this Mac doesn't have). Nothing the link itself carries is run.
///
/// Links arrive from LaunchServices (a click in a browser or Slack), from a ⌘-click in a terminal
/// pane, from a web pane's page, from a Markdown preview, and from `umi link URL`.
@MainActor
enum UmiSessionLinks {
    // MARK: The task

    struct Task: Equatable {
        enum Place: String { case mac, server }
        enum Agent: String { case claude, codex }

        var id: String
        var title: String
        var folder: String
        var remote: String?
        var branch: String?
        var place: Place
        var agent: Agent
        var prompt: String?
        var session: String?
        var from: String?
        var sshHost: String?
        var sshUser: String?
    }

    static func refused(_ why: String) -> UmiError { .badRequest("link refused: \(why)") }

    /// The task's URL from a `umi://open?task=URL` link, when its origin is one of `origins`.
    static func taskURL(from link: URL, origins: Set<String>) throws -> URL {
        guard link.scheme?.lowercased() == "umi" else { throw refused("not a umi:// link") }
        guard link.host?.lowercased() == "open" else {
            throw refused("\(link.absoluteString) isn't a umi://open link")
        }
        let items = URLComponents(url: link, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard let raw = items.first(where: { $0.name == "task" })?.value, !raw.isEmpty,
              let task = URL(string: raw) else { throw refused("the link names no task (umi://open?task=URL)") }
        guard let origin = UmiWebPanes.origin(of: task) else {
            throw refused("the task's address \(raw) isn't an http(s) URL")
        }
        guard origins.contains(origin) else {
            throw refused("\(origin) isn't listed in umi-web-origin, so its tasks aren't opened")
        }
        return task
    }

    private static let idChars = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
    private static let hostChars = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.-")

    private static func word(_ s: String, _ chars: CharacterSet, max: Int) -> Bool {
        !s.isEmpty && s.count <= max && !s.hasPrefix("-") && s.unicodeScalars.allSatisfy { chars.contains($0) }
    }

    /// Read and check a task's JSON. Fields Umi runs or types are restricted to safe words.
    static func parseTask(_ data: Data) throws -> Task {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw refused("the task isn't a JSON object")
        }
        func text(_ key: String) -> String? {
            (json[key] as? String).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
        }
        guard let id = text("id"), word(id, idChars, max: 64) else { throw refused("the task has no valid id") }
        guard let title = text("title") else { throw refused("the task has no title") }
        guard let folder = text("folder"), !folder.hasPrefix("/"), !folder.hasPrefix("~"),
              !folder.split(separator: "/").contains("..") else {
            throw refused("the task's folder must be a path inside ~/best")
        }
        guard let place = Task.Place(rawValue: text("where") ?? "mac") else { throw refused("unknown place to run: \(text("where") ?? "")") }
        guard let agent = Task.Agent(rawValue: text("agent") ?? "claude") else { throw refused("unknown agent: \(text("agent") ?? "")") }
        let prompt = json["prompt"] as? String
        let session = text("session")
        guard (prompt?.isEmpty == false) != (session != nil) else {
            throw refused("the task needs either a prompt or a session to resume")
        }
        if let session, !word(session, hostChars, max: 128) { throw refused("the task's session id isn't valid") }
        var task = Task(id: id, title: title, folder: folder.trimmingCharacters(in: CharacterSet(charactersIn: "/")),
                        remote: text("remote"), branch: text("branch"), place: place, agent: agent,
                        prompt: prompt?.isEmpty == false ? prompt : nil, session: session, from: text("from"))
        if let server = json["server"] as? [String: Any] {
            if let host = server["ssh"] as? String, word(host, hostChars, max: 253) { task.sshHost = host }
            if let user = server["user"] as? String, word(user, hostChars, max: 64) { task.sshUser = user }
        }
        return task
    }

    // MARK: The folder on this Mac

    /// `host/owner/repo`, lowercased, for comparing git remotes written as https, ssh or scp-style.
    static func normalizedRemote(_ raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if let scheme = s.range(of: "://") {
            s = String(s[scheme.upperBound...])
            if let at = s.firstIndex(of: "@"), at < (s.firstIndex(of: "/") ?? s.endIndex) { s = String(s[s.index(after: at)...]) }
        } else if let colon = s.firstIndex(of: ":"), !s.hasPrefix("/") {
            // scp-style: user@host:owner/repo
            var host = String(s[..<colon])
            if let at = host.firstIndex(of: "@") { host = String(host[host.index(after: at)...]) }
            s = host + "/" + s[s.index(after: colon)...]
        } else {
            return nil
        }
        var parts = s.split(separator: "/").map(String.init)
        guard parts.count >= 2 else { return nil }
        // Drop a port from the host.
        if let colon = parts[0].firstIndex(of: ":") { parts[0] = String(parts[0][..<colon]) }
        if parts[parts.count - 1].hasSuffix(".git") { parts[parts.count - 1].removeLast(4) }
        return parts.joined(separator: "/").lowercased()
    }

    /// The git directory of a checkout (a `.git` folder, or the folder a worktree's `.git` file names).
    private static func gitDir(_ checkout: URL) -> URL? {
        let dotGit = checkout.appendingPathComponent(".git")
        var isDir = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: dotGit.path, isDirectory: &isDir) else { return nil }
        if isDir.boolValue { return dotGit }
        guard let text = try? String(contentsOf: dotGit, encoding: .utf8),
              let line = text.split(separator: "\n").first(where: { $0.hasPrefix("gitdir:") }) else { return nil }
        let path = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
        return URL(fileURLWithPath: path, relativeTo: checkout).standardizedFileURL
    }

    /// The checkout's `origin` URL, read from its git config (a worktree's lives in the main one).
    static func originRemote(of checkout: URL) -> String? {
        guard var dir = gitDir(checkout) else { return nil }
        if let common = try? String(contentsOf: dir.appendingPathComponent("commondir"), encoding: .utf8) {
            dir = URL(fileURLWithPath: common.trimmingCharacters(in: .whitespacesAndNewlines), relativeTo: dir).standardizedFileURL
        }
        guard let config = try? String(contentsOf: dir.appendingPathComponent("config"), encoding: .utf8) else { return nil }
        var inOrigin = false
        for raw in config.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                inOrigin = line.replacingOccurrences(of: " ", with: "") == "[remote\"origin\"]"
            } else if inOrigin, line.hasPrefix("url") {
                let parts = line.split(separator: "=", maxSplits: 1)
                if parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces) == "url" {
                    return parts[1].trimmingCharacters(in: .whitespaces)
                }
            }
        }
        return nil
    }

    /// The branch a checkout is on, or nil when detached or unreadable.
    static func currentBranch(of checkout: URL) -> String? {
        guard let dir = gitDir(checkout),
              let head = try? String(contentsOf: dir.appendingPathComponent("HEAD"), encoding: .utf8) else { return nil }
        let line = head.trimmingCharacters(in: .whitespacesAndNewlines)
        guard line.hasPrefix("ref: refs/heads/") else { return nil }
        return String(line.dropFirst("ref: refs/heads/".count))
    }

    /// The task's folder on this Mac: a checkout under `best` (`best/*/*`, `best/orgs/*/*`) whose
    /// origin is the task's remote, else `best/<folder>` when it exists, else nil.
    static func localFolder(for task: Task, best: URL) -> URL? {
        let fm = FileManager.default
        if let wanted = task.remote.flatMap(normalizedRemote) {
            func children(_ dir: URL) -> [URL] {
                ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey],
                                              options: [.skipsHiddenFiles])) ?? [])
                    .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
                    .sorted { $0.path < $1.path }
            }
            var candidates: [URL] = []
            // The folder the task names first, so it wins among several clones of one repository.
            candidates.append(best.appendingPathComponent(task.folder))
            for area in children(best) { candidates += children(area) }
            for org in children(best.appendingPathComponent("orgs")) { candidates += children(org) }
            for dir in candidates where originRemote(of: dir).flatMap(normalizedRemote) == wanted {
                return dir.standardizedFileURL
            }
        }
        var isDir = ObjCBool(false)
        let named = best.appendingPathComponent(task.folder)
        if fm.fileExists(atPath: named.path, isDirectory: &isDir), isDir.boolValue { return named.standardizedFileURL }
        return nil
    }

    // MARK: What is typed

    /// Quote a word for a POSIX shell.
    static func quote(_ word: String) -> String { UmiAgentHooks.shellQuote(word) }

    /// The program for `name`: `$UMI_TEST_LINK_BIN/name` in the acceptance tests (labelled test hook:
    /// the panes' login shells set their own PATH, so fakes can't be put on it), else the bare name.
    static func program(_ name: String, env: [String: String]) -> String {
        if let dir = env["UMI_TEST_LINK_BIN"], !dir.isEmpty { return (dir as NSString).appendingPathComponent(name) }
        return name
    }

    /// The agent's command words: a new conversation on `promptFile`'s text (read by the shell, so a
    /// long or multi-line prompt isn't typed), or a resumed one.
    static func agentLine(_ task: Task, promptFile: String?, env: [String: String]) -> String {
        let bin = quote(program(task.agent.rawValue, env: env))
        let flag = task.agent == .claude ? "--dangerously-skip-permissions" : "--dangerously-bypass-approvals-and-sandbox"
        if let session = task.session {
            return task.agent == .claude ? "\(bin) \(flag) --resume \(quote(session))"
                                         : "\(bin) \(flag) resume \(quote(session))"
        }
        return "\(bin) \(flag) \"$(cat \(quote(promptFile ?? "/dev/null")))\""
    }

    /// The server's command: attach to (or start) the task's tmux session there as its agent user.
    static func serverLine(_ task: Task, env: [String: String]) throws -> String {
        guard let host = task.sshHost, let user = task.sshUser else {
            throw refused("the task doesn't say how to reach its server (server.ssh and server.user)")
        }
        return [program("ssh", env: env), "-t", host, "sudo", "-iu", user, "umi-link", "attach", task.id].map(quote).joined(separator: " ")
    }

    /// Lines printed at the top of the pane, before the command.
    static func noteLine(_ notes: [String]) -> String? {
        notes.isEmpty ? nil : "printf '%s\\n' " + notes.map { quote("Umi: " + $0) }.joined(separator: " ")
    }

    struct Plan {
        var place: Task.Place
        var folder: String?
        var notes: [String]
        var prompt: String?
    }

    /// Where and how the task runs here: on this Mac in its local folder, or on the server.
    static func plan(_ task: Task, best: URL) -> Plan {
        if task.place == .server { return Plan(place: .server, folder: nil, notes: [], prompt: nil) }
        guard let folder = localFolder(for: task, best: best) else {
            return Plan(place: .server, folder: nil,
                        notes: ["no folder for \(task.folder) on this Mac, so this task runs on the server."], prompt: nil)
        }
        var notes: [String] = []
        var prompt = task.prompt
        if let branch = task.branch, let current = currentBranch(of: folder), current != branch {
            let note = "This task is on branch \(branch); the checkout at \(folder.path) is on \(current). The branch wasn't switched."
            if prompt != nil { prompt = note + "\n\n" + prompt! } else { notes.append(note) }
        }
        return Plan(place: .mac, folder: folder.path, notes: notes, prompt: prompt)
    }

    // MARK: Opening

    static var bestFolder: URL {
        if let dir = ProcessInfo.processInfo.environment["UMI_TEST_BEST_DIR"], !dir.isEmpty {   // tests only
            return URL(fileURLWithPath: dir)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("best")
    }

    static func fetch(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let session = URLSession(configuration: .ephemeral)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw UmiError.failed("couldn't fetch the task from \(url.absoluteString): \(error.localizedDescription)")
        }
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw UmiError.failed("couldn't fetch the task from \(url.absoluteString): HTTP \(http.statusCode)")
        }
        guard data.count <= 1_000_000 else { throw refused("the task is larger than 1 MB") }
        return data
    }

    /// Open a link: fetch its task and start it in a new tab in front. Returns what `umi link` prints.
    static func open(_ link: URL) async throws -> [String: Any] {
        let taskURL = try taskURL(from: link, origins: UmiWebPanes.origins)
        let task = try parseTask(try await fetch(taskURL))
        let env = ProcessInfo.processInfo.environment
        let plan = plan(task, best: bestFolder)

        var line: String
        switch plan.place {
        case .mac:
            var promptFile: String?
            if let prompt = plan.prompt {
                let dir = UmiPaths.directory("links")
                let path = (dir as NSString).appendingPathComponent("\(task.id).prompt")
                FileManager.default.createFile(atPath: path, contents: Data(prompt.utf8), attributes: [.posixPermissions: 0o600])
                promptFile = path
            }
            line = agentLine(task, promptFile: promptFile, env: env)
        case .server:
            line = try serverLine(task, env: env)
        }
        if let notes = noteLine(plan.notes) { line = notes + "; " + line }

        var options = UmiLayout.PaneOptions()
        options.cwd = plan.folder ?? FileManager.default.homeDirectoryForCurrentUser.path
        options.input = line + "\n"
        let result: [String: Any]
        if let window = UmiTopology.currentWindow {
            result = try UmiLayout.newTab(in: window, options: options, tabName: task.title, color: .none,
                                          index: nil, focus: true, inheritFrom: nil)
        } else {
            result = try UmiLayout.newWindow(options, tabName: task.title, focus: true, inheritFrom: nil)
        }
        NSApp.activate(ignoringOtherApps: true)
        var out = result
        out["task"] = task.id
        out["title"] = task.title
        out["where"] = plan.place.rawValue
        out["folder"] = plan.folder ?? NSNull()
        out["notes"] = plan.notes
        out["command"] = line
        UmiEvents.shared.emit("link.opened", out)
        return out
    }

    /// A link from outside the CLI (LaunchServices, a ⌘-click, a page): open it, or say why not
    /// in a note at the top of the window.
    static func handle(_ link: URL) {
        _Concurrency.Task { @MainActor in
            do {
                _ = try await open(link)
            } catch {
                let why = (error as? UmiError)?.message ?? error.localizedDescription
                UmiEvents.shared.emit("link.refused", ["url": link.absoluteString, "reason": why])
                if UmiTopology.currentWindow != nil { NSApp.activate(ignoringOtherApps: true) }
                UmiToast.show(why, near: UmiTopology.currentPane, warning: true)
            }
        }
    }

    static func isLink(_ url: URL) -> Bool { url.scheme?.lowercased() == "umi" }

    /// The user's own Umi (the installed app, `dev.umi.app`, not an isolated instance) makes itself
    /// the handler of `umi://` at launch. Otherwise LaunchServices may send links to any other copy
    /// that declares the scheme: a dev or test build, or an old release in a build folder.
    static func claimScheme() {
        guard !UmiPaths.isIsolated, Bundle.main.bundleIdentifier == "dev.umi.app" else { return }
        let me = Bundle.main.bundleURL.standardizedFileURL
        let current = NSWorkspace.shared.urlForApplication(toOpen: URL(string: "umi://open")!)?.standardizedFileURL
        guard current != me else { return }
        NSWorkspace.shared.setDefaultApplication(at: me, toOpenURLsWithScheme: "umi") { error in
            let detail: [String: Any] = ["app": me.path, "was": current?.path ?? NSNull(),
                                         "error": error.map { $0.localizedDescription } ?? NSNull()]
            DispatchQueue.main.async { MainActor.assumeIsolated { UmiEvents.shared.emit("link.handler", detail) } }
        }
    }

    /// A link ⌘-clicked in a terminal pane: a session link is handled on the next turn of the main
    /// loop (the click arrives while the terminal is still handling its mouse event). False for
    /// every other link.
    static func openFromTerminal(_ raw: String) -> Bool {
        guard let url = URL(string: raw), isLink(url) else { return false }
        DispatchQueue.main.async { MainActor.assumeIsolated { handle(url) } }
        return true
    }
}
