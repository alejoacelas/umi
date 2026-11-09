import Darwin
import Foundation

/// The processes on this Mac, as the kernel reports them: what runs in front of a pane's
/// terminal and what it started (the quiet moment, I-4), and a process's environment
/// (KERN_PROCARGS2: an agent's configuration folder).
enum UmiProcessTree {
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
        UmiPerf.measure("process scan") { scan(everyone: everyone) }
    }

    private static func scan(everyone: Bool) -> [Info] {
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
}
