import Foundation

/// How the Markdown preview looks: as Warp draws a Markdown file (Warp parity, 2026-11-05).
/// Warp's numbers, from its notebook editor's styles: Roboto (bundled, OFL) at 13 px with a line
/// height of 1.5, the full width of the pane, headings at 2.25/1.8/1.5/1/0.83/0.67 em (h1–h4
/// semibold, h5–h6 regular), inline code in the terminal's red on `surface_3`, code blocks with a
/// 1 px `surface_3` border on the background and a footer naming the language, tables with 12 px
/// cell padding in the secondary text color with row lines only, a 3 px rule and checkboxes
/// filled with the accent. Colors are Warp's default Dark theme (Light on a light background):
/// `surface_3` is the foreground at 15% over the background, secondary text 60%, main text 90%.
enum UmiMarkdownStyle {
    /// Roboto, embedded in the page (the preview loads nothing from outside): its Latin and
    /// Latin Extended subsets, upright and italic, every weight (a variable font).
    static let fonts: String = {
        let faces: [(file: String, style: String, range: String)] = [
            ("umi-roboto-latin-wght-normal", "normal", latin),
            ("umi-roboto-latin-wght-italic", "italic", latin),
            ("umi-roboto-latin-ext-wght-normal", "normal", latinExt),
            ("umi-roboto-latin-ext-wght-italic", "italic", latinExt),
        ]
        return faces.compactMap { face -> String? in
            guard let url = Bundle.main.url(forResource: face.file, withExtension: "woff2"),
                  let data = try? Data(contentsOf: url) else { return nil }
            return "@font-face { font-family: 'Umi Roboto'; font-style: \(face.style); font-weight: 100 900; "
                + "src: url(data:font/woff2;base64,\(data.base64EncodedString())) format('woff2'); unicode-range: \(face.range); }"
        }.joined(separator: "\n")
    }()

    private static let latin = "U+0000-00FF,U+0131,U+0152-0153,U+02BB-02BC,U+02C6,U+02DA,U+02DC,U+0304,U+0308,U+0329,U+2000-206F,U+20AC,U+2122,U+2191,U+2193,U+2212,U+2215,U+FEFF,U+FFFD"
    private static let latinExt = "U+0100-02BA,U+02BD-02C5,U+02C7-02CC,U+02CE-02D7,U+02DD-02FF,U+0304,U+0308,U+0329,U+1D00-1DBF,U+1E00-1E9F,U+1EF2-1EFF,U+2020,U+20A0-20AB,U+20AD-20C0,U+2113,U+2C60-2C7F,U+A720-A7FF"

    /// Warp's default themes: foreground, background, accent and the terminal's normal colors
    /// that its code highlighting uses (keywords magenta, functions blue, strings and numbers
    /// green, types and tags red, comments yellow, properties cyan).
    struct Palette {
        let ink: String, solidBackground: String, surface2: String
        let red: String, green: String, yellow: String, blue: String, magenta: String, cyan: String
        let check: String
        let scheme: String

        static let dark = Palette(ink: "255,255,255", solidBackground: "#000000", surface2: "#1a1a1a",
                                  red: "#ff8272", green: "#b4fa72", yellow: "#fefdc2", blue: "#a5d5fe",
                                  magenta: "#ff8ffd", cyan: "#d0d1fe", check: "#ffffff", scheme: "dark")
        static let light = Palette(ink: "17,17,17", solidBackground: "#ffffff", surface2: "#e7e7e7",
                                   red: "#c30771", green: "#10a778", yellow: "#a89c14", blue: "#008ec4",
                                   magenta: "#523c79", cyan: "#20a5ba", check: "#111111", scheme: "light")
    }

    static func css(light: Bool, background: String) -> String {
        let p = light ? Palette.light : Palette.dark
        return """
        :root { color-scheme: \(p.scheme);
          --fg: rgba(\(p.ink),0.9); --fg-sub: rgba(\(p.ink),0.6); --fg-hint: rgba(\(p.ink),0.4);
          --surface-3: rgba(\(p.ink),0.15); --neutral-4: rgba(\(p.ink),0.2); --outline: rgba(\(p.ink),0.1);
          --surface-2: \(p.surface2); --bg: \(p.solidBackground); --accent: #19aad8; --red: \(p.red); --check: \(p.check);
          --mono: "SF Mono", Menlo, monospace; --ui: 'Umi Roboto', Roboto, -apple-system, BlinkMacSystemFont, sans-serif; }
        html, body { margin: 0; background: \(background); }
        body { color: var(--fg); font: 13px/1.5 var(--ui); padding: 16px 20px 60px; -webkit-font-smoothing: antialiased; }
        h1, h2, h3, h4, h5, h6 { color: var(--fg); font-weight: 600; line-height: 1.5; margin: 0.9em 0 0.3em; }
        h1 { font-size: 2.25em; } h2 { font-size: 1.8em; } h3 { font-size: 1.5em; } h4 { font-size: 1em; }
        h5 { font-size: 0.83em; font-weight: 400; } h6 { font-size: 0.67em; font-weight: 400; }
        body > :first-child, body > .front-matter + * { margin-top: 0; }
        p, ul, ol, blockquote, .umi-table { margin: 0 0 1em; }
        a { color: var(--accent); text-decoration: none; } a:hover { text-decoration: underline; }
        code { font: 13px/1.5 var(--mono); }
        :not(pre) > code, p code, li code, td code, th code { color: var(--red); background: var(--surface-3); padding: 0.05em 0.3em; border-radius: 3px; }
        blockquote { margin-left: 0; padding: 0 0 0 14px; border-left: 3px solid var(--surface-3); color: var(--fg-sub); }
        hr { border: none; height: 3px; background: var(--surface-3); margin: 1em 0; }
        ul, ol { padding-left: 20px; } li > p { margin: 0.1em 0; }
        li.task { list-style: none; margin-left: -20px; }
        li.task input[type=checkbox] { -webkit-appearance: none; appearance: none; width: 14px; height: 14px; margin: 0 8px 0 0;
          vertical-align: -2px; border: 2px solid var(--check); border-radius: 3px; box-sizing: border-box; position: relative; opacity: 1; }
        li.task input[type=checkbox]:checked { background: var(--accent); border-color: var(--accent); }
        li.task input[type=checkbox]:checked::after { content: ""; position: absolute; left: 3px; top: 0px; width: 4px; height: 7px;
          border: solid #fff; border-width: 0 2px 2px 0; transform: rotate(45deg); }
        .umi-table { overflow-x: auto; }
        .umi-table table { border-collapse: collapse; }
        .umi-table th, .umi-table td { padding: 12px; border-bottom: 1px solid var(--neutral-4); color: var(--fg-sub); white-space: nowrap; text-align: left; }
        .umi-table th { color: var(--fg); font-weight: 600; }
        .umi-table tr:last-child td { border-bottom: none; }
        img { max-width: 100%; }

        .umi-code { border: 1px solid var(--surface-3); border-radius: 8px; background: var(--bg); margin: 8px 16px 1em 4px; position: relative; }
        .umi-code pre { margin: 0; padding: 16px 8px 0 16px; overflow-x: auto; background: none; }
        .umi-code pre code { color: var(--fg); background: none; padding: 0; tab-size: 4; }
        .umi-code-footer { height: 42px; display: flex; align-items: center; justify-content: flex-end; gap: 4px; padding: 0 8px 0 16px; font: 12px var(--ui); }
        .umi-code-footer::before { content: attr(data-label); color: var(--fg-sub); font-weight: 300; margin-right: auto; }
        .umi-code-footer button { font: 12px var(--ui); color: var(--fg-sub); background: none; border: none; border-radius: 4px; height: 24px; padding: 0 8px; cursor: default; }
        .umi-code-footer button:hover { background: var(--surface-3); color: var(--fg); }
        .umi-code-footer button.umi-copy::before { content: "Copy"; }
        .umi-code-footer button.umi-copy.umi-done::before { content: "Copied"; }
        .umi-code-footer button.umi-run::before { content: "Run in terminal"; }
        .umi-code-footer button.umi-full::before { content: "Open full screen"; }
        .umi-mode { display: inline-flex; gap: 2px; padding: 2px; margin-left: 8px; border: 1px solid var(--surface-3); border-radius: 4px; background: var(--bg); }
        .umi-code-footer .umi-mode button { height: 20px; padding: 0 6px; }
        .umi-code-footer .umi-mode button.umi-on { background: var(--surface-3); color: var(--fg); }
        .umi-mode .umi-raw::before { content: "Raw"; } .umi-mode .umi-rendered::before { content: "Rendered"; }
        .umi-mermaid-view { padding: 16px 16px 0; overflow-x: auto; text-align: center; }
        .umi-mermaid-view svg { max-width: 100%; height: auto; }
        .umi-mermaid.umi-showing-diagram pre { display: none; }
        .umi-mermaid:not(.umi-showing-diagram) .umi-mermaid-view { display: none; }
        .umi-mermaid-error { color: var(--red); font: 12px var(--ui); padding: 8px 16px 0; white-space: pre-wrap; }

        .hljs-keyword, .hljs-literal, .hljs-selector-tag, .hljs-doctag { color: \(p.magenta); }
        .hljs-title, .hljs-title.function_, .hljs-built_in, .hljs-section { color: \(p.blue); }
        .hljs-string, .hljs-regexp, .hljs-char, .hljs-number, .hljs-symbol, .hljs-addition { color: \(p.green); }
        .hljs-type, .hljs-title.class_, .hljs-tag, .hljs-name, .hljs-deletion { color: \(p.red); }
        .hljs-comment, .hljs-quote { color: \(p.yellow); }
        .hljs-attr, .hljs-attribute, .hljs-property, .hljs-variable, .hljs-template-variable, .hljs-params { color: \(p.cyan); }
        .hljs-emphasis { font-style: italic; } .hljs-strong { font-weight: 600; }

        ::highlight(umi-find) { background-color: rgba(255,254,61,0.7); color: #000; }
        ::highlight(umi-find-current) { background-color: rgba(238,146,59,0.7); color: #000; }
        #umi-find { position: fixed; top: 10px; right: 20px; width: min(500px, calc(100vw - 40px)); box-sizing: border-box; z-index: 40;
          display: none; align-items: center; gap: 4px; padding: 0 14px 0 12px; height: 46px; background: var(--surface-2);
          border: 1px solid var(--outline); border-radius: 6px; font: 12px var(--ui); color: var(--fg); }
        #umi-find.umi-open { display: flex; }
        #umi-find input { flex: 1; min-width: 60px; font: 13px var(--ui); color: var(--fg); background: none; border: none; outline: none; padding: 0 4px; }
        #umi-find .umi-count { color: var(--fg-sub); white-space: nowrap; padding: 0 6px; }
        #umi-find .umi-sep { width: 1px; height: 20px; background: var(--outline); margin: 0 4px; }
        #umi-find button { font: 12px var(--ui); color: var(--fg-sub); background: none; border: none; border-radius: 4px; min-width: 24px; height: 24px; padding: 0 5px; cursor: default; }
        #umi-find button:hover { background: var(--surface-3); color: var(--fg); }
        #umi-find button:disabled { opacity: 0.4; }
        #umi-find button.umi-on { background: var(--surface-3); color: var(--fg); }
        #umi-find .umi-prev::before { content: "\\2191"; } #umi-find .umi-next::before { content: "\\2193"; }
        #umi-find .umi-regex::before { content: ". *"; } #umi-find .umi-case::before { content: "Aa"; }
        #umi-find .umi-close::before { content: "\\2715"; }
        #umi-lightbox { position: fixed; inset: 0; z-index: 50; display: none; align-items: center; justify-content: center;
          background: rgba(0,0,0,0.8); }
        #umi-lightbox.umi-open { display: flex; }
        #umi-lightbox .umi-frame { background: var(--bg); border-radius: 8px; padding: 24px; max-width: calc(100vw - 48px);
          max-height: calc(100vh - 48px); box-sizing: border-box; overflow: auto; }
        #umi-lightbox svg { display: block; width: calc(100vw - 96px); max-width: none; height: auto; max-height: calc(100vh - 96px); }

        .front-matter { font-size: 12px; color: var(--fg-sub); margin: 0 0 1.6em; }
        table.front-matter { width: 100%; border-collapse: collapse; border-top: 1px solid var(--neutral-4); }
        table.front-matter th, table.front-matter td { padding: 4px 12px 4px 0; vertical-align: top; font-weight: 400; text-align: left; }
        table.front-matter th { color: var(--fg-sub); width: 1%; white-space: nowrap; font: 12px/1.6 var(--mono); }
        table.front-matter td { color: var(--fg); }
        table.front-matter pre { margin: 0; padding: 0; background: none; font: 12px/1.6 var(--mono); white-space: pre-wrap; }
        pre.front-matter { font: 12px/1.6 var(--mono); }
        """
    }
}
