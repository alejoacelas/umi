// umi-next web state and model: the one module that holds what the UI knows and every operation
// on it. Views read `Umi.state` and call `Umi.model` / `Umi.actions`; nothing else changes state.
// Plain script (no build step); everything hangs off `window.Umi`. Spec: next/DESIGN.md.
//
// - A session (agent or shell) lives in the daemon; a pane is a view onto at most one session, and
//   a session shows in at most one pane: opening one already on screen moves it.
// - ⌘W stops showing a pane; the session keeps running. Only Exit (palette) ends a session. A
//   session whose program ends by itself leaves its pane.
// - A pane shows a `view`: 'terminal' (a native Ghostty view) or 'picker' (drawn here; ⌘D).
// - The palette is the bottom panel; it lies over the bottom of the panes, which keep their size
//   (native clips the terminals it covers), and the web view has the keys while it's open.
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
  // The tabs in the sidebar's list (pinned first), without the archived ones (SPEC AR-3).
  const listedTabs = () => S.layout.tabs.filter((t) => !t.archived);
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
    return S.panes[paneId]?.project || (sid && S.live[sid]?.project) || folderOf(paneId);
  }

  // Where a session stands for Alejo (DESIGN "Detached sessions that finish done stay out of the way"):
  //   'needs'    waiting for him: a question or permission dialog, or a finished turn whose reply
  //              doesn't say done (waiting on you, in progress, no readable status line);
  //   'finished' its turn ended and its reply says done (or done, pending verification);
  //   'busy'     a turn or program is running;
  //   'idle'     a shell at its prompt, or an agent that hasn't had a turn yet.
  function standing(s) {
    if (!s) return 'idle';
    if (s.state !== 'waiting') return 'busy';
    if (!s.agent) return 'idle';
    const ev = s.agent.event;
    if (ev === 'PermissionRequest' || ev === 'Notification' || ev === 'Interrupt') return 'needs';
    if (ev === 'Stop' || ev === 'StopFailure') return Umi.status.isDone(Umi.status.parseStatus(s.agent.reply)) ? 'finished' : 'needs';
    return 'idle';
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
  // Sessions the user started (picker, new tab, resume, restart); a session with no record (an
  // older daemon) counts as his. Session lists leave out those agents and scripts start.
  const userStarted = (s) => !s.by || s.by === 'user';
  const isSnoozed = (sid) => { const z = S.layout.meta?.sessions?.[sid]?.snooze; return z && !z.done; };
  // On the docket (native keeps the mark: <state>/docket.json): {state: pending|on|failed, error?}.
  const docketOf = (sid) => S.live[sid]?.docket || null;

  // What waits for Alejo, grouped by project, the current project first (DESIGN "Review"):
  // agent sessions waiting for input, and finished snoozes.
  function review() {
    const cur = currentProject();
    const groups = {};
    for (const s of Object.values(S.live)) {
      if ((!s.alive && !s.docket) || !userStarted(s)) continue;
      if (isSnoozed(s.id)) continue;
      // Docketed sessions never show here, except when the docket hook failed (no silent loss).
      if (s.docket) {
        if (s.docket.state === 'failed') (groups[s.project] = groups[s.project] || []).push({ ...s, docketFailed: true });
        continue;
      }
      const z = S.layout.meta?.sessions?.[s.id]?.snooze;
      // A finished snooze shows even if it says done: snoozing asked to be told.
      if (standing(s) !== 'needs' && !(z && z.done)) continue;
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
  // A new tab goes right after the current one, below the pinned tabs (SPEC S-7).
  function addTab(pane) {
    const cur = activeTab();
    const t = newTab(pane || newPane({ cwd: cur && folderOf(cur.focused) }));
    const pinned = S.layout.tabs.filter((x) => x.pinned).length;
    S.layout.tabs.splice(cur && !cur.archived ? Math.max(S.layout.tabs.indexOf(cur) + 1, pinned) : pinned, 0, t);
    S.layout.activeTab = t.id;
    return t;
  }

  // ---- sharing space (SPEC L-19, as Warp) ----
  // A run is a chain of splits in one direction: the panes (or cross-direction subtrees) of one row
  // or column. Splitting along a row gives the new pane 1/(N+1) of it and keeps the others'
  // proportions; closing a pane shares its space among the rest in proportion to their sizes.
  const firstLeaf = (n) => (n.type === 'pane' ? n.id : firstLeaf(n.a));
  function runMembers(n, dir, f = 1) {
    if (n.type !== 'split' || n.dir !== dir) return [{ node: n, f }];
    return [...runMembers(n.a, dir, f * n.ratio), ...runMembers(n.b, dir, f * (1 - n.ratio))];
  }
  function setRun(n, dir, fr) {
    if (n.type !== 'split' || n.dir !== dir) return;
    const k = runMembers(n.a, dir).length;
    const fa = fr.slice(0, k).reduce((x, y) => x + y, 0), fb = fr.slice(k).reduce((x, y) => x + y, 0);
    n.ratio = fa + fb > 0 ? fa / (fa + fb) : 0.5;
    setRun(n.a, dir, fr.slice(0, k));
    setRun(n.b, dir, fr.slice(k));
  }
  function pathTo(n, leafId, path = []) {
    path.push(n);
    if (n.type === 'pane') return n.id === leafId ? path : null;
    return pathTo(n.a, leafId, [...path]) || pathTo(n.b, leafId, [...path]);
  }
  // The top of the run holding path[i] (path: root … node), with its depth.
  function runTop(path, i, dir) {
    let d = i;
    while (d > 0 && path[d - 1].type === 'split' && path[d - 1].dir === dir) d--;
    return d;
  }
  // After a split (old | new): the new pane gets 1/(N+1) of its run; the others keep their proportions.
  function shareSplit(tab, newId) {
    const path = pathTo(tab.root, newId);
    if (!path || path.length < 2) return;
    const sp = path[path.length - 2], dir = sp.dir;
    const top = path[runTop(path, path.length - 2, dir)];
    const members = runMembers(top, dir);
    const n = members.length - 1; // members before the split
    // The old pane held both halves of the new split: it keeps its whole share, scaled like the rest.
    const fr = members.map((m) => (m.node === sp.b ? 1 / (n + 1) : (m.node === sp.a ? 2 * m.f : m.f) * (n / (n + 1))));
    setRun(top, dir, fr);
  }
  // Removes pane `id` from `tab`'s tree, its run's other members sharing its space in proportion.
  function removeShared(tab, id) {
    const path = pathTo(tab.root, id);
    if (!path || path.length < 2) return removeFromTree(tab.root, id);
    const parent = path[path.length - 2], dir = parent.dir;
    const d = runTop(path, path.length - 2, dir);
    const before = runMembers(path[d], dir).filter((m) => m.node.id !== id);
    const total = before.reduce((x, m) => x + m.f, 0) || 1;
    const share = new Map(before.map((m) => [firstLeaf(m.node), m.f / total]));
    const root = removeFromTree(tab.root, id);
    if (!root || !before.length) return root;
    const after = pathTo(root, firstLeaf(before[0].node));
    const top = after && after[d];
    if (top && top.type === 'split' && top.dir === dir) {
      setRun(top, dir, runMembers(top, dir).map((m) => share.get(firstLeaf(m.node)) ?? 1 / before.length));
    }
    return root;
  }

  // Splits the focused pane; the new pane shows `view` ('picker' for ⌘D).
  function split(dir, view = 'terminal', extra = {}) {
    const tab = activeTab();
    delete tab.zoomed;
    const p = newPane({ view, cwd: folderOf(tab.focused), ...extra });
    if (view === 'picker') p.picker = { kind: 'claude', name: '', sel: 0, project: projectOf(tab.focused) };
    tab.root = mapPane(tab.root, tab.focused, (old) => ({ type: 'split', dir, ratio: 0.5, a: old, b: p }));
    shareSplit(tab, p.id);
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
    if (tab.zoomed === id) delete tab.zoomed;
    const root = removeShared(tab, id);
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
    unhide(sid);
    // A pane is keyed to its terminal: give the target a fresh id so native starts a new view.
    const fresh = newPane({ session: sid, attach: sid, cwd: S.live[sid]?.folder });
    found.tab.root = mapPane(found.tab.root, paneId, () => fresh);
    if (found.tab.focused === paneId) found.tab.focused = fresh.id;
    S.closed[paneId] = 'detach';
    if (shown) removePane(shown);
    focusPane(fresh.id);
    const m = S.layout.meta?.sessions?.[sid];
    if (m && m.snooze) delete m.snooze; // looked at
    undocket(sid);
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

  // Focusing another pane of a zoomed tab unzooms it (Ghostty's and Warp's rule).
  function focusPane(id) {
    const found = findPane(id);
    if (!found) return;
    S.layout.activeTab = found.tab.id;
    found.tab.focused = id;
    if (found.tab.zoomed && found.tab.zoomed !== id) delete found.tab.zoomed;
  }

  // ⌘1–⌘8, ⌘9 (last), ⇧⌘[ ⇧⌘] and ⌃Tab go through the listed tabs, skipping archived ones (AR-3).
  function selectTab(index) {
    const list = listedTabs();
    const t = index === 9 ? list[list.length - 1] : list[index - 1];
    if (t) S.layout.activeTab = t.id;
  }

  function stepTab(d) {
    const list = listedTabs(), n = list.length;
    if (!n) return;
    const i = list.indexOf(activeTab());
    // From an archived tab, ⇧⌘] goes to the first listed tab and ⇧⌘[ to the last.
    S.layout.activeTab = list[i < 0 ? (d > 0 ? 0 : n - 1) : (i + d + n) % n].id;
  }

  // ---- the hidden-pane strip (SPEC H-5; DESIGN "Hidden-pane strip") ----
  // A tab remembers the sessions ⌘W hid from it (`tab.hidden`, session ids, in the order hidden).
  // Exit, or the session showing anywhere, takes it off the list.
  function hide(paneId) {
    const found = findPane(paneId);
    if (!found) return;
    const sid = found.node.view === 'terminal' ? sessionOf(paneId) : null;
    if (sid) {
      found.tab.hidden = (found.tab.hidden || []).filter((x) => x !== sid);
      found.tab.hidden.push(sid);
    }
    removePane(paneId);
  }
  function unhide(sid) {
    for (const t of S.layout.tabs) {
      if (!t.hidden) continue;
      t.hidden = t.hidden.filter((x) => x !== sid);
      if (!t.hidden.length) delete t.hidden;
    }
  }
  // The sessions a tab's strip shows as hidden: still running, not on the docket, on show nowhere.
  const hiddenOf = (tab) => (tab.hidden || []).filter((sid) => S.live[sid]?.alive !== false && !S.live[sid]?.docket && !paneOfSession(sid));
  // The number of panes in the top row of `node`, for an equal share on joining it.
  const rowWeight = (n) => (n.type === 'split' && n.dir === 'row' ? rowWeight(n.a) + rowWeight(n.b) : 1);
  // Adds `pane` at the right end of the tab, as a member of its top row with an equal share.
  function appendPane(tab, pane) {
    delete tab.zoomed;
    const w = rowWeight(tab.root);
    tab.root = { type: 'split', dir: 'row', ratio: w / (w + 1), a: tab.root, b: pane };
    tab.focused = pane.id;
    S.layout.activeTab = tab.id;
  }
  // Shows hidden session `sid` again at the right end of the current tab, focused.
  function showHidden(sid, tab = activeTab()) {
    const shown = paneOfSession(sid);
    unhide(sid);
    if (shown) return focusPane(shown);
    if (!S.live[sid] || S.live[sid].alive === false) return;
    appendPane(tab, newPane({ session: sid, attach: sid, cwd: S.live[sid]?.folder }));
    const m = S.layout.meta?.sessions?.[sid];
    if (m && m.snooze) delete m.snooze;
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

  // Sends a session to the docket: its pane stops showing it (like ⌘W) and native marks it.
  function docket(sid) {
    if (!sid) return;
    const m = S.layout.meta?.sessions?.[sid];
    if (m) delete m.snooze;
    Umi.bridge.post({ type: 'docket', session: sid, name: sessionName(sid) });
    if (S.live[sid]) S.live[sid].docket = { state: 'pending' };
    const p = paneOfSession(sid);
    if (p) removePane(p);
  }

  function undocket(sid) {
    if (!docketOf(sid)) return;
    Umi.bridge.post({ type: 'undocket', session: sid });
    delete S.live[sid].docket;
  }

  function rename(sid, name) { if (name) meta(sid).name = name; else delete meta(sid).name; }

  function openPanel(name, data = {}) { S.ui.panel = { name, ...data }; }
  function closePanel() { S.ui.panel = null; }

  // ---- from native ----
  function load(msg) {
    S.home = msg.home || '';
    S.sessionMode = msg.sessionMode || 'daemon';
    S.commands = msg.commands || {};
    S.fontBase = msg.fontBase || 13;
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
    const before = JSON.stringify([S.layout.meta || {}, S.layout.tabs.map((t) => t.hidden)]);
    updateSnoozes();
    // An ended session leaves the strips that listed it.
    for (const t of S.layout.tabs) {
      if (!t.hidden) continue;
      t.hidden = t.hidden.filter((sid) => live[sid] && live[sid].alive !== false);
      if (!t.hidden.length) delete t.hidden;
    }
    return JSON.stringify([S.layout.meta || {}, S.layout.tabs.map((t) => t.hidden)]) !== before;
  }

  return {
    newPane, newTab, panesOf, paneIds, findPane, activeTab, listedTabs, focusedPane, sessionOf, paneOfSession,
    mapPane, removeFromTree, hide, unhide, hiddenOf, appendPane, showHidden, rowWeight,
    folderOf, projectOf, currentProject, standing, sessionName, defaultName, userStarted, isSnoozed, review,
    addTab, split, removePane, openSession, showSession, startSession, focusPane,
    selectTab, stepTab, focusDir, moveToNewTab, snooze, rename, docket, undocket, docketOf, openPanel, closePanel,
    load, paneInfo, sessions,
  };
})();

// Named actions: what native shortcuts, sidebar buttons and the palette run. Each only changes
// Umi.state; Umi.app.run saves, draws and reports after it.
Umi.actions = {
  newTab: () => { const t = Umi.model.addTab(); Umi.state.ui.editingTab = t.id; },
  splitRight: () => Umi.model.split('row', 'picker'),
  splitDown: () => Umi.model.split('column', 'picker'),
  // ⌘W: the pane stops showing; its session keeps running and gets a chip in the strip. A file pane
  // with unsaved edits asks first (views/file.js); it has no session to keep.
  closePane: () => { const id = Umi.model.activeTab().focused; if (!Umi.views.file?.askClose(id)) Umi.model.hide(id); },
  showHidden: ({ session }) => Umi.model.showHidden(session),
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
    const cmds = Umi.state.commands || {};
    const cmd = s.kind === 'claude' && agentSession ? `${cmds.claude || 'claude'} --resume ${agentSession}`
      : s.kind === 'codex' && agentSession ? `${cmds.codex || 'codex'} resume ${agentSession}` : (s.command || null);
    Umi.bridge.post({ type: 'exitSession', session: sid });
    const found = M.findPane(p.id);
    const fresh = M.newPane({ cwd: M.folderOf(p.id), start: { cmd, name: M.sessionName(sid), cwd: M.folderOf(p.id) } });
    found.tab.root = (function map(n) { return n.type === 'pane' ? (n.id === p.id ? fresh : n) : { ...n, a: map(n.a), b: map(n.b) }; })(found.tab.root);
    found.tab.focused = fresh.id;
    Umi.state.closed[p.id] = 'detach';
  },
  moveToNewTab: () => Umi.model.moveToNewTab(),
  // ⌘[ / ⌘]: the previous or next pane of the tab, in layout order, wrapping (SPEC H-6, without
  // hidden panes).
  stepPane: ({ d }) => {
    const M = Umi.model, tab = M.activeTab(), ids = M.paneIds(tab.root);
    M.focusPane(ids[(ids.indexOf(tab.focused) + d + ids.length) % ids.length]);
  },
  // ⌥⌘W: stops showing the tab's panes, as its row's × does (sessions keep running).
  closeTab: () => { const M = Umi.model; M.paneIds(M.activeTab().root).forEach((id) => M.removePane(id)); },
  // ⌃⌘=: every split gives each pane the same share along its direction (Ghostty's equalize).
  equalize: () => {
    const weight = (n, dir) => (n.type === 'pane' ? 1
      : n.dir === dir ? weight(n.a, dir) + weight(n.b, dir) : Math.max(weight(n.a, dir), weight(n.b, dir)));
    (function walk(n) {
      if (n.type === 'pane') return;
      const a = weight(n.a, n.dir), b = weight(n.b, n.dir);
      n.ratio = a / (a + b);
      walk(n.a); walk(n.b);
    })(Umi.model.activeTab().root);
  },
  // ⌃⌘R renames the tab in its row; ⌃⇧⌘R renames the focused session (the palette's Rename).
  renameTab: () => { const t = Umi.model.activeTab(); Umi.state.ui.editingTab = t.id; Umi.state.ui.tabDraft = t.name || ''; },
  renameSession: () => {
    const sid = Umi.model.sessionOf(Umi.model.activeTab().focused);
    if (sid) Umi.model.openPanel('palette', { mode: 'rename', sid });
  },
  docketSession: () => Umi.model.docket(Umi.model.sessionOf(Umi.model.activeTab().focused)),
  // From a umi-next://open?task=… link (native fetched and checked the task): show its live
  // session, or resume its agent session, in a tab named after the task.
  openTask: ({ session, title, resume }) => {
    const M = Umi.model, S = Umi.state, cmds = S.commands || {};
    if (session) {
      const shown = M.paneOfSession(session);
      if (shown) { M.focusPane(shown); M.undocket(session); return; }
      const t = M.addTab(M.newPane({ session, attach: session, cwd: S.live[session]?.folder }));
      t.name = title;
      M.undocket(session);
      return;
    }
    if (resume) {
      const cmd = resume.agent === 'codex' ? `${cmds.codex || 'codex'} resume ${resume.id}` : `${cmds.claude || 'claude'} --resume ${resume.id}`;
      const t = M.addTab(M.newPane({ cwd: resume.cwd, start: { cmd, name: title, cwd: resume.cwd } }));
      t.name = title;
    }
  },
  reloadWeb: () => Umi.bridge.post({ type: 'reload' }),
};
