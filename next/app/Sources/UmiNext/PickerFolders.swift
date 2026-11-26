import Foundation

/// The session picker's folder search: `proj`'s list of projects, and browsing a typed path.
struct PickerFolders {
    private let fm = FileManager.default
    private var allowed: [String: Bool] = ["/": true]

    private mutating func allows(_ path: String) -> Bool {
        if let result = allowed[path] { return result }
        let dir = path as NSString
        let name = dir.lastPathComponent
        let result = path != "/private/tmp" && path != "/tmp"
            && name != ".worktrees" && name != "worktrees"
            && allows(dir.deletingLastPathComponent)
            && !isLinkedWorktree(path)
        allowed[path] = result
        return result
    }

    private func isLinkedWorktree(_ path: String) -> Bool {
        let marker = URL(fileURLWithPath: path, isDirectory: true).appendingPathComponent(".git")
        var directory: ObjCBool = false
        guard fm.fileExists(atPath: marker.path, isDirectory: &directory), !directory.boolValue,
              let text = try? String(contentsOf: marker, encoding: .utf8), text.hasPrefix("gitdir: ") else { return false }
        // A submodule also has a .git file. Only a linked worktree has its own Git admin
        // directory with a commondir pointing back to the repository.
        let target = String(text.dropFirst(8)).trimmingCharacters(in: .whitespacesAndNewlines)
        let admin = URL(fileURLWithPath: target, isDirectory: true, relativeTo: marker.deletingLastPathComponent())
        return fm.fileExists(atPath: admin.appendingPathComponent("commondir").path)
    }

    private mutating func includes(_ path: String) -> Bool {
        guard path.hasPrefix("/") else { return false }
        let url = URL(fileURLWithPath: path, isDirectory: true)
        return allows(url.standardizedFileURL.path) && allows(url.resolvingSymlinksInPath().standardizedFileURL.path)
    }

    private mutating func children(_ path: String, hidden: Bool = false) throws -> [String] {
        let urls = try fm.contentsOfDirectory(at: URL(fileURLWithPath: path, isDirectory: true),
            includingPropertiesForKeys: nil, options: hidden ? [] : [.skipsHiddenFiles])
        return urls.compactMap { url in
            var directory: ObjCBool = false
            guard url.lastPathComponent != ".git", fm.fileExists(atPath: url.path, isDirectory: &directory),
                  directory.boolValue, includes(url.path) else { return nil }
            return url.path
        }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    mutating func browse(_ path: String, hidden: Bool) throws -> [String: Any] {
        guard includes(path) else { return ["excluded": true, "names": [String]()] }
        return ["names": try children(path, hidden: hidden).map { ($0 as NSString).lastPathComponent }]
    }

    /// The folders `proj` offers (proj --list --here run in `cwd`): each area's folders and
    /// projects/ folders and the orgs, newest first, the area `cwd` is in first. `proj` comes from
    /// the login shell's PATH, or UMI_NEXT_PROJ.
    func projects(cwd: String) throws -> [String: Any] {
        let r = Self.proj(["--list", "--here"], cwd: cwd)
        guard r.status == 0 else { throw WebServices.Failure(code: "proj", message: r.err.isEmpty ? "proj --list failed" : r.err) }
        let best = NSHomeDirectory() + "/best"
        return ["paths": r.out.split(separator: "\n").map { best + "/" + $0 }]
    }

    /// Creates a dated project with `proj NAME --repo-later` from ~/best. The picker always names
    /// where: `work/name` goes to work/projects/, `orgs/aim/name` into that org, `systems/umi/name`
    /// into that folder. A new org's GitHub repo is made in the background.
    func createProject(_ name: String) throws -> [String: Any] {
        let cdFile = NSTemporaryDirectory() + "umi-next-proj-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: cdFile) }
        let r = Self.proj([name, "--repo-later"], cwd: NSHomeDirectory() + "/best", env: ["PROJ_CD_FILE": cdFile])
        let dir = (try? String(contentsOfFile: cdFile, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard r.status == 0, !dir.isEmpty else {
            throw WebServices.Failure(code: "proj", message: (r.err + r.out).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return ["path": dir, "output": r.out]
    }

    private static func proj(_ args: [String], cwd: String, env extra: [String: String] = [:]) -> (status: Int32, out: String, err: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", "command \"${UMI_NEXT_PROJ:-proj}\" \"$@\"", "proj"] + args
        p.currentDirectoryURL = URL(fileURLWithPath: cwd)
        p.environment = ProcessInfo.processInfo.environment.merging(extra) { _, new in new }
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return (-1, "", "\(error)") }
        let o = out.fileHandleForReading.readDataToEndOfFile(), e = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: o, as: UTF8.self), String(decoding: e, as: UTF8.self))
    }
}
