// umi-next web state and model: the one module that holds what the UI knows and every operation
// on it. Views read `Umi.state` and call `Umi.model`/`Umi.actions`; nothing else changes state.
// Plain script (no build step); everything hangs off `window.Umi`.
//
// The model follows next/DESIGN.md:
// - A session (agent or shell) lives in the daemon; a pane is a view onto at most one session, and
//   a session shows in at most one pane (`openSession` moves it).
// - A pane shows a `view`: 'terminal' (a native Ghostty view in its slot) or, later, others drawn
//   by the web layer (e.g. 'picker' in a fresh ⌘D split). Native starts a terminal only for
//   'terminal' panes.
// - Closing a pane asks `Umi.policy.closePane`: 'close' ends the pane (and its shell), 'detach'
//   keeps the session running without a pane (agents), 'ask' is left to a later dialog.
// - `state.ui.panel` is the bottom panel (the palette, sliding up from the window's bottom edge):
//   it takes height from the pane area, since the native terminals sit above the web view.
'use strict';
window.Umi = window.Umi || {};

Umi.state = {
  layout: null,     // persisted: {version, tabs:[{id, name?, root, focused}], activeTab, sidebar}
  panes: {},        // paneId -> what native reports: {session, title, pwd, exitCode}
  sessions: {},     // sessionId -> {id, paneId?, ...}; filled from panes now, from the daemon later
  ui: { panel: null, keys: 'terminal' }, // not persisted: open panel {name, ...}; who has the keys
  closed: {},       // paneId -> 'close' | 'detach': panes closed since the last layout sent to native
  home: '',
  sessionMode: 'shell',
};

Umi.policy = {
  // What ⌘W does to a pane. DESIGN: agent sessions detach; a shell closes (asks if busy).
  closePane(pane, info) { return 'close'; },
};

Umi.model = (() => {
  const S = Umi.state;
  const uid = (p) => p + Math.random().toString(36).slice(2, 10);

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
  const cwdOf = (paneId) => S.panes[paneId]?.pwd || findPane(paneId)?.node.cwd;

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

  // ---- operations ----
  function addTab(pane) {
    const cur = activeTab();
    const t = newTab(pane || newPane({ cwd: cur && cwdOf(cur.focused) }));
    S.layout.tabs.splice(S.layout.tabs.indexOf(cur) + 1, 0, t);
    S.layout.activeTab = t.id;
    return t;
  }

  // Splits the focused pane; the new pane shows `view` (later: 'picker', DESIGN ⌘D).
  function split(dir, view = 'terminal') {
    const tab = activeTab();
    const p = newPane({ view, cwd: cwdOf(tab.focused) });
    tab.root = mapPane(tab.root, tab.focused, (old) => ({ type: 'split', dir, ratio: 0.5, a: old, b: p }));
    tab.focused = p.id;
    return p;
  }

  // Takes the pane out of the layout. Whether its session ends is the caller's (native ends the
  // terminal; with the daemon, detach vs exit is SessionBackend's).
  function removePane(id) {
    const found = findPane(id);
    if (!found) return;
    const { tab } = found;
    const root = removeFromTree(tab.root, id);
    if (root) {
      tab.root = root;
      if (tab.focused === id) tab.focused = paneIds(root)[0];
      return;
    }
    const i = S.layout.tabs.indexOf(tab);
    S.layout.tabs.splice(i, 1);
    if (S.layout.tabs.length === 0) S.layout.tabs.push(newTab(newPane()));
    if (S.layout.activeTab === tab.id) S.layout.activeTab = S.layout.tabs[Math.min(i, S.layout.tabs.length - 1)].id;
  }

  function closePane(id) {
    const found = findPane(id);
    if (!found) return;
    const decision = Umi.policy.closePane(found.node, S.panes[id] || {});
    if (decision === 'ask') return; // a confirmation view comes later
    S.closed[id] = decision;        // sent with the next layout message
    removePane(id);
  }

  // Shows a session in a pane; if another pane shows it, that pane is the one focused instead
  // (one pane per session). Used by the picker and Review later.
  function openSession(sessionId, intoPaneId) {
    const shown = Object.entries(S.panes).find(([, info]) => info.session === sessionId);
    if (shown && findPane(shown[0])) return focusPane(shown[0]);
    const target = intoPaneId || activeTab().focused;
    const found = findPane(target);
    if (!found) return;
    // `attach` asks native to show that session in this pane (it ends or detaches the old view).
    Object.assign(found.node, { view: 'terminal', attach: sessionId });
  }

  function setPaneView(id, view, extra = {}) {
    const found = findPane(id);
    if (found) Object.assign(found.node, { view, ...extra });
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

  // Moves focus to the nearest pane in `dir`, given the slots' rects.
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

  function openPanel(name, data = {}) { S.ui.panel = { name, ...data }; }
  function closePanel() { S.ui.panel = null; }

  // ---- from native ----
  function load(msg) {
    S.home = msg.home || '';
    S.sessionMode = msg.sessionMode || 'shell';
    S.panes = msg.panes || {};
    const l = msg.layout;
    S.layout = l && l.tabs && l.tabs.length ? l : { version: 1, tabs: [newTab(newPane())], sidebar: true };
    for (const p of S.layout.tabs.flatMap((t) => panesOf(t.root))) p.view = p.view || 'terminal';
    if (!S.layout.tabs.some((t) => t.id === S.layout.activeTab)) S.layout.activeTab = S.layout.tabs[0].id;
    rebuildSessions();
  }

  function paneInfo(id, info) {
    S.panes[id] = info;
    const found = findPane(id);
    if (found && info.session) found.node.session = info.session;
    rebuildSessions();
  }

  function rebuildSessions() {
    const sessions = {};
    for (const [paneId, info] of Object.entries(S.panes)) {
      if (info.session) sessions[info.session] = { ...(S.sessions[info.session] || {}), id: info.session, paneId };
    }
    S.sessions = sessions;
  }

  return {
    newPane, panesOf, paneIds, findPane, activeTab, focusedPane, cwdOf,
    addTab, split, removePane, closePane, openSession, setPaneView, focusPane,
    selectTab, stepTab, focusDir, openPanel, closePanel, load, paneInfo,
  };
})();

// Named actions: what native shortcuts, sidebar buttons and (later) the palette run.
// Each returns nothing and only changes Umi.state; Umi.app.run saves, draws and reports after it.
Umi.actions = {
  newTab: () => Umi.model.addTab(),
  splitRight: () => Umi.model.split('row'),
  splitDown: () => Umi.model.split('column'),
  closePane: () => Umi.model.closePane(Umi.model.activeTab().focused),
  selectTab: ({ index }) => Umi.model.selectTab(index),
  nextTab: () => Umi.model.stepTab(1),
  prevTab: () => Umi.model.stepTab(-1),
  toggleSidebar: () => { Umi.state.layout.sidebar = Umi.state.layout.sidebar === false; },
  focusDir: ({ dir }) => Umi.model.focusDir(dir, Umi.views.panes.slotRects()),
};
