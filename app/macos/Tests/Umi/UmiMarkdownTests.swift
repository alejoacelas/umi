import Foundation
import Testing
@testable import Ghostty

/// YAML front matter in the Markdown preview: collapsed to one line that opens to a table of its
/// keys, not a rule and a heading.
struct UmiMarkdownTests {
    private let doc = "---\ntitle: Notes\ntags: [a, \"b\"]\nauthors:\n  - Ana\n  - Bo\ndate: 2026-11-07\n"
        + "summary: >\n  One line\n  and another\nmeta:\n  owner: x\n---\n\n# Heading\n\nBody.\n"

    @Test func frontMatterIsCollapsedToOneLine() {
        let html = UmiMarkdown.html(from: doc, baseURL: nil)
        #expect(html.hasPrefix("<details class=\"front-matter\"><summary><span class=\"arr\">\u{25B6}</span>"
            + "<span>Notes</span><span>2026-11-07</span><span class=\"k\">\u{00B7} 4 more</span></summary>"))
        #expect(!html.contains("<details class=\"front-matter\" open"))
        #expect(html.contains("<table class=\"dense\"><tr><th>title</th><td>Notes</td></tr>"))
        #expect(html.contains("<tr><th>tags</th><td>a, b</td></tr>"))
        #expect(html.contains("<tr><th>authors</th><td>Ana, Bo</td></tr>"))
        #expect(html.contains("<tr><th>summary</th><td>One line and another</td></tr>"))
        #expect(html.contains("<tr><th>meta</th><td><pre>owner: x</pre></td></tr>"))
        #expect(html.contains("<h1 id=\"heading\">Heading</h1>"))
        #expect(!html.contains("<hr>"))
        #expect(!html.contains("<h2"))
    }

    /// Without `title` or `date`, the summary shows the first short values; without any, it says
    /// "Front matter". Everything is escaped.
    @Test func frontMatterSummaryFallsBackToShortValues() {
        let html = UmiMarkdown.html(from: "---\nlong: \(String(repeating: "x", count: 61))\nname: <b>\nkind: note\nx: 1\n---\n", baseURL: nil)
        #expect(html.contains("<summary><span class=\"arr\">\u{25B6}</span><span>&lt;b&gt;</span><span>note</span>"
            + "<span class=\"k\">\u{00B7} 2 more</span></summary>"))
        let none = UmiMarkdown.html(from: "---\nlist:\n  - a\n---\n", baseURL: nil)
        #expect(none.contains("<summary><span class=\"arr\">\u{25B6}</span><span>Front matter</span></summary>"))
    }

    /// The body's runs keep their file offsets; the front matter carries none, so comments
    /// can't put review markup inside the YAML.
    @Test func bodyKeepsItsOffsetsAndFrontMatterHasNone() {
        let html = UmiMarkdown.html(from: doc, baseURL: nil, positions: { $0.location })
        let offset = (doc as NSString).range(of: "Body.").location
        #expect(html.contains("<p><span data-s=\"\(offset)\">Body.</span></p>"))
        #expect(html.contains("<tr><th>title</th><td>Notes</td></tr>"))
    }

    @Test func frontMatterThatIsNotAMapShowsAsCode() {
        let html = UmiMarkdown.html(from: "---\n- one\n- two\n---\nText\n", baseURL: nil)
        #expect(html.hasPrefix("<details class=\"front-matter\"><summary><span class=\"arr\">\u{25B6}</span>"
            + "<span>Front matter</span></summary><div class=\"body\"><pre><code>- one\n- two\n</code></pre></div></details>"))
    }

    @Test func onlyAClosedFenceAtTheTopIsFrontMatter() {
        #expect(UmiMarkdown.frontMatter("---\ntitle: x\n") == nil)
        #expect(UmiMarkdown.frontMatter("Text\n---\ntitle: x\n---\n") == nil)
        #expect(UmiMarkdown.frontMatter("---\r\ntitle: x\r\n...\r\nBody\r\n")?.end == 20)
    }
}
