import Foundation
import Testing
@testable import Ghostty

/// E-12: what a hosted page (the agent server's file page) may tell Umi. Messages arrive as
/// WebKit hands them over: dictionaries of strings, NSNumber booleans and NSNull.
struct UmiHostedPageTests {
    private func message(_ changes: [String: Any?] = [:]) -> [String: Any] {
        var body: [String: Any] = ["path": "desk/AGENTS.md", "mode": "preview", "hasModes": NSNumber(value: true),
                                   "github": "https://github.com/alejoacelas/desk/blob/main/AGENTS.md",
                                   "dirty": NSNumber(value: false)]
        for (key, value) in changes { body[key] = value ?? nil }
        return body
    }

    @Test func aWellFormedMessageIsRead() throws {
        let state = try #require(UmiHostedPage.State(message: message()))
        #expect(state.path == "desk/AGENTS.md")
        #expect(state.mode == .preview)
        #expect(state.hasModes && !state.dirty)
        #expect(state.github?.absoluteString == "https://github.com/alejoacelas/desk/blob/main/AGENTS.md")
        let source = try #require(UmiHostedPage.State(message: message(["mode": "source", "dirty": NSNumber(value: true)])))
        #expect(source.mode == .source && source.dirty)
    }

    @Test func gitHubMayBeAbsent() {
        #expect(UmiHostedPage.State(message: message(["github": NSNull()]))?.github == nil)
        var body = message()
        body["github"] = nil
        #expect(UmiHostedPage.State(message: body) != nil)
    }

    @Test func malformedMessagesAreIgnored() {
        #expect(UmiHostedPage.State(message: "desk/AGENTS.md") == nil)
        #expect(UmiHostedPage.State(message: [Any]()) == nil)
        #expect(UmiHostedPage.State(message: message(["path": NSNumber(value: 42)])) == nil)
        #expect(UmiHostedPage.State(message: message(["path": ""])) == nil)
        #expect(UmiHostedPage.State(message: message(["path": "a\nb"])) == nil)
        #expect(UmiHostedPage.State(message: message(["path": String(repeating: "a", count: 1025)])) == nil)
        #expect(UmiHostedPage.State(message: message(["mode": "edit"])) == nil)
        #expect(UmiHostedPage.State(message: message(["hasModes": NSNumber(value: 1)])) == nil, "a number isn't a boolean")
        #expect(UmiHostedPage.State(message: message(["hasModes": "true"])) == nil)
        #expect(UmiHostedPage.State(message: message(["dirty": nil])) == nil)
        #expect(UmiHostedPage.State(message: message(["github": NSNumber(value: true)])) == nil)
    }

    @Test func onlyHttpsGitHubLinksAreAccepted() {
        for bad in ["http://github.com/a/b", "https://github.com.evil.example/a", "https://evil.example/github.com",
                    "javascript:alert(1)", "file:///etc/passwd", "https://user@github.com/a", "https://gist.github.com/a",
                    "https://github.com:8443/a"] {
            #expect(UmiHostedPage.State(message: message(["github": bad])) == nil, "\(bad)")
        }
        #expect(UmiHostedPage.State(message: message(["github": "https://GitHub.com/a/b"])) != nil)
    }

    @Test func theSwitchScriptOnlyNamesAKnownMode() {
        #expect(UmiHostedPage.setModeScript(.source).contains("setMode('source')"))
        #expect(UmiHostedPage.setModeScript(.preview).contains("setMode('preview')"))
    }

    @Test func aPathSplitsIntoFolderAndName() {
        #expect(UmiPathTitle.split("desk/AGENTS.md") == ("desk", "AGENTS.md"))
        #expect(UmiPathTitle.split("inbox/2026-11-clerk/desk-pipeline/open.py") == ("desk-pipeline", "open.py"))
        #expect(UmiPathTitle.split("desk") == (nil, "desk"))
    }
}
