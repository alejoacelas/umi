// swift-tools-version:5.9
import PackageDescription

/// Umi's syntax highlighting: tree-sitter (MIT) through SwiftTreeSitter (BSD-3-Clause), with the
/// grammars for the languages Warp's editor highlights (`crates/languages` in Warp). Every grammar
/// is MIT or Apache-2.0; see licenses/TREE-SITTER.md at the repository root.
let grammars: [(url: String, version: String, package: String, product: String)] = [
    ("https://github.com/tree-sitter/tree-sitter-python", "0.23.6", "tree-sitter-python", "TreeSitterPython"),
    ("https://github.com/tree-sitter/tree-sitter-typescript", "0.23.2", "tree-sitter-typescript", "TreeSitterTypeScript"),
    ("https://github.com/tree-sitter/tree-sitter-javascript", "0.23.1", "tree-sitter-javascript", "TreeSitterJavaScript"),
    ("https://github.com/tree-sitter/tree-sitter-json", "0.24.8", "tree-sitter-json", "TreeSitterJSON"),
    ("https://github.com/tree-sitter/tree-sitter-bash", "0.25.1", "tree-sitter-bash", "TreeSitterBash"),
    ("https://github.com/tree-sitter/tree-sitter-rust", "0.24.2", "tree-sitter-rust", "TreeSitterRust"),
    ("https://github.com/tree-sitter/tree-sitter-go", "0.25.0", "tree-sitter-go", "TreeSitterGo"),
    ("https://github.com/tree-sitter/tree-sitter-c", "0.24.2", "tree-sitter-c", "TreeSitterC"),
    ("https://github.com/tree-sitter/tree-sitter-cpp", "0.23.4", "tree-sitter-cpp", "TreeSitterCPP"),
    ("https://github.com/tree-sitter/tree-sitter-java", "0.23.5", "tree-sitter-java", "TreeSitterJava"),
    ("https://github.com/tree-sitter/tree-sitter-ruby", "0.23.1", "tree-sitter-ruby", "TreeSitterRuby"),
    ("https://github.com/tree-sitter/tree-sitter-html", "0.23.2", "tree-sitter-html", "TreeSitterHTML"),
    ("https://github.com/tree-sitter/tree-sitter-css", "0.23.2", "tree-sitter-css", "TreeSitterCSS"),
    ("https://github.com/tree-sitter/tree-sitter-c-sharp", "0.23.5", "tree-sitter-c-sharp", "TreeSitterCSharp"),
    ("https://github.com/tree-sitter/tree-sitter-php", "0.25.1", "tree-sitter-php", "TreeSitterPHP"),
    ("https://github.com/tree-sitter/tree-sitter-scala", "0.26.4", "tree-sitter-scala", "TreeSitterScala"),
    ("https://github.com/tree-sitter-grammars/tree-sitter-yaml", "0.7.0", "tree-sitter-yaml", "TreeSitterYAML"),
    ("https://github.com/tree-sitter-grammars/tree-sitter-toml", "0.7.0", "tree-sitter-toml", "TreeSitterTOML"),
    ("https://github.com/tree-sitter-grammars/tree-sitter-lua", "0.3.0", "tree-sitter-lua", "TreeSitterLua"),
    ("https://github.com/tree-sitter-grammars/tree-sitter-xml", "0.7.0", "tree-sitter-xml", "TreeSitterXML"),
    ("https://github.com/tree-sitter-grammars/tree-sitter-markdown", "0.5.4", "tree-sitter-markdown", "TreeSitterMarkdown"),
    ("https://github.com/tree-sitter-grammars/tree-sitter-starlark", "1.3.0", "tree-sitter-starlark", "TreeSitterStarlark"),
    ("https://github.com/fwcd/tree-sitter-kotlin", "0.3.8", "tree-sitter-kotlin", "TreeSitterKotlin"),
    ("https://github.com/camdencheek/tree-sitter-dockerfile", "0.2.0", "tree-sitter-dockerfile", "TreeSitterDockerfile"),
    ("https://github.com/elixir-lang/tree-sitter-elixir", "0.3.5", "tree-sitter-elixir", "TreeSitterElixir"),
]

let package = Package(
    name: "UmiSyntax",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "UmiSyntax", targets: ["UmiSyntax"]),
    ],
    dependencies: [
        .package(url: "https://github.com/tree-sitter/swift-tree-sitter", exact: "0.25.0"),
        // The grammar's tags leave out the generated parser; this branch carries it.
        .package(url: "https://github.com/alex-pinkus/tree-sitter-swift", branch: "with-generated-files"),
    ] + grammars.map { .package(url: $0.url, exact: Version(stringLiteral: $0.version)) },
    targets: [
        .target(
            name: "UmiSyntax",
            dependencies: [
                .product(name: "SwiftTreeSitter", package: "swift-tree-sitter"),
                .product(name: "TreeSitterSwift", package: "tree-sitter-swift"),
            ] + grammars.map { .product(name: $0.product, package: $0.package) }
        ),
        .executableTarget(name: "UmiSyntaxProbe", dependencies: ["UmiSyntax"]),
    ]
)
