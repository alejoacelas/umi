import Foundation
import SwiftTreeSitter
import TreeSitterBash
import TreeSitterC
import TreeSitterCPP
import TreeSitterCSS
import TreeSitterCSharp
import TreeSitterDockerfile
import TreeSitterElixir
import TreeSitterGo
import TreeSitterHTML
import TreeSitterJSON
import TreeSitterJava
import TreeSitterJavaScript
import TreeSitterKotlin
import TreeSitterLua
import TreeSitterMarkdown
import TreeSitterPHP
import TreeSitterPython
import TreeSitterRuby
import TreeSitterRust
import TreeSitterScala
import TreeSitterStarlark
import TreeSitterSwift
import TreeSitterTOML
import TreeSitterTSX
import TreeSitterTypeScript
import TreeSitterXML
import TreeSitterYAML

/// The languages Umi's editor highlights, picked by file name the way Warp's editor picks them
/// (`crates/languages/src/lib.rs`), with each language's line-comment prefix (its `config.yaml`).
public enum UmiSyntax {
    /// What highlighting colors a stretch of text as: Warp's eight colors (W:
    /// `crates/syntax_tree/src/queries/highlight_query.rs`).
    public enum Role: String, CaseIterable, Sendable {
        case keyword, function, string, type, number, comment, property, tag
    }

    public struct Span: Equatable, Sendable {
        /// UTF-16 range in the text.
        public let range: NSRange
        public let role: Role
    }

    public struct Language: Sendable {
        /// Lowercase id, as Warp names it ("python", "golang", …).
        public let id: String
        public let displayName: String
        /// The line-comment prefix ⌘/ adds, if the language has one.
        public let commentPrefix: String?
    }

    // MARK: Picking the language

    /// The language of a file, by its name (W: `language_by_filename_parts`).
    public static func language(forFileName name: String) -> Language? {
        let ext = (name as NSString).pathExtension
        let id: String?
        switch name {
        case ".bashrc", ".bash_profile", ".zshrc", ".zsh_profile", ".zprofile": id = "shell"
        case "BUILD", "WORKSPACE": id = "starlark"
        case "Dockerfile", "Containerfile", "dockerfile", "containerfile": id = "dockerfile"
        default:
            if name.hasPrefix("Dockerfile.") || name.hasPrefix("Containerfile.") {
                id = "dockerfile"
            } else {
                id = languageID(forExtension: ext)
            }
        }
        return id.flatMap { languages[$0] }
    }

    static func languageID(forExtension ext: String) -> String? {
        switch ext {
        case "rs": return "rust"
        case "go": return "golang"
        case "yml", "yaml": return "yaml"
        case "py", "py3", "pyw", "pyi": return "python"
        case "js", "cjs", "mjs": return "javascript"
        case "jsx": return "jsx"
        case "tsx": return "tsx"
        case "ts", "cts", "mts": return "typescript"
        case "java", "groovy", "gvy", "gy", "gsh": return "java"
        case "cpp", "cxx", "cc", "h", "hh", "hpp", "hxx", "H", "h++": return "cpp"
        case "sh", "zsh", "bash", "command": return "shell"
        case "cs": return "csharp"
        case "html", "htm": return "html"
        case "css": return "css"
        case "c": return "c"
        case "json": return "json"
        case "tf", "hcl", "tfvars": return "hcl"
        case "lua": return "lua"
        case "rb": return "ruby"
        case "php", "phtml": return "php"
        case "toml": return "toml"
        case "swift": return "swift"
        case "kt", "kts": return "kotlin"
        case "scala", "sbt", "sc": return "scala"
        case "ex", "exs": return "elixir"
        case "sql": return "sql"
        case "bzl", "bazel": return "starlark"
        case "xml": return "xml"
        case "dockerfile": return "dockerfile"
        case "md", "markdown": return "markdown"
        default: return nil
        }
    }

    /// The languages Umi knows by file name: Warp's list less jq, Nix, Objective-C, PowerShell and
    /// Vue, which have no usable Swift package of their grammar. HCL and SQL are known (⌘/ comments
    /// them) but not highlighted: HCL's package ships no highlights query, SQL's manifest doesn't load.
    public static let languages: [String: Language] = {
        let list: [(String, String, String?)] = [
            ("c", "C", "//"), ("cpp", "C++", "//"), ("csharp", "C#", "//"), ("css", "CSS", nil),
            ("dockerfile", "Dockerfile", "#"), ("elixir", "Elixir", "#"), ("golang", "Go", "//"),
            ("hcl", "HCL", "//"), ("html", "HTML", nil), ("java", "Java", "//"),
            ("javascript", "JavaScript", "//"), ("json", "JSON", nil), ("jsx", "JSX", "//"),
            ("kotlin", "Kotlin", "//"), ("lua", "Lua", "--"), ("markdown", "Markdown", nil),
            ("php", "PHP", "//"), ("python", "Python", "#"), ("ruby", "Ruby", "#"), ("rust", "Rust", "//"),
            ("scala", "Scala", "//"), ("shell", "Shell", "#"), ("sql", "SQL", "--"),
            ("starlark", "Bazel (Starlark)", "#"), ("swift", "Swift", "//"), ("toml", "TOML", "#"),
            ("tsx", "TSX", "//"), ("typescript", "TypeScript", "//"), ("xml", "XML", "<!--"), ("yaml", "YAML", "#"),
        ]
        return Dictionary(uniqueKeysWithValues: list.map { ($0.0, Language(id: $0.0, displayName: $0.1, commentPrefix: $0.2)) })
    }()

    // MARK: Grammars

    /// A grammar and the module (resource bundle) its queries are in. Some languages reuse
    /// another's highlights first, as the tree-sitter CLI does (TypeScript on JavaScript's, C++ on C's).
    private struct Grammar {
        let language: OpaquePointer
        let bundles: [String]
    }

    private static func grammar(for id: String) -> Grammar? {
        switch id {
        case "c": return Grammar(language: tree_sitter_c(), bundles: ["TreeSitterC"])
        case "cpp": return Grammar(language: tree_sitter_cpp(), bundles: ["TreeSitterC", "TreeSitterCPP"])
        case "csharp": return Grammar(language: tree_sitter_c_sharp(), bundles: ["TreeSitterCSharp"])
        case "css": return Grammar(language: tree_sitter_css(), bundles: ["TreeSitterCSS"])
        case "dockerfile": return Grammar(language: tree_sitter_dockerfile(), bundles: ["TreeSitterDockerfile"])
        case "elixir": return Grammar(language: tree_sitter_elixir(), bundles: ["TreeSitterElixir"])
        case "golang": return Grammar(language: tree_sitter_go(), bundles: ["TreeSitterGo"])
        case "html": return Grammar(language: tree_sitter_html(), bundles: ["TreeSitterHTML"])
        case "java": return Grammar(language: tree_sitter_java(), bundles: ["TreeSitterJava"])
        case "javascript", "jsx": return Grammar(language: tree_sitter_javascript(), bundles: ["TreeSitterJavaScript"])
        case "json": return Grammar(language: tree_sitter_json(), bundles: ["TreeSitterJSON"])
        case "kotlin": return Grammar(language: tree_sitter_kotlin(), bundles: ["TreeSitterKotlin"])
        case "lua": return Grammar(language: tree_sitter_lua(), bundles: ["TreeSitterLua"])
        case "markdown": return Grammar(language: tree_sitter_markdown(), bundles: ["TreeSitterMarkdown"])
        case "php": return Grammar(language: tree_sitter_php(), bundles: ["TreeSitterPHP"])
        case "python": return Grammar(language: tree_sitter_python(), bundles: ["TreeSitterPython"])
        case "ruby": return Grammar(language: tree_sitter_ruby(), bundles: ["TreeSitterRuby"])
        case "rust": return Grammar(language: tree_sitter_rust(), bundles: ["TreeSitterRust"])
        case "scala": return Grammar(language: tree_sitter_scala(), bundles: ["TreeSitterScala"])
        case "shell": return Grammar(language: tree_sitter_bash(), bundles: ["TreeSitterBash"])
        case "starlark": return Grammar(language: tree_sitter_starlark(), bundles: ["TreeSitterStarlark"])
        case "swift": return Grammar(language: tree_sitter_swift(), bundles: ["TreeSitterSwift"])
        case "toml": return Grammar(language: tree_sitter_toml(), bundles: ["TreeSitterTOML"])
        case "tsx": return Grammar(language: tree_sitter_tsx(), bundles: ["TreeSitterJavaScript", "TreeSitterTSX"])
        case "typescript": return Grammar(language: tree_sitter_typescript(), bundles: ["TreeSitterJavaScript", "TreeSitterTypeScript"])
        case "xml": return Grammar(language: tree_sitter_xml(), bundles: ["TreeSitterXML"])
        case "yaml": return Grammar(language: tree_sitter_yaml(), bundles: ["TreeSitterYAML"])
        default: return nil
        }
    }

    /// A language's parser language and highlights query, made once.
    private final class Loaded: @unchecked Sendable {
        let language: SwiftTreeSitter.Language
        let query: Query
        init(language: SwiftTreeSitter.Language, query: Query) {
            self.language = language
            self.query = query
        }
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: Loaded?] = [:]

    private static func loaded(_ id: String) -> Loaded? {
        lock.lock()
        defer { lock.unlock() }
        if let hit = cache[id] { return hit }
        var made: Loaded?
        if let grammar = grammar(for: id) {
            let language = SwiftTreeSitter.Language(language: grammar.language)
            let source = grammar.bundles.compactMap(highlightsQuery(inModule:)).joined(separator: "\n")
            if !source.isEmpty, let query = try? Query(language: language, data: Data(source.utf8)) {
                made = Loaded(language: language, query: query)
            }
        }
        cache[id] = made
        return made
    }

    /// Whether a language's grammar and highlights load (for checks).
    public static func isAvailable(_ id: String) -> Bool { loaded(id) != nil }

    /// The `queries/highlights.scm` of a grammar module, from its resource bundle
    /// (`<Package>_<Module>.bundle`, in the app's resources or next to a command-line tool).
    static func highlightsQuery(inModule module: String) -> String? {
        var folders: [URL] = []
        if let resources = Bundle.main.resourceURL { folders.append(resources) }
        folders.append(Bundle.main.bundleURL)
        if let executable = Bundle.main.executableURL { folders.append(executable.deletingLastPathComponent()) }
        for folder in folders {
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { continue }
            for name in names where name.hasSuffix("_\(module).bundle") {
                // `queries/highlights.scm`, or `xml/highlights.scm` where a repository holds several grammars.
                let bundle = folder.appendingPathComponent(name)
                let walker = FileManager.default.enumerator(at: bundle, includingPropertiesForKeys: nil)
                while let file = walker?.nextObject() as? URL {
                    if file.lastPathComponent == "highlights.scm", let text = try? String(contentsOf: file, encoding: .utf8) {
                        return text
                    }
                }
            }
        }
        return nil
    }

    // MARK: Highlighting

    /// The colored stretches of `text` in a language, in order. Empty for a language Umi doesn't
    /// highlight. Runs on any thread.
    public static func highlights(in text: String, language id: String) -> [Span] {
        guard let loaded = loaded(id) else { return [] }
        let parser = Parser()
        guard (try? parser.setLanguage(loaded.language)) != nil, let tree = parser.parse(text) else { return [] }
        let cursor = loaded.query.execute(in: tree)
        var spans: [Span] = []
        for named in cursor.resolve(with: .init(string: text)).highlights() {
            guard let role = role(forCapture: named.name) else { continue }
            spans.append(Span(range: named.range, role: role))
        }
        return spans
    }

    /// Warp's rule: a few whole names for Markdown, else the capture's first part.
    public static func role(forCapture name: String) -> Role? {
        switch name {
        case "text.title": return .keyword
        case "text.literal": return .string
        case "text.uri": return .function
        case "text.reference": return .property
        default: break
        }
        let first = name.split(separator: ".").first.map(String.init) ?? name
        switch first {
        case "keyword": return .keyword
        case "function": return .function
        case "string": return .string
        case "type": return .type
        case "number": return .number
        case "comment", "punctuation": return .comment
        case "property": return .property
        case "tag": return .tag
        default: return nil
        }
    }
}
