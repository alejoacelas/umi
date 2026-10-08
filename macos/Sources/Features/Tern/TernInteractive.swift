import AppKit
import GhosttyKit

/// `tern claude …` / `tern codex …`: a pane whose shell gets the command typed into it,
/// exactly as if the user had typed it into a fresh terminal (IA-1). Tern doesn't control
/// the agent afterwards; it only notes when it exits (IA-2).
@MainActor
enum TernInteractive {
    static func launch(_ params: TernParams, caller: TernCaller) throws -> [String: Any] {
        guard let kind = params.string("kind"), ["claude", "codex"].contains(kind) else {
            throw TernError.badRequest("unknown agent kind (use claude or codex)")
        }
        guard let line = params.string("line"), !line.isEmpty else { throw TernError.badRequest("nothing to run") }
        var options = TernLayout.PaneOptions(params)
        options.input = line + "\n"
        options.command = nil
        let name = options.name
        let focus = params.bool("focus") ?? true

        let result: [String: Any]
        switch params.string("placement") ?? "tab" {
        case "split":
            options.name = name
            let target = try TernTopology.pane(params.string("pane"), caller: caller)
            result = try TernLayout.split(target, direction: try TernLayout.direction(params.string("direction")),
                                          options: options, ratio: nil, focus: focus)
        case "window":
            options.name = nil
            result = try TernLayout.newWindow(options, tabName: name, focus: focus)
        default:
            options.name = nil
            let window: TerminalController?
            if let selector = params.string("window") {
                window = try TernTopology.resolveWindow(selector, caller: caller)
            } else if let selector = params.string("pane") {
                window = TernTopology.locate(try TernTopology.resolvePane(selector, caller: caller))?.window
            } else if let callerPane = try TernTopology.callerPane(caller) {
                window = TernTopology.locate(callerPane)?.window
            } else {
                window = TernTopology.currentWindow
            }
            if let window {
                result = try TernLayout.newTab(in: window, options: options, tabName: name, color: .none,
                                               index: nil, focus: focus, inheritFrom: nil)
            } else {
                result = try TernLayout.newWindow(options, tabName: name, focus: focus)
            }
        }

        if let paneID = result["pane"] as? String,
           let pane = TernTopology.allSurfaces.first(where: { $0.ternID == paneID }) {
            TernState.shared.setInteractiveAgent(pane.id, TernInteractiveAgent(kind: kind, commandLine: line, running: true))
            watch(pane)
            TernEvents.shared.emit("agent.interactive.started", ["pane": paneID, "kind": kind, "command": line])
        }
        var out = result
        out["command"] = line
        return out
    }

    // MARK: Noticing the exit

    /// Panes whose agent we saw running in the foreground (so a shell prompt afterwards
    /// means it exited, not that it hasn't started yet).
    private static var seenRunning: Set<UUID> = []
    private static var timer: Timer?

    /// The shell reported that a command finished (OSC 133). The first command a launch
    /// pane runs is the agent, so this is the agent exiting. Later commands in the pane are
    /// never taken for the agent.
    static func commandFinished(_ pane: Ghostty.SurfaceView, exitCode: Int?) {
        guard var agent = TernState.shared.interactiveAgents[pane.id], agent.running else { return }
        agent.running = false
        agent.exitCode = exitCode
        TernState.shared.setInteractiveAgent(pane.id, agent)
        seenRunning.remove(pane.id)
        TernEvents.shared.emit("agent.interactive.exited", ["pane": pane.ternID, "kind": agent.kind, "exit_code": exitCode ?? -1])
    }

    /// Without shell integration there's no command-finished report: watch the pane's
    /// foreground process instead.
    private static func watch(_ pane: Ghostty.SurfaceView) {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            MainActor.assumeIsolated { poll() }
        }
    }

    private static func poll() {
        let running = TernState.shared.interactiveAgents.filter { $0.value.running }
        if running.isEmpty {
            timer?.invalidate()
            timer = nil
            return
        }
        let panes = TernTopology.allSurfaces
        for (id, agent) in running {
            guard let pane = panes.first(where: { $0.id == id }), let surface = pane.surface else { continue }
            let foreground = pid_t(truncatingIfNeeded: ghostty_surface_foreground_pid(surface))
            guard foreground > 0 else { continue }
            let atShell = TernProcess.isShell(foreground)
            if !atShell {
                seenRunning.insert(id)
            } else if seenRunning.contains(id) {
                var exited = agent
                exited.running = false
                TernState.shared.setInteractiveAgent(id, exited)
                seenRunning.remove(id)
                TernEvents.shared.emit("agent.interactive.exited", ["pane": pane.ternID, "kind": agent.kind])
            }
        }
    }
}

/// Process facts from the kernel.
enum TernProcess {
    static let shells: Set<String> = ["zsh", "bash", "fish", "sh", "dash", "ksh", "tcsh", "csh", "nu", "elvish", "xonsh", "login"]

    static func name(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXCOMLEN) + 1)
        guard proc_name(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }

    /// Whether a terminal's foreground process is its shell (at the prompt). The shell runs
    /// under a root-owned `login` whose process group it keeps, and whose name we can't
    /// read; commands the user runs are theirs and readable.
    static func isShell(_ pid: pid_t) -> Bool {
        guard let name = name(pid) else { return true }
        let bare = name.hasPrefix("-") ? String(name.dropFirst()) : name
        return shells.contains(bare)
    }

    /// A process's argument vector (via KERN_PROCARGS2).
    static func arguments(_ pid: pid_t) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        let argc = buffer.withUnsafeBytes { Int($0.load(as: Int32.self)) }
        var index = MemoryLayout<Int32>.size
        while index < size, buffer[index] != 0 { index += 1 }
        while index < size, buffer[index] == 0 { index += 1 }
        var args: [String] = []
        while args.count < argc, index < size {
            let start = index
            while index < size, buffer[index] != 0 { index += 1 }
            args.append(String(decoding: buffer[start..<index], as: UTF8.self))
            index += 1
        }
        return args
    }
}
