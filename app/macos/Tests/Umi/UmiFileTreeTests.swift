import Foundation
import Testing
@testable import Ghostty

/// The project explorer's folders (SPEC S-2): reading a folder off the main thread gives the same
/// entries in the same order as before, and taking a new read keeps what the user did to the
/// nodes already known.
@MainActor
struct UmiFileTreeTests {
    private func folder(_ names: [String], dirs: [String] = []) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("umi-tree-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        for name in names { try Data().write(to: url.appendingPathComponent(name)) }
        for name in dirs {
            try FileManager.default.createDirectory(at: url.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        return url
    }

    @Test func readSortsAsWarpAndHidesWhatTheExplorerHides() throws {
        let url = try folder(["b.txt", "file10.md", "file2.md", ".env", ".DS_Store", "A.txt"],
                             dirs: ["src", ".github", ".git", "lib"])
        defer { try? FileManager.default.removeItem(at: url) }
        let entries = UmiFileNode.read(url)
        #expect(entries.map(\.name) == [".github", "lib", "src", ".env", "A.txt", "b.txt", "file2.md", "file10.md"])
        #expect(entries.map(\.isDirectory) == [true, true, true, false, false, false, false, false])
    }

    @Test func aNewReadKeepsKnownNodesAndTheirState() throws {
        let url = try folder(["one.txt"], dirs: ["src"])
        defer { try? FileManager.default.removeItem(at: url) }
        let root = UmiFileNode(url: url, isDirectory: true)
        root.loadChildren()
        let src = try #require(root.children?.first { $0.name == "src" })
        src.expanded = true
        src.loadChildren()
        let generation = root.generation

        try Data().write(to: url.appendingPathComponent("two.txt"))
        try FileManager.default.removeItem(at: url.appendingPathComponent("one.txt"))
        root.apply(UmiFileNode.read(url))
        #expect(root.children?.map(\.name) == ["src", "two.txt"])
        #expect(root.children?.first === src, "the folder's node, with its open state, is kept")
        #expect(src.expanded)
        #expect(root.generation != generation, "a read is told apart from the one before")
    }

    @Test func aStaleFolderIsReadAgainWhenNextLoaded() throws {
        let url = try folder(["one.txt"])
        defer { try? FileManager.default.removeItem(at: url) }
        let node = UmiFileNode(url: url, isDirectory: true)
        node.loadChildren()
        try Data().write(to: url.appendingPathComponent("two.txt"))
        node.loadChildren()
        #expect(node.children?.count == 1, "a folder already read isn't read again unasked")
        node.stale = true
        node.loadChildren()
        #expect(node.children?.map(\.name) == ["one.txt", "two.txt"])
        #expect(!node.stale)
    }

    private func names(in model: UmiFileTreeModel, under folder: URL) -> [String] {
        let real = UmiFileTreeModel.realURL(folder).path
        return model.rows.filter { $0.url.deletingLastPathComponent().path == real }.map { $0.url.lastPathComponent }
    }

    /// Review finding 1: a folder left open inside a closed one, changed while hidden by its
    /// parent, shows what's on disk when the parent opens again.
    @Test func openingAFolderShowsCurrentEntriesOfTheOpenFoldersInside() throws {
        let url = UmiFileTreeModel.realURL(try folder(["top.txt"], dirs: ["src/lib"]))
        defer { try? FileManager.default.removeItem(at: url) }
        let src = url.appendingPathComponent("src"), lib = src.appendingPathComponent("lib")
        try Data().write(to: lib.appendingPathComponent("old.py"))
        let model = UmiFileTreeModel(watchesFiles: false)
        model.start()
        defer { model.stop() }
        model.setRoot(url)
        model.setExpanded(src, true, byUser: true)
        model.setExpanded(lib, true, byUser: true)
        #expect(names(in: model, under: lib) == ["old.py"])
        model.setExpanded(src, false, byUser: true)
        try Data().write(to: lib.appendingPathComponent("new.py"))
        try FileManager.default.removeItem(at: lib.appendingPathComponent("old.py"))
        model.filesChanged([UmiFSWatcher.Event(path: lib.path, flags: 0)])
        model.setExpanded(src, true, byUser: true)
        #expect(names(in: model, under: lib) == ["new.py"], "lib, still open, shows its current entries")
    }

    /// Review finding 2: hidden and shown again while a background read is in flight, the old
    /// read doesn't stand for the folder; what changed while hidden shows.
    @Test func showingAgainDuringABackgroundReadShowsChangesMadeWhileHidden() async throws {
        let url = UmiFileTreeModel.realURL(try folder(["old.txt"]))
        defer { try? FileManager.default.removeItem(at: url) }
        let model = UmiFileTreeModel(watchesFiles: false)
        model.start()
        defer { model.stop() }
        model.setRoot(url)
        // A background read of the root, held back from the main thread: it finishes reading
        // (blocking keeps the main actor busy) before anything else happens.
        model.filesChanged([UmiFSWatcher.Event(path: url.path, flags: 0)])
        blockMainThread(seconds: 0.3)
        model.stop()
        try Data().write(to: url.appendingPathComponent("hidden.txt"))
        model.start()
        for _ in 0..<40 {
            if names(in: model, under: url).contains("hidden.txt") { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        #expect(names(in: model, under: url) == ["hidden.txt", "old.txt"])
        #expect(model.root?.stale == false)
    }

    private func blockMainThread(seconds: TimeInterval) { Thread.sleep(forTimeInterval: seconds) }

    @Test func loadedFoldersSayWhichAreShown() throws {
        let url = try folder([], dirs: ["a/inner", "b"])
        defer { try? FileManager.default.removeItem(at: url) }
        let root = UmiFileNode(url: url, isDirectory: true)
        root.expanded = true
        root.loadChildren()
        let a = try #require(root.children?.first { $0.name == "a" })
        a.loadChildren()   // read, but closed
        let inner = try #require(a.children?.first)
        inner.expanded = true
        inner.loadChildren()
        var all: [(node: UmiFileNode, shown: Bool)] = []
        root.loadedFolders(into: &all)
        let shown = Dictionary(uniqueKeysWithValues: all.map { ($0.node.name, $0.shown) })
        #expect(shown == [url.lastPathComponent: true, "a": false, "inner": false],
                "b was never read; a is closed, so neither it nor inner shows entries")
    }
}
