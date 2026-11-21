// The pane switcher opens live sessions across projects. New and History share its folder chooser.
'use strict';
Umi.views = Umi.views || {};

Umi.views.picker = (() => {
  const S = Umi.state, M = Umi.model;
  const KINDS = ['claude', 'codex', 'antigravity', 'shell'];
  const LABEL = Umi.icons.agentLabels;
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
  // Projects whose past sessions were asked for since the page loaded (S.past holds the answers).
  const askedPast = new Set();
  function askPast(project) {
    if (!project || askedPast.has(project)) return;
    askedPast.add(project);
    Umi.bridge.post({ type: 'pastSessions', project });
  }

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

  function changePage(el, node, mode) {
    const pk = node.picker;
    pk.mode = mode;
    delete pk.choice;
    delete pk.notice;
    const input = el.querySelector('.picker-name');
    input.value = fieldValue(pk);
    refresh(el, node);
    input.focus();
    Umi.views.panes.refreshChrome();
    Umi.app.save();
  }

  function folderMode(el, node, on) {
    const pk = node.picker;
    if (on) {
      pk.folderFrom = pk.mode === 'history' ? 'history' : 'new';
      dirs = new Map();
      known = null;
      Umi.bridge.post({ type: 'agentProjects' });
    }
    pk.query = '';
    pk.fsel = 0;
    changePage(el, node, on ? 'folder' : pk.folderFrom || 'new');
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
      if (pk.project === project || !M.findPane(node.id)) return;
      pk.project = project;
      Umi.app.save();
      redraw();
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

  const groups = [
    ['needs', 'Needs you'], ['busy', 'Running'], ['available', 'Available'],
    ['snoozed', 'Snoozed'], ['docketed', 'On the docket'],
  ];
  const collapsible = (group) => group === 'snoozed' || group === 'docketed';
  function fieldValue(pk) {
    if (pk.mode === 'folder') return pk.query || '';
    if (pk.mode === 'new') return pk.name || '';
    if (pk.mode === 'history') return pk.historyQuery || '';
    return pk.search || '';
  }

  // Keys identify the choices even as a session changes group or another arrives above it.
  function choices(node) {
    const pk = node.picker;
    if (pk.mode === 'new') return [{ key: 'new', name: 'New session', detail: pk.name.trim() || M.defaultName(node.cwd), icon: pk.kind }];
    if (pk.mode === 'history') {
      const q = (pk.historyQuery || '').trim().toLowerCase();
      return (S.past[pk.project] || []).filter((p) => p.title.toLowerCase().includes(q))
        .map((p) => ({ key: 'past:' + p.kind + ':' + p.id, name: p.title, detail: ago(p.mtime), icon: p.kind, past: p }));
    }
    const found = M.switcherGroups(pk.search);
    const rows = [];
    for (const [group, label] of groups) {
      const sessions = found[group];
      if (!sessions.length) continue;
      if (collapsible(group) && !pk.search?.trim()) {
        const expanded = !!pk.expanded?.[group];
        rows.push({ key: group, disclosure: group, name: label, count: sessions.length, expanded });
        if (!expanded) continue;
      } else {
        rows.push({ heading: group, name: label });
      }
      for (const s of sessions) {
        const project = s.project || s.folder || '';
        const name = M.sessionName(s.id);
        const tip = s.docket?.state === 'failed' ? 'Docket failed: ' + (s.docket.error || '') : project;
        rows.push({ key: 'session:' + s.id, session: s.id, kind: s.kind, group, name, detail: base(project), tip });
      }
    }
    return rows;
  }

  function activate(el, node, item) {
    if (!item) return;
    const pk = node.picker, cmds = S.commands || {};
    if (item.disclosure) {
      pk.expanded ??= {};
      pk.expanded[item.disclosure] = !pk.expanded[item.disclosure];
      pk.choice = item.key;
      refresh(el, node);
      return;
    }
    Umi.app.update(() => {
      if (item.key === 'new') {
        const cmd = pk.kind === 'shell' ? null : cmds[pk.kind] || pk.kind;
        M.startSession(node.id, { cmd, name: pk.name.trim() });
      } else if (item.session) {
        pk.notice = M.switchFromPicker(item.session, node.id);
      } else if (item.past) {
        const p = item.past;
        M.startSession(node.id, { cmd: (cmds[p.kind] || p.kind) + ' --resume ' + p.id, name: p.title.slice(0, 40), cwd: p.cwd });
      }
    });
  }

  function selected(rows, pk) {
    return rows.find((r) => r.key && r.key === pk.choice) || rows.find((r) => r.key);
  }

  function handleKey(e, el, node) {
    if (e.isComposing) return;
    const pk = node.picker, input = el.querySelector('.picker-name');
    if (pk.mode === 'folder' && e.target === input) return folderKey(e, el, node);
    if (e.key === 'Escape') {
      e.preventDefault();
      if (pk.mode === 'folder') return folderMode(el, node, false);
      if (pk.mode === 'new' || pk.mode === 'history') return changePage(el, node, 'switcher');
      if (S.layout.tabs.some((t) => M.paneIds(t.root).some((id) => id !== node.id))) {
        Umi.app.update(() => M.removePane(node.id));
      }
      return;
    }
    if (e.metaKey || e.ctrlKey || e.altKey) return;
    if (e.key === 'Tab' && (!pk.mode || pk.mode === 'switcher')) {
      const order = [input, el.querySelector('[data-page=new]'), el.querySelector('[data-page=history]')];
      const i = order.indexOf(e.target);
      if (i >= 0) {
        e.preventDefault();
        order[(i + (e.shiftKey ? 2 : 1)) % 3].focus();
      }
      return;
    }
    if (e.target !== input) return;
    if (e.key === '/' && !input.value) {
      e.preventDefault();
      return folderMode(el, node, true);
    }
    if (e.key === 'Tab' && pk.mode === 'new') {
      e.preventDefault();
      pk.kind = KINDS[(KINDS.indexOf(pk.kind) + (e.shiftKey ? KINDS.length - 1 : 1)) % KINDS.length];
      return refresh(el, node);
    }
    if (!['Enter', 'ArrowDown', 'ArrowUp'].includes(e.key)) return;
    e.preventDefault();
    const rows = choices(node).filter((r) => r.key);
    const on = selected(rows, pk);
    if (!on) return;
    if (e.key === 'Enter') return activate(el, node, on);
    const i = rows.indexOf(on) + (e.key === 'ArrowDown' ? 1 : -1);
    pk.choice = rows[Math.max(0, Math.min(i, rows.length - 1))].key;
    refresh(el, node);
  }

  function render(el, node) {
    const pk = node.picker;
    el.classList.add('picker');
    el.innerHTML = `
      <div class="picker-head">
        <button type="button" data-page="switcher" class="picker-nav picker-back" aria-label="Back to sessions" title="Back (Esc)">‹</button>
        <input class="picker-name" spellcheck="false" autocomplete="off">
        <button type="button" data-page="new" class="picker-nav picker-new">+ New</button>
        <div class="picker-kinds">${KINDS.map((k) => `<button type="button" data-kind="${k}" title="${LABEL[k]}" aria-label="${LABEL[k]}"></button>`).join('')}</div>
      </div>
      <button type="button" class="picker-project"><b></b><span></span></button>
      <div role="status" class="picker-notice" hidden></div>
      <div class="picker-list"></div>
      <button type="button" data-page="history" class="picker-nav picker-history">History</button>`;
    el.querySelectorAll('[data-kind]').forEach((k) => k.prepend(Umi.icons.agent(k.dataset.kind)));
    const input = el.querySelector('.picker-name');
    input.value = fieldValue(pk);
    input.addEventListener('input', () => {
      if (pk.mode === 'folder') { pk.query = input.value; pk.fsel = 0; }
      else if (pk.mode === 'new') pk.name = input.value;
      else if (pk.mode === 'history') pk.historyQuery = input.value;
      else pk.search = input.value;
      delete pk.choice;
      delete pk.notice;
      refresh(el, node);
    });
    el.addEventListener('keydown', (e) => handleKey(e, el, node));
    el.addEventListener('click', (e) => {
      const button = e.target.closest('button');
      if (!button) return;
      if (button.classList.contains('picker-project')) return folderMode(el, node, pk.mode !== 'folder');
      if (button.dataset.page) {
        if (pk.mode === 'folder' && button.dataset.page === 'switcher') return folderMode(el, node, false);
        return changePage(el, node, button.dataset.page);
      }
      if (button.closest('.picker-kinds')) {
        pk.kind = button.dataset.kind;
        refresh(el, node);
        input.focus();
      }
    });
    refresh(el, node);
  }

  function focus() {
    const tab = M.activeTab();
    const el = document.querySelector(`#panes .slot[data-pane="${tab.focused}"]`);
    if (el && !el.contains(document.activeElement)) el.querySelector('.picker-name')?.focus();
  }

  function drawChoice(el, node, item, on) {
    if (item.heading) {
      const heading = document.createElement('div');
      heading.className = 'picker-section';
      heading.dataset.group = item.heading;
      heading.textContent = item.name;
      return heading;
    }
    const row = document.createElement('button');
    row.type = 'button';
    row.tabIndex = -1;
    row.className = 'picker-row' + (item === on ? ' sel' : '');
    if (item.disclosure) {
      row.classList.add('picker-disclosure');
      row.dataset.action = item.disclosure;
      row.setAttribute('aria-expanded', item.expanded);
      row.innerHTML = '<span class="picker-caret" aria-hidden="true"></span><b></b><span class="dim"></span>';
      row.querySelector('b').textContent = item.name;
      row.querySelector('.dim').textContent = item.count;
    } else {
      row.innerHTML = '<b></b><span class="dim"></span>';
      row.querySelector('b').textContent = item.name;
      row.querySelector('.dim').textContent = item.detail;
      if (item.session) {
        row.dataset.session = item.session;
        row.dataset.group = item.group;
        row.dataset.kind = item.kind;
        row.title = [item.name, item.tip].filter(Boolean).join('\n');
      }
      if (item.past) row.dataset.past = item.past.id;
      if (item.icon) row.prepend(Umi.icons.agent(item.icon));
    }
    row.addEventListener('mousedown', (e) => e.preventDefault());
    row.addEventListener('click', () => {
      activate(el, node, item);
      if (item.disclosure) el.querySelector('.picker-name').focus();
    });
    return row;
  }

  function refresh(el, node) {
    const pk = node.picker, mode = pk.mode || 'switcher';
    const switcher = mode === 'switcher', folder = mode === 'folder';
    el.dataset.mode = mode;
    for (const b of el.querySelectorAll('[data-page]')) b.hidden = (b.dataset.page === 'switcher') === switcher;
    el.querySelector('.picker-kinds').hidden = mode !== 'new';
    el.querySelectorAll('.picker-kinds [data-kind]').forEach((k) => {
      k.classList.toggle('on', k.dataset.kind === pk.kind);
      k.setAttribute('aria-pressed', String(k.dataset.kind === pk.kind));
    });
    const input = el.querySelector('.picker-name');
    input.placeholder = { switcher: 'Find a session…', new: 'Session name', history: 'Find a past session…', folder: 'Find a folder or enter a path…' }[mode];
    input.setAttribute('aria-label', input.placeholder);
    const where = el.querySelector('.picker-project');
    where.hidden = switcher;
    where.querySelector('b').hidden = mode === 'new';
    where.querySelector('b').textContent = mode === 'history' ? base(pk.project) : tilde(node.cwd || S.home || '');
    where.querySelector('span').textContent = folder ? '↩ choose · ⇥ enter folder · esc back' : '/ to change the folder';
    where.title = mode === 'history' ? pk.project : node.cwd || '';
    const list = el.querySelector('.picker-list');
    const notice = el.querySelector('.picker-notice');
    notice.hidden = !pk.notice;
    notice.textContent = pk.notice || '';
    const scroll = list.scrollTop;
    let at;
    if (folder) {
      delete list.dataset.drawn;
      list.replaceChildren();
      drawFolders(el, node, list);
      at = 'folder:' + (pk.fsel || 0);
    } else {
      if (mode === 'history') askPast(pk.project);
      const rows = choices(node), on = selected(rows, pk);
      at = on?.key || '';
      pk.choice = at;
      // Session snapshots arrive while the user is pointing at a row. Keep the actual
      // buttons when their contents and selection match the previous drawing.
      const drawn = JSON.stringify([mode, at, rows, fieldValue(pk), mode === 'history' && pk.project in S.past]);
      if (list.dataset.drawn === drawn) return;
      list.dataset.drawn = drawn;
      list.replaceChildren(...rows.map((item) => drawChoice(el, node, item, on)));
      if (!rows.length) {
        const msg = document.createElement('div');
        msg.className = 'picker-empty';
        if (fieldValue(pk).trim()) msg.textContent = 'No matching sessions';
        else if (mode === 'history') msg.textContent = pk.project in S.past ? 'No past sessions in this project' : 'Loading history…';
        else msg.textContent = 'No live sessions';
        list.append(msg);
      }
    }
    if (list.dataset.at !== at) list.querySelector('.sel')?.scrollIntoView({ block: 'nearest' });
    else list.scrollTop = scroll;
    list.dataset.at = at;
  }

  return { render, refresh, focus };
})();
