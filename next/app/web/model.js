// umi-next web state and model: the one module that holds what the UI knows and every operation
// on it. Views read `Umi.state` and call `Umi.model` / `Umi.actions`; nothing else changes state.
// Plain script (no build step); everything hangs off `window.Umi`. Spec: next/DESIGN.md.
//
// - A session (agent or shell) lives in the daemon; a pane is a view onto at most one session, and
//   a session shows in at most one pane: opening one already on screen moves it.
// - ⌘W stops showing a pane; the session keeps running. Only Exit (palette) ends a session. A
//   session whose program ends by itself leaves its pane.
// - A pane shows a `view`: 'terminal' (a native Ghostty view) or 'picker' (drawn here; ⌘D).
// - The palette is the bottom panel; it takes height from the panes (terminals sit above the web
//   view), and the web view has the keys while it's open.
'use strict';
window.Umi = window.Umi || {};

Umi.state = {
  // Persisted in layout.json (native merges each pane's session in):
  //   {version, tabs:[{id, name?, root, focused}], activeTab, sidebar,
  //    meta: {sessions: {sid: {name?, snooze?: {since, until?, done?}}}}}
  layout: null,
  panes: {},        // paneId -> what native reports for the pane: {session, title, pwd, exitCode}
  live: {},         // sessionId -> the daemon's session + {folder, project, state, kind, agent?}
  past: { project: null, list: [] }, // resumable Claude/Codex sessions of a project
  ui: { panel: null, keys: 'terminal', editingTab: null }, // not persisted
  closed: {},       // paneId -> 'detach': panes closed since the last layout sent to native
  home: '',
  sessionMode: 'daemon',
};

Umi.model = (() => {
  const S = Umi.state;
  const uid = (p) => p + Math.random().toString(36).slice(2, 10);
  const now = () => Date.now() / 1000;

  // ---- tree ----
  const newPane = (extra = {}) => ({ type: 'pane', id: uid('p'), view: 'terminal', ...extra });
  const newTab = (pane) => { const p = pane || newPane(); return { id: uid('t'), root: p, focused: p.id }; };

  function panesOf(node) {
    if (!node) return [];
    return node.type === 'pane' ? [node] : [...panesOf(node.a), ...panesOf(node.b)];
  }
  const paneIds = (node) => panesOf(node).map((p) => p.id);
  function findPane(id) {
    for (const tab of S.layout.tabs) {
      const node = panesOf(tab.root).find((p) => p.id === id);
      if (node) return { tab, node };
    }
    return null;
  }
  const activeTab = () => S.layout.tabs.find((t) => t.id === S.layout.activeTab) || S.layout.tabs[0];
  const focusedPane = () => findPane(activeTab().focused)?.node;
  const sessionOf = (paneId) => S.panes[paneId]?.session || findPane(paneId)?.node.session;
  const paneOfSession = (sid) => Object.keys(S.panes).find((p) => S.panes[p].session === sid && findPane(p));

  function mapPane(node, id, fn) {
    if (node.type === 'pane') return node.id === id ? fn(node) : node;
    return { ...node, a: mapPane(node.a, id, fn), b: mapPane(node.b, id, fn) };
  }
  function removeFromTree(node, id) {
    if (node.type === 'pane') return node.id === id ? null : node;
    const a = removeFromTree(node.a, id), b = removeFromTree(node.b, id);
    if (!a) return b;
    if (!b) return a;
    return { ...node, a, b };
  }

  // ---- sessions ----
  const meta = (sid) => {
    S.layout.meta = S.layout.meta || { sessions: {} };
    return (S.layout.meta.sessions[sid] = S.layout.meta.sessions[sid] || {});
  };
  const base = (p) => (p || '').split('/').filter(Boolean).pop() || '~';
  function folderOf(paneId) {
    const sid = sessionOf(paneId);
    return S.panes[paneId]?.pwd || (sid && S.live[sid]?.folder) || findPane(paneId)?.node.cwd || S.home;
  }
  function projectOf(paneId) {
    const sid = sessionOf(paneId);
    return (sid && S.live[sid]?.project) || folderOf(paneId);
  }
  const currentProject = () => projectOf(activeTab().focused);
  function sessionName(sid) {
    const s = S.live[sid] || {};
    return S.layout.meta?.sessions?.[sid]?.name || s.name || `${base(s.folder)} · ${sid}`;
  }
  // A new session's default name: its folder and a number (DESIGN "Names at creation").
  function defaultName(folder) {
    const b = base(folder);
    const used = new Set(Object.keys(S.live).map(sessionName));
    for (let n = 1; ; n++) if (!used.has(`${b} ${n}`)) return `${b} ${n}`;
  }
  const isSnoozed = (sid) => { const z = S.layout.meta?.sessions?.[sid]?.snooze; return z && !z.done; };

  // What waits for Alejo, grouped by project, the current project first (DESIGN "Review"):
  // agent sessions waiting for input, and finished snoozes.
  function review() {
    const cur = currentProject();
    const groups = {};
    for (const s of Object.values(S.live)) {
      if (!s.alive || isSnoozed(s.id)) continue;
      const z = S.layout.meta?.sessions?.[s.id]?.snooze;
      const waiting = s.agent && s.state === 'waiting';
      if (!waiting && !(z && z.done)) continue;
      (groups[s.project] = groups[s.project] || []).push({ ...s, badge: !!(z && z.done) });
    }
    for (const g of Object.values(groups)) g.sort((a, b) => (b.agent?.ts || 0) - (a.agent?.ts || 0));
    return Object.keys(groups).sort((a, b) => (a === cur ? -1 : b === cur ? 1 : a.localeCompare(b)))
      .map((project) => ({ project, current: project === cur, items: groups[project] }));
  }

  // Snoozed sessions finish when their turn ends after the snooze or their time runs out.
  function updateSnoozes() {
    for (const [sid, m] of Object.entries(S.layout.meta?.sessions || {})) {
      const z = m.snooze;
      if (!z || z.done) continue;
      const s = S.live[sid];
      if (!s) { delete m.snooze; continue; }
      if ((z.until && now() >= z.until) || (s.state === 'waiting' && (s.agent?.ts || 0) > z.since)) z.done = true;
    }
  }

  // ---- layout operations ----
  function addTab(pane) {
    const cur = activeTab();
    const t = newTab(pane || newPane({ cwd: cur && folderOf(cur.focused) }));
    S.layout.tabs.splice(S.layout.tabs.indexOf(cur) + 1, 0, t);
    S.layout.activeTab = t.id;
    return t;
  }

  // Splits the focused pane; the new pane shows `view` ('picker' for ⌘D).
  function split(dir, view = 'terminal', extra = {}) {
    const tab = activeTab();
    const p = newPane({ view, cwd: folderOf(tab.focused), ...extra });
    if (view === 'picker') p.picker = { kind: 'claude', name: '', sel: 0, project: projectOf(tab.focused) };
    tab.root = mapPane(tab.root, tab.focused, (old) => ({ type: 'split', dir, ratio: 0.5, a: old, b: p }));
    tab.focused = p.id;
    return p;
  }

  // Takes the pane out of the layout; its session (if any) keeps running in the daemon.
  function removePane(id) {
    const found = findPane(id);
    if (!found) return;
    const { tab } = found;
    const folder = folderOf(id), project = projectOf(id);
    S.closed[id] = 'detach';
    const root = removeFromTree(tab.root, id);
    if (root) {
      tab.root = root;
      if (tab.focused === id) tab.focused = paneIds(root)[0];
      return;
    }
    const i = S.layout.tabs.indexOf(tab);
    S.layout.tabs.splice(i, 1);
    // The window always shows something: the last pane gone, a picker in its project takes its place.
    if (S.layout.tabs.length === 0) S.layout.tabs.push(newTab(newPane({ view: 'picker', cwd: folder, picker: { kind: 'claude', name: '', sel: 0, project } })));
    if (S.layout.activeTab === tab.id) S.layout.activeTab = S.layout.tabs[Math.min(i, S.layout.tabs.length - 1)].id;
  }

  // Shows session `sid` in pane `paneId`. A pane already showing it gives it up (it moves).
  function openSession(sid, paneId) {
    const shown = paneOfSession(sid);
    if (shown === paneId) return focusPane(paneId);
    const found = findPane(paneId);
    if (!found) return;
    // A pane is keyed to its terminal: give the target a fresh id so native starts a new view.
    const fresh = newPane({ session: sid, attach: sid, cwd: S.live[sid]?.folder });
    found.tab.root = mapPane(found.tab.root, paneId, () => fresh);
    if (found.tab.focused === paneId) found.tab.focused = fresh.id;
    S.closed[paneId] = 'detach';
    if (shown) removePane(shown);
    focusPane(fresh.id);
    const m = S.layout.meta?.sessions?.[sid];
    if (m && m.snooze) delete m.snooze; // looked at
  }

  // Shows a session wherever is best: its pane if on screen, else a split of the focused pane.
  function showSession(sid) {
    const shown = paneOfSession(sid);
    if (shown) return focusPane(shown);
    const p = split('row', 'picker');
    openSession(sid, p.id);
  }

  // Starts a new session in pane `paneId` (a picker): kind claude|codex|shell, or a resume command.
  function startSession(paneId, { cmd = null, name = '', cwd } = {}) {
    const found = findPane(paneId);
    if (!found) return;
    const folder = cwd || found.node.cwd || S.home;
    const fresh = newPane({ cwd: folder, start: { cmd, name: name || defaultName(folder), cwd: folder } });
    found.tab.root = mapPane(found.tab.root, paneId, () => fresh);
    found.tab.focused = fresh.id;
  }

  function focusPane(id) {
    const found = findPane(id);
    if (!found) return;
    S.layout.activeTab = found.tab.id;
    found.tab.focused = id;
  }

  function selectTab(index) {
    const t = index === 9 ? S.layout.tabs[S.layout.tabs.length - 1] : S.layout.tabs[index - 1];
    if (t) S.layout.activeTab = t.id;
  }

  function stepTab(d) {
    const n = S.layout.tabs.length;
    S.layout.activeTab = S.layout.tabs[(S.layout.tabs.indexOf(activeTab()) + d + n) % n].id;
  }

  function focusDir(dir, rects) {
    const tab = activeTab();
    const from = rects[tab.focused];
    if (!from) return;
    const cx = from.x + from.w / 2, cy = from.y + from.h / 2;
    let best = null, bestD = Infinity;
    for (const [id, r] of Object.entries(rects)) {
      if (id === tab.focused) continue;
      const x = r.x + r.w / 2, y = r.y + r.h / 2;
      const ok = { left: x < cx - 1, right: x > cx + 1, up: y < cy - 1, down: y > cy + 1 }[dir];
      const dist = Math.hypot(x - cx, y - cy);
      if (ok && dist < bestD) { best = id; bestD = dist; }
    }
    if (best) tab.focused = best;
  }

  // Moves the focused pane into a tab of its own (its terminal stays).
  function moveToNewTab() {
    const tab = activeTab();
    const node = focusedPane();
    if (!node || paneIds(tab.root).length < 2) return;
    tab.root = removeFromTree(tab.root, node.id);
    tab.focused = paneIds(tab.root)[0];
    addTab(node);
  }

  function snooze(sid, seconds) {
    meta(sid).snooze = { since: now(), until: seconds ? now() + seconds : null, done: false };
    const p = paneOfSession(sid);
    if (p) removePane(p);
  }

  function rename(sid, name) { if (name) meta(sid).name = name; else delete meta(sid).name; }

  function openPanel(name, data = {}) { S.ui.panel = { name, ...data }; }
  function closePanel() { S.ui.panel = null; }

  // ---- from native ----
  function load(msg) {
    S.home = msg.home || '';
    S.sessionMode = msg.sessionMode || 'daemon';
    S.commands = msg.commands || {};
    S.panes = msg.panes || {};
    const l = msg.layout;
    S.layout = l && l.tabs && l.tabs.length ? l : { version: 1, tabs: [newTab(newPane({ cwd: S.home }))], sidebar: true };
    S.layout.meta = S.layout.meta || { sessions: {} };
    for (const p of S.layout.tabs.flatMap((t) => panesOf(t.root))) p.view = p.view || 'terminal';
    if (!S.layout.tabs.some((t) => t.id === S.layout.activeTab)) S.layout.activeTab = S.layout.tabs[0].id;
  }

  function paneInfo(id, info) {
    S.panes[id] = info;
    const found = findPane(id);
    if (found && info.session) {
      found.node.session = info.session;
      delete found.node.start;
    }
  }

  // Returns true when a snooze finished (the layout's meta changed and should be saved).
  function sessions(list) {
    const live = {};
    for (const s of list) live[s.id] = s;
    S.live = live;
    const before = JSON.stringify(S.layout.meta || {});
    updateSnoozes();
    return JSON.stringify(S.layout.meta || {}) !== before;
  }

  return {
    newPane, panesOf, paneIds, findPane, activeTab, focusedPane, sessionOf, paneOfSession,
    folderOf, projectOf, currentProject, sessionName, defaultName, isSnoozed, review,
    addTab, split, removePane, openSession, showSession, startSession, focusPane,
    selectTab, stepTab, focusDir, moveToNewTab, snooze, rename, openPanel, closePanel,
    load, paneInfo, sessions,
  };
})();

// Named actions: what native shortcuts, sidebar buttons and the palette run. Each only changes
// Umi.state; Umi.app.run saves, draws and reports after it.
Umi.actions = {
  newTab: () => { const t = Umi.model.addTab(); Umi.state.ui.editingTab = t.id; },
  splitRight: () => Umi.model.split('row', 'picker'),
  splitDown: () => Umi.model.split('column', 'picker'),
  closePane: () => Umi.model.removePane(Umi.model.activeTab().focused),
  selectTab: ({ index }) => Umi.model.selectTab(index),
  nextTab: () => Umi.model.stepTab(1),
  prevTab: () => Umi.model.stepTab(-1),
  toggleSidebar: () => { Umi.state.layout.sidebar = Umi.state.layout.sidebar === false; },
  focusDir: ({ dir }) => Umi.model.focusDir(dir, Umi.views.panes.slotRects()),
  togglePalette: () => {
    if (Umi.state.ui.panel?.name === 'palette') Umi.model.closePanel();
    else Umi.model.openPanel('palette', { mode: 'commands', query: '' });
  },
  // "Next waiting": the first Review item that isn't the focused pane's session.
  nextWaiting: () => {
    const cur = Umi.model.sessionOf(Umi.model.activeTab().focused);
    const item = Umi.model.review().flatMap((g) => g.items).find((s) => s.id !== cur);
    if (item) Umi.model.showSession(item.id);
  },
  switchSession: () => {
    const M = Umi.model, p = M.focusedPane();
    if (!p) return;
    const fresh = M.newPane({ view: 'picker', cwd: M.folderOf(p.id), picker: { kind: 'claude', name: '', sel: 0, project: M.projectOf(p.id) } });
    const found = M.findPane(p.id);
    found.tab.root = (function map(n) { return n.type === 'pane' ? (n.id === p.id ? fresh : n) : { ...n, a: map(n.a), b: map(n.b) }; })(found.tab.root);
    found.tab.focused = fresh.id;
    Umi.state.closed[p.id] = 'detach';
  },
  exitSession: () => {
    const sid = Umi.model.sessionOf(Umi.model.activeTab().focused);
    if (sid) Umi.bridge.post({ type: 'exitSession', session: sid });
  },
  restartSession: () => {
    const M = Umi.model, p = M.focusedPane();
    const sid = p && M.sessionOf(p.id);
    if (!sid) return;
    const s = Umi.state.live[sid] || {};
    const agentSession = s.agent?.agentSession;
    const cmd = s.kind === 'claude' && agentSession ? `claude --resume ${agentSession}`
      : s.kind === 'codex' && agentSession ? `codex resume ${agentSession}` : (s.command || null);
    Umi.bridge.post({ type: 'exitSession', session: sid });
    const found = M.findPane(p.id);
    const fresh = M.newPane({ cwd: M.folderOf(p.id), start: { cmd, name: M.sessionName(sid), cwd: M.folderOf(p.id) } });
    found.tab.root = (function map(n) { return n.type === 'pane' ? (n.id === p.id ? fresh : n) : { ...n, a: map(n.a), b: map(n.b) }; })(found.tab.root);
    found.tab.focused = fresh.id;
    Umi.state.closed[p.id] = 'detach';
  },
  moveToNewTab: () => Umi.model.moveToNewTab(),
  reloadWeb: () => Umi.bridge.post({ type: 'reload' }),
};
