// Arranging tabs and panes: zoom a pane, pin, move and archive tabs, reopen what was closed, move
// panes, synchronized input, and the interface zoom and terminal font size. Each operation only
// changes Umi.state; the actions at the end are what keys, the palette and the CLI run.
// Persisted in layout.json:
//   tab.zoomed (pane id) · tab.pinned · tab.archived (when, ms) · layout.archiveOpen
//   layout.reopen [{kind: 'pane'|'tab', ...}] (latest last) · layout.sync {all} | {tabs: [ids]}
//   layout.zoom {ui, font} (native applies both; Sources/UmiNext/MainWindow.swift)
'use strict';

Umi.arrange = (() => {
  const S = Umi.state, M = Umi.model;
  const tabs = () => S.layout.tabs;
  const copy = (x) => JSON.parse(JSON.stringify(x));

  // ---- zoom a pane (⇧⌘↩) ----
  function toggleZoom() {
    const tab = M.activeTab();
    if (tab.zoomed) delete tab.zoomed;
    else if (M.paneIds(tab.root).length > 1) tab.zoomed = tab.focused;
  }

  // ---- pin and move tabs (SPEC L-2, L-13, S-7) ----
  // The listed tabs stay pinned first; a move never crosses between pinned and unpinned.
  const group = (t) => tabs().filter((x) => !x.archived && !!x.pinned === !!t.pinned);
  function moveTab(tab, d) {
    const g = group(tab), i = g.indexOf(tab), other = g[i + d];
    if (i < 0 || !other) return false;
    const a = tabs().indexOf(tab), b = tabs().indexOf(other);
    [tabs()[a], tabs()[b]] = [tabs()[b], tabs()[a]];
    return true;
  }
  // Puts `tab` before (or after) `target` in the list, within its group (sidebar drag).
  function placeTab(tab, target, after) {
    if (tab === target || !!tab.pinned !== !!target.pinned || tab.archived || target.archived) return;
    tabs().splice(tabs().indexOf(tab), 1);
    tabs().splice(tabs().indexOf(target) + (after ? 1 : 0), 0, tab);
  }
  // Pinning puts the tab at the end of the pinned tabs; unpinning at the top of the others (Warp).
  function togglePin(tab) {
    if (tab.archived) return;
    tabs().splice(tabs().indexOf(tab), 1);
    if (tab.pinned) delete tab.pinned; else tab.pinned = true;
    tabs().splice(tabs().filter((x) => x.pinned && x !== tab).length, 0, tab);
  }

  // ---- the archive (SPEC AR-1, AR-2) ----
  // An archived tab keeps its panes and sessions; it leaves the list (⌘1–9, ⇧⌘[ ⇧⌘] skip it) and
  // shows under the sidebar's Archived row. Archiving the selected tab selects the tab closing it
  // would; one brought back goes to the top of the unpinned tabs.
  function archive(tab) {
    if (tab.archived) return;
    if (S.layout.activeTab === tab.id) {
      const list = M.listedTabs(), i = list.indexOf(tab);
      const next = list[i + 1] || list[i - 1];
      if (next) S.layout.activeTab = next.id;
    }
    delete tab.pinned;
    tab.archived = Date.now();
  }
  function unarchive(tab) {
    if (!tab.archived) return;
    delete tab.archived;
    tabs().splice(tabs().indexOf(tab), 1);
    tabs().splice(tabs().filter((x) => x.pinned).length, 0, tab);
  }
  const archived = () => tabs().filter((t) => t.archived).sort((a, b) => a.archived - b.archived);

  // ---- reopen (⇧⌘T, SPEC L-20) ----
  // Closing a pane (⌘W) or a tab records it; reopen brings back the latest whose sessions still
  // run: a pane in its old place when its tab hasn't changed since (else at the tab's right end),
  // a tab at its old position with its name and pin. Sessions keep running while closed, so
  // there is no time limit.
  const REOPEN_MAX = 30;
  function record(item) {
    S.layout.reopen = (S.layout.reopen || []).concat([item]).slice(-REOPEN_MAX);
  }
  // A copy of a tree with each terminal pane's session written in.
  function snapshot(node) {
    const c = copy(node);
    for (const p of M.panesOf(c)) {
      const sid = M.sessionOf(p.id);
      if (!sid) continue;
      p.session = sid;
      const resume = M.resumeOf(sid);
      if (resume) p.resume = resume;
    }
    return c;
  }
  function noteClosePane(paneId) {
    const found = M.findPane(paneId);
    if (!found) return;
    if (M.paneIds(found.tab.root).length === 1) return noteCloseTab(found.tab);
    const sid = found.node.view === 'terminal' && M.sessionOf(paneId);
    if (sid) record({ kind: 'pane', tab: found.tab.id, pane: paneId, session: sid, resume: M.resumeOf(sid), root: snapshot(found.tab.root) });
  }
  function noteCloseTab(tab) {
    const root = snapshot(tab.root);
    if (!M.panesOf(root).some((p) => p.session)) return;
    record({ kind: 'tab', index: tabs().indexOf(tab), tab: { ...copy(tab), root } });
  }
  const canShow = (sid) => sid && S.live[sid] && S.live[sid].alive !== false && !M.paneOfSession(sid);
  const attachPane = (sid, cwd) => M.newPane({ session: sid, attach: sid, cwd: S.live[sid]?.folder || cwd });
  // A closed pane comes back showing its session if it still runs, else as a new session resuming
  // the agent's transcript (⌘W ended it); a shell that ended can't come back (null).
  const revive = (sid, resume, cwd) => (canShow(sid) ? attachPane(sid, cwd)
    : resume && !M.paneOfSession(sid) ? M.newPane({ cwd: resume.cwd || cwd, start: { ...resume } }) : null);

  function reopenPane(item) {
    const fresh = revive(item.session, item.resume);
    if (!fresh) return false;
    M.unhide(item.session);
    const tab = tabs().find((t) => t.id === item.tab);
    if (!tab) { M.addTab(fresh); return true; }
    const now = M.paneIds(tab.root).slice().sort().join(' ');
    const before = M.paneIds(item.root).filter((id) => id !== item.pane).sort().join(' ');
    if (now === before) {
      // The tab is as it was: the old tree, the closed pane back in its place and size.
      const map = (n) => (n.type === 'pane' ? (n.id === item.pane ? fresh : M.findPane(n.id).node) : { ...n, a: map(n.a), b: map(n.b) });
      tab.root = map(item.root);
      delete tab.zoomed;
      tab.focused = fresh.id;
      S.layout.activeTab = tab.id;
    } else {
      M.appendPane(tab, fresh);
    }
    if (tab.archived) unarchive(tab);
    return true;
  }

  function reopenTab(item) {
    // Panes whose session still runs and shows nowhere come back; the rest stay closed.
    let root = item.tab.root;
    for (const p of M.panesOf(root)) {
      const fresh = p.session && revive(p.session, p.resume, p.cwd);
      root = fresh ? M.mapPane(root, p.id, () => fresh) : M.removeFromTree(root, p.id);
      if (!root) return false;
    }
    const t = { ...item.tab, id: 'tab' + Math.random().toString(36).slice(2, 10), root, focused: M.paneIds(root)[0] };
    delete t.zoomed; delete t.archived;
    for (const p of M.panesOf(root)) M.unhide(p.session);
    const pinned = tabs().filter((x) => x.pinned).length;
    const at = t.pinned ? Math.min(item.index, pinned) : Math.min(Math.max(item.index, pinned), tabs().length);
    tabs().splice(at, 0, t);
    S.layout.activeTab = t.id;
    return true;
  }

  function reopen() {
    const stack = S.layout.reopen || [];
    while (stack.length) {
      const item = stack.pop();
      if (item.kind === 'pane' ? reopenPane(item) : reopenTab(item)) break;
    }
    if (!stack.length) delete S.layout.reopen;
  }

  // ---- moving panes (SPEC L-9: ⌃⌘←→ within the tab, ⌃⌘↑↓ to the tab above or below) ----
  // ←/→ swap the focused pane with the previous or next pane in layout order.
  function swapPane(d) {
    const tab = M.activeTab(), ids = M.paneIds(tab.root);
    const i = ids.indexOf(tab.focused), j = i + d;
    if (i < 0 || j < 0 || j >= ids.length) return;
    const a = M.findPane(ids[i]).node, b = M.findPane(ids[j]).node;
    const map = (n) => (n.type === 'pane' ? (n.id === a.id ? b : n.id === b.id ? a : n) : { ...n, a: map(n.a), b: map(n.b) });
    tab.root = map(tab.root);
  }
  // Cycle through the listed tabs and a new tab at the end. A lone pane already has its own tab.
  function paneToTab(d) {
    const from = M.activeTab(), list = M.listedTabs();
    if (from.root.type === 'split') list.push(null);
    if (!list.length) return;
    const i = Math.max(0, list.indexOf(from));
    const to = list[(i + d + list.length) % list.length];
    M.moveFocusedPane({ to, atEnd: true });
  }

  // ---- synchronized input (⌥⌘I, ⌥⇧⌘I; SPEC L-32, Warp's rules) ----
  // What's typed into a terminal of a synced tab is typed into every terminal of every synced tab
  // (native does the typing). From nothing, ⌥⌘I syncs just this tab; toggled from a synced set,
  // every tab synced is "all tabs", which new tabs join.
  const isSynced = (tab) => !!(S.layout.sync && (S.layout.sync.all || S.layout.sync.tabs?.includes(tab.id)));
  function toggleSyncTab(tab) {
    const all = tabs().map((t) => t.id), sync = S.layout.sync;
    if (!sync) { S.layout.sync = { tabs: [tab.id] }; return; }
    const set = new Set(sync.all ? all : sync.tabs.filter((id) => all.includes(id)));
    if (set.has(tab.id)) set.delete(tab.id); else set.add(tab.id);
    if (!set.size) delete S.layout.sync;
    else S.layout.sync = set.size === all.length ? { all: true } : { tabs: [...set] };
  }
  function toggleSyncAll() { if (S.layout.sync?.all) delete S.layout.sync; else S.layout.sync = { all: true }; }
  function stopSync() { delete S.layout.sync; }

  // ---- interface zoom and terminal font size (SPEC L-33) ----
  // ⌘= ⌘- step through Warp's levels and ⌘0 goes back to 100%: the page and the terminals' text.
  // ⌥⇧> ⌥⇧< change the terminals' font size by a point, between 5 and 25 (base: the config's
  // font-size, which native sends as `fontBase`); terminals show that size times the zoom.
  const LEVELS = [0.5, 0.6, 0.7, 0.8, 0.9, 1, 1.1, 1.25, 1.5, 1.75, 2, 2.25, 2.5, 3, 3.5];
  const zoom = () => (S.layout.zoom = S.layout.zoom || { ui: 1, font: 0 });
  function stepZoom(d) {
    const z = zoom();
    const i = LEVELS.findIndex((l) => l >= z.ui - 1e-6);
    const at = i < 0 ? LEVELS.length - 1 : i;
    const next = d > 0 ? LEVELS.find((l) => l > z.ui + 1e-6) : [...LEVELS].reverse().find((l) => l < z.ui - 1e-6);
    z.ui = d === 0 ? 1 : next ?? LEVELS[at];
  }
  function stepFont(d) {
    const z = zoom(), base = S.fontBase || 13;
    z.font = d === 0 ? 0 : Math.max(5 - base, Math.min(25 - base, z.font + d));
  }

  return { toggleZoom, moveTab, placeTab, togglePin, archive, unarchive, archived, noteClosePane, noteCloseTab, reopen,
    swapPane, paneToTab, isSynced, toggleSyncTab, toggleSyncAll, stopSync, stepZoom, stepFont, LEVELS };
})();

Object.assign(Umi.actions, (() => {
  const A = Umi.arrange, M = Umi.model, S = Umi.state;
  const close = Umi.actions.closePane, hide = Umi.actions.hidePane, nextWaiting = Umi.actions.nextWaiting;
  return {
    closePane: () => { A.noteClosePane(M.activeTab().focused); close(); },
    hidePane: () => { A.noteClosePane(M.activeTab().focused); hide(); },
    // ⌥⌘W or a row's ×: stops showing the tab's panes (sessions keep running); ⇧⌘T brings it back.
    closeTab: ({ tab } = {}) => {
      const t = (tab && S.layout.tabs.find((x) => x.id === tab)) || M.activeTab();
      A.noteCloseTab(t);
      M.paneIds(t.root).forEach((id) => M.removePane(id));
    },
    // `umi-next go --next`: the next session waiting for Alejo; `go --back`: back to where the walk started.
    nextWaiting: () => {
      if (!S.ui.walkFrom) S.ui.walkFrom = M.sessionOf(M.activeTab().focused) || null;
      nextWaiting();
    },
    goBack: () => {
      const sid = S.ui.walkFrom;
      S.ui.walkFrom = null;
      if (sid && S.live[sid] && S.live[sid].alive !== false) M.showSession(sid);
    },
    toggleZoom: () => A.toggleZoom(),
    moveTabUp: () => A.moveTab(M.activeTab(), -1),
    moveTabDown: () => A.moveTab(M.activeTab(), 1),
    togglePin: () => A.togglePin(M.activeTab()),
    toggleArchive: () => { const t = M.activeTab(); if (t.archived) A.unarchive(t); else A.archive(t); },
    showArchived: () => { const a = A.archived(); S.layout.archiveOpen = true; if (a[0]) S.layout.activeTab = a[0].id; },
    reopen: () => A.reopen(),
    swapPaneLeft: () => A.swapPane(-1),
    swapPaneRight: () => A.swapPane(1),
    paneToTabUp: () => A.paneToTab(-1),
    paneToTabDown: () => A.paneToTab(1),
    toggleSyncTab: () => A.toggleSyncTab(M.activeTab()),
    toggleSyncAll: () => A.toggleSyncAll(),
    stopSync: () => A.stopSync(),
    zoomIn: () => A.stepZoom(1),
    zoomOut: () => A.stepZoom(-1),
    zoomReset: () => A.stepZoom(0),
    fontUp: () => A.stepFont(1),
    fontDown: () => A.stepFont(-1),
    fontReset: () => A.stepFont(0),
  };
})());
