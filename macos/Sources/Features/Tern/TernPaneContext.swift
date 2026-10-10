import Darwin
import Foundation
import GhosttyKit

/// What a pane is doing, for the sidebar: its folder, git branch or linked worktree, and
/// the command it is running (or last ran).
@MainActor
enum TernPaneContext {
    struct Git: Equatable {
        let branch: String
        /// Name of the linked worktree, nil for the main checkout.
        let worktree: String?
    }

    struct Command {
        let text: String
        let running: Bool
    }

    private static var gitCache: [String: (info: Git?, at: Date)] = [:]

    // MARK: Folder and git

    static func folderName(_ cwd: String) -> String {
        if cwd == NSHomeDirectory() { return "~" }
        let name = (cwd as NSString).lastPathComponent
        return name.isEmpty ? cwd : name
    }

    /// Branch for a directory, read straight from `.git` (no subprocess) and cached for a
    /// couple of seconds.
    static func git(for cwd: String) -> Git? {
        if let cached = gitCache[cwd], Date().timeIntervalSince(cached.at) < 2 { return cached.info }
        let info = readGit(cwd)
        if gitCache.count > 256 { gitCache.removeAll() }
        gitCache[cwd] = (info, Date())
        return info
    }

    private static func readGit(_ cwd: String) -> Git? {
        let fm = FileManager.default
        var dir = URL(fileURLWithPath: cwd).standardizedFileURL
        while true {
            let dotGit = dir.appendingPathComponent(".git")
            var isDirectory = ObjCBool(false)
            if fm.fileExists(atPath: dotGit.path, isDirectory: &isDirectory) {
                var gitDir = dotGit
                var worktree: String?
                if !isDirectory.boolValue {
                    // Linked worktree (or submodule): `.git` is a file naming the real git dir.
                    guard let content = try? String(contentsOf: dotGit, encoding: .utf8),
                          let line = content.split(separator: "\n").first(where: { $0.hasPrefix("gitdir:") }) else {
                        return nil
                    }
                    let path = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
                    gitDir = URL(fileURLWithPath: path, relativeTo: dir).standardizedFileURL
                    if gitDir.deletingLastPathComponent().lastPathComponent == "worktrees" {
                        worktree = dir.lastPathComponent
                    }
                }
                guard let head = try? String(contentsOf: gitDir.appendingPathComponent("HEAD"), encoding: .utf8)
                    .trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
                if head.hasPrefix("ref: ") {
                    let ref = String(head.dropFirst("ref: ".count))
                    let branch = ref.hasPrefix("refs/heads/") ? String(ref.dropFirst("refs/heads/".count)) : ref
                    return Git(branch: branch, worktree: worktree)
                }
                return Git(branch: String(head.prefix(7)), worktree: worktree)
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { return nil }
            dir = parent
        }
    }

    // MARK: Commands

    /// The command running in the pane, or the last one it ran (S-3, S-6).
    ///
    /// Ghostty's shell integration titles the pane with the command line while it runs (and
    /// with the folder at the prompt). Every title change is recorded as it happens, so even
    /// commands that finish instantly are seen. Without shell integration this falls back
    /// to the foreground process's arguments.
    static func command(for pane: Ghostty.SurfaceView) -> Command? {
        var running = false
        var foreground: pid_t = 0
        if let surface = pane.surface {
            foreground = pid_t(truncatingIfNeeded: ghostty_surface_foreground_pid(surface))
            running = foreground > 0 && !TernProcess.isShell(foreground)
        }
        if let last = TernCommandLog.shared.last(pane.id) {
            return Command(text: last.command, running: running && !last.finished)
        }
        if running, let args = TernProcess.arguments(foreground), !args.isEmpty {
            return Command(text: display(args), running: true)
        }
        return nil
    }

    /// The pane's shell has the terminal and shows its prompt (shell integration marks it;
    /// it's what Ghostty asks before closing a pane without confirmation).
    static func shellAtPrompt(_ pane: Ghostty.SurfaceView) -> Bool {
        guard let surface = pane.surface else { return true }
        let foreground = pid_t(truncatingIfNeeded: ghostty_surface_foreground_pid(surface))
        guard foreground <= 0 || TernProcess.isShell(foreground) else { return false }
        return !ghostty_surface_needs_confirm_quit(surface)
    }

    private static func display(_ args: [String]) -> String {
        var argv = args
        let interpreters: Set<String> = ["node", "python", "python3", "ruby", "bun", "deno", "perl"]
        if argv.count > 1, interpreters.contains((argv[0] as NSString).lastPathComponent) { argv.removeFirst() }
        argv[0] = (argv[0] as NSString).lastPathComponent
        let text = argv.joined(separator: " ")
        return text.count > 120 ? String(text.prefix(120)) + "…" : text
    }
}

/// The latest command each pane ran, fed from Ghostty's title changes (before display
/// debouncing) and command-finished reports.
final class TernCommandLog: @unchecked Sendable {
    static let shared = TernCommandLog()

    struct Entry {
        let command: String
        var finished: Bool
    }

    private let lock = NSLock()
    private var commands: [UUID: Entry] = [:]
    private var lastTitle: [UUID: String] = [:]

    /// A title change. Shell integration sets the title to the command line when a command
    /// starts and back to the folder at the prompt.
    func recordTitle(_ paneID: UUID, _ title: String) {
        lock.lock()
        defer { lock.unlock() }
        lastTitle[paneID] = title
        guard Self.isCommandLike(title) else {
            // Back at the prompt: whatever ran has finished.
            if var entry = commands[paneID] {
                entry.finished = true
                commands[paneID] = entry
            }
            return
        }
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        let value = trimmed.count > 160 ? String(trimmed.prefix(160)) + "…" : trimmed
        if commands.count > 4096 { commands.removeAll() }
        commands[paneID] = Entry(command: value, finished: false)
    }

    func commandFinished(_ paneID: UUID) {
        lock.lock()
        defer { lock.unlock() }
        if var entry = commands[paneID] {
            entry.finished = true
            commands[paneID] = entry
        }
    }

    func last(_ paneID: UUID) -> Entry? {
        lock.lock()
        defer { lock.unlock() }
        return commands[paneID]
    }

    /// Titles that are just a location (`~/src`, `/tmp`, `user@host:~`) or the shell's name
    /// aren't commands.
    static func isCommandLike(_ title: String) -> Bool {
        let t = title.trimmingCharacters(in: .whitespaces)
        if t.isEmpty || t == "👻" { return false }
        if t.hasPrefix("/") || t.hasPrefix("~") || t.hasPrefix("…") { return false }
        let bare = t.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        if TernProcess.shells.contains(t) || TernProcess.shells.contains(bare) { return false }
        if let at = t.firstIndex(of: "@"), let colon = t.firstIndex(of: ":"), at < colon, !t[..<at].contains(" ") {
            return false
        }
        return true
    }
}
