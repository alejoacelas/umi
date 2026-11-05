import AppKit
import SwiftUI

/// File-type icons, colored by language as Warp's are: Material Icon Theme's SVGs (MIT,
/// licenses/MATERIAL-ICON-THEME.md) in the asset catalog's `FileIcons` folder, each named
/// `fileicon-<name>`. One place for every view that shows a file's type (stack chips, the
/// file tree).
enum UmiFileIcons {
    /// The icon's asset name for a file, by its name.
    static func assetName(for url: URL) -> String {
        "fileicon-" + iconName(forFileName: url.lastPathComponent)
    }

    static func iconName(forFileName name: String) -> String {
        let lower = name.lowercased()
        switch lower {
        case "dockerfile", "containerfile": return "docker"
        case ".gitignore", ".gitattributes", ".gitmodules": return "git"
        case "build", "workspace", "build.bazel", "workspace.bazel": return "bazel"
        case ".bashrc", ".bash_profile", ".zshrc", ".zprofile", ".zsh_profile", ".profile": return "console"
        case "package-lock.json", "yarn.lock", "cargo.lock", "pnpm-lock.yaml", "package.resolved": return "lock"
        default: break
        }
        if lower.hasPrefix("dockerfile.") || lower.hasPrefix("containerfile.") { return "docker" }
        switch (name as NSString).pathExtension.lowercased() {
        case "swift": return "swift"
        case "py", "py3", "pyw", "pyi": return "python"
        case "js", "cjs", "mjs": return "javascript"
        case "ts", "cts", "mts": return "typescript"
        case "jsx": return "react"
        case "tsx": return "react_ts"
        case "json", "jsonc", "jsonl": return "json"
        case "md", "markdown", "mdown", "mkd", "mkdn", "mdx": return "markdown"
        case "rs": return "rust"
        case "go": return "go"
        case "c": return "c"
        case "cpp", "cxx", "cc", "c++": return "cpp"
        case "h": return "h"
        case "hpp", "hh", "hxx", "h++": return "hpp"
        case "java", "groovy", "gvy", "gy", "gsh": return "java"
        case "rb": return "ruby"
        case "html", "htm": return "html"
        case "css": return "css"
        case "cs": return "csharp"
        case "php", "phtml": return "php"
        case "scala", "sbt", "sc": return "scala"
        case "kt", "kts": return "kotlin"
        case "lua": return "lua"
        case "yml", "yaml": return "yaml"
        case "toml": return "toml"
        case "xml", "plist": return "xml"
        case "dockerfile": return "docker"
        case "ex", "exs": return "elixir"
        case "tf", "tfvars", "hcl": return "terraform"
        case "sql": return "database"
        case "sh", "zsh", "bash", "fish", "command": return "console"
        case "ps1", "pwsh": return "powershell"
        case "nix": return "nix"
        case "vue": return "vue"
        case "bzl", "bazel": return "bazel"
        case "csv", "tsv": return "table"
        case "log": return "log"
        case "ini", "conf", "cfg", "env", "properties": return "settings"
        case "lock": return "lock"
        case "png", "jpg", "jpeg", "gif", "webp", "heic", "ico", "bmp", "tiff": return "image"
        case "svg": return "svg"
        case "pdf": return "pdf"
        case "zip", "tar", "gz", "tgz", "xz", "bz2", "7z": return "zip"
        default: return "document"
        }
    }
}

/// A file's type icon at a size (14 pt in chips, as Warp's tab icons).
struct UmiFileIcon: View {
    let url: URL
    var size: CGFloat = 14

    var body: some View {
        Image(UmiFileIcons.assetName(for: url))
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}
