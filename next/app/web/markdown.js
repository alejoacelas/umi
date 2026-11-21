// The Markdown preview's page (SPEC E-1, E-7, MD-1..MD-4), as Umi draws it (UmiMarkdown*.swift):
// Warp's look, code blocks with a language footer and Copy, Mermaid diagrams, find, heading
// anchors, task lists, front matter as a table, review markup (comments.js) as marks.
//
// The page goes into an iframe (views/file.js) with a Content-Security-Policy that allows no
// scripts, so a document's own scripts, inline handlers and javascript: links never run and can't
// reach Umi.bridge. Everything interactive is attached from here, by the parent page.
//
//   Umi.markdown.shell()                    → srcdoc for the iframe: CSP, styles, empty body
//   Umi.markdown.render(text, resolvedIds)  → {html, preview}  body HTML; every text run is a
//       <span data-s="fileOffset"> so a selection maps back to the file (comments)
//   Umi.markdown.fill(doc, html)            puts the HTML in the iframe's body, without anything
//       that could run or navigate (script, iframe, object, embed, base, meta, forms, on* handlers)
//   Umi.markdown.enhance(doc, win, ctx)     → the page's controller {find…, state()}: highlighting, code
//       footers (Copy, Run in terminal), Mermaid, the find bar, the diagram lightbox, links, images.
//       ctx: {dir, openFile(path, hash), openURL(url), copy(text), run(text), keydown(e)}
'use strict';
window.Umi = window.Umi || {};

Umi.markdown = (() => {
  const SHELLS = new Set(['sh', 'shell', 'bash', 'fish', 'zsh', 'warp-runnable-command']);
  const LABELS = { '': 'Code', text: 'Code', mermaid: 'Mermaid', go: 'Go', golang: 'Go', 'c++': 'C++', cpp: 'C++',
    'c#': 'C#', csharp: 'C#', cs: 'C#', java: 'Java', groovy: 'Java', javascript: 'JavaScript', jsx: 'JavaScript', js: 'JavaScript',
    python: 'Python', py: 'Python', ruby: 'Ruby on Rails', 'ruby on rails': 'Ruby on Rails', rust: 'Rust', sql: 'SQL', yaml: 'YAML',
    json: 'JSON', php: 'PHP', toml: 'TOML', swift: 'Swift', kotlin: 'Kotlin', powershell: 'PowerShell' };
  const label = (id) => (SHELLS.has(id) ? 'Shell' : LABELS[id] ?? id);
  const esc = (t) => String(t).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');

  // ---- Styles (UmiMarkdownStyle.swift and UmiCommentsScript.swift, Warp's default Dark) ----

  const p = { ink: '255,255,255', bg: '#050505', solid: '#000000', surface2: '#1a1a1a', red: '#ff8272', green: '#b4fa72',
    yellow: '#fefdc2', blue: '#a5d5fe', magenta: '#ff8ffd', cyan: '#d0d1fe', accent: '#19aad8', check: '#ffffff' };
  const size = 13;
  const font = (file, style, range) => `@font-face { font-family: 'Umi Roboto'; font-style: ${style}; font-weight: 100 900; src: url(lib/${file}.woff2) format('woff2'); unicode-range: ${range}; }`;
  const LATIN = 'U+0000-00FF,U+0131,U+0152-0153,U+02BB-02BC,U+02C6,U+02DA,U+02DC,U+0304,U+0308,U+0329,U+2000-206F,U+20AC,U+2122,U+2191,U+2193,U+2212,U+2215,U+FEFF,U+FFFD';
  const LATIN_EXT = 'U+0100-02BA,U+02BD-02C5,U+02C7-02CC,U+02CE-02D7,U+02DD-02FF,U+0304,U+0308,U+0329,U+1D00-1DBF,U+1E00-1E9F,U+1EF2-1EFF,U+2020,U+20A0-20AB,U+20AD-20C0,U+2113,U+2C60-2C7F,U+A720-A7FF';

  const CSS = `
${font('roboto-latin-wght-normal', 'normal', LATIN)}
${font('roboto-latin-wght-italic', 'italic', LATIN)}
${font('roboto-latin-ext-wght-normal', 'normal', LATIN_EXT)}
${font('roboto-latin-ext-wght-italic', 'italic', LATIN_EXT)}
:root { color-scheme: dark;
  --fg: rgba(${p.ink},0.9); --fg-sub: rgba(${p.ink},0.6); --fg-hint: rgba(${p.ink},0.4);
  --surface-3: rgba(${p.ink},0.15); --neutral-4: rgba(${p.ink},0.2); --outline: rgba(${p.ink},0.1);
  --surface-2: ${p.surface2}; --bg: ${p.solid}; --accent: ${p.accent}; --red: ${p.red}; --check: ${p.check};
  --mono: "Hack", "JetBrains Mono", "SF Mono", Menlo, monospace; --ui: 'Umi Roboto', Roboto, -apple-system, BlinkMacSystemFont, sans-serif;
  --umi-mw: 260px;
  --umi-card: #26272b; --umi-input: #1d1e21; --umi-fg: #e6e6e6; --umi-fg2: #a8a8a8; --umi-fg3: #7c7c80;
  --umi-line: rgba(255,255,255,0.09); --umi-line-strong: rgba(255,255,255,0.16); --umi-hover: rgba(255,255,255,0.07);
  --umi-shadow: rgba(0,0,0,0.45); --umi-accent: #0a84ff; --umi-mark: rgba(255, 196, 0, 0.16);
  --umi-mark-line: rgba(255, 196, 0, 0.6); --umi-mark-active: rgba(255, 196, 0, 0.32); }
html, body { margin: 0; background: ${p.bg}; }
body { color: var(--fg); font: ${size}px/1.5 var(--ui); padding: 16px 20px 60px; -webkit-font-smoothing: antialiased; position: relative; }
h1, h2, h3, h4, h5, h6 { color: var(--fg); font-weight: 600; line-height: 1.5; margin: 0.9em 0 0.3em; }
h1 { font-size: 2.25em; } h2 { font-size: 1.8em; } h3 { font-size: 1.5em; } h4 { font-size: 1em; }
h5 { font-size: 0.83em; font-weight: 400; } h6 { font-size: 0.67em; font-weight: 400; }
#umi-doc > :first-child, #umi-doc > .front-matter + * { margin-top: 0; }
p, ul, ol, blockquote, .umi-table { margin: 0 0 1em; }
a { color: var(--accent); text-decoration: none; } a:hover { text-decoration: underline; }
code { font: ${size}px/1.5 var(--mono); }
:not(pre) > code { color: var(--red); background: var(--surface-3); padding: 0.05em 0.3em; border-radius: 3px; }
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
.umi-code-footer { height: 42px; display: flex; align-items: center; gap: 4px; padding: 0 8px 0 16px; font: 12px var(--ui); }
.umi-code-footer::before { content: attr(data-label); color: var(--fg-sub); font-weight: 300; }
.umi-code-footer .umi-copy { margin-left: auto; }
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
.umi-mermaid:not(.umi-showing-diagram) .umi-mermaid-view, .umi-mermaid:not(.umi-showing-diagram) .umi-full { display: none; }
.umi-mermaid-error { color: var(--red); font: 12px var(--ui); padding: 8px 16px 0; white-space: pre-wrap; }
.umi-mermaid-error::before { content: attr(data-error); }
.hljs-keyword, .hljs-selector-tag, .hljs-emphasis { color: ${p.magenta}; }
.hljs-title, .hljs-title.function_, .hljs-section, .hljs-selector-id { color: ${p.blue}; }
.hljs-string, .hljs-char, .hljs-symbol, .hljs-addition, .hljs-title.class_.inherited__ { color: ${p.green}; }
.hljs-name, .hljs-deletion { color: ${p.red}; }
.hljs-title.class_, .hljs-type, .hljs-strong { color: ${p.yellow}; }
.hljs-built_in, .hljs-regexp, .hljs-char.escape_ { color: ${p.cyan}; }
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
#umi-lightbox { position: fixed; inset: 0; z-index: 50; display: none; align-items: center; justify-content: center; background: rgba(0,0,0,0.8); }
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
/* Comments (E-11): the margin is drawn by views/comments.js. */
body.umi-commenting { padding-right: calc(20px + var(--umi-mw) + 24px); }
mark { background: none; color: inherit; }
mark.umi-hl { background: rgba(255, 214, 10, 0.22); border-radius: 2px; }
mark.umi-c { background: var(--umi-mark); border-bottom: 2px solid var(--umi-mark-line); border-radius: 2px; cursor: pointer; }
mark.umi-c.umi-resolved { background: none; border-bottom: none; cursor: auto; }
mark.umi-c.umi-active { background: var(--umi-mark-active); }
span.umi-pin::after { content: "\\201D"; display: inline-block; font-size: 0.75em; line-height: 1; padding: 1px 4px;
  margin: 0 2px; border-radius: 4px; background: var(--umi-mark); color: var(--umi-fg2); cursor: pointer; vertical-align: 0.1em; }
span.umi-pin.umi-resolved::after { display: none; }
ins { background: rgba(46, 160, 67, 0.18); text-decoration: none; border-bottom: 1px solid rgba(46,160,67,0.6); }
del { background: rgba(248, 81, 73, 0.14); color: var(--umi-fg2); }
::highlight(umi-pending) { background-color: var(--umi-mark-active); }
#umi-ui { position: absolute; top: 0; right: 0; width: 0; height: 0; z-index: 10;
  font: 12.5px/1.45 -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif; }
#umi-margin { position: absolute; top: 0; width: var(--umi-mw); }
.umi-card { position: absolute; left: 0; width: var(--umi-mw); box-sizing: border-box; padding: 9px 11px 10px;
  background: var(--umi-card); border: 1px solid var(--umi-line); border-radius: 9px; color: var(--umi-fg);
  transition: top 0.12s ease, box-shadow 0.12s ease; cursor: default; }
.umi-card.umi-selected { box-shadow: 0 3px 14px var(--umi-shadow); border-color: var(--umi-line-strong); z-index: 2; }
.umi-card.umi-resolved-card { opacity: 0.62; }
.umi-card.umi-detached { border-style: dashed; }
.umi-head { display: flex; align-items: center; gap: 6px; min-height: 20px; }
.umi-who { font-weight: 600; } .umi-when { color: var(--umi-fg3); font-size: 11.5px; }
.umi-head .umi-spacer { flex: 1; }
.umi-icon { border: none; background: none; color: var(--umi-fg2); width: 22px; height: 22px; border-radius: 5px;
  font-size: 13px; line-height: 22px; padding: 0; cursor: pointer; text-align: center; }
.umi-icon:hover { background: var(--umi-hover); color: var(--umi-fg); }
.umi-text { white-space: pre-wrap; word-wrap: break-word; margin-top: 3px; }
.umi-quote { color: var(--umi-fg2); font-size: 11.5px; margin-top: 4px; border-left: 2px solid var(--umi-mark-line);
  padding-left: 6px; white-space: pre-wrap; word-wrap: break-word; }
.umi-note { color: var(--umi-fg3); font-size: 11.5px; margin-top: 4px; }
.umi-reply { margin-top: 9px; padding-top: 8px; border-top: 1px solid var(--umi-line); }
.umi-card textarea { display: block; width: 100%; box-sizing: border-box; margin-top: 7px; min-height: 52px; max-height: 240px; resize: none; overflow-y: auto;
  font: inherit; color: var(--umi-fg); background: var(--umi-input); border: 1px solid var(--umi-line-strong);
  border-radius: 6px; padding: 6px 7px; outline: none; }
.umi-card textarea:focus { border-color: var(--umi-accent); }
.umi-card textarea.umi-small { min-height: 30px; height: 30px; }
.umi-actions { display: flex; justify-content: flex-end; align-items: center; gap: 6px; margin-top: 7px; }
.umi-btn { font: inherit; font-size: 12px; border-radius: 6px; padding: 3px 10px; cursor: pointer; border: 1px solid var(--umi-line-strong);
  background: none; color: var(--umi-fg); }
.umi-btn.umi-primary { background: var(--umi-accent); border-color: var(--umi-accent); color: #fff; }
.umi-btn.umi-danger { color: #e5534b; border-color: rgba(229,83,75,0.5); }
.umi-btn:disabled { opacity: 0.5; cursor: default; }
.umi-error { color: #e5534b; font-size: 11.5px; margin-top: 6px; }
.umi-menu { position: absolute; right: 8px; top: 30px; background: var(--umi-card); border: 1px solid var(--umi-line-strong);
  border-radius: 7px; box-shadow: 0 4px 16px var(--umi-shadow); padding: 3px; z-index: 5; }
.umi-menu button { display: block; width: 100%; text-align: left; border: none; background: none; color: var(--umi-fg);
  font: inherit; padding: 4px 12px; border-radius: 4px; cursor: pointer; }
.umi-menu button:hover { background: var(--umi-hover); }
#umi-add { position: absolute; display: none; white-space: nowrap; font: 600 12px/1 -apple-system, sans-serif;
  padding: 6px 10px; border-radius: 7px; border: 1px solid var(--umi-line-strong); background: var(--umi-card);
  color: var(--umi-fg); box-shadow: 0 2px 10px var(--umi-shadow); cursor: pointer; z-index: 6; }
#umi-add:hover { border-color: var(--umi-accent); }
#umi-add .umi-key { color: var(--umi-fg3); font-weight: 400; margin-left: 6px; }
#umi-bar { position: fixed; bottom: 12px; right: 14px; display: none; align-items: center; gap: 8px; z-index: 20;
  font: 12px/1 -apple-system, BlinkMacSystemFont, sans-serif; color: var(--umi-fg2); background: var(--umi-card);
  border: 1px solid var(--umi-line); border-radius: 8px; padding: 4px 4px 4px 10px; box-shadow: 0 2px 10px var(--umi-shadow); }
#umi-bar .umi-link { border: none; background: none; color: var(--umi-fg2); font: inherit; cursor: pointer; padding: 3px 4px; }
#umi-bar .umi-link:hover { color: var(--umi-fg); }
#umi-bar .umi-waiting { display: inline-flex; align-items: center; gap: 5px; color: var(--umi-accent); }
#umi-bar .umi-dot { width: 7px; height: 7px; border-radius: 50%; background: var(--umi-accent); }
#umi-toast { position: fixed; bottom: 54px; right: 14px; max-width: 320px; display: none; z-index: 30;
  font: 12px/1.4 -apple-system, sans-serif; color: var(--umi-fg); background: var(--umi-card);
  border: 1px solid var(--umi-line-strong); border-radius: 8px; padding: 8px 11px; box-shadow: 0 4px 16px var(--umi-shadow); }
`;

  // No script runs in the page: the document's raw HTML can show images but never run code.
  const CSP = "default-src 'none'; script-src 'none'; object-src 'none'; frame-src 'none'; form-action 'none'; base-uri 'none'; "
    + "img-src * data: blob:; style-src 'unsafe-inline' file: *; font-src file: data: *; media-src * data:";

  const shell = () => `<!doctype html><html><head><meta charset="utf-8"><meta http-equiv="Content-Security-Policy" content="${CSP}"><style>${CSS}</style></head><body><div id="umi-doc"></div></body></html>`;

  // ---- Markdown → HTML ----

  let md = null;
  function parser() {
    if (md) return md;
    md = window.markdownit({ html: true, linkify: true, typographer: false });
    md.linkify.set({ fuzzyEmail: false });
    // Task list items: `[ ]` / `[x]` at the start of a list item.
    md.core.ruler.after('inline', 'umi-tasks', (state) => {
      const t = state.tokens;
      for (let i = 2; i < t.length; i++) {
        if (t[i].type !== 'inline' || t[i - 1].type !== 'paragraph_open' || t[i - 2].type !== 'list_item_open') continue;
        const first = t[i].children[0];
        const m = first && first.type === 'text' && /^\[([ xX])\] /.exec(first.content);
        if (!m) continue;
        first.content = first.content.slice(4);
        const box = new state.Token('html_inline', '', 0);
        box.content = `<input type="checkbox" disabled${m[1] === ' ' ? '' : ' checked'}> `;
        box.meta = { synthetic: true };
        t[i].children.unshift(box);
        t[i - 2].attrJoin('class', 'task');
      }
    });
    // Heading ids, GitHub's way: repeats get -1, -2 (unique against every id so far).
    md.core.ruler.push('umi-anchors', (state) => {
      const used = {}, emitted = new Set();
      const t = state.tokens;
      for (let i = 0; i < t.length; i++) {
        if (t[i].type !== 'heading_open') continue;
        const text = (t[i + 1].children || []).filter((c) => c.type === 'text' || c.type === 'code_inline').map((c) => c.content).join('');
        let slug = [...text.toLowerCase()].map((c) => (/[\p{L}\p{N}_-]/u.test(c) ? c : c === ' ' ? '-' : '')).join('') || 'section';
        let candidate = slug, n = used[slug] || 0;
        while (emitted.has(candidate)) candidate = `${slug}-${++n}`;
        used[slug] = n;
        emitted.add(candidate);
        t[i].attrSet('id', candidate);
      }
    });
    const r = md.renderer.rules;
    r.table_open = () => '<div class="umi-table"><table>\n';
    r.table_close = () => '</table></div>\n';
    return md;
  }

  // Front matter at the very top: `---` … `---` (or `...`). → {yaml, end} or null.
  function frontMatter(src) {
    const m = /^---[ \t]*\r?\n/.exec(src);
    if (!m) return null;
    const re = /^(---|\.\.\.)[ \t]*(\r?\n|$)/gm;
    re.lastIndex = m[0].length;
    const close = re.exec(src);
    return close ? { yaml: src.slice(m[0].length, close.index), end: close.index + close[0].length } : null;
  }

  function frontMatterHTML(yaml) {
    const rows = [];
    let isMap = true;
    for (const line of yaml.split('\n').map((l) => l.replace(/\r$/, ''))) {
      if (!line.trim() || line.startsWith('#')) continue;
      if (/^[ \t]/.test(line) || line.startsWith('- ') || line === '-') {
        if (!rows.length) { isMap = false; break; }
        rows[rows.length - 1].block.push(line);
        continue;
      }
      const c = /:(\s|$)/.exec(line);
      if (!c || c.index === 0) { isMap = false; break; }
      rows.push({ key: line.slice(0, c.index).trim(), value: line.slice(c.index + 1).trim(), block: [] });
    }
    if (!isMap) return `<pre class="front-matter"><code>${esc(yaml)}</code></pre>`;
    if (!rows.length) return '';
    return '<table class="front-matter">' + rows.map((row) => {
      let v = esc(row.value);
      if (row.block.length) {
        if (/^[|>][-+0-9]*$/.test(row.value)) v = '';
        const indent = Math.min(...row.block.filter((l) => l.trim()).map((l) => l.length - l.replace(/^ +/, '').length));
        v += `<pre>${esc(row.block.map((l) => l.slice(Math.min(indent, l.length - l.replace(/^ +/, '').length))).join('\n').replace(/\s+$/, ''))}</pre>`;
      }
      return `<tr><th>${esc(row.key)}</th><td>${v}</td></tr>`;
    }).join('') + '</table>';
  }

  function render(text, resolvedIds = new Set()) {
    const m = parser();
    const preview = UmiComments.preview(text, resolvedIds);
    const source = preview.source;
    const fm = frontMatter(source);
    const start = fm ? fm.end : 0;
    const src = source.slice(start);
    // Where each line of `src` starts in `source`.
    const lines = [start];
    for (let i = 0; i < src.length; i++) if (src.charCodeAt(i) === 10) lines.push(start + i + 1);
    const env = {};
    const tokens = m.parse(src, env);
    for (const t of tokens) {
      if (!t.map) continue;
      const base = lines[t.map[0]];
      t.meta = { ...(t.meta || {}), base };
      for (const c of t.children || []) c.meta = { ...(c.meta || {}), base };
    }
    // Text runs found in `source` in order (as Umi does): a run whose text is there gets its file
    // offset; one that isn't (an escape, an entity) is left unmarked.
    let cursor = start;
    const trace = (content, token) => {
      if (token.meta?.base > cursor) cursor = token.meta.base;
      if (!content) return '';
      const at = source.indexOf(content, cursor);
      if (at < 0 || at - cursor > content.length + 4000) return esc(content);
      cursor = at + content.length;
      const off = preview.fileOffset(at, at + content.length);
      return off == null ? esc(content) : `<span data-s="${off}">${esc(content)}</span>`;
    };
    const r = m.renderer.rules;
    r.text = (t, i) => trace(t[i].content, t[i]);
    r.code_inline = (t, i) => `<code>${trace(t[i].content, t[i])}</code>`;
    r.html_inline = (t, i) => {
      const tok = t[i];
      if (!tok.meta?.synthetic) {
        const at = source.indexOf(tok.content, Math.max(cursor, tok.meta?.base || 0));
        if (at >= 0) cursor = at + tok.content.length;
      }
      return tok.content;
    };
    r.html_block = (t, i) => {
      const tok = t[i];
      const at = source.indexOf(tok.content, Math.max(cursor, tok.meta?.base || 0));
      if (at >= 0) cursor = at + tok.content.length;
      return tok.content;
    };
    const code = (t, i) => {
      const tok = t[i];
      const id = (tok.info || '').trim().split(/\s+/)[0].toLowerCase();
      const kind = SHELLS.has(id) ? ' umi-shell' : id === 'mermaid' ? ' umi-mermaid' : '';
      return `<div class="umi-code${kind}" data-lang="${esc(id)}"><pre><code>${trace(tok.content, tok)}</code></pre>`
        + `<div class="umi-code-footer" data-label="${esc(label(id))}"></div></div>\n`;
    };
    r.fence = code;
    r.code_block = code;
    const html = (fm ? frontMatterHTML(fm.yaml) : '') + m.renderer.render(tokens, m.options, env);
    return { html, preview };
  }

  // ---- Into the iframe ----

  const BLOCKED = 'script, iframe, frame, frameset, object, embed, applet, base, meta, link, form, portal, noscript';
  function fill(doc, html) {
    const tpl = doc.createElement('template');
    tpl.innerHTML = html;
    const root = tpl.content;
    root.querySelectorAll(BLOCKED).forEach((e) => e.remove());
    for (const e of root.querySelectorAll('*')) {
      for (const a of [...e.attributes]) {
        const n = a.name.toLowerCase();
        if (n.startsWith('on') || n === 'srcdoc' || n === 'formaction'
          || ((n === 'href' || n === 'src' || n === 'xlink:href' || n === 'action') && /^\s*(javascript|vbscript):/i.test(a.value))) e.removeAttribute(a.name);
      }
    }
    doc.getElementById('umi-doc').replaceChildren(root);
  }

  // ---- What the page does (UmiMarkdownScript.swift), attached from outside ----

  let mermaidLoading = null;
  function loadMermaid() {
    if (window.mermaid) return Promise.resolve();
    if (!mermaidLoading) {
      mermaidLoading = new Promise((resolve, reject) => {
        const s = document.createElement('script');
        s.src = 'lib/mermaid.min.js';
        s.onload = () => resolve();
        s.onerror = () => reject(new Error('mermaid did not load'));
        document.head.append(s);
      }).then(() => {
        // The bundle sets __esbuild_esm_mermaid; its default export is the API.
        if (!window.mermaid && window.__esbuild_esm_mermaid) window.mermaid = window.__esbuild_esm_mermaid.default || window.__esbuild_esm_mermaid;
      });
    }
    return mermaidLoading;
  }

  function enhance(doc, win, ctx) {
    const el = (tag, cls, attrs) => { const e = doc.createElement(tag); if (cls) e.className = cls; Object.assign(e, attrs || {}); return e; };
    const codeText = (block) => { const c = block.querySelector('pre > code'); return c ? c.textContent : ''; };
    const page = doc.getElementById('umi-doc');

    // Code blocks: highlighting, Copy, Run in terminal, Mermaid's Raw / Rendered and full screen.
    let highlighted = 0;
    for (const block of page.querySelectorAll('.umi-code')) {
      const code = block.querySelector('pre > code');
      const footer = block.querySelector('.umi-code-footer');
      const lang = block.dataset.lang || '';
      if (!code || !footer) continue;
      if (window.hljs && lang && !block.classList.contains('umi-mermaid')) {
        const language = SHELLS.has(lang) ? 'bash' : lang;
        // Highlight inside the run's span, so the text keeps its file offset (comments).
        const target = code.children.length === 1 && code.firstElementChild.matches('span[data-s]') ? code.firstElementChild : code;
        if (hljs.getLanguage(language) && target.children.length === 0) {
          try {
            target.innerHTML = hljs.highlight(target.textContent, { language, ignoreIllegals: true }).value;
            block.classList.add('umi-highlighted');
            highlighted++;
          } catch (e) { /* left plain */ }
        }
      }
      if (block.classList.contains('umi-mermaid')) {
        const mode = el('span', 'umi-mode');
        const raw = el('button', 'umi-raw', { type: 'button', title: 'Raw' });
        const rendered = el('button', 'umi-rendered umi-on', { type: 'button', title: 'Rendered' });
        raw.addEventListener('click', () => showDiagram(block, false));
        rendered.addEventListener('click', () => showDiagram(block, true));
        mode.append(raw, rendered);
        const full = el('button', 'umi-full', { type: 'button', title: 'Open full screen' });
        full.addEventListener('click', () => lightbox.open(block));
        footer.append(mode, full);
      }
      const copy = el('button', 'umi-copy', { type: 'button', title: 'Copy' });
      copy.addEventListener('click', () => {
        ctx.copy(codeText(block).trim());
        copy.classList.add('umi-done');
        setTimeout(() => copy.classList.remove('umi-done'), 1200);
      });
      footer.append(copy);
      if (block.classList.contains('umi-shell') && ctx.run) {
        const run = el('button', 'umi-run', { type: 'button', title: 'Run in terminal' });
        run.addEventListener('click', () => ctx.run(codeText(block).trim()));
        footer.append(run);
      }
    }

    function showDiagram(block, on) {
      if (on && !block.querySelector('.umi-mermaid-view svg')) on = false;
      block.classList.toggle('umi-showing-diagram', on);
      const raw = block.querySelector('.umi-raw'), rendered = block.querySelector('.umi-rendered');
      if (raw) raw.classList.toggle('umi-on', !on);
      if (rendered) rendered.classList.toggle('umi-on', on);
      ctx.relayout && ctx.relayout();
    }
    let mermaidRuns = 0;
    const mermaidState = { blocks: 0, rendered: 0, errors: 0 };
    async function renderMermaid() {
      const blocks = [...page.querySelectorAll('.umi-mermaid')];
      mermaidState.blocks = blocks.length;
      if (!blocks.length) return mermaidState;
      try { await loadMermaid(); } catch (e) { return mermaidState; }
      mermaid.initialize({ startOnLoad: false, securityLevel: 'strict', theme: 'dark', fontFamily: "'Umi Roboto', Roboto, sans-serif" });
      for (const block of blocks) {
        let view = block.querySelector('.umi-mermaid-view');
        if (!view) { view = el('div', 'umi-mermaid-view'); block.insertBefore(view, block.firstChild); }
        block.querySelector('.umi-mermaid-error')?.remove();
        try {
          const { svg } = await mermaid.render('umi-mermaid-' + Date.now().toString(36) + (++mermaidRuns), codeText(block));
          view.innerHTML = svg;
          showDiagram(block, true);
          mermaidState.rendered++;
        } catch (e) {
          mermaidState.errors++;
          const message = el('div', 'umi-mermaid-error');
          message.dataset.error = String((e && e.message) || e);
          block.insertBefore(message, block.querySelector('pre'));
          showDiagram(block, false);
          document.querySelectorAll('[id^="dumi-mermaid-"]').forEach((x) => x.remove()); // mermaid's leftovers
        }
      }
      ctx.relayout && ctx.relayout();
      return mermaidState;
    }
    const mermaidDone = renderMermaid();

    // The lightbox: a diagram larger, over the page; Esc or a click outside closes it.
    doc.getElementById('umi-lightbox')?.remove();
    const box = el('div'); box.id = 'umi-lightbox';
    const frame = el('div', 'umi-frame');
    box.append(frame);
    doc.body.append(box);
    const lightbox = {
      open(block) {
        const svg = block.classList.contains('umi-showing-diagram') && block.querySelector('.umi-mermaid-view svg');
        if (!svg) return false;
        frame.replaceChildren(svg.cloneNode(true));
        box.classList.add('umi-open');
        return true;
      },
      close() { box.classList.remove('umi-open'); frame.replaceChildren(); },
      get isOpen() { return box.classList.contains('umi-open'); },
    };
    box.addEventListener('click', (e) => { if (e.target === box) lightbox.close(); });

    // Images: local ones (relative to the document, or file:) come through the bridge, since the
    // page may only load files from web/ itself.
    for (const img of page.querySelectorAll('img[src]')) {
      const src = img.getAttribute('src');
      if (/^(https?:|data:|blob:)/i.test(src)) continue;
      let path = src.replace(/^file:\/\//i, '');
      try { path = decodeURIComponent(path.split(/[?#]/)[0]); } catch (e) { /* as is */ }
      const abs = Umi.fs.resolve(path, ctx.dir);
      img.removeAttribute('src');
      Umi.fs.readData(abs).then((d) => { img.src = `data:${d.mime};base64,${d.base64}`; img.addEventListener('load', () => ctx.relayout && ctx.relayout(), { once: true }); },
        () => { img.alt = img.alt || src; img.title = 'Not found: ' + abs; });
    }

    // Links: #anchors scroll here, web links open in the browser, others open the file in Umi.
    const onClick = (e) => {
      const a = e.target.closest && e.target.closest('a[href]');
      if (!a) return;
      e.preventDefault();
      const href = a.getAttribute('href');
      if (href.startsWith('#')) {
        let id = href.slice(1);
        try { id = decodeURIComponent(id); } catch (x) { /* as is */ }
        const target = doc.getElementById(id) || doc.getElementsByName(id)[0];
        if (target) target.scrollIntoView({ block: 'start' });
      } else if (/^(https?|mailto):/i.test(href)) ctx.openURL(href);
      else if (!/^[a-z][a-z0-9+.-]*:/i.test(href) || /^file:/i.test(href)) {
        let [path, hash] = href.replace(/^file:\/\//i, '').split('#');
        try { path = decodeURIComponent(path); } catch (x) { /* as is */ }
        ctx.openFile(Umi.fs.resolve(path, ctx.dir), hash || null);
      }
    };
    // The page element outlives a render: one listener, the latest.
    if (doc.__umiClick) page.removeEventListener('click', doc.__umiClick);
    doc.__umiClick = onClick;
    page.addEventListener('click', onClick);

    // Find (MD-4): Warp's bar at the top right.
    doc.getElementById('umi-find')?.remove();
    const bar = el('div'); bar.id = 'umi-find';
    const input = el('input', '', { type: 'text', placeholder: 'Find', spellcheck: false });
    const count = el('span', 'umi-count');
    const prev = el('button', 'umi-prev', { type: 'button', title: 'Previous match (⇧⌘G)' });
    const next = el('button', 'umi-next', { type: 'button', title: 'Next match (⌘G)' });
    const regex = el('button', 'umi-regex', { type: 'button', title: 'Regex search' });
    const caseButton = el('button', 'umi-case', { type: 'button', title: 'Case-sensitive search' });
    const close = el('button', 'umi-close', { type: 'button', title: 'Close' });
    bar.append(input, count, el('span', 'umi-sep'), prev, next, regex, caseButton, close);
    doc.body.append(bar);
    const find = { open: false, regex: false, caseSensitive: false, ranges: [], current: -1, error: false };
    const highlights = win.CSS && win.CSS.highlights && win.Highlight ? win.CSS.highlights : null;

    function searchable() {
      const out = [];
      const walker = doc.createTreeWalker(page, NodeFilter.SHOW_TEXT, {
        acceptNode: (n) => {
          const pe = n.parentElement;
          if (!pe || pe.closest('.umi-code-footer, .umi-mermaid-view, .umi-mermaid-error, style')) return NodeFilter.FILTER_REJECT;
          if (pe.closest('.umi-showing-diagram pre')) return NodeFilter.FILTER_REJECT;
          return NodeFilter.FILTER_ACCEPT;
        } });
      let n; while ((n = walker.nextNode())) out.push(n);
      return out;
    }
    function search() {
      find.ranges = []; find.current = -1; find.error = false;
      const query = input.value;
      if (find.open && query) {
        let pattern;
        try { pattern = new RegExp(find.regex ? query : query.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'), find.caseSensitive ? 'g' : 'gi'); }
        catch (e) { find.error = true; }
        if (pattern) {
          const nodes = searchable();
          let text = ''; const starts = [];
          for (const n of nodes) { starts.push(text.length); text += n.data; }
          const at = (offset, end) => {
            let lo = 0, hi = nodes.length - 1;
            while (lo < hi) { const mid = (lo + hi + 1) >> 1; if (starts[mid] < offset || (!end && starts[mid] === offset)) lo = mid; else hi = mid - 1; }
            while (!end && lo < nodes.length - 1 && offset - starts[lo] >= nodes[lo].length) lo++;
            return [nodes[lo], offset - starts[lo]];
          };
          let m;
          while ((m = pattern.exec(text)) && find.ranges.length < 2000) {
            if (m[0].length === 0) { pattern.lastIndex++; continue; }
            const [sn, so] = at(m.index, false), [en, eo] = at(m.index + m[0].length, true);
            const r = doc.createRange(); r.setStart(sn, so); r.setEnd(en, eo);
            find.ranges.push(r);
          }
        }
      }
      if (find.ranges.length) {
        const i = find.ranges.findIndex((r) => r.getBoundingClientRect().bottom >= 0);
        find.current = i < 0 ? 0 : i;
      }
      paint(false);
    }
    function paint(scroll) {
      const n = find.ranges.length;
      if (highlights) {
        highlights.delete('umi-find'); highlights.delete('umi-find-current');
        if (find.open && n) {
          highlights.set('umi-find', new win.Highlight(...find.ranges.filter((_, i) => i !== find.current)));
          highlights.set('umi-find-current', new win.Highlight(find.ranges[find.current]));
        }
      }
      count.textContent = !input.value ? '' : find.error ? 'Invalid regex' : n === 0 ? 'No matches' : (find.current + 1) + '/' + n;
      prev.disabled = next.disabled = n === 0;
      regex.classList.toggle('umi-on', find.regex);
      caseButton.classList.toggle('umi-on', find.caseSensitive);
      if (scroll && n) {
        const rect = find.ranges[find.current].getBoundingClientRect();
        if (rect.top < 60 || rect.bottom > win.innerHeight - 20) win.scrollTo({ top: win.scrollY + rect.top - win.innerHeight / 3 });
      }
    }
    function openFind(seed) {
      find.open = true;
      bar.classList.add('umi-open');
      if (seed) input.value = seed;
      input.focus(); input.select();
      search(); paint(true);
    }
    function move(delta) {
      if (!find.open) return openFind();
      const n = find.ranges.length;
      if (n) { find.current = (find.current + delta + n) % n; paint(true); }
    }
    function closeFind() {
      find.open = false; bar.classList.remove('umi-open');
      find.ranges = []; find.current = -1; paint(false);
      if (doc.activeElement === input) { input.blur(); ctx.focusBack && ctx.focusBack(); }
    }
    input.addEventListener('input', () => { search(); paint(true); });
    input.addEventListener('keydown', (e) => {
      if (e.key === 'Enter') { e.preventDefault(); move(e.shiftKey ? -1 : 1); }
      else if (e.key === 'Escape') { e.preventDefault(); e.stopPropagation(); closeFind(); }
    });
    prev.addEventListener('click', () => move(-1));
    next.addEventListener('click', () => move(1));
    regex.addEventListener('click', () => { find.regex = !find.regex; search(); paint(true); input.focus(); });
    caseButton.addEventListener('click', () => { find.caseSensitive = !find.caseSensitive; search(); paint(true); input.focus(); });
    close.addEventListener('click', closeFind);

    // Esc closes the lightbox or the find bar; other keys go to the file view (⌘S, ⌘E, …).
    const onKey = (e) => {
      if (e.key === 'Escape' && lightbox.isOpen) { e.preventDefault(); lightbox.close(); return; }
      if (e.key === 'Escape' && find.open) { e.preventDefault(); closeFind(); return; }
      ctx.keydown && ctx.keydown(e);
    };
    if (doc.__umiKey) doc.removeEventListener('keydown', doc.__umiKey, true);
    doc.__umiKey = onKey;
    doc.addEventListener('keydown', onKey, true);

    function state() {
      const blocks = [...page.querySelectorAll('.umi-code')];
      return {
        code_blocks: blocks.length, highlighted,
        copy_buttons: page.querySelectorAll('.umi-code-footer .umi-copy').length,
        run_buttons: page.querySelectorAll('.umi-code-footer .umi-run').length,
        labels: blocks.map((b) => b.querySelector('.umi-code-footer').dataset.label),
        mermaid: { blocks: page.querySelectorAll('.umi-mermaid').length,
          diagrams: page.querySelectorAll('.umi-mermaid.umi-showing-diagram .umi-mermaid-view svg').length,
          errors: [...page.querySelectorAll('.umi-mermaid-error')].map((e) => e.dataset.error) },
        lightbox: { open: lightbox.isOpen },
        find: { open: find.open, query: input.value, count: find.ranges.length, current: find.current, label: count.textContent,
          current_text: find.current >= 0 ? find.ranges[find.current].toString() : null, regex: find.regex, case_sensitive: find.caseSensitive },
        links: [...page.querySelectorAll('a[href]')].map((a) => ({ text: a.textContent, href: a.getAttribute('href') })),
        headings: [...page.querySelectorAll('h1,h2,h3,h4,h5,h6')].map((h) => h.id),
        images: [...page.querySelectorAll('img')].map((i) => ({ alt: i.alt, loaded: i.complete && i.naturalWidth > 0, data: (i.src || '').startsWith('data:') })),
        scroll_y: win.scrollY,
      };
    }

    return { openFind, findNext: () => move(1), findPrevious: () => move(-1), closeFind, findOpen: () => find.open,
      lightbox, state, mermaid: () => mermaidDone,
      typeInFind(text) { if (!find.open) return false; input.value += text; input.dispatchEvent(new win.Event('input')); return true; } };
  }

  return { shell, render, fill, enhance, label, CSS };
})();
