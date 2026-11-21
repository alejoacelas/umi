// The pane picker (DESIGN "⌘D: the pane picker"), drawn inside a new pane:
//   1. a name field, focused: Enter starts a Claude session with that name; Tab cycles
//      Claude, Codex, shell;
//   2. live sessions of the focused pane's project waiting for input, most recent first;
//   3. live sessions of that project that are busy;
//   4. past sessions of that project that can be resumed (Claude's and Codex's transcripts).
// ↑↓ choose, Enter opens, Esc closes the pane.
//
// The session starts in the folder under the name field: at first the focused pane's. `/` in the
// empty name field (or a click on the folder) turns the field into a folder search:
//   - letters match folders in use (live sessions, tabs, folders chosen here before), the folders
//     next to them and, for a folder two or more levels under home, the folders next to its parent
//     (so every project of a workspace like ~/best). Projects with Claude/Codex history come
//     first, then match quality and recent folder choices;
//   - a path (`~/…`, `/…`, `./…`, `../…`, or anything with a `/`) lists that folder's folders,
//     filtered by what follows the last `/`.
// ↑↓ choose, Enter takes the folder, Tab goes into the chosen one, ⇧Tab goes up one, Esc (or ⌫ in
// the empty field) goes back to the name without changing the folder.
'use strict';
Umi.views = Umi.views || {};

Umi.views.picker = (() => {
  const S = Umi.state, M = Umi.model;
  const KINDS = ['claude', 'codex', 'shell'];
  const LABEL = { claude: 'Claude', codex: 'Codex', shell: 'Shell' };
  const base = (p) => (p || '').split('/').filter(Boolean).pop() || '~';
  const ago = (t) => {
    const s = Date.now() / 1000 - t;
    return s < 90 ? 'just now' : s < 5400 ? `${Math.round(s / 60)} min ago` : s < 129600 ? `${Math.round(s / 3600)} h ago` : `${Math.round(s / 86400)} d ago`;
  };

  // ---- the folder search ----
  const tilde = (p) => (S.home && (p === S.home || p.startsWith(S.home + '/')) ? '~' + p.slice(S.home.length) : p);
  const parent = (p) => p.replace(/\/[^/]*$/, '') || '/';
  const inHome = (p) => !!S.home && (p === S.home || p.startsWith(S.home + '/'));
  const redraw = () => Umi.views.panes.refreshPickers();

  // Folders in use, most recent first: those chosen here before, live sessions' and the tabs' panes'.
  function recents() {
    const chosen = Object.entries(S.layout.meta?.folders || {}).sort((a, b) => b[1] - a[1]).map((e) => e[0]);
    const live = Object.values(S.live).filter((s) => s.alive && M.userStarted(s))
      .sort((a, b) => (b.created || 0) - (a.created || 0)).flatMap((s) => [s.project, s.folder]);
    const panes = S.layout.tabs.flatMap((t) => M.paneIds(t.root)).flatMap((id) => [M.projectOf(id), M.folderOf(id)]);
    return [...new Set([...chosen, ...live, ...panes].filter(Boolean))];
  }

  // A folder's folders (names), from a cache that lasts one folder search: [] while loading,
  // null when the folder can't be read.
  let dirs = new Map();
  function subdirs(dir, hidden) {
    const k = (hidden ? '.' : '') + dir;
    if (!dirs.has(k)) {
      dirs.set(k, []);
      const cache = dirs;
      Umi.fs.list(dir, { hidden, ignored: true })
        .then((r) => r.entries.filter((e) => e.kind === 'dir').map((e) => e.name), () => null)
        .then((names) => { cache.set(k, names); if (cache === dirs) { known = null; redraw(); } });
    }
    return dirs.get(k);
  }

  // The folders letters match: recents, then the folders next to each and next to its parent.
  // Only inside home, and never home's own folders' contents unless one is in use, so macOS
  // doesn't ask for Documents, Desktop and the like.
  let known = null;
  let history = [];
  Umi.bridge.on('agentProjects', (msg) => {
    history = msg.list;
    known = null;
    redraw();
  });
  function agentFolders() {
    return new Set([...history, ...Object.values(S.live)
      .filter((s) => M.userStarted(s) && ['claude', 'codex'].includes(s.kind))
      .flatMap((s) => [s.project, s.folder]).filter(Boolean)]);
  }
  function prioritize(paths) {
    const used = agentFolders();
    return paths.sort((a, b) => Number(used.has(b)) - Number(used.has(a)));
  }
  function knownFolders() {
    if (known) return known;
    const seeds = [...new Set([...recents(), ...history])];
    const parents = new Set();
    for (const p of seeds) {
      const up = parent(p), top = parent(up);
      if (inHome(up)) parents.add(up);
      if (inHome(top) && top !== S.home) for (const n of subdirs(top, false) || []) parents.add(top + '/' + n);
    }
    const out = new Set(seeds);
    const near = [...parents].slice(0, 60);
    for (const d of near) for (const n of subdirs(d, false) || []) out.add(d + '/' + n);
    for (const d of near) out.add(d);
    return (known = [...out]);
  }

  // The rows of the folder search for what is typed: [{path, use?}] and whether the folder exists.
  function folderRows(node) {
    const q = node.picker.query || '';
    if (/^[~/.]/.test(q) || q.includes('/')) {
      const typed = q === '~' ? '~/' : q;
      const cut = typed.lastIndexOf('/') + 1;
      const dir = Umi.fs.resolve(typed.slice(0, cut) || '.', node.cwd || S.home);
      const seg = typed.slice(cut);
      const names = subdirs(dir, seg.startsWith('.'));
      if (!names) return { rows: [], missing: tilde(dir) };
      const rows = (seg ? Umi.fs.fuzzy(seg, names, 200).map((r) => r.path) : names).map((n) => ({ path: (dir === '/' ? '' : dir) + '/' + n }));
      return { rows: seg ? rows : [{ path: dir, use: true }, ...rows] };
    }
    const all = prioritize([...knownFolders()]);
    if (!q.trim()) return { rows: all.slice(0, 200).map((path) => ({ path })) };
    const shown = all.map(tilde);
    const rank = new Map(shown.map((p, i) => [p, i]));
    const used = agentFolders();
    const hits = Umi.fs.fuzzy(q, shown, shown.length).sort((a, b) =>
      Number(used.has(all[rank.get(b.path)])) - Number(used.has(all[rank.get(a.path)])) ||
      b.score - a.score || rank.get(a.path) - rank.get(b.path)).slice(0, 200);
    return { rows: hits.map((r) => ({ path: all[rank.get(r.path)] })) };
  }

  function folderMode(el, node, on) {
    const pk = node.picker;
    if (on) { dirs = new Map(); known = null; pk.mode = 'folder'; Umi.bridge.post({ type: 'agentProjects' }); } else delete pk.mode;
    pk.query = '';
    pk.fsel = 0;
    el.querySelector('.picker-name').value = on ? '' : pk.name;
    refresh(el, node);
  }

  // The repository's main folder (a worktree counts as its repository), else the folder.
  async function projectOfFolder(path) {
    const root = (await Umi.fs.gitRoot(path).catch(() => null))?.root;
    if (!root) return path;
    const link = await Umi.fs.read(root + '/.git').catch(() => null);
    const m = link && /^gitdir: (.*)\/\.git\/worktrees\//m.exec(link.text);
    return m ? m[1] : root;
  }

  // The picker's session will start in `path`; its lists become that folder's project's.
  function chooseFolder(el, node, path) {
    const pk = node.picker;
    Umi.app.update(() => {
      node.cwd = path;
      pk.project = path;
      pk.sel = 0;
      S.layout.meta = S.layout.meta || { sessions: {} };
      const f = (S.layout.meta.folders = S.layout.meta.folders || {});
      f[path] = Date.now();
      for (const old of Object.keys(f).sort((a, b) => f[b] - f[a]).slice(40)) delete f[old];
    });
    const now = document.querySelector(`#panes .slot[data-pane="${node.id}"]`) || el;
    folderMode(now, node, false);
    focus();
    projectOfFolder(path).then((project) => {
      if (node.cwd !== path) return;
      Umi.app.update(() => { pk.project = project; });
      if (S.past.project !== project) Umi.bridge.post({ type: 'pastSessions', project });
    });
  }

  function folderKey(e, el, node) {
    const pk = node.picker, input = e.target;
    const { rows } = folderRows(node);
    const sel = rows[pk.fsel] || rows[0];
    const type = (text) => { input.value = pk.query = text; pk.fsel = 0; refresh(el, node); };
    if (e.key === 'Tab') {
      e.preventDefault();
      if (!e.shiftKey) { if (sel) type(tilde(sel.path).replace(/\/$/, '') + '/'); return; }
      const use = rows.find((r) => r.use);
      type(tilde(parent(use ? use.path : node.cwd || S.home)).replace(/\/$/, '') + '/');
    } else if (e.key === 'ArrowDown' || e.key === 'ArrowUp') {
      e.preventDefault();
      pk.fsel = Math.max(0, Math.min(rows.length - 1, (pk.fsel || 0) + (e.key === 'ArrowDown' ? 1 : -1)));
      refresh(el, node);
    } else if (e.key === 'Enter') {
      e.preventDefault();
      if (sel) chooseFolder(el, node, sel.path);
    } else if (e.key === 'Escape' || (e.key === 'Backspace' && !input.value)) {
      e.preventDefault();
      folderMode(el, node, false);
    }
  }

  function drawFolders(el, node, list) {
    const pk = node.picker;
    const { rows, missing } = folderRows(node);
    if (missing || !rows.length) {
      const none = document.createElement('div');
      none.className = 'picker-section';
      none.textContent = missing ? `No folder ${missing}` : 'No folder matches';
      list.append(none);
    }
    rows.forEach((r, i) => {
      const row = document.createElement('div');
      row.className = 'picker-row' + (i === (pk.fsel || 0) ? ' sel' : '');
      row.innerHTML = '<b></b><span class="dim"></span>';
      row.querySelector('b').textContent = r.use ? 'This folder' : base(r.path);
      row.querySelector('.dim').textContent = tilde(r.use ? r.path : parent(r.path));
      row.addEventListener('mousedown', (e) => { e.preventDefault(); chooseFolder(el, node, r.path); });
      list.append(row);
    });
  }

  function items(node) {
    const pk = node.picker;
    const all = Object.values(S.live).filter((s) => M.userStarted(s) && s.project === pk.project);
    const docketed = all.filter((s) => s.docket);
    const live = all.filter((s) => s.alive && !s.docket);
    const recent = (a, b) => (b.agent?.ts || b.created || 0) - (a.agent?.ts || a.created || 0);
    const by = (st) => live.filter((s) => M.standing(s) === st).sort(recent);
    const past = S.past.project === pk.project ? S.past.list : [];
    return [
      { type: 'new' },
      ...[...by('needs'), ...by('idle')].map((s) => ({ type: 'live', section: 'Waiting for you', s })),
      ...by('busy').map((s) => ({ type: 'live', section: 'Busy', s })),
      ...by('finished').map((s) => ({ type: 'live', section: 'Finished', s })),
      ...docketed.sort(recent).map((s) => ({ type: 'live', section: 'On the docket', s })),
      ...past.map((p) => ({ type: 'past', section: 'Past sessions', p })),
    ];
  }

  function act(node, item) {
    const pk = node.picker;
    const cmds = S.commands || {};
    Umi.app.update(() => {
      if (item.type === 'new') {
        const cmd = pk.kind === 'shell' ? null : (cmds[pk.kind] || pk.kind);
        M.startSession(node.id, { cmd, name: pk.name.trim() });
      } else if (item.type === 'live') {
        M.openSession(item.s.id, node.id);
      } else {
        const p = item.p;
        const cmd = p.kind === 'claude' ? `${cmds.claude || 'claude'} --resume ${p.id}` : `${cmds.codex || 'codex'} resume ${p.id}`;
        M.startSession(node.id, { cmd, name: p.title.slice(0, 40), cwd: p.cwd });
      }
    });
  }

  function render(el, node) {
    const pk = node.picker;
    el.classList.add('picker');
    el.innerHTML = `
      <div class="picker-head">
        <input class="picker-name" spellcheck="false">
        <div class="picker-kinds">${KINDS.map((k) => `<span data-kind="${k}">${LABEL[k]}</span>`).join('')}</div>
      </div>
      <div class="picker-project"></div>
      <div class="picker-list"></div>`;
    const input = el.querySelector('.picker-name');
    input.value = pk.mode === 'folder' ? pk.query || '' : pk.name;
    input.addEventListener('input', () => {
      if (pk.mode === 'folder') { pk.query = input.value; pk.fsel = 0; } else { pk.name = input.value; pk.sel = 0; }
      refresh(el, node);
    });
    input.addEventListener('keydown', (e) => {
      if (pk.mode === 'folder') return folderKey(e, el, node);
      if (e.key === '/' && !input.value) { e.preventDefault(); return folderMode(el, node, true); }
      const list = items(node);
      if (e.key === 'Tab') {
        e.preventDefault();
        pk.kind = KINDS[(KINDS.indexOf(pk.kind) + (e.shiftKey ? 2 : 1)) % 3];
        refresh(el, node);
      } else if (e.key === 'ArrowDown' || e.key === 'ArrowUp') {
        e.preventDefault();
        pk.sel = Math.max(0, Math.min(list.length - 1, pk.sel + (e.key === 'ArrowDown' ? 1 : -1)));
        refresh(el, node);
      } else if (e.key === 'Enter') {
        e.preventDefault();
        act(node, list[pk.sel] || list[0]);
      } else if (e.key === 'Escape') {
        e.preventDefault();
        const all = S.layout.tabs.flatMap((t) => M.paneIds(t.root));
        if (all.length > 1) Umi.app.update(() => M.removePane(node.id));
      }
    });
    el.addEventListener('mousedown', (e) => {
      const k = e.target.closest('[data-kind]');
      if (k) { pk.kind = k.dataset.kind; refresh(el, node); }
      if (e.target.closest('.picker-project')) { e.preventDefault(); folderMode(el, node, pk.mode !== 'folder'); input.focus(); }
    });
    refresh(el, node);
    if (S.past.project !== pk.project && !pk.askedPast) {
      pk.askedPast = true;
      Umi.bridge.post({ type: 'pastSessions', project: pk.project });
    }
  }

  // Focuses the name field of the focused picker (after a render, when the web view has the keys).
  function focus() {
    const tab = M.activeTab();
    const el = document.querySelector(`#panes .slot[data-pane="${tab.focused}"] .picker-name`);
    if (el && document.activeElement !== el) { el.focus(); el.setSelectionRange(el.value.length, el.value.length); }
  }

  function refresh(el, node) {
    const pk = node.picker;
    el.querySelectorAll('[data-kind]').forEach((k) => k.classList.toggle('on', k.dataset.kind === pk.kind));
    const folder = pk.mode === 'folder';
    el.querySelector('.picker-name').placeholder = folder
      ? 'Folder: letters to match, or a path like ~/ or ../'
      : `Name (empty: ${base(node.cwd)} and a number)`;
    const where = el.querySelector('.picker-project');
    where.innerHTML = '<b></b> <span></span>';
    where.querySelector('b').textContent = tilde(node.cwd || S.home || '');
    where.querySelector('span').textContent = folder ? '↩ take · ⇥ go in · ⇧⇥ up · esc back' : '/ to change the folder';
    const list = el.querySelector('.picker-list');
    list.textContent = '';
    if (folder) {
      drawFolders(el, node, list);
      const on = list.querySelector('.sel');
      if (on) on.scrollIntoView({ block: 'nearest' });
      return;
    }
    if (pk.jump === 'past') {
      const i = items(node).findIndex((it) => it.type === 'past');
      if (i > 0) { pk.sel = i; delete pk.jump; }
    }
    let section = null;
    items(node).forEach((item, i) => {
      if (item.section && item.section !== section) {
        section = item.section;
        const h = document.createElement('div');
        h.className = 'picker-section';
        h.textContent = section;
        list.append(h);
      }
      const row = document.createElement('div');
      row.className = 'picker-row' + (i === pk.sel ? ' sel' : '');
      if (item.type === 'new') {
        row.innerHTML = `<b>New ${LABEL[pk.kind]} session</b><span class="dim"></span>`;
        row.querySelector('.dim').textContent = pk.name.trim() || M.defaultName(node.cwd);
      } else if (item.type === 'live') {
        const s = item.s;
        const shown = M.paneOfSession(s.id);
        row.innerHTML = `<span class="kind"></span><b></b><span class="dim"></span>`;
        row.querySelector('.kind').textContent = s.kind;
        row.querySelector('b').textContent = M.sessionName(s.id);
        const st = s.agent && Umi.status.parseStatus(s.agent.reply);
        const said = st ? (st.kind === 'other' ? st.detail : `${st.kind === 'pending' ? 'done, pending' : st.kind}${st.detail ? ': ' + st.detail : ''}`) : '';
        const dk = s.docket && ({ pending: 'docketed, turn running', on: 'on the docket', failed: 'docket hook failed' }[s.docket.state]);
        row.querySelector('.dim').textContent = [dk, M.isSnoozed(s.id) ? 'snoozed' : '', shown ? 'on screen' : '', said || s.foreground, base(s.folder)].filter(Boolean).join(' · ');
      } else {
        const p = item.p;
        row.innerHTML = `<span class="kind"></span><b></b><span class="dim"></span>`;
        row.querySelector('.kind').textContent = p.kind;
        row.querySelector('b').textContent = p.title;
        row.querySelector('.dim').textContent = ago(p.mtime);
      }
      row.addEventListener('mousedown', (e) => { e.preventDefault(); pk.sel = i; act(node, item); });
      list.append(row);
    });
    const sel = list.querySelector('.sel');
    if (sel) sel.scrollIntoView({ block: 'nearest' });
  }

  return { render, refresh, focus };
})();
