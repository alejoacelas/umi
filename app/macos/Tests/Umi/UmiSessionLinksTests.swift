import Foundation
import Testing
@testable import Ghostty

/// Session links (AG-20): the origin check, reading a task, finding its folder on this Mac, and
/// what is typed in the new tab.
@MainActor struct UmiSessionLinksTests {
    private let origins: Set<String> = ["https://agent-server.example.ts.net"]

    private func link(_ task: String) -> URL {
        var c = URLComponents(string: "umi://open")!
        c.queryItems = [URLQueryItem(name: "task", value: task)]
        return c.url!
    }

    private func task(_ fields: [String: Any]) throws -> UmiSessionLinks.Task {
        var json: [String: Any] = ["id": "Ab_c-12345", "title": "Fix the docket", "folder": "projects/x", "prompt": "hello"]
        for (k, v) in fields { json[k] = v }
        json = json.filter { !($0.value is NSNull) }
        return try UmiSessionLinks.parseTask(try JSONSerialization.data(withJSONObject: json))
    }

    private func refuses(_ body: () throws -> Void) -> Bool {
        do { try body(); return false } catch { return true }
    }

    // MARK: The link and its origin

    @Test func aTaskFromAListedOriginIsAccepted() throws {
        let url = try UmiSessionLinks.taskURL(from: link("https://agent-server.example.ts.net/umi/abc.json"), origins: origins)
        #expect(url.absoluteString == "https://agent-server.example.ts.net/umi/abc.json")
        // The scheme and host compare without case; the default port is the same origin.
        _ = try UmiSessionLinks.taskURL(from: URL(string: "UMI://OPEN?task=https%3A%2F%2Fagent-server.example.ts.net%3A443%2Fumi%2Fa.json")!,
                                        origins: origins)
    }

    @Test func everyOtherLinkIsRefused() {
        let cases = [
            link("https://evil.example.com/umi/abc.json"),             // an origin not listed
            link("http://agent-server.example.ts.net/umi/abc.json"),   // http isn't the listed https origin
            link("https://agent-server.example.ts.net:8443/x.json"),   // another port is another origin
            link("file:///etc/passwd"),
            URL(string: "umi://open")!,                                 // no task
            URL(string: "umi://run?task=https%3A%2F%2Fagent-server.example.ts.net%2Fa.json")!,
            URL(string: "https://agent-server.example.ts.net/umi/abc.json")!,
        ]
        for url in cases {
            #expect(refuses { _ = try UmiSessionLinks.taskURL(from: url, origins: origins) }, "\(url)")
        }
        #expect(refuses { _ = try UmiSessionLinks.taskURL(from: link("https://agent-server.example.ts.net/a.json"), origins: []) })
    }

    @Test func theRefusalSaysWhy() {
        do {
            _ = try UmiSessionLinks.taskURL(from: link("https://evil.example.com/a.json"), origins: origins)
            Issue.record("accepted")
        } catch let error as UmiError {
            #expect(error.message.contains("https://evil.example.com"))
            #expect(error.message.contains("umi-web-origin"))
        } catch {
            Issue.record("\(error)")
        }
    }

    // MARK: Reading the task

    @Test func aTaskReadsWithItsDefaults() throws {
        let t = try task([:])
        #expect(t.place == .mac && t.agent == .claude && t.prompt == "hello" && t.session == nil)
        let s = try task(["prompt": NSNull(), "session": "0f3e-11", "agent": "codex", "where": "server",
                          "server": ["ssh": "agent-server", "user": "agent"]])
        #expect(s.place == .server && s.agent == .codex && s.session == "0f3e-11")
        #expect(s.sshHost == "agent-server" && s.sshUser == "agent")
    }

    @Test func badTasksAreRefused() {
        let bad: [[String: Any]] = [
            ["id": "a b"], ["id": "-rf"], ["id": NSNull()], ["title": NSNull()],
            ["folder": "/etc"], ["folder": "~/best/x"], ["folder": "projects/../../etc"],
            ["where": "elsewhere"], ["agent": "bash"],
            ["session": "s1"],                       // both a prompt and a session
            ["prompt": NSNull()],                    // neither
            ["prompt": NSNull(), "session": "$(rm -rf ~)"],
        ]
        for fields in bad {
            #expect(refuses { _ = try task(fields) }, "\(fields)")
        }
        #expect(refuses { _ = try UmiSessionLinks.parseTask(Data("[1]".utf8)) })
    }

    @Test func anUnsafeServerIsIgnoredAndTheServerLineRefused() throws {
        let t = try task(["where": "server", "server": ["ssh": "-oProxyCommand=x", "user": "agent;id"]])
        #expect(t.sshHost == nil && t.sshUser == nil)
        #expect(refuses { _ = try UmiSessionLinks.serverLine(t, env: [:]) })
    }

    // MARK: The folder

    @Test func remotesCompareAcrossTheirForms() {
        let forms = ["https://github.com/alejoacelas/umi.git", "https://github.com/AlejoAcelas/umi",
                     "git@github.com:alejoacelas/umi.git", "ssh://git@github.com/alejoacelas/umi.git",
                     "https://token@github.com/alejoacelas/umi"]
        let normal = Set(forms.compactMap(UmiSessionLinks.normalizedRemote))
        #expect(normal == ["github.com/alejoacelas/umi"])
        #expect(UmiSessionLinks.normalizedRemote("https://github.com/alejoacelas/umi-other") != "github.com/alejoacelas/umi")
        #expect(UmiSessionLinks.normalizedRemote("/local/path") == nil)
    }

    private func makeCheckout(_ dir: URL, remote: String?, branch: String = "main") throws {
        let git = dir.appendingPathComponent(".git")
        try FileManager.default.createDirectory(at: git, withIntermediateDirectories: true)
        try "ref: refs/heads/\(branch)\n".write(to: git.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8)
        var config = "[core]\n\tbare = false\n"
        if let remote { config += "[remote \"origin\"]\n\turl = \(remote)\n\tfetch = +refs/heads/*:refs/remotes/origin/*\n" }
        try config.write(to: git.appendingPathComponent("config"), atomically: true, encoding: .utf8)
    }

    private func tempBest() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("umi-links-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.resolvingSymlinksInPath()
    }

    @Test func theCheckoutWithTheTasksRemoteWinsOverThePath() throws {
        let best = try tempBest()
        defer { try? FileManager.default.removeItem(at: best) }
        let moved = best.appendingPathComponent("areas/renamed")
        try makeCheckout(moved, remote: "git@github.com:alejoacelas/thing.git")
        try makeCheckout(best.appendingPathComponent("projects/thing"), remote: "https://github.com/alejoacelas/other")
        let t = try task(["folder": "projects/thing", "remote": "https://github.com/alejoacelas/thing"])
        #expect(UmiSessionLinks.localFolder(for: t, best: best)?.path == moved.standardizedFileURL.path)

        // A client repository under orgs/.
        let client = best.appendingPathComponent("orgs/acme/2026-10-tool")
        try makeCheckout(client, remote: "https://github.com/acme/tool.git")
        let c = try task(["folder": "orgs/acme/old-name", "remote": "https://github.com/acme/tool"])
        #expect(UmiSessionLinks.localFolder(for: c, best: best)?.path == client.standardizedFileURL.path)
    }

    @Test func withoutAMatchingRemoteThePathIsUsedOrNothing() throws {
        let best = try tempBest()
        defer { try? FileManager.default.removeItem(at: best) }
        let desk = best.appendingPathComponent("desk")
        try FileManager.default.createDirectory(at: desk, withIntermediateDirectories: true)
        #expect(UmiSessionLinks.localFolder(for: try task(["folder": "desk"]), best: best)?.path == desk.standardizedFileURL.path)
        #expect(UmiSessionLinks.localFolder(for: try task(["folder": "projects/missing", "remote": "https://github.com/a/b"]),
                                            best: best) == nil)
    }

    @Test func aWorktreeReadsItsRemoteAndBranch() throws {
        let best = try tempBest()
        defer { try? FileManager.default.removeItem(at: best) }
        let main = best.appendingPathComponent("projects/repo")
        try makeCheckout(main, remote: "https://github.com/a/repo")
        let wtGit = main.appendingPathComponent(".git/worktrees/feature")
        try FileManager.default.createDirectory(at: wtGit, withIntermediateDirectories: true)
        try "ref: refs/heads/feature\n".write(to: wtGit.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8)
        try "../..\n".write(to: wtGit.appendingPathComponent("commondir"), atomically: true, encoding: .utf8)
        let wt = best.appendingPathComponent("projects/repo-feature")
        try FileManager.default.createDirectory(at: wt, withIntermediateDirectories: true)
        try "gitdir: \(wtGit.path)\n".write(to: wt.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
        #expect(UmiSessionLinks.originRemote(of: wt) == "https://github.com/a/repo")
        #expect(UmiSessionLinks.currentBranch(of: wt) == "feature")
    }

    // MARK: The plan and what is typed

    @Test func aBranchTheCheckoutIsntOnLeadsThePrompt() throws {
        let best = try tempBest()
        defer { try? FileManager.default.removeItem(at: best) }
        try makeCheckout(best.appendingPathComponent("projects/x"), remote: nil, branch: "main")
        let plan = UmiSessionLinks.plan(try task(["branch": "feature"]), best: best)
        #expect(plan.place == .mac)
        #expect(plan.prompt?.split(separator: "\n").first?.contains("branch feature") == true)
        #expect(plan.prompt?.hasSuffix("\n\nhello") == true)
        #expect(plan.notes.isEmpty)
        // The same branch: the prompt as it was.
        #expect(UmiSessionLinks.plan(try task(["branch": "main"]), best: best).prompt == "hello")
        // A resume has no prompt: the note is printed instead.
        let resume = UmiSessionLinks.plan(try task(["branch": "feature", "prompt": NSNull(), "session": "s1"]), best: best)
        #expect(resume.prompt == nil && resume.notes.count == 1)
    }

    @Test func noLocalFolderRunsOnTheServerAndSaysSo() throws {
        let best = try tempBest()
        defer { try? FileManager.default.removeItem(at: best) }
        let plan = UmiSessionLinks.plan(try task(["folder": "projects/nowhere"]), best: best)
        #expect(plan.place == .server && plan.notes.first?.contains("projects/nowhere") == true)
    }

    @Test func theTypedCommands() throws {
        let claude = try task([:])
        #expect(UmiSessionLinks.agentLine(claude, promptFile: "/tmp/a b.prompt", env: [:])
                == "claude --dangerously-skip-permissions \"$(cat '/tmp/a b.prompt')\"")
        let resume = try task(["prompt": NSNull(), "session": "abc-123"])
        #expect(UmiSessionLinks.agentLine(resume, promptFile: nil, env: [:]) == "claude --dangerously-skip-permissions --resume abc-123")
        let codex = try task(["prompt": NSNull(), "session": "t1", "agent": "codex"])
        #expect(UmiSessionLinks.agentLine(codex, promptFile: nil, env: [:]) == "codex --dangerously-bypass-approvals-and-sandbox resume t1")
        let server = try task(["where": "server", "server": ["ssh": "agent-server", "user": "agent"]])
        #expect(try UmiSessionLinks.serverLine(server, env: [:]) == "ssh -t agent-server sudo -iu agent umi-link attach Ab_c-12345")
        #expect(UmiSessionLinks.agentLine(claude, promptFile: "/p", env: ["UMI_TEST_LINK_BIN": "/fakes"]).hasPrefix("/fakes/claude "))
        #expect(UmiSessionLinks.noteLine(["it's here"]) == "printf '%s\\n' 'Umi: it'\\''s here'")
    }
}
