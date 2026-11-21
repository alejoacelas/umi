import Foundation

/// Directory discovery for the session picker's folder search. The explorer can still browse
/// these locations. Each request shares ancestry checks across its candidates.
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

    mutating func suggestions(_ seeds: [String]) -> [String] {
        let home = NSHomeDirectory()
        let seeds = seeds.filter { includes($0) }
        var parents: [String] = [], visited = Set<String>()
        func addParent(_ path: String) {
            if visited.insert(path).inserted { parents.append(path) }
        }
        // Nearby workspace folders. Never traverse every child of home for suggestions.
        var expanded = Set<String>()
        for seed in seeds {
            let up = (seed as NSString).deletingLastPathComponent
            let top = (up as NSString).deletingLastPathComponent
            if up == home || up.hasPrefix(home + "/") { addParent(up) }
            if top.hasPrefix(home + "/"), expanded.insert(top).inserted {
                for folder in (try? children(top)) ?? [] { addParent(folder) }
            }
        }
        var result = seeds
        for folder in parents.prefix(60) { result += (try? children(folder)) ?? [] }
        result += parents.prefix(60)
        var seen = Set<String>()
        return result.filter { seen.insert($0).inserted }
    }
}
