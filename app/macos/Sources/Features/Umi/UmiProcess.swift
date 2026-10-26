import Darwin
import Foundation

/// What Umi reads about a pane's processes (its folder, its foreground program).
enum UmiProcess {
    static let shells: Set<String> = ["zsh", "bash", "fish", "sh", "dash", "ksh", "tcsh", "csh", "nu", "elvish", "xonsh", "login"]

    /// A process's current folder (nil for processes we can't inspect, like root's `login`).
    static func cwd(_ pid: pid_t) -> String? {
        guard pid > 0 else { return nil }
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafeBytes(of: &info.pvi_cdir.vip_path) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
        return path.isEmpty ? nil : path
    }

    static func name(_ pid: pid_t) -> String? {
        // proc_name fails outright with a buffer of MAXCOMLEN + 1 (it wants room for the longer
        // name it may return).
        var buffer = [CChar](repeating: 0, count: 2 * Int(MAXCOMLEN) + 1)
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
