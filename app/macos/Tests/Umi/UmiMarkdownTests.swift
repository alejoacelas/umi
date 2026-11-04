import Foundation
import Testing
@testable import Ghostty

/// YAML front matter in the Markdown preview: a table of its keys, not a rule and a heading.
struct UmiMarkdownTests {
    private let doc = "---\ntitle: Notes\ntags: [a, b]\nauthors:\n  - Ana\n  - Bo\n---\n\n# Heading\n\nBody.\n"

    @Test func frontMatterShowsAsATableOfKeys() {
        let html = UmiMarkdown.html(from: doc, baseURL: nil)
        #expect(html.hasPrefix("<table class=\"front-matter\">"))
        #expect(html.contains("<tr><th>title</th><td>Notes</td></tr>"))
        #expect(html.contains("<tr><th>tags</th><td>[a, b]</td></tr>"))
        #expect(html.contains("<tr><th>authors</th><td><pre>- Ana\n- Bo</pre></td></tr>"))
        #expect(html.contains("<h1 id=\"heading\">Heading</h1>"))
        #expect(!html.contains("<hr>"))
        #expect(!html.contains("<h2"))
    }

    /// The body's runs keep their file offsets; the front matter carries none, so comments
    /// can't put review markup inside the YAML.
    @Test func bodyKeepsItsOffsetsAndFrontMatterHasNone() {
        let html = UmiMarkdown.html(from: doc, baseURL: nil, positions: { $0.location })
        let offset = (doc as NSString).range(of: "Body.").location
        #expect(html.contains("<p><span data-s=\"\(offset)\">Body.</span></p>"))
        #expect(html.contains("<tr><th>title</th>"))
    }

    @Test func frontMatterThatIsNotAMapShowsAsCode() {
        let html = UmiMarkdown.html(from: "---\n- one\n- two\n---\nText\n", baseURL: nil)
        #expect(html.hasPrefix("<pre class=\"front-matter\"><code>- one\n- two\n</code></pre>"))
    }

    @Test func onlyAClosedFenceAtTheTopIsFrontMatter() {
        #expect(UmiMarkdown.frontMatter("---\ntitle: x\n") == nil)
        #expect(UmiMarkdown.frontMatter("Text\n---\ntitle: x\n---\n") == nil)
        #expect(UmiMarkdown.frontMatter("---\r\ntitle: x\r\n...\r\nBody\r\n")?.end == 20)
    }
}
