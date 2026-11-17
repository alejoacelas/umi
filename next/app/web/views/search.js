// Global search: the sidebar's Search mode (SPEC S-2, Umi's UmiGlobalSearch.swift).
//
// Searches the focused pane's project (the explorer's root) with Umi.fs.search (ripgrep), leaving
// out what git ignores, 300 ms after typing stops: literal and case-insensitive unless the Regex
// (Perl-style) or Case toggle is on, at most 20,000 matching lines. Results stream in as rg finds
// them, grouped by file. A new query, or an empty one, cancels the search running.
//
// Keys: ↓ (or Enter) from the query into the results, ↑ on the first result back; ← / → fold and
// unfold a file; Enter opens the file at the match's line and column; Esc gives the keys back to
// the pane.
'use strict';
Umi.views = Umi.views || {};

Umi.views.search = (() => {
  const S = Umi.state, I = Umi.icons, V = () => Umi.views.modes;
  const ROW = 25, MAX = 20000, DEBOUNCE = 300;
  const st = {
    query: '', regex: false, caseSensitive: false,
    files: [], byPath: new Map(), count: 0, collapsed: new Set(), selected: null,
    searching: false, capped: false, error: null, searched: null, root: null,
    run: null, timer: null, gen: 0,
  };
  let box, input, msgEl, capEl, listEl, list, rows = [], dirty = false, frame = 0;

  // ---- searching ----
  function schedule() {
    clearTimeout(st.timer);
    st.timer = setTimeout(search, DEBOUNCE);
  }

  function search() {
    clearTimeout(st.timer);
    st.timer = null;
    if (st.run) st.run.cancel();
    st.run = null;
    const gen = ++st.gen;
    st.root = V().root();
    Object.assign(st, { files: [], byPath: new Map(), count: 0, collapsed: new Set(), selected: null, capped: false, error: null });
    const q = st.query;
    if (!q) { Object.assign(st, { searching: false, searched: null }); return changed(); }
    if (!st.root) {
      // git hasn't said yet where the repository starts: search once it has.
      const M = Umi.model;
      V().rootOf(M.folderOf(M.activeTab().focused)).then(() => { if (gen === st.gen) search(); });
      return;
    }
    st.searching = true;
    st.searched = q;
    const run = Umi.fs.search(q, {
      root: st.root, regex: st.regex, pcre2: st.regex, caseSensitive: st.caseSensitive, maxResults: MAX,
      // Dotfiles git tracks are searched too, as git grep does; .git itself never.
      hidden: true, glob: ['!.git'],
    }, (batch) => {
      if (gen !== st.gen) return;
      for (const m of batch) {
        let f = st.byPath.get(m.path);
        if (!f) { f = { path: m.path, matches: [] }; st.byPath.set(m.path, f); st.files.push(f); }
        f.matches.push(m);
        st.count++;
      }
      changed();
    });
    st.run = run;
    run.done.then((sum) => {
      if (gen !== st.gen) return;
      st.searching = false;
      st.capped = !!sum.truncated;
      st.run = null;
      changed();
      if (S.ui.sidebarFocus === 'results' && !st.selected && rows.length) select(0);
    }, (e) => {
      if (gen !== st.gen) return;
      st.searching = false;
      st.run = null;
      st.error = e.message;
      changed();
    });
    changed();
  }

  // Redraws at most once a frame while results stream in.
  function changed() {
    dirty = true;
    if (!frame) frame = requestAnimationFrame(draw);
  }

  function message() {
    if (st.error) return st.error;
    if (st.searched == null && !st.searching) return null;
    const n = st.count, f = st.files.length;
    if (st.searching && n === 0) return 'Searching…';
    if (n === 0) return 'No results found. Review your gitignore files.';
    const fw = f === 1 ? 'file' : 'files';
    return n === 1 ? `1 result in ${f} ${fw}` : `${n.toLocaleString('en-US')} results in ${f} ${fw}`;
  }

  function buildRows() {
    const out = [];
    for (const f of st.files) {
      out.push({ key: f.path, f });
      if (st.collapsed.has(f.path)) continue;
      f.matches.forEach((m, i) => out.push({ key: f.path + '\0' + i, f, m }));
    }
    rows = out;
    if (st.selected && !rows.some((r) => r.key === st.selected)) st.selected = null;
  }

  function draw() {
    frame = 0;
    if (!box) return;
    const msg = message();
    msgEl.hidden = !msg;
    msgEl.textContent = msg || '';
    msgEl.classList.toggle('error', !!st.error);
    capEl.hidden = !st.capped;
    box.querySelectorAll('.sq-toggle').forEach((b) => b.classList.toggle('on', !!st[b.dataset.opt]));
    if (dirty) { buildRows(); dirty = false; list.set(rows.length); } else list.redraw();
  }

  // ---- rows ----
  // The line as shown: leading spaces dropped, a long lead cut to 15 characters before the first
  // match, at most 200 characters (Umi's snippet).
  function snippet(m) {
    let text = m.text.replace(/\r?\n$/, '');
    let ranges = m.ranges.map(([a, b]) => [a, b]);
    const lead = text.length - text.trimStart().length;
    text = text.slice(lead);
    ranges = ranges.map(([a, b]) => [a - lead, b - lead]);
    if (ranges.length && ranges[0][0] > 40) {
      const cut = ranges[0][0] - 15;
      text = '…' + text.slice(cut);
      ranges = ranges.map(([a, b]) => [a - cut + 1, b - cut + 1]);
    }
    if (text.length > 200) {
      text = text.slice(0, 200) + '…';
      ranges = ranges.filter(([a]) => a < 200).map(([a, b]) => [a, Math.min(b, 200)]);
    }
    return { text, ranges: ranges.filter(([a, b]) => b > a && a >= 0) };
  }

  function rowEl(i) {
    const r = rows[i];
    const el = document.createElement('div');
    el.className = 'sr-row' + (r.key === st.selected ? ' sel' : '') + (r.m ? ' match' : ' file');
    if (r.m) {
      const { text, ranges } = snippet(r.m);
      let at = 0;
      for (const [a, b] of ranges) {
        if (a < at) continue;
        el.append(document.createTextNode(text.slice(at, a)));
        const mark = document.createElement('mark');
        mark.textContent = text.slice(a, b);
        el.append(mark);
        at = b;
      }
      el.append(document.createTextNode(text.slice(at)));
      el.title = `${r.f.path}:${r.m.line}`;
    } else {
      const slash = r.f.path.lastIndexOf('/');
      el.innerHTML = `<span class="chev">${st.collapsed.has(r.f.path) ? I.svg.chevronRight : I.svg.chevronDown}</span><span class="ficon"></span><span class="name"></span><span class="folder"></span><span class="count"></span>`;
      el.querySelector('.ficon').append(I.img(r.f.path, 16));
      el.querySelector('.name').textContent = r.f.path.slice(slash + 1);
      // The folder is cut at its start, so the part next to the name stays.
      el.querySelector('.folder').innerHTML = slash > 0 ? '<bdi></bdi>' : '';
      if (slash > 0) el.querySelector('.folder bdi').textContent = r.f.path.slice(0, slash);
      el.querySelector('.count').textContent = r.f.matches.length;
      el.title = r.f.path;
    }
    el.addEventListener('mousedown', (e) => {
      if (e.button !== 0) return;
      e.preventDefault();
      st.selected = r.key;
      focusResults();
      activate(r);
      Umi.app.report(true);
    });
    return el;
  }

  // ---- selection, keys ----
  const index = () => rows.findIndex((r) => r.key === st.selected);

  function select(i) {
    st.selected = rows[i]?.key ?? null;
    list.redraw();
    list.reveal(i);
  }

  function fold(collapse) {
    const r = rows[index()];
    if (!r || r.m) return;
    if (collapse) st.collapsed.add(r.f.path); else st.collapsed.delete(r.f.path);
    dirty = true;
    draw();
    list.reveal(index());
  }

  function activate(r) {
    if (!r.m) {
      st.selected = r.key;
      return fold(!st.collapsed.has(r.f.path));
    }
    const col = r.m.ranges.length ? r.m.ranges[0][0] + 1 : 1;
    V().openPath(Umi.fs.resolve(r.f.path, st.root), { line: r.m.line, col });
  }

  function onResultsKey(e) {
    if (e.metaKey || e.ctrlKey || e.altKey) return;
    const i = index();
    switch (e.key) {
      case 'ArrowUp': if (i <= 0) { st.selected = null; list.redraw(); S.ui.sidebarFocus = 'search'; focusQuery(); } else select(i - 1); break;
      case 'ArrowDown': select(i < 0 ? 0 : Math.min(rows.length - 1, i + 1)); break;
      case 'ArrowLeft': fold(true); break;
      case 'ArrowRight': fold(false); break;
      case 'Enter': if (i >= 0) activate(rows[i]); break;
      case 'Escape': V().focusPane(); break;
      default: return;
    }
    e.preventDefault();
  }

  function onQueryKey(e) {
    if (e.key === 'ArrowDown' || e.key === 'Enter') {
      e.preventDefault();
      if (e.key === 'Enter' && (st.timer || st.searched !== st.query)) search();
      focusResults();
    } else if (e.key === 'Escape') {
      e.preventDefault();
      V().focusPane();
    }
  }

  // ---- focus ----
  function focusQuery() {
    if (!box) return;
    if (document.activeElement !== input) input.focus();
    if (S.ui.searchSelectAll) { S.ui.searchSelectAll = false; input.select(); }
  }

  function focusResults() {
    if (!box) return;
    if (!rows.length) { S.ui.sidebarFocus = 'search'; return focusQuery(); }
    S.ui.sidebarFocus = 'results';
    if (index() < 0) select(0);
    if (document.activeElement !== listEl) listEl.focus({ preventScroll: true });
  }

  // ---- on screen ----
  function build() {
    box = document.querySelector('#search');
    box.innerHTML = `
      <div class="sq-title">Search</div>
      <div class="sq-field">
        <input spellcheck="false" placeholder="Search in files" aria-label="Search in files">
        <button class="sq-toggle" data-opt="caseSensitive" title="Toggle Case Sensitivity">${I.svg.caseToggle}</button>
        <button class="sq-toggle" data-opt="regex" title="Toggle Regex">${I.svg.regexToggle}</button>
      </div>
      <div class="sq-msg" hidden></div>
      <div class="sq-capped" hidden>${I.svg.warning}<span>The result set only contains a subset of all matches. Be more specific in your search to narrow down results.</span></div>
      <div class="sr-list" tabindex="0" aria-label="Search Results"></div>`;
    input = box.querySelector('input');
    msgEl = box.querySelector('.sq-msg');
    capEl = box.querySelector('.sq-capped');
    listEl = box.querySelector('.sr-list');
    list = Umi.views.vlist(listEl, { rowHeight: ROW, row: rowEl });
    input.addEventListener('input', () => { st.query = input.value; schedule(); });
    input.addEventListener('keydown', onQueryKey);
    input.addEventListener('focus', () => {
      if (S.ui.sidebarFocus === 'search') return;
      S.ui.sidebarFocus = 'search';
      Umi.app.report(true);
    });
    listEl.addEventListener('keydown', onResultsKey);
    box.querySelectorAll('.sq-toggle').forEach((b) => b.addEventListener('mousedown', (e) => {
      e.preventDefault();
      st[b.dataset.opt] = !st[b.dataset.opt];
      search();
    }));
  }

  // While Search shows: a project change (another pane focused) runs the query there.
  function render() {
    if (!box) { build(); dirty = true; }
    const root = V().root();
    if (st.query && root && root !== st.root) search();
    if (dirty) draw();
  }

  function debug() {
    return {
      query: st.query, root: st.root, searching: st.searching, count: st.count, files: st.files.length, capped: st.capped,
      error: st.error, message: message(), selected: st.selected,
      rows: rows.slice(0, 200).map((r) => (r.m ? { path: r.f.path, line: r.m.line, text: snippet(r.m).text } : { file: r.f.path, count: r.f.matches.length })),
    };
  }

  return { render, focusQuery, focusResults, debug, search: () => search(), set: (o) => { Object.assign(st, o); if (input) input.value = st.query; search(); } };
})();
