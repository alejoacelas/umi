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
