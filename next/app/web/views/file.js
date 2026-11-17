// File panes (SPEC E-1..E-7, E-11, E-21..E-24): a pane with `view: 'file'` and `{path, mode}`
// shows a file, Markdown rendered (an iframe that runs no scripts, markdown.js) or any text as
// source (CodeMirror 6, lib/codemirror.js). As Umi's, with Warp's header: the name centred with a
// dot while unsaved, Rendered / Raw, ⋯ and close.
//
// A file view lives as long as its pane, not as long as one drawing of the layout: views/panes.js
// redraws every slot on each change, so each view sits in #files over its pane's slot (as native
// terminals sit over theirs) and keeps its editor, undo and scroll.
//
// Unsaved edits are kept in the layout (`meta.drafts[path] = {text, version}`), so a reload of
// the web layer, a quit or a closed tab never loses them; opening the file again brings them back.
//
//   Umi.actions.openFile({path, line?, col?, pane?, mode?, focus?})  opens (or focuses) a file pane
//   Umi.views.file.sync()           places the views over their slots (panes.render calls it)
//   Umi.views.file.askClose(paneId) → true when the pane is a file pane with unsaved edits (it asks)
//   Umi.views.file.get(paneId)      the view, for checks: .state(), .save(), .setMode(), .page, .margin
//   Umi.views.file.setWaiting(path, n)  agents waiting for the review of `path` (comments wait)
//   events on window: 'umi:commentsDone' {detail: {path, open}}
'use strict';
Umi.views = Umi.views || {};

Umi.views.file = (() => {
  const S = Umi.state, M = Umi.model;
  const views = new Map(); // paneId -> FileView
  const waiting = {};      // path -> agents waiting for its review
  const base = (p) => (p || '').split('/').filter(Boolean).pop() || p;
  const dirOf = (p) => p.replace(/\/[^/]*$/, '') || '/';
  const isMarkdown = (p) => /\.(md|markdown|mdown|mkd|mdx)$/i.test(p);
  const el = (tag, cls, text) => { const e = document.createElement(tag); if (cls) e.className = cls; if (text != null) e.textContent = text; return e; };

  // ---- Languages, as Warp picks them by file name ----
  const EXT = { md: 'markdown', markdown: 'markdown', mdx: 'markdown', js: 'javascript', mjs: 'javascript', cjs: 'javascript', jsx: 'javascript',
    ts: 'typescript', tsx: 'typescript', mts: 'typescript', json: 'json', jsonc: 'json', py: 'python', pyi: 'python', css: 'css', scss: 'css',
    html: 'html', htm: 'html', rs: 'rust', c: 'cpp', h: 'cpp', cc: 'cpp', cpp: 'cpp', cxx: 'cpp', hpp: 'cpp', hh: 'cpp', go: 'go',
    java: 'java', yaml: 'yaml', yml: 'yaml', sh: 'shell', bash: 'shell', zsh: 'shell', fish: 'shell', swift: 'swift', toml: 'toml',
    rb: 'ruby', lua: 'lua', cs: 'csharp', kt: 'kotlin', kts: 'kotlin', scala: 'scala' };
  const NAMES = { Dockerfile: 'dockerfile', Makefile: null, Gemfile: 'ruby', Rakefile: 'ruby', '.zshrc': 'shell', '.bashrc': 'shell', '.zprofile': 'shell', '.profile': 'shell' };
  function languageOf(path) {
    const name = base(path);
    if (name in NAMES) return NAMES[name];
    const ext = (/\.([^./]+)$/.exec(name) || [])[1];
    return ext ? EXT[ext.toLowerCase()] || null : null;
  }

  // ---- The source editor's look (E-21): the terminal's font and ANSI colors, Warp's gutter ----
  let look = null;
  function editorLook() {
    if (look) return look;
    const { EditorView } = CM.view, { HighlightStyle, syntaxHighlighting } = CM.language, t = CM.tags;
    const c = { magenta: '#ff8ffd', blue: '#a5d5fe', green: '#b4fa72', red: '#ff8272', yellow: '#fefdc2', cyan: '#d0d1fe' };
    const theme = EditorView.theme({
      '&': { height: '100%', color: 'rgba(255,255,255,0.9)', backgroundColor: 'var(--bg)', fontSize: '13px' },
      '.cm-scroller': { fontFamily: 'var(--mono)', lineHeight: '1.5' },
      '.cm-content': { caretColor: 'var(--accent)', padding: '6px 0 40vh' },
      '.cm-cursor, .cm-dropCursor': { borderLeftColor: 'var(--accent)', borderLeftWidth: '2px' },
      '&.cm-focused > .cm-scroller > .cm-selectionLayer .cm-selectionBackground, .cm-selectionBackground, ::selection': { backgroundColor: 'rgba(118,167,250,0.4)' },
      '.cm-gutters': { backgroundColor: 'var(--bg)', border: 'none', color: 'rgba(255,255,255,0.6)', minWidth: '94px' },
      '.cm-lineNumbers': { flex: '1' },
      '.cm-lineNumbers .cm-gutterElement': { padding: '0 24px 0 8px', textAlign: 'right' },
      '.cm-activeLineGutter': { backgroundColor: 'transparent', color: 'rgba(255,255,255,0.9)' },
      '.cm-activeLine': { backgroundColor: 'rgba(255,255,255,0.10)' },
      '&.has-selection .cm-activeLine': { backgroundColor: 'transparent' },
      '.cm-searchMatch': { backgroundColor: 'rgba(255,254,61,0.35)' },
      '.cm-searchMatch.cm-searchMatch-selected': { backgroundColor: 'rgba(238,146,59,0.7)', color: '#000' },
      '.cm-selectionMatch': { backgroundColor: 'rgba(255,255,255,0.08)' },
      '.cm-matchingBracket': { backgroundColor: 'rgba(255,255,255,0.15)', outline: 'none' },
    }, { dark: true });
    const highlight = HighlightStyle.define([
      { tag: [t.keyword, t.controlKeyword, t.operatorKeyword, t.modifier, t.definitionKeyword, t.moduleKeyword, t.self], color: c.magenta },
      { tag: [t.function(t.variableName), t.function(t.propertyName), t.macroName], color: c.blue },
      { tag: [t.string, t.special(t.string), t.number, t.bool, t.regexp, t.character], color: c.green },
      { tag: [t.typeName, t.className, t.tagName, t.namespace], color: c.red },
      { tag: [t.comment, t.lineComment, t.blockComment, t.docComment, t.punctuation, t.bracket, t.separator], color: c.yellow },
      { tag: [t.propertyName, t.attributeName], color: c.cyan },
      { tag: t.heading, color: c.blue, fontWeight: '600' },
      { tag: t.emphasis, fontStyle: 'italic' },
      { tag: t.strong, fontWeight: '600' },
      { tag: t.link, color: c.cyan },
      { tag: t.url, color: c.green },
      { tag: t.monospace, color: c.red },
      { tag: t.quote, color: 'rgba(255,255,255,0.6)' },
      { tag: t.invalid, color: c.red },
    ]);
    return (look = [theme, syntaxHighlighting(highlight)]);
  }

  // ---- One file pane ----
  class FileView {
    constructor(node) {
      this.id = node.id;
      this.path = node.path;
      this.markdown = isMarkdown(node.path);
      this.mode = this.markdown ? (node.mode === 'raw' ? 'raw' : 'rendered') : 'raw';
      this.text = '';
      this.disk = null;          // {text, version} as last read or written
      this.conflict = null;      // the disk's newer {text, version} while there are unsaved edits
      this.missing = false;      // the file was deleted while open
      this.error = null;         // why the file can't be shown (E-6), or the last failed save
      this.confirmClose = false;
      this.selected = null;      // the comment thread shown selected
      this.showResolved = false;
      this.replyDraft = null;
      this.composing = false;
      this.previewStale = true;
      this.build();
      this.load(node);
    }

    get dirty() { return !!this.disk && this.text !== this.disk.text || (!this.disk && this.text !== '' && !this.error); }
    node() { return M.findPane(this.id)?.node; }

    build() {
      const root = this.root = el('div', 'fileview');
      root.dataset.pane = this.id;
      const head = this.head = el('div', 'fv-head');
      const left = el('div', 'fv-edge');
      const name = el('div', 'fv-name');
      this.dot = el('span', 'fv-dot');
      this.nameText = el('span', 'fv-title', base(this.path));
      name.title = this.path;
      name.append(this.dot, this.nameText);
      const right = el('div', 'fv-edge fv-right');
      if (this.markdown) {
        const toggle = this.toggle = el('div', 'fv-mode');
        toggle.title = 'Toggle rendered / raw (⌘E or ⇧⌘M)';
        for (const [m, label] of [['rendered', 'Rendered'], ['raw', 'Raw']]) {
          const b = el('button', 'fv-seg', label);
          b.dataset.mode = m;
          b.addEventListener('click', () => this.setMode(m));
          toggle.append(b);
        }
        right.append(toggle);
      }
      const more = el('button', 'fv-icon fv-more', '⋯');
      more.title = 'More';
      more.addEventListener('click', (e) => this.menu(e));
      const close = el('button', 'fv-icon fv-close', '✕');
      close.title = 'Close (⌘W)';
      close.addEventListener('click', () => this.close());
      right.append(more, close);
      if (this.markdown) left.classList.add('wide'), right.classList.add('wide');
      head.append(left, name, right);
      head.addEventListener('contextmenu', (e) => { e.preventDefault(); this.menu(e); });
      this.bars = el('div', 'fv-bars');
      this.body = el('div', 'fv-body');
      this.source = el('div', 'fv-source');
      this.message = el('div', 'fv-message');
      this.body.append(this.source, this.message);
      if (this.markdown) {
        const f = this.frame = document.createElement('iframe');
        f.className = 'fv-preview';
        // Scripts may run only from this page (the parent): the page's CSP allows none of its own.
        f.setAttribute('sandbox', 'allow-same-origin allow-scripts');
        f.addEventListener('load', () => this.frameLoaded());
        f.srcdoc = Umi.markdown.shell();
        this.body.append(f);
      }
      this.toast = el('div', 'fv-toast');
      root.append(head, this.bars, this.body, this.toast);
      root.addEventListener('mousedown', () => {
        if (M.activeTab().focused !== this.id) Umi.app.update(() => M.focusPane(this.id), { focus: false });
      }, true);
      root.addEventListener('keydown', (e) => this.key(e), true);
      document.getElementById('files').append(root);
      this.paint();
    }

    // ---- Loading and the disk ----
    async load(node) {
      const draft = S.layout.meta?.drafts?.[this.path];
      try {
        const r = await Umi.fs.read(this.path);
        this.disk = { text: r.text, version: r.version };
        this.text = draft ? draft.text : r.text;
        if (draft && draft.version !== r.version && draft.text !== r.text) this.conflict = this.disk;
      } catch (e) {
        if (e.code === 'notFound' && draft) { this.missing = true; this.disk = { text: '', version: null }; this.text = draft.text; }
        else if (e.code === 'notFound') { this.disk = { text: '', version: null }; this.missing = true; this.text = ''; }
        else this.error = refusal(e, this.path);
      }
      if (!this.error) this.makeEditor();
      this.watch();
      this.paint();
      if (node.goto) this.goto(node.goto.line, node.goto.col);
      if (M.activeTab().focused === this.id && S.ui.keys === 'web') this.focus();
    }

    watch() {
      this.watcher = Umi.fs.watch(this.path, () => this.diskChanged());
      this.watcher.done.catch(() => {});
    }

    async diskChanged() {
      let r;
      try { r = await Umi.fs.read(this.path); } catch (e) {
        if (e.code === 'notFound') { this.missing = true; this.paint(); }
        return;
      }
      const wasMissing = this.missing;
      this.missing = false;
      if (this.disk && r.version === this.disk.version) { if (wasMissing) this.paint(); return; }
      if (!this.dirty || r.text === this.text) {
        this.disk = { text: r.text, version: r.version };
        this.conflict = null;
        this.setText(r.text);
      } else {
        this.conflict = { text: r.text, version: r.version };
      }
      this.paint();
    }

    // ---- Text ----
    makeEditor() {
      const { EditorView, keymap, lineNumbers, highlightActiveLine, highlightActiveLineGutter, drawSelection, highlightSpecialChars, dropCursor, rectangularSelection, crosshairCursor } = CM.view;
      const { EditorState } = CM.state;
      const { defaultKeymap, history, historyKeymap, indentWithTab, toggleComment } = CM.commands;
      const { indentOnInput, bracketMatching } = CM.language;
      const { search, searchKeymap, highlightSelectionMatches, gotoLine } = CM.search;
      const lang = languageOf(this.path);
      const exts = [
        lineNumbers(), highlightActiveLineGutter(), highlightSpecialChars(), history(), drawSelection(), dropCursor(),
        EditorState.allowMultipleSelections.of(true), indentOnInput(), bracketMatching(), rectangularSelection(), crosshairCursor(),
        highlightActiveLine(), highlightSelectionMatches(), search({ top: true }),
        keymap.of([
          { key: 'Ctrl-g', run: gotoLine, preventDefault: true },
          { key: 'Mod-/', run: toggleComment, preventDefault: true },
          ...searchKeymap, ...defaultKeymap, ...historyKeymap, indentWithTab,
        ]),
        editorLook(),
        EditorView.updateListener.of((u) => {
          if (u.selectionSet || u.docChanged) u.view.dom.classList.toggle('has-selection', !u.state.selection.main.empty);
          if (!u.docChanged || this.settingText) return;
          this.text = u.state.doc.toString();
          this.previewStale = true;
          this.changed();
        }),
      ];
      if (lang && CM.languages[lang]) exts.push(CM.languages[lang]());
      this.cm = new EditorView({ state: EditorState.create({ doc: this.text, extensions: exts }), parent: this.source });
    }

    // Replaces the text with `text`, changing only what differs, so the caret and undo stay.
    setText(text) {
      if (text === this.text && (!this.cm || this.cm.state.doc.length === text.length)) return;
      const old = this.cm ? this.cm.state.doc.toString() : this.text;
      this.text = text;
      this.previewStale = true;
      if (this.cm && old !== text) {
        let a = 0;
        while (a < old.length && a < text.length && old[a] === text[a]) a++;
        let b = 0;
        while (b < old.length - a && b < text.length - a && old[old.length - 1 - b] === text[text.length - 1 - b]) b++;
        this.settingText = true;
        this.cm.dispatch({ changes: { from: a, to: old.length - b, insert: text.slice(a, text.length - b) } });
        this.settingText = false;
      }
      this.changed();
      if (this.mode === 'rendered') this.renderPreview();
    }

    changed() {
      this.paint();
      Umi.views.panes.renderStrip(M.activeTab());
      clearTimeout(this.draftTimer);
      this.draftTimer = setTimeout(() => this.keepDraft(), 250);
    }

    keepDraft() {
      if (!S.layout) return;
      const meta = (S.layout.meta = S.layout.meta || { sessions: {} });
      meta.drafts = meta.drafts || {};
      const had = !!meta.drafts[this.path];
      if (this.dirty) meta.drafts[this.path] = { text: this.text, version: this.disk?.version ?? null };
      else delete meta.drafts[this.path];
      if (this.dirty || had) Umi.app.save();
    }

    async save({ overwrite = false } = {}) {
      if (this.error && !this.disk) return;
      const version = overwrite ? (this.conflict?.version ?? undefined) : this.missing ? null : this.disk?.version;
      try {
        const w = await Umi.fs.write(this.path, this.text, version === undefined ? {} : { version });
        this.disk = { text: this.text, version: w.version };
        this.conflict = null;
        this.missing = false;
        this.error = null;
        this.changed();
        this.showToast('File saved.');
        return true;
      } catch (e) {
        if (e.code === 'conflict') {
          try { const r = await Umi.fs.read(this.path); this.conflict = { text: r.text, version: r.version }; this.missing = false; }
          catch (x) { this.missing = true; }
        } else this.error = e.message;
        this.paint();
        return false;
      }
    }

    discard() {
      if (!this.conflict) return;
      this.disk = this.conflict;
      this.conflict = null;
      this.setText(this.disk.text);
    }

    showToast(text) {
      this.toast.textContent = '✓  ' + text;
      this.toast.classList.add('on');
      clearTimeout(this.toastTimer);
      this.toastTimer = setTimeout(() => this.toast.classList.remove('on'), 4000);
    }

    // ---- Comments (E-11): every change goes to the file at once; unsaved edits stay unsaved ----
    async changeComments(fn) {
      for (let attempt = 0; attempt < 3; attempt++) {
        const disk = await Umi.fs.read(this.path);
        const updated = fn(disk.text);
        try {
          const w = await Umi.fs.write(this.path, updated.text ?? updated, { version: disk.version });
          const was = this.dirty;
          let mine = updated.text ?? updated;
          if (was) { try { const m = fn(this.text); mine = m.text ?? m; } catch (e) { mine = this.text; } }
          this.disk = { text: updated.text ?? updated, version: w.version };
          this.conflict = null;
          this.setText(mine);
          return updated;
        } catch (e) {
          if (e.code !== 'conflict') throw e;
        }
      }
      throw new Error('the file kept changing; try again');
    }

    async comment(msg) {
      const C = UmiComments;
      const base = this.renderedText;
      try {
        if (msg.type === 'add') {
          const r = await this.changeComments((cur) => {
            const at = C.relocate({ start: msg.start, end: msg.end }, base, cur);
            if (!at) throw new C.Failure('that text changed in the file meanwhile; select it again');
            return C.add(cur, msg.body, at, C.USER);
          });
          this.selected = r.id;
          this.composing = false;
        } else if (msg.type === 'reply') {
          await this.changeComments((cur) => C.reply(cur, msg.id, msg.body, C.USER));
          this.replyDraft = null;
          this.composing = false;
        } else if (msg.type === 'edit') await this.changeComments((cur) => C.edit(cur, msg.id, msg.body));
        else if (msg.type === 'resolve') await this.changeComments((cur) => C.resolve(cur, msg.id, msg.resolved));
        else if (msg.type === 'delete') { await this.changeComments((cur) => C.remove(cur, msg.id)); if (this.selected === msg.id) this.selected = null; }
        this.renderPreview();
      } catch (e) {
        this.margin?.failed(e.message);
      }
    }

    marginMessage(msg) {
      switch (msg.type) {
        case 'add': case 'reply': case 'edit': case 'resolve': case 'delete': this.comment(msg); break;
        case 'select': this.selected = msg.id; break;
        case 'composing': this.composing = msg.on; if (!msg.on && this.previewStale) setTimeout(() => this.renderPreview(), 0); break;
        case 'show_resolved': this.showResolved = msg.on; break;
        case 'replyDraft': this.replyDraft = msg.draft; break;
        case 'scroll': this.scrollY = msg.y; break;
        case 'done': {
          const open = UmiComments.threads(this.text).filter((t) => t.status === 'open').length;
          const n = waiting[this.path] || 0;
          window.dispatchEvent(new CustomEvent('umi:commentsDone', { detail: { path: this.path, open } }));
          Umi.bridge.post({ type: 'log', message: `comments done ${this.path} (${open} open)` });
          this.margin?.notice(n ? (n === 1 ? 'Sent: the agent waiting on this file has your comments.' : `Sent to the ${n} agents waiting on this file.`)
            : 'No agent is waiting on this file. Your comments are saved in it; an agent can read them with `umi-next comments`.');
          break;
        }
        default: break;
      }
    }

    // ⌥⌘M: in the preview, the margin's compose card; in the source, a comment on the selection.
    startComment() {
      if (!this.markdown) return;
      if (this.mode === 'rendered') { this.margin?.startCompose(); return; }
      const sel = this.cm.state.selection.main;
      if (sel.empty) { this.showToast('Select the text to comment on first.'); return; }
      this.ask = { start: sel.from, end: sel.to, quote: this.text.slice(sel.from, sel.to) };
      this.paint();
      setTimeout(() => this.bars.querySelector('textarea')?.focus(), 0);
    }

    async submitAsk(body) {
      const ask = this.ask;
      if (!ask || !body.trim()) return;
      const base = this.text;
      try {
        await this.changeComments((cur) => {
          const at = UmiComments.relocate({ start: ask.start, end: ask.end }, base, cur);
          if (!at) throw new UmiComments.Failure('that text changed in the file meanwhile; select it again');
          return UmiComments.add(cur, body, at, UmiComments.USER);
        });
        this.ask = null;
        this.paint();
        this.focus();
      } catch (e) { this.ask.error = e.message; this.paint(); }
    }

    // ---- The preview ----
    frameLoaded() {
      this.frameReady = true;
      const doc = this.frame.contentDocument;
      doc.addEventListener('keydown', (e) => this.key(e));
      doc.addEventListener('mousedown', () => {
        if (M.activeTab().focused !== this.id) Umi.app.update(() => M.focusPane(this.id), { focus: false });
      }, true);
      doc.addEventListener('contextmenu', (e) => { e.preventDefault(); this.menu(e, true); });
      if (this.mode === 'rendered') this.renderPreview();
    }

    renderPreview() {
      if (!this.frameReady || this.mode !== 'rendered' || !this.disk) return;
      if (this.composing) { this.previewStale = true; return; }
      const doc = this.frame.contentDocument, win = this.frame.contentWindow;
      const threads = UmiComments.threads(this.text);
      const resolved = new Set(threads.filter((t) => t.status === 'resolved').map((t) => t.id));
      const y = win.scrollY;
      const { html } = Umi.markdown.render(this.text, resolved);
      Umi.markdown.fill(doc, html);
      this.renderedText = this.text;
      this.previewStale = false;
      this.page = Umi.markdown.enhance(doc, win, {
        dir: dirOf(this.path),
        openFile: (path, hash) => Umi.app.run('openFile', { path, pane: this.id }),
        openURL: (url) => Umi.fs.openURL(url),
        copy: (text) => Umi.bridge.request('clipboard', { text }),
        run: (text) => this.runInTerminal(text),
        keydown: () => {},
        focusBack: () => this.focus(),
        relayout: () => this.margin && this.margin.layout && this.margin.layout(),
      });
      this.margin = Umi.views.comments.attach(doc, win, {
        threads, focus: this.selected, showResolved: this.showResolved, waiting: waiting[this.path] || 0,
        scroll: y, replyDraft: this.replyDraft,
      }, (msg) => this.marginMessage(msg));
    }

    // MD-2: the command goes to the input of the tab's terminal, which takes focus; not run.
    runInTerminal(text) {
      const tab = M.activeTab();
      const term = M.panesOf(tab.root).find((p) => p.view === 'terminal' && M.sessionOf(p.id));
      if (!term) { this.showToast('No terminal in this tab.'); return; }
      Umi.bridge.request('sendText', { session: M.sessionOf(term.id), text }).catch((e) => this.showToast(e.message));
      Umi.app.update(() => M.focusPane(term.id));
    }

    setMode(mode) {
      if (!this.markdown || mode === this.mode) return;
      this.mode = mode;
      const n = this.node();
      if (n) n.mode = mode;
      Umi.app.save();
      this.paint();
      if (mode === 'rendered') this.renderPreview();
      this.focus();
    }

    goto(line, col = 1) {
      const n = this.node();
      if (n) delete n.goto;
      if (!this.cm || !line) return;
      if (this.mode !== 'raw') this.setMode('raw');
      const doc = this.cm.state.doc;
      const l = doc.line(Math.max(1, Math.min(line, doc.lines)));
      const pos = Math.min(l.to, l.from + Math.max(0, (col || 1) - 1));
      this.cm.dispatch({ selection: { anchor: pos }, effects: CM.view.EditorView.scrollIntoView(pos, { y: 'center' }) });
    }

    // ---- Keys (E-2, E-3, E-22, E-23); Caps Lock doesn't matter (by physical key, E-8) ----
    key(e) {
      const k = e.code, cmd = e.metaKey, sh = e.shiftKey, alt = e.altKey, ctrl = e.ctrlKey;
      const only = (c, s, a) => cmd === c && sh === s && alt === a && !ctrl;
      let done = true;
      if (this.confirmClose && e.key === 'Escape') { this.confirmClose = false; this.paint(); this.focus(); }
      else if (k === 'KeyS' && only(true, false, false)) this.save();
      else if (this.markdown && ((k === 'KeyM' && only(true, true, false)) || (k === 'KeyE' && only(true, false, false)))) this.setMode(this.mode === 'raw' ? 'rendered' : 'raw');
      else if (this.markdown && k === 'KeyM' && only(true, false, true)) this.startComment();
      else if (this.mode === 'rendered' && this.page && k === 'KeyF' && only(true, false, false)) {
        const sel = this.frame.contentWindow.getSelection().toString().split('\n')[0];
        this.page.openFind(sel);
      } else if (this.mode === 'rendered' && this.page && k === 'KeyG' && only(true, false, false)) this.page.findNext();
      else if (this.mode === 'rendered' && this.page && k === 'KeyG' && only(true, true, false)) this.page.findPrevious();
      else if (this.mode === 'rendered' && k === 'KeyF' && only(true, false, true)) {
        this.setMode('raw');
        CM.search.openSearchPanel(this.cm);
      } else done = false;
      if (done) { e.preventDefault(); e.stopPropagation(); }
    }

    // ---- The pane menu (E-24), through the native menu ----
    async menu(e, inPreview = false) {
      const items = [];
      const add = (title, fn, enabled = true) => items.push({ title, enabled, fn });
      if (inPreview && this.frame.contentWindow.getSelection().toString()) add('Copy', () => this.frame.contentDocument.execCommand('copy'));
      if (this.mode === 'raw') {
        add('Copy file path', () => Umi.bridge.request('clipboard', { text: this.path }));
        add('Reveal in Finder', () => Umi.fs.reveal(this.path));
        if (this.markdown) add('View Markdown preview', () => this.setMode('rendered'));
      } else {
        add('Refresh file', () => this.refresh());
        add('Open in editor', () => this.setMode('raw'));
        add('Copy file path', () => Umi.bridge.request('clipboard', { text: this.path }));
      }
      const x = e.clientX + (inPreview ? this.frame.getBoundingClientRect().left : 0);
      const y = e.clientY + (inPreview ? this.frame.getBoundingClientRect().top : 0);
      const r = await Umi.bridge.request('menu', { items: items.map(({ title, enabled }) => ({ title, enabled })), x, y });
      if (r && r.index != null) items[r.index].fn();
    }

    async refresh() {
      if (this.dirty) { this.confirmRefresh = true; this.paint(); return; }
      this.confirmRefresh = false;
      try { const r = await Umi.fs.read(this.path); this.disk = { text: r.text, version: r.version }; this.conflict = null; this.setText(r.text); }
      catch (e) { this.error = refusal(e, this.path); }
      this.paint();
    }

    // ---- Closing (E-3): ⌘W and × close; unsaved edits ask first ----
    close() {
      if (this.dirty) { this.confirmClose = true; this.paint(); setTimeout(() => this.bars.querySelector('.fv-primary')?.focus(), 0); return; }
      this.closeNow();
    }
    closeNow(discard = false) {
      if (discard) { const d = S.layout.meta?.drafts; if (d) delete d[this.path]; }
      this.confirmClose = false;
      Umi.app.update(() => M.removePane(this.id));
    }

    focus() {
      if (this.root.contains(document.activeElement) && document.activeElement !== document.body && document.activeElement !== this.frame) return;
      if (this.confirmClose) { this.bars.querySelector('.fv-primary')?.focus(); return; }
      if (this.mode === 'rendered' && this.frame) { this.frame.focus(); this.frame.contentWindow?.focus(); }
      else if (this.cm) this.cm.focus();
      else this.root.focus();
    }

    // ---- Drawing the header and bars ----
    paint() {
      this.root.classList.toggle('dirty', this.dirty);
      this.root.dataset.mode = this.mode;
      if (this.toggle) for (const b of this.toggle.children) b.classList.toggle('on', b.dataset.mode === this.mode);
      this.bars.textContent = '';
      const bar = (text, actions, cls = '') => {
        const b = el('div', 'fv-bar ' + cls);
        b.append(el('span', 'fv-bar-text', text));
        for (const [label, fn, primary] of actions) {
          const btn = el('button', primary ? 'fv-primary' : '', label);
          btn.addEventListener('click', fn);
          b.append(btn);
        }
        this.bars.append(b);
        return b;
      };
      if (this.confirmClose) {
        const b = bar(`Save changes to ${base(this.path)} before closing?`, [
          ['Save', async () => { if (await this.save()) this.closeNow(); }, true],
          ["Don't Save", () => this.closeNow(true)],
          ['Cancel', () => { this.confirmClose = false; this.paint(); this.focus(); }],
        ], 'fv-ask');
        b.addEventListener('keydown', (e) => { if (e.key === 'Escape') { e.preventDefault(); this.confirmClose = false; this.paint(); this.focus(); } });
      }
      if (this.confirmRefresh) bar('Your unsaved changes will be lost.', [
        ['Refresh', () => { this.text = this.disk.text; this.confirmRefresh = false; this.refresh(); }, true],
        ['Cancel', () => { this.confirmRefresh = false; this.paint(); }],
      ]);
      if (this.conflict) bar('This file has saved changes that are not reflected here.', [
        ['Discard this version', () => this.discard()],
        ['Overwrite', () => this.save({ overwrite: true })],
      ], 'fv-conflict');
      else if (this.missing && this.disk && this.disk.version) bar('This file was deleted. Save to write it again.', []);
      if (this.error && this.disk) bar(this.error, [['Dismiss', () => { this.error = null; this.paint(); }]]);
      if (this.ask) {
        const b = el('div', 'fv-bar fv-comment');
        const q = this.ask.quote.length > 120 ? this.ask.quote.slice(0, 117) + '…' : this.ask.quote;
        b.append(el('span', 'fv-bar-text', `Comment on “${q}”`));
        const t = el('textarea');
        t.placeholder = 'Comment…';
        t.addEventListener('keydown', (e) => {
          if (e.key === 'Enter' && e.metaKey) { e.preventDefault(); this.submitAsk(t.value); }
          else if (e.key === 'Escape') { e.preventDefault(); this.ask = null; this.paint(); this.focus(); }
          e.stopPropagation();
        });
        const ok = el('button', 'fv-primary', 'Comment');
        ok.addEventListener('click', () => this.submitAsk(t.value));
        const cancel = el('button', '', 'Cancel');
        cancel.addEventListener('click', () => { this.ask = null; this.paint(); this.focus(); });
        b.append(t, ok, cancel);
        if (this.ask.error) b.append(el('span', 'fv-err', this.ask.error));
        this.bars.append(b);
      }
      const refused = this.error && !this.disk;
      this.message.textContent = refused ? this.error : '';
      this.message.hidden = !refused;
      this.source.hidden = refused || this.mode !== 'raw';
      if (this.frame) this.frame.hidden = refused || this.mode !== 'rendered';
    }

    place(rect) {
      const s = this.root.style;
      if (!rect) { s.display = 'none'; return; }
      s.display = 'flex';
      s.left = rect.x + 'px'; s.top = rect.y + 'px'; s.width = rect.w + 'px'; s.height = rect.h + 'px';
    }

    destroy() {
      clearTimeout(this.draftTimer);
      this.keepDraft();
      this.watcher?.close();
      this.cm?.destroy();
      this.root.remove();
    }

    state() {
      return { path: this.path, mode: this.mode, dirty: this.dirty, text: this.text, disk: this.disk?.version ?? null,
        conflict: !!this.conflict, missing: this.missing, error: this.error, confirmClose: !!this.confirmClose,
        bars: [...this.bars.querySelectorAll('.fv-bar-text')].map((b) => b.textContent),
        toast: this.toast.classList.contains('on') ? this.toast.textContent : '', selected: this.selected,
        focused: this.root.contains(document.activeElement) || document.activeElement === this.frame,
        caret: this.cm ? this.cm.state.selection.main.head : null };
    }
  }

  function refusal(e, path) {
    const name = base(path);
    switch (e.code) {
      case 'isDir': return `${name} is a folder, not a file.`;
      case 'binary': return `${name} isn't UTF-8 text, so it can't be edited here.`;
      case 'tooLarge': return `${name} is too large to open here.`;
      case 'notFound': return `There's no file at ${path}.`;
      default: return `Can't open ${name}: ${e.message}`;
    }
  }

  // ---- Keeping views in step with the layout ----
  function sync() {
    if (!S.layout) return;
    const all = new Map();
    for (const tab of S.layout.tabs) for (const p of M.panesOf(tab.root)) if (p.view === 'file') all.set(p.id, p);
    for (const [id, v] of views) if (!all.has(id)) { v.destroy(); views.delete(id); }
    for (const [id, node] of all) if (!views.has(id)) views.set(id, new FileView(node));
    const rects = Umi.views.panes.slotRects();
    const active = new Set(M.panesOf(M.activeTab().root).map((p) => p.id));
    for (const [id, v] of views) v.place(active.has(id) ? rects[id] : null);
    // A pending go-to (openFile on a file already open).
    for (const [id, node] of all) if (node.goto && views.get(id).cm) views.get(id).goto(node.goto.line, node.goto.col);
  }
  window.addEventListener('resize', () => sync());
  window.addEventListener('pagehide', () => { for (const v of views.values()) { clearTimeout(v.draftTimer); v.keepDraft(); } });

  Umi.views.panes.renderers.file = (slot) => { slot.classList.add('file-slot'); };

  function focus(id) { views.get(id)?.focus(); }
  function askClose(id) {
    const v = views.get(id);
    if (!v || !v.dirty) return false;
    v.close();
    return true;
  }
  function label(node) { return base(node.path); }
  function isDirty(id) { return !!views.get(id)?.dirty; }
  function setWaiting(path, n) {
    waiting[path] = n;
    for (const v of views.values()) if (v.path === path && v.mode === 'rendered' && v.margin) v.margin.setWaiting(n);
  }

  return { sync, focus, askClose, label, isDirty, setWaiting, get: (id) => views.get(id), views, languageOf };
})();

// Opens a file in a pane of its own to the right of `pane` (default: the focused one), or shows
// the pane already showing it (E-9). `line`/`col` (1-based) put the caret there in the source.
// `focus: false` leaves the focus where it was (the CLI's `edit`).
Umi.actions.openFile = ({ path, line, col, pane, mode, focus = true } = {}) => {
  const M = Umi.model, S = Umi.state;
  if (!path) return;
  const abs = Umi.fs.resolve(path);
  const goto = line ? { line: Number(line), col: Number(col) || 1 } : null;
  for (const tab of S.layout.tabs) {
    const shown = M.panesOf(tab.root).find((p) => p.view === 'file' && p.path === abs);
    if (shown) {
      if (goto) shown.goto = goto;
      const v = Umi.views.file.get(shown.id);
      if (mode && v) v.setMode(mode); else if (mode) shown.mode = mode;
      if (focus) M.focusPane(shown.id);
      return shown.id;
    }
  }
  const from = pane && M.findPane(pane) ? pane : M.activeTab().focused;
  const before = M.activeTab().focused, beforeTab = S.layout.activeTab;
  M.focusPane(from);
  const p = M.split('row', 'file', { path: abs, ...(mode ? { mode } : goto ? { mode: 'raw' } : {}), ...(goto ? { goto } : {}) });
  if (!focus) {
    S.layout.activeTab = beforeTab;
    const t = M.findPane(p.id).tab;
    t.focused = M.findPane(before)?.tab === t ? before : from;
  }
  return p.id;
};
