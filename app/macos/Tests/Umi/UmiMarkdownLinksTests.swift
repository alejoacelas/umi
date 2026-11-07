import Foundation
import Testing
@testable import Ghostty

/// Bare URLs made links and fenced blocks' language labels in the Markdown preview (MD-1, MD-2).
struct UmiMarkdownLinksTests {
    private func link(_ url: String, href: String? = nil) -> String {
        "<a href=\"\(href ?? url)\">\(url)</a>"
    }

    @Test func trailingPunctuationStaysText() {
        #expect(UmiMarkdown.linkified("see https://x.com/a.") == "see \(link("https://x.com/a")).")
        #expect(UmiMarkdown.linkified("https://x.com.") == "\(link("https://x.com")).")
        #expect(UmiMarkdown.linkified("https://x.com/a, then") == "\(link("https://x.com/a")), then")
        #expect(UmiMarkdown.linkified("is it https://x.com/a?") == "is it \(link("https://x.com/a"))?")
    }

    @Test func anUnmatchedClosingBracketStaysText() {
        #expect(UmiMarkdown.linkified("(see https://x.com/a)") == "(see \(link("https://x.com/a")))")
        #expect(UmiMarkdown.linkified("(see https://x.com/a_(b))") == "(see \(link("https://x.com/a_(b)")))")
        #expect(UmiMarkdown.linkified("https://x.com/a_(b)") == link("https://x.com/a_(b)"))
    }

    @Test func wwwGetsHTTPS() {
        #expect(UmiMarkdown.linkified("go to www.x.com/a now") == "go to \(link("www.x.com/a", href: "https://www.x.com/a")) now")
    }

    @Test func textAndURLsAreEscaped() {
        #expect(UmiMarkdown.linkified("a < b & https://x.com/?a=1&b=2")
                == "a &lt; b &amp; \(link("https://x.com/?a=1&amp;b=2"))")
        #expect(UmiMarkdown.linkified("no links <here>") == "no links &lt;here&gt;")
    }

    @Test func urlsInLinksAndCodeAreLeftAlone() {
        let html = UmiMarkdown.html(from: "[https://x.com](https://y.com) and `https://z.com`\n\n```\nhttps://w.com\n```\n",
                                    baseURL: nil)
        #expect(html.components(separatedBy: "<a ").count == 2, "only the written link")
        #expect(html.contains("href=\"https://y.com\""))
        #expect(!html.contains("href=\"https://x.com\""))
        #expect(!html.contains("href=\"https://z.com\""))
        #expect(!html.contains("href=\"https://w.com\""))
    }

    @Test func codeLanguageLabelsAsWarps() {
        #expect(UmiMarkdown.CodeLanguage("rust path=/foo").label == "Rust")
        #expect(UmiMarkdown.CodeLanguage("JS").label == "JavaScript")
        #expect(UmiMarkdown.CodeLanguage("py").label == "Python")
        #expect(UmiMarkdown.CodeLanguage("").label == "Code")
        #expect(UmiMarkdown.CodeLanguage(nil).label == "Code")
        #expect(UmiMarkdown.CodeLanguage("text").label == "Code")
        #expect(UmiMarkdown.CodeLanguage("elixir").label == "elixir")
    }

    @Test func codeLanguageKinds() {
        #expect(UmiMarkdown.CodeLanguage("zsh").kind == "shell")
        #expect(UmiMarkdown.CodeLanguage("Bash").label == "Shell")
        #expect(UmiMarkdown.CodeLanguage("Mermaid").kind == "mermaid")
        #expect(UmiMarkdown.CodeLanguage("python").kind == nil)
    }
}
