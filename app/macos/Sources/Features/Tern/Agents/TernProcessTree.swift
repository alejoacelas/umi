import Darwin
import Foundation

/// Finding and stopping every process started for a session (MA-9, R-1).
///
/// A harness runs as the leader of its own session and process group, and everything it
/// starts inherits its environment, which carries `TERN_SESSION_ID` and `TERN_STATE_DIR`.
/// Commands that detach (`setsid`, double fork, reparented to launchd) leave the process
/// group but keep the environment, so the environment is what finds them, through the
/// kernel's copy of each process's arguments and environment (KERN_PROCARGS2). Process
/// groups and parent links catch the rest.
enum TernProcessTree {
    struct Info {
        let pid: pid_t
        let ppid: pid_t
        let pgid: pid_t
        /// Its controlling terminal, and that terminal's foreground process group.
        let tdev: dev_t
        let tpgid: pid_t
        let zombie: Bool
        let start: timeval
    }

    /// Every process of this user (`everyone`: of every user, for links through root-owned
    /// processes such as `login`).
    static func all(everyone: Bool = false) -> [Info] {
        var mib: [Int32] = everyone ? [CTL_KERN, KERN_PROC, KERN_PROC_ALL] : [CTL_KERN, KERN_PROC, KERN_PROC_UID, Int32(getuid())]
        let length = u_int(mib.count)
        var size = 0
        guard sysctl(&mib, length, nil, &size, nil, 0) == 0, size > 0 else { return [] }
        let stride = MemoryLayout<kinfo_proc>.stride
        var buffer = [kinfo_proc](repeating: kinfo_proc(), count: size / stride + 16)
        size = buffer.count * stride
        guard sysctl(&mib, length, &buffer, &size, nil, 0) == 0 else { return [] }
        let count = size / stride
        return buffer.prefix(count).map { p in
            Info(pid: p.kp_proc.p_pid, ppid: p.kp_eproc.e_ppid, pgid: p.kp_eproc.e_pgid, tdev: p.kp_eproc.e_tdev, tpgid: p.kp_eproc.e_tpgid,
                 zombie: p.kp_proc.p_stat == 5 /* SZOMB */, start: p.kp_proc.p_un.__p_starttime)
        }
    }

    /// The foreground process group of a terminal (`/dev/ttysNNN`), read from the processes it
    /// controls (the pty's master side can't say on macOS). Nil if none is found.
    static func foregroundGroup(ofTerminal tty: String) -> pid_t? {
        var info = stat()
        guard stat(tty, &info) == 0 else { return nil }
        let device = info.st_rdev
        return all(everyone: true).first { $0.tdev == device && $0.tpgid > 0 }?.tpgid
    }

    /// A process's environment, or nil if the kernel won't tell (another user, gone).
    static func environment(_ pid: pid_t) -> [String: String]? {
        guard pid > 0 else { return nil }
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        let argc = buffer.withUnsafeBytes { Int($0.load(as: Int32.self)) }
        var index = MemoryLayout<Int32>.size
        // The executable path, then padding.
        while index < size, buffer[index] != 0 { index += 1 }
        while index < size, buffer[index] == 0 { index += 1 }
        // argv
        var seen = 0
        while seen < argc, index < size {
            while index < size, buffer[index] != 0 { index += 1 }
            index += 1
            seen += 1
        }
        var env: [String: String] = [:]
        while index < size {
            let start = index
            while index < size, buffer[index] != 0 { index += 1 }
            if index == start { break }
            let entry = String(decoding: buffer[start..<index], as: UTF8.self)
            if let eq = entry.firstIndex(of: "=") {
                env[String(entry[..<eq])] = String(entry[entry.index(after: eq)...])
            }
            index += 1
        }
        return env
    }

    /// Processes started for sessions of this instance: their environment names this
    /// state directory and one of these sessions (all sessions when `sessions` is nil).
    static func tagged(sessions: Set<String>?, stateDir: String, excluding: Set<pid_t> = []) -> [(pid: pid_t, session: String)] {
        let me = getpid()
        var out: [(pid_t, String)] = []
        for info in all() where info.pid != me && !info.zombie && !excluding.contains(info.pid) {
            guard let env = environment(info.pid),
                  let session = env["TERN_SESSION_ID"], !session.isEmpty,
                  env["TERN_STATE_DIR"] == stateDir else { continue }
            if let sessions, !sessions.contains(session) { continue }
            out.append((info.pid, session))
        }
        return out
    }

    /// Descendants of a process (by parent links, as of now).
    static func descendants(of root: pid_t, in infos: [Info]? = nil) -> [pid_t] {
        let list = infos ?? all()
        var children: [pid_t: [pid_t]] = [:]
        for info in list { children[info.ppid, default: []].append(info.pid) }
        var out: [pid_t] = []
        var queue = [root]
        while let pid = queue.popLast() {
            for child in children[pid] ?? [] where child != root {
                out.append(child)
                queue.append(child)
            }
        }
        return out
    }

    static func members(ofGroup pgid: pid_t, in infos: [Info]? = nil) -> [pid_t] {
        guard pgid > 1 else { return [] }
        return (infos ?? all()).filter { $0.pgid == pgid && !$0.zombie }.map(\.pid)
    }

    static func isAlive(_ pid: pid_t) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid, 0) != 0 { return errno == EPERM }
        // A zombie still answers kill(0).
        return !(all().first { $0.pid == pid }?.zombie ?? false)
    }

    /// Members of the process group a harness led, once the harness itself is gone. A process
    /// id isn't reused while a group with that id exists, so if no process has the group's id
    /// the members are the harness's leftovers (children that cleared their environment
    /// included). If a process has that id, it is the live harness (counted elsewhere) or an
    /// unrelated process that reused the id: the group isn't touched.
    static func orphanedGroup(_ pgid: pid_t, in infos: [Info]) -> [pid_t] {
        guard pgid > 1, !infos.contains(where: { $0.pid == pgid && !$0.zombie }) else { return [] }
        return members(ofGroup: pgid, in: infos)
    }

    /// Everything that belongs to a session right now: its harness's group and descendants,
    /// the group a harness that already exited left behind, and any process carrying the
    /// session's tag.
    static func sessionProcesses(session: String, stateDir: String, harness: pid_t?, exitedHarness: pid_t? = nil) -> Set<pid_t> {
        let infos = all()
        var pids = Set<pid_t>()
        if let harness, harness > 1 {
            pids.insert(harness)
            pids.formUnion(members(ofGroup: harness, in: infos))
            pids.formUnion(descendants(of: harness, in: infos))
        }
        if let exitedHarness {
            pids.formUnion(orphanedGroup(exitedHarness, in: infos))
        }
        let me = getpid()
        for info in infos where info.pid != me && !info.zombie {
            if pids.contains(info.pid) { continue }
            if let env = environment(info.pid), env["TERN_SESSION_ID"] == session, env["TERN_STATE_DIR"] == stateDir {
                pids.insert(info.pid)
                pids.formUnion(descendants(of: info.pid, in: infos))
            }
        }
        pids.remove(me)
        pids.remove(0)
        pids.remove(1)
        return pids
    }

    /// SIGTERM, then SIGKILL whatever is left after `grace` seconds. Process groups led by
    /// these processes get the same signals. Blocks for at most `grace` + a little.
    static func terminate(_ pids: Set<pid_t>, grace: TimeInterval) {
        guard !pids.isEmpty else { return }
        for pid in pids {
            kill(pid, SIGTERM)
            kill(-pid, SIGTERM)
        }
        let deadline = Date().addingTimeInterval(grace)
        while Date() < deadline {
            if !pids.contains(where: { isAliveCheap($0) }) { return }
            usleep(50_000)
        }
        for pid in pids {
            kill(-pid, SIGKILL)
            kill(pid, SIGKILL)
        }
    }

    static func killNow(_ pids: Set<pid_t>) {
        for pid in pids {
            kill(-pid, SIGKILL)
            kill(pid, SIGKILL)
        }
    }

    /// kill(0) without the zombie check (a zombie is as good as gone for signalling).
    private static func isAliveCheap(_ pid: pid_t) -> Bool {
        if kill(pid, 0) == 0 { return !isZombie(pid) }
        return errno == EPERM
    }

    private static func isZombie(_ pid: pid_t) -> Bool {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return false }
        return info.kp_proc.p_stat == 5
    }
}
