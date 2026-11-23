// The project explorer: the sidebar's Files mode (SPEC S-2, Umi's UmiFileTree.swift).
//
// The root is the focused pane's repository (Umi.views.modes.root(): its git top folder) shown as an ordinary collapsible row.
// A folder is listed (Umi.fs.list) when first opened; the root is watched (Umi.fs.watch, which is
// recursive) while the tree is on screen, and a change re-lists the open folders it touches, so the
// tree follows the disk with no refresh. Folders first, dotfiles first (⇧⌘> hides them); what git
// ignores is italic and lighter; `.git` and `.DS_Store` are never listed. When the focused pane
// shows a file (track a's `view: 'file'` pane), the tree opens its folders and selects it,
// stopping at a folder the user closed.
//
// Keys while the tree has them: ↑↓ select, → opens a folder, ← closes it or goes to its folder,
// Enter opens a file or opens/closes a folder, Esc gives the keys back to the pane. Right-click:
// Umi's menu (native). New File and Rename edit the name in the row.
'use strict';
Umi.views = Umi.views || {};

Umi.views.explorer = (() => {
  const S = Umi.state, M = Umi.model, I = Umi.icons, V = () => Umi.views.modes;
  const ROW = 25, INDENT = 16;
  const trees = new Map(); // root → tree, so a project's open folders survive switching tabs
  let T = null;            // the tree on screen
  let box, listEl, list, rows = [], dirty = true;
  let watch = null, watchRoot = null;
  let editEl = null;

  const dirname = (p) => p.slice(0, p.lastIndexOf('/')) || '/';
  const basename = (p) => p.split('/').filter(Boolean).pop() || '/';

  function makeTree(root) {
    const t = { root, nodes: new Map(), selected: null, collapsedByUser: new Set(), edit: null, revealed: null, stale: false };
    t.nodes.set(root, { path: root, name: basename(root), kind: 'dir', expanded: true, children: null });
    load(t, root);
    return t;
  }

  // Lists a folder (again), keeping what is known about the entries still there.
  function load(t, path) {
    const n = t.nodes.get(path);
    if (!n) return Promise.resolve();
    const p = Umi.fs.list(path, { hidden: true, ignored: true }).then((r) => {
      const now = new Set(r.entries.map((e) => e.path));
      for (const old of n.children || []) if (!now.has(old)) forget(t, old);
      for (const e of r.entries) {
        const had = t.nodes.get(e.path);
        if (had && had.kind === e.kind) Object.assign(had, { name: e.name, ignored: e.ignored, hidden: e.hidden, link: !!e.link });
        else {
          if (had) forget(t, e.path);
          t.nodes.set(e.path, { path: e.path, name: e.name, kind: e.kind, ignored: e.ignored, hidden: e.hidden, link: !!e.link, expanded: false, children: null });
        }
      }
      // Warp's order: folders first, dotfiles first within each, then natural order (Umi.fs.list's).
      const rank = (e) => (e.kind === 'dir' ? 0 : 2) + (e.name.startsWith('.') ? 0 : 1);
      n.children = r.entries.map((e, i) => [rank(e), i, e.path]).sort((x, y) => x[0] - y[0] || x[1] - y[1]).map((x) => x[2]);
      n.error = null;
    }, (e) => { n.children = n.children || []; n.error = e.message; })
      .finally(() => { if (n.loading === p) n.loading = null; changed(t); });
    n.loading = p;
    return p;
  }

  function forget(t, path) {
    const n = t.nodes.get(path);
    if (!n) return;
    for (const c of n.children || []) forget(t, c);
    t.nodes.delete(path);
  }

  const loadedFolders = (t) => [...t.nodes.values()].filter((n) => n.kind === 'dir' && n.children);

  function changed(t) {
    if (t !== T) return;
    dirty = true;
    draw();
  }

  // ---- rows ----
  function buildRows() {
    const out = [];
    const hide = !!S.layout.hideDotfiles;
    const add = (path, depth) => {
      const n = T.nodes.get(path);
      if (!n) return;
      out.push({ kind: 'item', n, depth });
      if (n.kind !== 'dir' || !n.expanded) return;
      if (T.edit?.type === 'new' && T.edit.folder === path) out.push({ kind: 'new', depth: depth + 1 });
      for (const c of n.children || []) {
        const cn = T.nodes.get(c);
        if (cn && !(hide && cn.hidden)) add(c, depth + 1);
      }
    };
    add(T.root, 0);
    rows = out;
    // The selected item went away (deleted or hidden): nothing selected, as Warp does.
    if (T.selected && !rows.some((r) => r.kind === 'item' && r.n.path === T.selected)) T.selected = null;
  }

  function draw() {
    if (!T || !list) return;
    if (dirty) { buildRows(); dirty = false; list.set(rows.length); } else list.redraw();
  }

  // A name too long for its row, cut in the middle as Umi's (truncationMode(.middle)):
  // "BRIEF-com…e-sizes.md".
  const measure = document.createElement('canvas').getContext('2d');
  function fit(name, depth, ignored) {
    // The row's room for the name: the list less the indent, chevron, icon and padding.
    const room = listEl.clientWidth - (depth * INDENT + 8) - (16 + 4 + 16 + 8) - 8;
    measure.font = `${ignored ? 'italic 300 ' : ''}14px -apple-system, BlinkMacSystemFont, sans-serif`;
    if (room <= 0 || measure.measureText(name).width <= room) return name;
    let lo = 1, hi = name.length - 1, best = name.slice(0, 1) + '…';
    while (lo <= hi) {
      const keep = (lo + hi) >> 1, head = Math.ceil(keep / 2), tail = keep - head;
      const s = name.slice(0, head) + '…' + (tail ? name.slice(-tail) : '');
      if (measure.measureText(s).width <= room) { best = s; lo = keep + 1; } else hi = keep - 1;
    }
    return best;
  }

  function rowEl(i) {
    const r = rows[i];
    if (r.kind === 'new' || (T.edit?.type === 'rename' && T.edit.path === r.n.path)) return editRow(r);
    const n = r.n;
    const el = document.createElement('div');
    el.className = 'ft-row' + (n.path === T.selected ? ' sel' : '') + (n.ignored ? ' ignored' : '');
    el.style.paddingLeft = r.depth * INDENT + 8 + 'px';
    el.title = n.path;
    const chev = document.createElement('span');
    chev.className = 'chev';
    if (n.kind === 'dir') chev.innerHTML = n.expanded ? I.svg.chevronDown : I.svg.chevronRight;
    const icon = document.createElement('span');
    icon.className = 'ficon';
    if (n.kind === 'dir') icon.innerHTML = I.svg.folder; else icon.append(I.img(n.name, 16));
    const name = document.createElement('span');
    name.className = 'name';
    name.textContent = fit(n.name, r.depth, n.ignored);
    el.append(chev, icon, name);
    el.addEventListener('mousedown', (e) => {
      if (e.button !== 0 || e.ctrlKey) return;
      e.preventDefault();
      S.ui.sidebarFocus = 'files';
      activate(n.path);
      Umi.app.report(true);
    });
    el.addEventListener('contextmenu', (e) => { e.preventDefault(); menu(n, e); });
    return el;
  }

  // The row being named (New File, Rename): one element kept across redraws so it keeps focus.
  function editRow(r) {
    if (!editEl) {
      editEl = document.createElement('div');
      editEl.className = 'ft-row editing';
      editEl.innerHTML = '<span class="chev"></span><span class="ficon"></span><input spellcheck="false">';
      const input = editEl.querySelector('input');
      input.addEventListener('keydown', (e) => {
        e.stopPropagation();
        if (e.key === 'Enter') { e.preventDefault(); commitEdit(); }
        if (e.key === 'Escape') { e.preventDefault(); cancelEdit(); }
      });
      input.addEventListener('blur', () => { if (T?.edit && !T.edit.closing) commitEdit(); });
    }
    editEl.style.paddingLeft = r.depth * INDENT + 8 + 'px';
    const icon = editEl.querySelector('.ficon');
    const name = T.edit.type === 'rename' ? basename(T.edit.path) : 'new_file';
    icon.replaceChildren(T.edit.type === 'rename' && r.n.kind === 'dir' ? Object.assign(document.createElement('span'), { innerHTML: I.svg.folder }) : I.img(name, 16));
    return editEl;
  }

  // ---- selection, keys ----
  const items = () => rows.filter((r) => r.kind === 'item');

  function select(path, reveal = true) {
    T.selected = path;
    list.redraw();
    if (reveal) list.reveal(rows.findIndex((r) => r.kind === 'item' && r.n.path === path));
  }

  function move(d) {
    const its = items();
    if (!its.length) return;
    const i = its.findIndex((r) => r.n.path === T.selected);
    select(its[i < 0 ? 0 : Math.max(0, Math.min(its.length - 1, i + d))].n.path);
  }

  function setExpanded(path, open, byUser = false) {
    const n = T.nodes.get(path);
    if (!n || n.kind !== 'dir') return;
    if (byUser) { if (open) T.collapsedByUser.delete(path); else T.collapsedByUser.add(path); }
    if (n.expanded === open) return;
    n.expanded = open;
    // A folder opened again is read again (it may have changed while closed).
    if (open) load(T, path);
    dirty = true;
    draw();
  }

  // Enter, or a click: a folder opens or closes, a file opens.
  function activate(path) {
    select(path, false);
    const n = T.nodes.get(path);
    if (!n) return;
    if (n.kind === 'dir') setExpanded(path, !n.expanded, true);
    else V().openPath(path);
  }

  function onKey(e) {
    if (T.edit || e.metaKey || e.ctrlKey || e.altKey) return;
    const sel = T.nodes.get(T.selected);
    switch (e.key) {
      case 'ArrowUp': move(-1); break;
      case 'ArrowDown': move(1); break;
      case 'ArrowRight': if (sel && sel.kind === 'dir' && !sel.expanded) setExpanded(sel.path, true, true); break;
      case 'ArrowLeft':
        if (!sel) break;
        if (sel.kind === 'dir' && sel.expanded) setExpanded(sel.path, false, true);
        else if (sel.path !== T.root) select(dirname(sel.path));
        break;
      case 'Enter': if (sel) activate(sel.path); else move(1); break;
      case 'Escape': V().focusPane(); break;
      default: return;
    }
    e.preventDefault();
  }

  // ---- reveal the focused file ----
  async function reveal(path) {
    const t = T;
    if (!path.startsWith(t.root + '/') || t.collapsedByUser.has(t.root)) return;
    const parts = path.slice(t.root.length + 1).split('/');
    let cur = t.root;
    for (let i = 0; i < parts.length; i++) {
      const n = t.nodes.get(cur);
      if (!n.expanded) { n.expanded = true; dirty = true; }
      if (!n.children) await (n.loading || load(t, cur));
      const next = cur + '/' + parts[i];
      if (!t.nodes.has(next)) return changed(t);
      cur = next;
      if (i < parts.length - 1 && t.collapsedByUser.has(cur)) return changed(t);
    }
    if (t !== T) return;
    dirty = true;
    draw();
    select(cur);
  }

  // ---- watching ----
  function startWatch() {
    if (watch && watchRoot === T.root) return;
    stopWatch();
    watchRoot = T.root;
    const t = T;
    watch = Umi.fs.watch(t.root, ({ changes }) => {
      const again = new Set();
      for (const c of changes) {
        if (c.kinds.includes('rescan') || c.path.endsWith('/.gitignore')) { loadedFolders(t).forEach((n) => again.add(n.path)); continue; }
        const parent = dirname(c.path);
        if (t.nodes.get(parent)?.children) again.add(parent);
      }
      again.forEach((p) => load(t, p));
    });
    watch.done.catch(() => {});
  }
  function stopWatch() {
    if (watch) watch.close();
    watch = null;
    watchRoot = null;
  }

  // ---- inline editing ----
  function startNew(folder) {
    setExpanded(folder, true);
    T.edit = { type: 'new', folder };
    S.ui.sidebarFocus = 'files';
    dirty = true;
    draw();
    list.reveal(rows.findIndex((r) => r.kind === 'new'));
    const input = editEl.querySelector('input');
    input.value = '';
    input.focus();
  }

  function startRename(path) {
    if (path === T.root) return;
    T.edit = { type: 'rename', path };
    S.ui.sidebarFocus = 'files';
    T.selected = path;
    dirty = true;
    draw();
    list.reveal(rows.findIndex((r) => r.kind === 'item' && r.n.path === path));
    const input = editEl.querySelector('input');
    input.value = basename(path);
    const dot = input.value.lastIndexOf('.');
    input.focus();
    input.setSelectionRange(0, dot > 0 ? dot : input.value.length);
  }

  function endEdit() {
    const ed = T.edit;
    if (ed) ed.closing = true;
    T.edit = null;
    dirty = true;
    draw();
    listEl.focus({ preventScroll: true });
    return ed;
  }

  function cancelEdit() {
    const ed = endEdit();
    if (ed?.type === 'rename') select(ed.path);
  }

  // Enter, or leaving the field: an empty name cancels (as in Warp and VS Code).
  async function commitEdit() {
    const name = editEl.querySelector('input').value.trim();
    const t = T, ed = endEdit();
    if (!ed || !name) { if (ed?.type === 'rename') select(ed.path); return; }
    if (name.includes('/')) return V().flash('A file name can\'t contain "/".');
    if (ed.type === 'new') {
      const path = ed.folder + '/' + name;
      try {
        await Umi.fs.write(path, '', { version: null });
      } catch (e) {
        return V().flash(`Can't create ${name}: ${e.code === 'conflict' ? 'something with that name is already there' : e.message}`);
      }
      await load(t, ed.folder);
      if (t === T) select(path);
      V().openPath(path);
    } else {
      const to = dirname(ed.path) + '/' + name;
      if (to === ed.path) return select(ed.path);
      try {
        await Umi.fs.rename(ed.path, to);
      } catch (e) {
        return V().flash(`Can't rename ${basename(ed.path)}: ${e.message}`);
      }
      await load(t, dirname(ed.path));
      if (t === T) select(to);
    }
  }

  // ---- the right-click menu (Umi's items, UmiFileTree.menuItems) ----
  async function menu(n, e) {
    select(n.path, false);
    const isDir = n.kind === 'dir', isRoot = n.path === T.root;
    const tp = V().terminalPane(), pp = V().promptPane();
    const items = [];
    const add = (title, fn, enabled = true) => items.push({ title, enabled, fn });
    const sep = () => items.push({ separator: true });
    if (isDir) {
      add('New File', () => startNew(n.path));
      sep();
      add('cd to Directory', () => cdTo(pp, n.path), !!pp);
      add('Open in New Tab', () => Umi.app.update(() => M.addTab(M.newPicker(n.path, n.path))));
    } else {
      add('Open in New Pane', () => V().openPath(n.path));
      add('Open in New Tab', () => V().openPath(n.path, { newTab: true }));
      add('Open with Default App', () => Umi.fs.openDefault(n.path));
    }
    add('Reveal in Finder', () => Umi.fs.reveal(n.path));
    if (!isRoot) {
      add('Rename', () => startRename(n.path));
      add('Delete', () => trash(n.path));
    }
    sep();
    add('Insert Path in Terminal', () => V().sendText(tp, V().shellQuote(n.path) + ' '), !!tp);
    sep();
    add('Copy Path', () => Umi.bridge.request('clipboard', { text: n.path }));
    add('Copy Relative Path', () => Umi.bridge.request('clipboard', { text: relative(n.path) }));
    const r = await Umi.bridge.request('menu', { items: items.map(({ title, enabled, separator }) => (separator ? { separator } : { title, enabled })), x: e.clientX, y: e.clientY });
    if (r && r.index != null) items[r.index].fn();
  }

  const relative = (p) => (p === T.root ? '.' : p.startsWith(T.root + '/') ? p.slice(T.root.length + 1) : p);

  // Warp's "cd to directory": replaces what is typed at the prompt (⌃E ⌃U) with `cd FOLDER`, not
  // run; the keys go to that terminal.
  function cdTo(pane, folder) {
    V().sendText(pane, '\x05\x15cd ' + V().shellQuote(folder));
    Umi.app.update(() => M.focusPane(pane));
  }

  // Delete moves to the Trash, asking nothing (as Warp); file panes showing it, or a file in it, close.
  async function trash(path) {
    const t = T;
    try {
      await Umi.fs.trash(path);
    } catch (e) {
      return V().flash(`Can't move ${basename(path)} to the Trash: ${e.message}`);
    }
    const showing = S.layout.tabs.flatMap((tab) => M.panesOf(tab.root)).filter((p) => {
      if (p.view !== 'file' || !p.path) return false;
      const abs = Umi.fs.resolve(p.path);
      return abs === path || abs.startsWith(path + '/');
    });
    if (showing.length) Umi.app.update(() => showing.forEach((p) => M.removePane(p.id)));
    await load(t, dirname(path));
  }

  // ---- on screen ----
  function build() {
    box = document.querySelector('#explorer');
    box.innerHTML = '<div class="ft-list" tabindex="0" aria-label="Project Explorer"></div>';
    listEl = box.querySelector('.ft-list');
    list = Umi.views.vlist(listEl, { rowHeight: ROW, row: rowEl });
    listEl.addEventListener('keydown', onKey);
    listEl.addEventListener('focus', () => {
      if (S.ui.sidebarFocus === 'files') return;
      S.ui.sidebarFocus = 'files';
      Umi.app.report(true);
    });
  }

  // Draws the tree for the focused pane's project (sidebar.render calls this while Files shows).
  function render() {
    if (!box) build();
    const root = V().root();
    if (!root) return; // git is being asked; the sidebar draws again when it answers
    if (!T || T.root !== root) {
      if (T && T.edit) T.edit = null;
      T = trees.get(root) || makeTree(root);
      trees.set(root, T);
      dirty = true;
    }
    if (T.stale) {
      // Hidden for a while: read the open folders again.
      T.stale = false;
      loadedFolders(T).forEach((n) => load(T, n.path));
    }
    startWatch();
    const pane = M.focusedPane();
    const file = pane && pane.view === 'file' && pane.path ? Umi.fs.resolve(pane.path) : null;
    // Each time a file pane takes the focus (again), the tree shows its file.
    if (file !== T.revealed) { T.revealed = file; if (file) reveal(file); }
    if ((S.layout.hideDotfiles ? 1 : 0) !== T.hideShown) { T.hideShown = S.layout.hideDotfiles ? 1 : 0; dirty = true; }
    // Only when something changed: the sidebar draws every second (sessions), and redrawing rows
    // under the pointer would lose a click.
    if (dirty) draw();
  }

  // Files no longer shows: stop watching; its open folders are read again when it shows.
  function hide() {
    if (!watch) return;
    stopWatch();
    for (const t of trees.values()) t.stale = true;
  }

  function focus() {
    if (!box) return;
    if (T && T.edit) { const i = editEl.querySelector('input'); if (document.activeElement !== i) i.focus(); return; }
    if (document.activeElement !== listEl) listEl.focus({ preventScroll: true });
  }

  // For checks: the rows as text.
  function debug() {
    return { root: T?.root, selected: T?.selected, rows: rows.map((r) => (r.kind === 'new' ? { new: true, depth: r.depth } : { path: r.n.path, depth: r.depth, dir: r.n.kind === 'dir', open: !!r.n.expanded, ignored: !!r.n.ignored })) };
  }

  // Shows `path` with its folders opened and selects it; a folder opens too (the CLI and checks).
  async function show(path) {
    if (!T) return;
    if (path !== T.root) await reveal(path);
    if (T.nodes.get(path)?.kind === 'dir') setExpanded(path, true, true);
    select(path);
  }

  return { render, hide, focus, debug, startNew, startRename, trash, show };
})();
