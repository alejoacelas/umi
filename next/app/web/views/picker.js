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
  const redraw = () => Umi.views.panes.refreshPickers();
  // Projects whose past sessions were asked for since the page loaded (S.past holds the answers).
  const askedPast = new Set();
  function askPast(project) {
    if (!project || askedPast.has(project)) return;
    askedPast.add(project);
    Umi.bridge.post({ type: 'pastSessions', project });
  }

  // Results are cached for this visit to the folder chooser. The native service checks Git
  // worktree metadata and resolves symlinks before returning any selectable paths.
  let dirs = new Map();
  let known = null;
  function subdirs(path, hidden) {
    const key = (hidden ? '.' : '') + path;
    if (!dirs.has(key)) {
      const cache = dirs;
      cache.set(key, null);
      Umi.bridge.request('pickerFolders', { path, hidden }).then(
        (result) => cache.set(key, result),
        (error) => cache.set(key, { error: error.message }),
      ).then(() => { if (dirs === cache) redraw(); });
    }
    return dirs.get(key);
  }
  // proj's list (~/best's projects, areas and orgs, newest first, the current area first), asked
  // for once per visit to the folder chooser.
  function knownFolders(cwd) {
    if (!known) {
      const request = known = { paths: [] };
      Umi.bridge.request('pickerFolders', { projects: true, cwd }).then(
        ({ paths }) => { request.paths = paths; },
        (error) => { request.error = error.message; },
      ).then(() => { if (known === request) redraw(); });
    }
    return known;
  }
  // Where `proj NAME` puts a new project: a bare name in ~/best/projects, a name typed after a folder
  // inside ~/best (Tab fills one in) in that folder. Elsewhere nothing is created.
  const best = () => S.home + '/best';
  function createRow(dir, name, names) {
    name = name.trim();
    if (!name || name.startsWith('.')) return null;
    const rel = dir === null ? '' : dir.startsWith(best() + '/') ? dir.slice(best().length + 1) : null;
    if (rel === null) return null;
    const low = name.toLowerCase();
    return { create: rel ? rel + '/' + name : name, where: rel ? '~/best/' + rel : '~/best/projects',
      label: name, first: !names.some((n) => n.toLowerCase().includes(low)) };
  }
  const withCreate = (rows, c) => (!c ? rows : c.first ? [c, ...rows] : [...rows, c]);

  // The rows of the folder search for what is typed: [{path, use?}] and whether the folder exists.
  function folderRows(node) {
    const q = node.picker.query || '';
    if (/^[~/.]/.test(q) || q.includes('/')) {
      const typed = q === '~' ? '~/' : q;
      const cut = typed.lastIndexOf('/') + 1;
      const dir = Umi.fs.resolve(typed.slice(0, cut) || '.', node.cwd || S.home);
      const seg = typed.slice(cut);
      const result = subdirs(dir, seg.startsWith('.'));
      if (!result || result.excluded) return { rows: [] };
      if (result.error) return { rows: [], error: result.error };
      const names = result.names;
      const rows = (seg ? Umi.fs.fuzzy(seg, names, 200).map((r) => r.path) : names).map((n) => ({ path: (dir === '/' ? '' : dir) + '/' + n }));
      if (!seg) return { rows: [{ path: dir, use: true }, ...rows] };
      return { rows: withCreate(rows, dir !== best() && createRow(dir, seg, names)) };
    }
    const cwd = node.cwd || S.home;
    const { paths, error } = knownFolders(cwd);
    if (!q.trim()) {
      const otherFolders = paths.filter((path) => path !== cwd).map((path) => ({ path }));
      return { rows: [{ path: cwd, use: true }, ...otherFolders], error };
    }
    if (error) return { rows: [], error };
    const rel = paths.map((p) => p.slice(best().length + 1));
    const rank = new Map(rel.map((p, i) => [p, i]));
    const hits = Umi.fs.fuzzy(q, rel, rel.length).sort((a, b) => b.score - a.score || rank.get(a.path) - rank.get(b.path));
    const rows = hits.map((r) => ({ path: paths[rank.get(r.path)] }));
    return { rows: withCreate(rows, createRow(null, q, paths.map(base))) };
  }

  function changePage(el, node, mode) {
    const pk = node.picker;
    if ((!pk.mode || pk.mode === 'switcher') && (mode === 'new' || mode === 'folder')) pk.name = pk.search || '';
    if (mode === 'switcher') delete pk.folderChosen;
    if (mode === 'history') askedPast.delete(pk.project);
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
    }
    pk.query = '';
    pk.fsel = 0;
    delete pk.creating;
    delete pk.createError;
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
      pk.folderChosen = true;
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
      if (!e.shiftKey) { if (sel?.path) type(tilde(sel.path).replace(/\/$/, '') + '/'); return; }
      const use = rows.find((r) => r.use);
      type(tilde(parent(use ? use.path : node.cwd || S.home)).replace(/\/$/, '') + '/');
    } else if (e.key === 'ArrowDown' || e.key === 'ArrowUp') {
      e.preventDefault();
      pk.fsel = Math.max(0, Math.min(rows.length - 1, (pk.fsel || 0) + (e.key === 'ArrowDown' ? 1 : -1)));
      refresh(el, node);
    } else if (e.key === 'Enter') {
      e.preventDefault();
      // ⌘Enter creates the typed name even when folders match it.
      const make = e.metaKey ? rows.find((r) => r.create) : sel?.create && sel;
      if (make) createProject(el, node, make);
      else if (sel) chooseFolder(el, node, sel.path);
    } else if (e.key === 'Escape' || (e.key === 'Backspace' && !input.value)) {
      e.preventDefault();
      folderMode(el, node, false);
    }
  }

  // proj makes the folder (its GitHub repo follows in the background); the session starts there.
  function createProject(el, node, row) {
    const pk = node.picker;
    if (pk.creating) return;
    pk.creating = row.create;
    redraw();
    Umi.bridge.request('createProject', { name: row.create }).then(
      ({ path }) => { delete pk.creating; delete pk.createError; chooseFolder(el, node, path); },
      (error) => { delete pk.creating; pk.createError = error.message; redraw(); },
    );
  }

  function drawFolders(el, node, list) {
    const pk = node.picker;
    const { rows, error } = folderRows(node);
    if (!rows.length || error || pk.creating || pk.createError) {
      const none = document.createElement('div');
      none.className = 'picker-section';
      none.textContent = pk.creating ? `Creating ${pk.creating}…` : pk.createError || error || 'No folder matches';
      list.append(none);
    }
    rows.forEach((r, i) => {
      const row = document.createElement('div');
      row.className = 'picker-row' + (i === (pk.fsel || 0) ? ' sel' : '');
      if (r.create) {
        row.title = 'proj ' + r.create;
        row.innerHTML = '<b></b><span class="dim"></span>';
        row.querySelector('b').textContent = 'New project: ' + r.label;
        row.querySelector('.dim').textContent = 'in ' + r.where + (r.first ? '' : ' · ⌘↩');
        row.addEventListener('mousedown', (e) => { e.preventDefault(); createProject(el, node, r); });
        list.append(row);
        return;
      }
      row.title = r.path;
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
    if (pk.mode === 'history') {
      const q = (pk.historyQuery || '').trim().toLowerCase();
      return (S.past[pk.project] || []).filter((p) => p.title.toLowerCase().includes(q))
        .map((p) => ({ key: 'past:' + p.kind + ':' + p.id, name: p.title, detail: ago(p.mtime), icon: p.kind, past: p }));
    }
    const rows = [];
    const name = fieldValue(pk).trim();
    if (pk.mode === 'new' || name) {
      const chooseFolder = !!name && !pk.folderChosen;
      const automatic = !name && (pk.kind === 'claude' || pk.kind === 'codex');
      const launchName = name || (automatic ? '' : M.defaultName(node.cwd));
      const detail = automatic ? `${LABEL[pk.kind]} will name this session` : name ? '' : launchName;
      rows.push({ key: 'new', name: chooseFolder ? `Choose folder for “${name}”` : name ? `Create “${name}”` : 'New session',
        detail, icon: pk.kind, chooseFolder, launchName });
    }
    if (pk.mode === 'new') return rows;
    const found = M.switcherGroups(pk.search);
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
        rows.push({ key: 'session:' + s.id, session: s.id, icon: s.kind, group, name, detail: base(project), tip });
      }
    }
    return rows;
  }

  function activate(el, node, item) {
    if (!item) return;
    const pk = node.picker, cmds = S.commands || {};
    if (item.chooseFolder) return folderMode(el, node, true);
    if (item.disclosure) {
      pk.expanded ??= {};
      pk.expanded[item.disclosure] = !pk.expanded[item.disclosure];
      pk.choice = item.key;
      refresh(el, node);
      return;
    }
    Umi.app.update(() => {
      if (item.key === 'new') {
        const named = item.launchName && S.namedCommands?.[pk.kind];
        const cmd = pk.kind === 'shell' ? null : named || cmds[pk.kind] || pk.kind;
        M.startSession(node.id, { cmd, name: item.launchName, cwd: node.cwd });
      } else if (item.session) {
        pk.notice = M.switchFromPicker(item.session, node.id);
      } else if (item.past) {
        const p = item.past;
        const resume = p.kind === 'codex' ? ' resume ' : ' --resume ';
        M.startSession(node.id, { cmd: (cmds[p.kind] || p.kind) + resume + Umi.views.modes.shellQuote(p.id), name: p.title, cwd: p.cwd });
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
    const switcher = !pk.mode || pk.mode === 'switcher';
    if (e.key === 'Tab' && e.target === input && (pk.mode === 'new' || (switcher && pk.search?.trim()))) {
      e.preventDefault();
      pk.kind = KINDS[(KINDS.indexOf(pk.kind) + (e.shiftKey ? KINDS.length - 1 : 1)) % KINDS.length];
      pk.choice = 'new';
      return refresh(el, node);
    }
    if (e.key === 'Tab' && switcher) {
      const order = [input, el.querySelector('[data-page=new]'), el.querySelector('.picker-project'),
        ...el.querySelectorAll('.picker-kinds button'), el.querySelector('[data-page=history]')];
      const i = order.indexOf(e.target);
      if (i >= 0) {
        e.preventDefault();
        order[(i + (e.shiftKey ? -1 : 1) + order.length) % order.length].focus();
      }
      return;
    }
    if (e.target !== input) return;
    // After a typed name, / keeps it as the new session's name and chooses its folder.
    if (e.key === '/' && (!input.value || switcher || pk.mode === 'new')) {
      e.preventDefault();
      return folderMode(el, node, true);
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
      </div>
      <div class="picker-context">
        <button type="button" class="picker-project"><b></b><span></span></button>
        <div class="picker-kinds" role="group" aria-label="New session type">${KINDS.map((k) => `<button type="button" data-kind="${k}" title="${LABEL[k]}" aria-label="${LABEL[k]}"></button>`).join('')}</div>
      </div>
      <div role="status" class="picker-notice" hidden></div>
      <div class="picker-list"></div>
      <button type="button" data-page="history" class="picker-nav picker-history">History</button>`;
    el.querySelectorAll('[data-kind]').forEach((k) => k.prepend(Umi.icons.agent(k.dataset.kind)));
    const input = el.querySelector('.picker-name');
    input.value = fieldValue(pk);
    input.addEventListener('input', () => {
      if (pk.mode === 'folder') { pk.query = input.value; pk.fsel = 0; delete pk.createError; }
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
        if (pk.mode === 'new' || pk.search?.trim()) pk.choice = 'new';
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
        row.dataset.kind = item.icon;
        row.title = [item.name, item.tip].filter(Boolean).join('\n');
      }
      if (item.past) row.dataset.past = item.past.id;
      if (item.key === 'new') row.dataset.action = 'new';
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
    el.querySelector('.picker-kinds').hidden = !(switcher || mode === 'new');
    el.querySelectorAll('.picker-kinds [data-kind]').forEach((k) => {
      k.classList.toggle('on', k.dataset.kind === pk.kind);
      k.setAttribute('aria-pressed', String(k.dataset.kind === pk.kind));
    });
    const input = el.querySelector('.picker-name');
    input.placeholder = { switcher: 'Find or name a session…', new: 'Session name', history: 'Find a past session…', folder: 'Find a folder or enter a path…' }[mode];
    input.setAttribute('aria-label', input.placeholder);
    const where = el.querySelector('.picker-project');
    const cwd = node.cwd || S.home, project = pk.project || cwd;
    const subfolder = cwd === project ? '' : cwd.startsWith(project + '/') ? cwd.slice(project.length) : tilde(cwd);
    where.querySelector('b').textContent = folder ? tilde(cwd) : base(tilde(project));
    where.querySelector('span').textContent = folder ? '↩ choose · ⇥ enter folder · esc back'
      : mode === 'history' ? '/ to change the folder' : subfolder;
    where.title = mode === 'history' ? project : cwd;
    where.setAttribute('aria-label', `Change folder (${where.title})`);
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
      const drawn = JSON.stringify([mode, at, rows, fieldValue(pk), mode === 'history' && pk.project in S.past, pk.creating, pk.createError]);
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
