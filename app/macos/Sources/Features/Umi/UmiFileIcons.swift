import AppKit
import SwiftUI

/// Colored file-type icons, as Warp shows in its project explorer and file chips: a small
/// rounded badge in the language's usual color with a short monogram (RS, TS, PY …). Umi draws
/// them itself (no third-party icon set), so they are Umi's own, MIT like the rest.
///
/// Use `UmiFileIcon(url:)` in SwiftUI or `UmiFileIcons.image(for:)` in AppKit. Files without a
/// known type, and folders, get a monochrome symbol in the caller's tint.
@MainActor
enum UmiFileIcons {
    /// What an icon shows: a monogram badge in a color, or a symbol (tinted by the caller
    /// unless `color` is given).
    struct Style: Equatable {
        var label: String?
        var symbol: String?
        var color: NSColor?

        static func badge(_ label: String, _ hex: UInt32) -> Style {
            Style(label: label, symbol: nil, color: color(hex))
        }

        static func symbol(_ name: String, _ hex: UInt32? = nil) -> Style {
            Style(label: nil, symbol: name, color: hex.map(color))
        }

        static func color(_ hex: UInt32) -> NSColor {
            NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                    blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        }
    }

    static let folder = Style.symbol("folder")
    static let folderOpen = Style.symbol("folder")
    static let plain = Style.symbol("doc")

    /// By extension (lowercased).
    private static let byExtension: [String: Style] = {
        var map: [String: Style] = [:]
        func add(_ exts: [String], _ style: Style) { for ext in exts { map[ext] = style } }
        add(["rs"], .badge("RS", 0xDEA584))
        add(["swift"], .badge("SW", 0xF05138))
        add(["ts", "tsx", "mts", "cts"], .badge("TS", 0x3178C6))
        add(["js", "jsx", "mjs", "cjs"], .badge("JS", 0xF1E05A))
        add(["py", "pyi", "pyx", "pxd"], .badge("PY", 0x3572A5))
        add(["go"], .badge("GO", 0x00ADD8))
        add(["c", "h"], .badge("C", 0x6E8CBF))
        add(["cpp", "hpp", "cc", "cxx", "hh", "hxx"], .badge("C+", 0xF34B7D))
        add(["m", "mm"], .badge("OC", 0x438EFF))
        add(["java"], .badge("JV", 0xB07219))
        add(["kt", "kts"], .badge("KT", 0xA97BFF))
        add(["rb"], .badge("RB", 0xCC342D))
        add(["php"], .badge("PH", 0x4F5D95))
        add(["pl", "pm"], .badge("PL", 0x0298C3))
        add(["lua"], .badge("LU", 0x4F77C8))
        add(["zig", "zon"], .badge("ZG", 0xEC915C))
        add(["sh", "bash", "zsh", "fish"], .badge("SH", 0x89E051))
        add(["md", "markdown", "mdx"], .badge("MD", 0x4A90D9))
        add(["json", "jsonc", "jsonl"], .badge("{}", 0xCBCB41))
        add(["yaml", "yml"], .badge("YM", 0xCB4B4B))
        add(["toml"], .badge("TM", 0xB0703F))
        add(["html", "htm"], .badge("<>", 0xE34C26))
        add(["css", "scss", "sass", "less"], .badge("#", 0x8A63D2))
        add(["sql"], .badge("DB", 0xE38C00))
        add(["tf", "tfvars", "hcl"], .badge("TF", 0x7B42BC))
        add(["wasm", "wat"], .badge("WA", 0x654FF0))
        add(["csv", "tsv"], .badge("CS", 0x3FA66B))
        add(["xml", "plist"], .badge("<>", 0x0060AC))
        add(["png", "jpg", "jpeg", "gif", "webp", "heic", "bmp", "tiff", "ico", "svg"], .symbol("photo", 0xA074C4))
        add(["pdf"], .symbol("doc.richtext", 0xE5534B))
        add(["zip", "gz", "tgz", "xz", "bz2", "tar", "7z"], .symbol("doc.zipper", 0xB59F6B))
        return map
    }()

    /// By whole file name (exact match).
    private static let byName: [String: Style] = [
        "Dockerfile": .badge("DK", 0x2496ED),
        "Makefile": .badge("MK", 0x6D8C3A),
        "Package.swift": .badge("SW", 0xF05138),
        "Cargo.toml": .badge("RS", 0xDEA584),
        "go.mod": .badge("GO", 0x00ADD8),
    ]

    /// The icon for a file (or folder).
    static func style(for url: URL, isDirectory: Bool = false) -> Style {
        if isDirectory { return folder }
        let name = url.lastPathComponent
        if let style = byName[name] { return style }
        return byExtension[url.pathExtension.lowercased()] ?? plain
    }

    /// The icon as an image, for AppKit (`tint` colors symbols without a color of their own).
    static func image(for url: URL, isDirectory: Bool = false, size: CGFloat = 16,
                      tint: NSColor = .secondaryLabelColor) -> NSImage {
        let style = style(for: url, isDirectory: isDirectory)
        if let label = style.label, let color = style.color {
            return badgeImage(label: label, color: color, size: size)
        }
        let symbol = NSImage(systemSymbolName: style.symbol ?? "doc", accessibilityDescription: nil) ?? NSImage()
        let configured = symbol.withSymbolConfiguration(
            .init(pointSize: size * 0.8, weight: .regular).applying(.init(paletteColors: [style.color ?? tint]))) ?? symbol
        return configured
    }

    private static var badgeCache: [String: NSImage] = [:]

    /// A rounded square in `color` with `label` in white or near-black, whichever reads better.
    static func badgeImage(label: String, color: NSColor, size: CGFloat) -> NSImage {
        let key = "\(label)|\(color.hashValue)|\(size)"
        if let cached = badgeCache[key] { return cached }
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let inset = rect.insetBy(dx: size * 0.06, dy: size * 0.06)
            let path = NSBezierPath(roundedRect: inset, xRadius: size * 0.2, yRadius: size * 0.2)
            color.setFill()
            path.fill()
            let rgb = color.usingColorSpace(.sRGB) ?? color
            let luminance = 0.2126 * rgb.redComponent + 0.7152 * rgb.greenComponent + 0.0722 * rgb.blueComponent
            let ink = luminance > 0.6 ? NSColor(white: 0.08, alpha: 0.9) : NSColor.white
            let fontSize = size * (label.count > 1 ? 0.5 : 0.62)
            let font = NSFont.systemFont(ofSize: fontSize, weight: .heavy)
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: ink]
            let text = NSAttributedString(string: label, attributes: attributes)
            let bounds = text.size()
            text.draw(at: NSPoint(x: inset.midX - bounds.width / 2, y: inset.midY - bounds.height / 2 + size * 0.02))
            return true
        }
        badgeCache[key] = image
        return image
    }
}

/// A file's colored type icon (`UmiFileIcons`), `size` points square.
struct UmiFileIcon: View {
    let url: URL
    var isDirectory = false
    var size: CGFloat = 16
    /// For symbols without a color of their own (folders, plain files).
    var tint: Color = UmiTheme.textSecondary

    var body: some View {
        let style = UmiFileIcons.style(for: url, isDirectory: isDirectory)
        Group {
            if let label = style.label, let color = style.color {
                Image(nsImage: UmiFileIcons.badgeImage(label: label, color: color, size: size))
                    .resizable()
            } else {
                Image(systemName: style.symbol ?? "doc")
                    .font(.system(size: size * 0.78))
                    .foregroundColor(style.color.map { Color($0) } ?? tint)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
