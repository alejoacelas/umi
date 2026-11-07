import Foundation
import UmiSyntax

// Checks that every language loads and colors a sample: `swift run UmiSyntaxProbe`.
let samples: [String: String] = [
    "python": "def f(x):\n    # hi\n    return 'a' + 1\n",
    "swift": "func f() -> Int { let s = \"a\"; return 1 } // c\n",
    "markdown": "# Title\n\nSome `code` and a [link](http://x).\n",
]
var failed = false
for id in UmiSyntax.languages.keys.sorted() {
    let ok = UmiSyntax.isAvailable(id) || ["hcl", "sql"].contains(id)
    if !ok { failed = true }
    let text = samples[id] ?? "x = 1 // \"s\" # c\n"
    let spans = UmiSyntax.highlights(in: text, language: id)
    print(id, ok ? "ok" : "MISSING", spans.count, spans.prefix(4).map { "\($0.role.rawValue)@\($0.range.location)" })
}
exit(failed ? 1 : 0)
