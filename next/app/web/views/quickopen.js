// Quick open, ⌘O (SPEC L-16): a panel over the top of the panes, as Umi's palette filtered to
// files (640 wide, 117 from the top). It searches the focused pane's project: what git tracks plus
// untracked files it doesn't ignore (Umi.fs.files), fuzzy on the path with the file name counting
// most (Umi.fs.fuzzy); files opened recently first. `path:line` (and `path:line:col`) opens the
// file there. When nothing matches, "Create a file named NAME…" makes it (and its folders) in the
// pane's folder; a NAME starting with `~/` or `/` names the place itself. ↑↓ (⌃P ⌃N) choose,
// Enter opens, Esc or a click elsewhere closes.
//
// Departures: no "Browse…" entry (no Open panel); changed files don't rank above the rest.
'use strict';
Umi.views = Umi.views || {};

Umi.views.quickOpen = (() => {
  const S = Umi.state, M = Umi.model, I = Umi.icons, V = () => Umi.views.modes;
  const LIMIT = 100;
  let index = null; // {root, files, set, loading}

  // The query's file name, line and column: "src/a.js:12:3" → ['src/a.js', 12, 3].
  function parse(raw) {
    let q = raw.trim();
    let line = null, col = null;
    const m = /^(.*?):(\d+)(?::(\d+))?$/.exec(q);
    if (m) { q = m[1]; line = +m[2]; col = m[3] ? +m[3] : null; } else if (q.endsWith(':')) q = q.slice(0, -1);
    if (q.startsWith('./')) q = q.slice(2);
    return { name: q, line, col };
  }

  function load(root) {
    if (index && index.root === root && index.loading) return;
    const keep = index && index.root === root ? index : null;
    index = { root, files: keep?.files || null, set: keep?.set || null, loading: true };
    const mine = index;
    Umi.fs.files(root).then((r) => {
      mine.files = r.files;
      mine.set = new Set(r.files);
    }, (e) => {
      mine.files = mine.files || [];
      mine.set = mine.set || new Set();
      mine.error = e.message;
    }).finally(() => {
      mine.loading = false;
      if (index === mine) refresh();
    });
  }

  // Recent files under the root, as paths relative to it, most recent first.
  function recent(root) {
    const pre = root.replace(/\/$/, '') + '/';
    return V().recentFiles().filter((p) => p.startsWith(pre)).map((p) => p.slice(pre.length)).filter((p) => index.set?.has(p));
  }

  function results(p) {
    if (!index?.files || index.root !== p.root) return [];
    const { name } = parse(p.query || '');
    const rec = recent(p.root);
    if (!name) {
      const seen = new Set(rec);
      return [...rec, ...index.files.filter((f) => !seen.has(f))].slice(0, LIMIT).map((path) => ({ path, hits: [] }));
    }
    // Recent files get a lift (Umi adds min(rank, 200) / 10 to the score: 20 for a recent file).
    const lift = new Set(rec);
    const found = Umi.fs.fuzzy(name, index.files, 1000);
    for (const r of found) if (lift.has(r.path)) r.score += 20;
    found.sort((a, b) => b.score - a.score);
    return found.slice(0, LIMIT);
  }

  // Where "Create a file named NAME…" makes the file.
  function createPath(p, name) {
    if (name.startsWith('/') || name.startsWith('~/')) return Umi.fs.resolve(name);
    return Umi.fs.resolve(name, p.folder || p.root);
  }

  function items(p) {
    const found = results(p);
    const { name } = parse(p.query || '');
    if (!found.length && name && index?.files) return [{ create: true, name, path: createPath(p, name) }];
    return found;
  }

  async function choose(p, it) {
    const { line, col } = parse(p.query || '');
    Umi.app.update(() => M.closePanel());
    if (it.create) {
      try {
        await Umi.fs.write(it.path, '', { version: null, createDirs: true });
      } catch (e) {
        if (e.code !== 'conflict') return V().flash(`Can't create ${it.name}: ${e.message}`);
      }
      return V().openPath(it.path);
    }
    V().openPath(Umi.fs.resolve(it.path, p.root), { line, col });
  }

  // Text with the characters at `hits` (indexes into it) in bold.
  function marked(text, hits, cls) {
    const el = document.createElement('span');
    el.className = cls;
    const set = new Set(hits);
    let run = '', bold = false;
    const flush = () => {
      if (!run) return;
      if (bold) { const b = document.createElement('b'); b.textContent = run; el.append(b); } else el.append(document.createTextNode(run));
      run = '';
    };
    for (let i = 0; i < text.length; i++) {
      const h = set.has(i);
      if (h !== bold) { flush(); bold = h; }
      run += text[i];
    }
    flush();
    return el;
  }

  function rowEl(p, it, i) {
    const row = document.createElement('div');
    row.className = 'qo-row' + (i === p.sel ? ' sel' : '');
    if (it.create) {
      row.classList.add('create');
      row.innerHTML = `<span class="ficon">${I.svg.plusCircle}</span><span class="title"></span>`;
      row.querySelector('.title').textContent = `Create a file named ${it.name}…`;
      row.title = it.path;
    } else {
      const slash = it.path.lastIndexOf('/');
      const name = it.path.slice(slash + 1), folder = slash > 0 ? it.path.slice(0, slash) : '';
      const icon = document.createElement('span');
      icon.className = 'ficon';
      icon.innerHTML = I.glyph(name);
      row.append(icon, marked(name, it.hits.filter((h) => h > slash).map((h) => h - slash - 1), 'name'));
      if (folder) {
        // Cut at its start: the end of the folder stays next to the name.
        const f = document.createElement('span');
        f.className = 'folder';
        const bdi = document.createElement('bdi');
        bdi.append(marked(folder, it.hits.filter((h) => h < slash), ''));
        f.append(bdi);
        row.append(f);
      }
      const { line, col } = parse(p.query || '');
      if (line) row.append(Object.assign(document.createElement('span'), { className: 'line', textContent: `:${line}${col ? ':' + col : ''}` }));
      row.title = it.path;
    }
    row.addEventListener('mousedown', (e) => { e.preventDefault(); p.sel = i; choose(p, it); });
    row.addEventListener('mousemove', () => { if (p.sel !== i) { p.sel = i; refresh(); } });
    return row;
  }

  let current = null; // {el, p}

  function refresh() {
    if (!current || S.ui.panel !== current.p) return;
    const { el, p } = current;
    const list = el.querySelector('.qo-list');
    const its = items(p);
    p.sel = Math.max(0, Math.min(p.sel || 0, its.length - 1));
    list.textContent = '';
    if (!index?.files || index.root !== p.root) {
      list.append(Object.assign(document.createElement('div'), { className: 'qo-busy', textContent: 'Indexing files…' }));
    } else if (!its.length) {
      list.append(Object.assign(document.createElement('div'), { className: 'qo-busy', textContent: index.error || 'No files.' }));
    }
    its.forEach((it, i) => list.append(rowEl(p, it, i)));
    list.querySelector('.sel')?.scrollIntoView({ block: 'nearest' });
    current.items = its;
    Umi.app.report(false);
  }

  function render(el, p) {
    el.classList.add('quickopen');
    el.innerHTML = `
      <div class="qo-field"><span class="qo-filter">files:</span><input spellcheck="false" placeholder="Search files" aria-label="Search files"></div>
      <div class="qo-list"></div>`;
    const input = el.querySelector('input');
    input.value = p.query || '';
    current = { el, p, items: [] };
    input.addEventListener('input', () => { p.query = input.value; p.sel = 0; refresh(); });
    input.addEventListener('keydown', (e) => {
      const n = current.items.length;
      const step = (d) => { e.preventDefault(); if (n) { p.sel = (p.sel + d + n) % n; refresh(); } };
      if (e.key === 'ArrowDown' || (e.ctrlKey && e.key === 'n')) return step(1);
      if (e.key === 'ArrowUp' || (e.ctrlKey && e.key === 'p')) return step(-1);
      if (e.key === 'Escape') { e.preventDefault(); return Umi.app.update(() => M.closePanel()); }
      if (e.key === 'Enter') {
        e.preventDefault();
        const it = current.items[p.sel];
        if (it) choose(p, it);
      }
    });
    if (!p.loaded) {
      p.loaded = true;
      if (p.root) load(p.root);
      else V().rootOf(p.folder).then((r) => { p.root = r; load(r); });
    }
    refresh();
  }

  // A click outside the panel closes it (a click in a terminal does too, via 'focused').
  window.addEventListener('mousedown', (e) => {
    if (S.ui.panel?.name === 'quickOpen' && !e.target.closest('#panel')) Umi.app.update(() => M.closePanel());
  }, true);

  Umi.views.panel.renderers.quickOpen = render;

  function debug() {
    const p = S.ui.panel;
    if (!p || p.name !== 'quickOpen') return null;
    return { query: p.query, sel: p.sel, loading: !!index?.loading, count: index?.files?.length, items: (current?.items || []).slice(0, 20).map((it) => (it.create ? { create: it.path } : it.path)) };
  }

  return { parse, debug };
})();
