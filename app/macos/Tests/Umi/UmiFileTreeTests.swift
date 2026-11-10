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
        node.markChanged()
        node.loadChildren()
        #expect(node.children?.map(\.name) == ["one.txt", "two.txt"])
        #expect(!node.stale)
    }

    private func names(in model: UmiFileTreeModel, under folder: URL) -> [String] {
        let real = UmiFileTreeModel.realURL(folder).path
        return model.rows.filter { $0.url.deletingLastPathComponent().path == real }.map { $0.url.lastPathComponent }
    }

    /// Waits (on the main actor, so background results can land) until no folder is queued or
    /// being read.
    private func settle(_ model: UmiFileTreeModel) async throws {
        for _ in 0..<200 where model.readsPending {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        try #require(!model.readsPending, "the background reads end")
    }

    private func child(_ node: UmiFileNode?, _ name: String) -> UmiFileNode? {
        node?.children?.first { $0.name == name }
    }

    /// Reviews 1 and 2: a folder left open inside a closed one, changed while hidden by its parent,
    /// shows what's on disk once the parent opens again; it's read again in the background, not
    /// on the main thread while the parent opens, and keeps its node and open state.
    @Test func openingAFolderShowsCurrentEntriesOfTheOpenFoldersInside() async throws {
        let url = UmiFileTreeModel.realURL(try folder(["top.txt"], dirs: ["src/lib/deep"]))
        defer { try? FileManager.default.removeItem(at: url) }
        let src = url.appendingPathComponent("src"), lib = src.appendingPathComponent("lib")
        let deep = lib.appendingPathComponent("deep")
        try Data().write(to: lib.appendingPathComponent("old.py"))
        try Data().write(to: deep.appendingPathComponent("old.c"))
        let model = UmiFileTreeModel(watchesFiles: false)
        model.start()
        defer { model.stop() }
        model.setRoot(url)
        model.setExpanded(src, true, byUser: true)
        model.setExpanded(lib, true, byUser: true)
        model.setExpanded(deep, true, byUser: true)
        #expect(names(in: model, under: lib) == ["deep", "old.py"])
        let libNode = try #require(child(child(model.root, "src"), "lib"))
        let deepNode = try #require(child(libNode, "deep"))
        model.setExpanded(src, false, byUser: true)
        try Data().write(to: lib.appendingPathComponent("new.py"))
        try FileManager.default.removeItem(at: lib.appendingPathComponent("old.py"))
        try Data().write(to: deep.appendingPathComponent("new.c"))
        model.filesChanged([UmiFSWatcher.Event(path: lib.path, flags: 0),
                            UmiFSWatcher.Event(path: deep.path, flags: 0)])
        #expect(libNode.stale && deepNode.stale, "closed folders that changed are only marked")

        model.setExpanded(src, true, byUser: true)
        #expect(libNode.stale && deepNode.stale, "opening src doesn't read lib or deep on the main thread")
        #expect(model.readsPending, "they're read in the background")
        try await settle(model)
        #expect(names(in: model, under: lib) == ["deep", "new.py"], "lib, still open, shows its current entries")
        #expect(names(in: model, under: deep) == ["new.c", "old.c"], "and so does deep, open inside it")
        #expect(child(child(model.root, "src"), "lib") === libNode && child(libNode, "deep") === deepNode,
                "the nodes are kept")
        #expect(libNode.expanded && deepNode.expanded)
    }

    /// Review 2: revealing a file opens its folders; the folders left open inside them are read
    /// again in the background, and those on the way to the file at once (the file must be found).
    @Test func revealingAFileShowsCurrentEntriesOfTheOpenFoldersOnTheWay() async throws {
        let url = UmiFileTreeModel.realURL(try folder(["top.txt"], dirs: ["src/lib", "src/other"]))
        defer { try? FileManager.default.removeItem(at: url) }
        let src = url.appendingPathComponent("src"), lib = src.appendingPathComponent("lib")
        let other = src.appendingPathComponent("other")
        try Data().write(to: other.appendingPathComponent("old.txt"))
        let model = UmiFileTreeModel(watchesFiles: false)
        model.start()
        defer { model.stop() }
        model.setRoot(url)
        model.setExpanded(src, true, byUser: true)
        model.setExpanded(other, true, byUser: true)
        model.setExpanded(lib, true, byUser: true)
        let otherNode = try #require(child(child(model.root, "src"), "other"))
        model.setExpanded(src, false)   // not by the user, so revealing may open it again
        let target = lib.appendingPathComponent("made.py")
        try Data().write(to: target)
        try Data().write(to: other.appendingPathComponent("new.txt"))
        model.filesChanged([UmiFSWatcher.Event(path: lib.path, flags: 0),
                            UmiFSWatcher.Event(path: other.path, flags: 0)])

        model.reveal(target)
        #expect(model.selected?.path == target.path, "the file is found and selected at once")
        #expect(otherNode.stale, "src/other, open but off the way, isn't read on the main thread")
        try await settle(model)
        #expect(names(in: model, under: other) == ["new.txt", "old.txt"])
        #expect(model.selected?.path == target.path)
    }

    /// Review findings 1 (round 1) and 2 (round 2): hidden and shown again while a background read's
    /// result is on its way to the main thread, that result doesn't stand for the folder; what
    /// changed while hidden shows.
    @Test func showingAgainDuringABackgroundReadShowsChangesMadeWhileHidden() async throws {
        let url = UmiFileTreeModel.realURL(try folder(["old.txt"]))
        defer { try? FileManager.default.removeItem(at: url) }
        let model = UmiFileTreeModel(watchesFiles: false)
        model.start()
        defer { model.stop() }
        model.setRoot(url)
        // A background read of the root. Wait (blocking the main thread, so its result can't land)
        // until it has read the folder and sent the result to the main thread.
        let sent = DispatchSemaphore(value: 0)
        model.snapshotSent = { sent.signal() }
        model.filesChanged([UmiFSWatcher.Event(path: url.path, flags: 0)])
        try #require(waitBlocking(sent), "the background read sends its result")
        model.snapshotSent = nil
        model.stop()
        try Data().write(to: url.appendingPathComponent("hidden.txt"))
        model.start()
        try await settle(model)
        #expect(names(in: model, under: url) == ["hidden.txt", "old.txt"])
        #expect(model.root?.stale == false)
    }

    private func waitBlocking(_ semaphore: DispatchSemaphore) -> Bool {
        semaphore.wait(timeout: .now() + 5) == .success
    }

    /// Waits for a semaphore without holding the main thread, so results can land meanwhile.
    private func waitAsync(_ semaphore: DispatchSemaphore) async throws -> Bool {
        for _ in 0..<500 {
            if semaphore.wait(timeout: .now()) == .success { return true }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        return false
    }

    /// Review 4: a shown folder that keeps changing (a change notice during every background read)
    /// shows each read while the changes go on, not only once they stop.
    @Test func aShownFolderUnderSteadyChangeShowsEachRead() async throws {
        let url = UmiFileTreeModel.realURL(try folder(["top.txt"], dirs: ["src"]))
        defer { try? FileManager.default.removeItem(at: url) }
        let src = url.appendingPathComponent("src")
        let busy = src.appendingPathComponent("busy.log")
        try Data("0".utf8).write(to: busy)
        let model = UmiFileTreeModel(watchesFiles: false)
        model.start()
        defer { model.stop() }
        model.setRoot(url)
        model.setExpanded(src, true, byUser: true)
        let srcNode = try #require(child(model.root, "src"))
        // Each background read waits after its snapshot until let go, so the test knows where it is.
        let ready = DispatchSemaphore(value: 0), go = DispatchSemaphore(value: 0)
        model.resultReady = { ready.signal(); go.wait() }
        defer {
            model.resultReady = nil
            for _ in 0..<3 { go.signal() }
        }

        try Data().write(to: src.appendingPathComponent("marker.txt"))
        model.filesChanged([UmiFSWatcher.Event(path: src.path, flags: 0)])
        try #require(try await waitAsync(ready), "the first read takes its snapshot (with marker.txt)")
        for cycle in 1...5 {
            // The producer: a change, and its notice, while the read is under way.
            try Data("\(cycle)".utf8).write(to: busy)
            model.filesChanged([UmiFSWatcher.Event(path: src.path, flags: 0)])
            go.signal()
            // The read queued by that notice takes its snapshot only after the previous result
            // was handled on the main thread; it waits at the gate, so nothing else lands now.
            try #require(try await waitAsync(ready), "read \(cycle + 1) takes its snapshot")
            #expect(names(in: model, under: src) == ["busy.log", "marker.txt"],
                    "cycle \(cycle): marker.txt shows while the folder keeps changing")
            #expect(srcNode.stale, "cycle \(cycle): a change came after the read began")
        }
        // The producer stops: the last read lands and the folder is current.
        model.resultReady = nil
        go.signal()
        try await settle(model)
        #expect(names(in: model, under: src) == ["busy.log", "marker.txt"])
        #expect(!srcNode.stale)
    }

    /// What starts the background read that a later change must overtake.
    enum FirstRead { case reopeningTheParent, aChangeWhileShown }

    /// Review 3: a background read of `src/inner` has taken its snapshot and sent it to the main
    /// thread; then `src` is closed, `inner` changes and the change notice comes (inner closed);
    /// then the old result lands. It mustn't stand for `inner`: reopening `src` shows what's on disk.
    private func aChangeAfterTheSnapshot(firstRead: FirstRead) async throws {
        let url = UmiFileTreeModel.realURL(try folder(["top.txt"], dirs: ["src/inner"]))
        defer { try? FileManager.default.removeItem(at: url) }
        let src = url.appendingPathComponent("src"), inner = src.appendingPathComponent("inner")
        try Data().write(to: inner.appendingPathComponent("old.txt"))
        let model = UmiFileTreeModel(watchesFiles: false)
        model.start()
        defer { model.stop() }
        model.setRoot(url)
        model.setExpanded(src, true, byUser: true)
        model.setExpanded(inner, true, byUser: true)
        let innerNode = try #require(child(child(model.root, "src"), "inner"))
        let sent = DispatchSemaphore(value: 0)

        switch firstRead {
        case .reopeningTheParent:
            // inner changes while src is closed, so reopening src reads it in the background.
            model.setExpanded(src, false, byUser: true)
            try Data().write(to: inner.appendingPathComponent("first.txt"))
            model.filesChanged([UmiFSWatcher.Event(path: inner.path, flags: 0)])
            model.snapshotSent = { sent.signal() }
            model.setExpanded(src, true, byUser: true)
        case .aChangeWhileShown:
            model.snapshotSent = { sent.signal() }
            try Data().write(to: inner.appendingPathComponent("first.txt"))
            model.filesChanged([UmiFSWatcher.Event(path: inner.path, flags: 0)])
        }
        // The read has taken its snapshot of inner ([first.txt, old.txt]); its result can't land
        // while the main thread waits.
        try #require(waitBlocking(sent), "the background read sends its result")
        model.snapshotSent = nil

        model.setExpanded(src, false, byUser: true)
        try Data().write(to: inner.appendingPathComponent("lost.txt"))
        try FileManager.default.removeItem(at: inner.appendingPathComponent("old.txt"))
        model.filesChanged([UmiFSWatcher.Event(path: inner.path, flags: 0)])
        try await settle(model)   // the old result lands
        #expect(innerNode.stale, "a read taken before the change doesn't stand for inner")

        model.setExpanded(src, true, byUser: true)
        try await settle(model)
        #expect(names(in: model, under: inner) == ["first.txt", "lost.txt"])
        #expect(!innerNode.stale)
        #expect(child(child(model.root, "src"), "inner") === innerNode && innerNode.expanded)
    }

    @Test func aChangeAfterAReopeningReadsSnapshotIsKept() async throws {
        try await aChangeAfterTheSnapshot(firstRead: .reopeningTheParent)
    }

    @Test func aChangeAfterAShownFoldersReadSnapshotIsKept() async throws {
        try await aChangeAfterTheSnapshot(firstRead: .aChangeWhileShown)
    }

    /// Review 3, shown variant: a change notice for a folder still shown, after a background read
    /// of it took its snapshot, reads it again; the folder ends up current and not stale.
    @Test func aChangeToAShownFolderAfterTheSnapshotIsReadAgain() async throws {
        let url = UmiFileTreeModel.realURL(try folder(["top.txt"], dirs: ["src"]))
        defer { try? FileManager.default.removeItem(at: url) }
        let src = url.appendingPathComponent("src")
        try Data().write(to: src.appendingPathComponent("old.txt"))
        let model = UmiFileTreeModel(watchesFiles: false)
        model.start()
        defer { model.stop() }
        model.setRoot(url)
        model.setExpanded(src, true, byUser: true)
        let srcNode = try #require(child(model.root, "src"))
        let sent = DispatchSemaphore(value: 0)
        model.snapshotSent = { sent.signal() }
        try Data().write(to: src.appendingPathComponent("first.txt"))
        model.filesChanged([UmiFSWatcher.Event(path: src.path, flags: 0)])
        try #require(waitBlocking(sent), "the background read sends its result")
        model.snapshotSent = nil
        try Data().write(to: src.appendingPathComponent("lost.txt"))
        try FileManager.default.removeItem(at: src.appendingPathComponent("old.txt"))
        model.filesChanged([UmiFSWatcher.Event(path: src.path, flags: 0)])
        #expect(model.readsPending)
        try await settle(model)
        #expect(names(in: model, under: src) == ["first.txt", "lost.txt"])
        #expect(!srcNode.stale)
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
