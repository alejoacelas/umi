import AppKit

/// A session's transcript as attributed text: what each side said (assistant text rendered
/// from Markdown, code set apart), tool calls that expand to their output, requests and
/// notices, in order (AP-1, AP-5, AP-10).
enum TernAgentTranscriptRenderer {
    static func render(_ items: [TernTranscriptItem], expanded: Set<String>, light: Bool) -> NSAttributedString {
        let ink = light ? NSColor.black.withAlphaComponent(0.86) : NSColor.white.withAlphaComponent(0.9)
        let dim = ink.withAlphaComponent(0.5)
        let body = NSFont.systemFont(ofSize: 13)
        let small = NSFont.systemFont(ofSize: 11)
        let mono = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
        let codeBackground = ink.withAlphaComponent(light ? 0.05 : 0.07)
        let out = NSMutableAttributedString()

        func paragraph(spacingBefore: CGFloat, indent: CGFloat = 0) -> NSParagraphStyle {
            let style = NSMutableParagraphStyle()
            style.paragraphSpacingBefore = spacingBefore
            style.paragraphSpacing = 2
            style.headIndent = indent
            style.firstLineHeadIndent = indent
            style.lineHeightMultiple = 1.12
            return style
        }

        func append(_ text: String, _ attrs: [NSAttributedString.Key: Any]) {
            out.append(NSAttributedString(string: text, attributes: attrs))
        }

        var previousKind: String?
        for item in items {
            let gap: CGFloat = previousKind == item.kind && item.kind == "tool" ? 1 : 10
            if out.length > 0 { append("\n", [.font: small]) }
            switch item.kind {
            case "user":
                append("You", [.font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: TernTheme.accentNSColor,
                               .paragraphStyle: paragraph(spacingBefore: gap)])
                append("\n", [.font: small])
                append(item.text, [.font: body, .foregroundColor: ink, .paragraphStyle: paragraph(spacingBefore: 1)])
            case "assistant":
                let commentary = item.state == "commentary"
                let rendered = TernAgentMarkdown.render(item.text, font: body, color: commentary ? dim : ink, mono: mono,
                                                         codeBackground: codeBackground)
                let mutable = NSMutableAttributedString(attributedString: rendered)
                if mutable.length > 0 {
                    mutable.addAttribute(.paragraphStyle, value: paragraph(spacingBefore: gap),
                                         range: NSRange(location: 0, length: min(1, mutable.length)))
                }
                out.append(mutable)
            case "tool":
                let symbol: String
                switch item.state ?? "" {
                case "running": symbol = "◌"
                case let s where s.hasPrefix("error"): symbol = "✕"
                case "declined", "interrupted", "withdrawn": symbol = "–"
                default: symbol = "✓"
                }
                let isOpen = expanded.contains(item.id)
                let link = "tern-tool:\(item.id)"
                append("\(isOpen ? "▾" : "▸") \(symbol) ", [.font: mono, .foregroundColor: dim, .link: link,
                                                          .paragraphStyle: paragraph(spacingBefore: gap)])
                append(item.tool ?? item.text, [.font: NSFont.monospacedSystemFont(ofSize: 11.5, weight: .semibold),
                                                .foregroundColor: ink.withAlphaComponent(0.75), .link: link])
                if let detail = item.detail, !detail.isEmpty {
                    append("  " + TernAgentText.oneLine(detail, max: 200), [.font: mono, .foregroundColor: dim, .link: link])
                }
                if let state = item.state, state != "done", state != "running" {
                    append("  (\(state))", [.font: small, .foregroundColor: dim])
                }
                if isOpen {
                    let output = item.output ?? ""
                    append("\n", [.font: small])
                    let block = paragraph(spacingBefore: 2, indent: 18)
                    if !(item.detail ?? "").isEmpty, (item.detail ?? "").count > 200 {
                        append((item.detail ?? "") + "\n", [.font: mono, .foregroundColor: dim, .paragraphStyle: block])
                    }
                    append(output.isEmpty ? "(no output)" : output,
                           [.font: mono, .foregroundColor: ink.withAlphaComponent(0.8), .backgroundColor: codeBackground,
                            .paragraphStyle: block])
                }
            case "request":
                append("⚑ \(item.text)", [.font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor.systemOrange,
                                          .paragraphStyle: paragraph(spacingBefore: gap)])
                if let detail = item.detail, !detail.isEmpty {
                    append("  \(TernAgentText.oneLine(detail, max: 240))", [.font: mono, .foregroundColor: dim])
                }
                if let state = item.state { append("  (\(state))", [.font: small, .foregroundColor: dim]) }
            case "error":
                append(item.text, [.font: body, .foregroundColor: NSColor.systemRed, .paragraphStyle: paragraph(spacingBefore: gap)])
            default:
                append(item.text, [.font: NSFont.systemFont(ofSize: 11).withTraits(.italic), .foregroundColor: dim,
                                   .paragraphStyle: paragraph(spacingBefore: gap)])
            }
            previousKind = item.kind
        }
        return out
    }
}

/// Markdown to attributed text with Foundation's parser: headings, emphasis, inline code,
/// code blocks set apart, lists, quotes and links.
enum TernAgentMarkdown {
    static func render(_ text: String, font: NSFont, color: NSColor, mono: NSFont, codeBackground: NSColor) -> NSAttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: false, interpretedSyntax: .full, failurePolicy: .returnPartiallyParsedIfPossible)
        guard let parsed = try? AttributedString(markdown: text, options: options) else {
            return NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
        }
        let out = NSMutableAttributedString()
        var lastBlock: Int?
        var lastListItem: Int?
        for run in parsed.runs {
            var content = String(parsed[run.range].characters)
            let components = run.presentationIntent?.components ?? []
            let block = components.first?.identity
            if let lastBlock, let block, block != lastBlock {
                out.append(NSAttributedString(string: "\n", attributes: [.font: font]))
            }
            lastBlock = block
            var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
            var isCodeBlock = false
            for component in components {
                switch component.kind {
                case .codeBlock:
                    isCodeBlock = true
                    attrs[.font] = mono
                    attrs[.backgroundColor] = codeBackground
                    let style = NSMutableParagraphStyle()
                    style.headIndent = 8
                    style.firstLineHeadIndent = 8
                    attrs[.paragraphStyle] = style
                case .header(let level):
                    let size = max(font.pointSize, font.pointSize + CGFloat(4 - min(level, 4)) * 1.5)
                    attrs[.font] = NSFont.systemFont(ofSize: size, weight: .semibold)
                case .blockQuote:
                    attrs[.foregroundColor] = color.withAlphaComponent(0.7)
                case .listItem(let ordinal):
                    if component.identity != lastListItem {
                        lastListItem = component.identity
                        let ordered = components.contains { if case .orderedList = $0.kind { return true }; return false }
                        content = (ordered ? "\(ordinal). " : "• ") + content
                    }
                    let style = NSMutableParagraphStyle()
                    style.headIndent = 14
                    style.firstLineHeadIndent = 2
                    attrs[.paragraphStyle] = style
                default:
                    break
                }
            }
            if !isCodeBlock, let inline = run.inlinePresentationIntent {
                if inline.contains(.code) {
                    attrs[.font] = mono
                    attrs[.backgroundColor] = codeBackground
                }
                if inline.contains(.stronglyEmphasized) {
                    attrs[.font] = (attrs[.font] as? NSFont ?? font).withTraits(.bold)
                }
                if inline.contains(.emphasized) {
                    attrs[.font] = (attrs[.font] as? NSFont ?? font).withTraits(.italic)
                }
                if inline.contains(.strikethrough) { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            }
            if let link = run.link { attrs[.link] = link }
            if isCodeBlock, content.hasSuffix("\n") { content.removeLast() }
            out.append(NSAttributedString(string: content, attributes: attrs))
        }
        return out
    }
}

extension NSFont {
    func withTraits(_ traits: NSFontDescriptor.SymbolicTraits) -> NSFont {
        let descriptor = fontDescriptor.withSymbolicTraits(fontDescriptor.symbolicTraits.union(traits))
        return NSFont(descriptor: descriptor, size: pointSize) ?? self
    }
}
