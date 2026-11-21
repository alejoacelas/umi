// The `umi-next` CLI's side in the page (next/app/cli, Sources/UmiNext/ControlServer.swift).
// Native hands each request on as {type: 'cli', id, req: {cmd, args, caller}}; the handler for
// `cmd` returns a result (or a promise of one) or throws, and the answer goes back as
// {type: 'cliReply', id, ok, result|error}. Handlers change state only through Umi.app.update
// and Umi.actions, so the CLI and the keys share code.
//
// Selectors (`args.pane`): absent → the caller's pane (the pane showing `caller.session`, the
// session the CLI runs in), else the focused pane; '.' → the focused pane; a pane id or unique
// prefix; a session id or unique prefix; a session name. Tabs (`args.tab`): absent → the caller's
// tab, else the current one; '.', an id or unique prefix, a name, '#N'.
//
// Sessions the CLI starts in a pane are recorded as started by the user (start.by), so the
// session lists show them (DESIGN "Sessions the user started").
//
//   Umi.cli.commentsDone(path)   the editor's Done on a file's comments: answers `comments wait`
//   Umi.cli.waiting()            the files `comments wait` waits on
'use strict';
window.Umi = window.Umi || {};

Umi.cli = (() => {
  const S = Umi.state, M = Umi.model;
  const fail = (message) => { throw new Error(message); };
  const WINDOW = 'main'; // one window (PARITY: `window …` isn't mirrored)

  // ---- selectors ----
  function callerPane(caller) {
    const sid = caller && caller.session;
    return (sid && M.paneOfSession(sid)) || null;
  }

  function sessionsMatching(sel) {
    const ids = Object.keys(S.live);
    if (ids.includes(sel)) return [sel];
    const byName = ids.filter((id) => M.sessionName(id) === sel || S.live[id].name === sel);
    if (byName.length) return byName;
    return ids.filter((id) => id.startsWith(sel));
  }

  // → {pane: id|null, session: id|null}. `needPane`: a session not on screen fails.
  function resolvePane(sel, caller, { needPane = true } = {}) {
    if (sel === undefined || sel === null || sel === '') {
      const id = callerPane(caller) || M.activeTab().focused;
      return { pane: id, session: M.sessionOf(id) || null };
    }
    if (sel === '.') { const id = M.activeTab().focused; return { pane: id, session: M.sessionOf(id) || null }; }
    const allPanes = S.layout.tabs.flatMap((t) => M.paneIds(t.root));
    if (allPanes.includes(sel)) return { pane: sel, session: M.sessionOf(sel) || null };
    const sids = sessionsMatching(sel);
    const prefix = allPanes.filter((p) => p.startsWith(sel));
    if (sids.length + prefix.length > 1) fail(`"${sel}" is ambiguous: ${[...prefix, ...sids].slice(0, 6).join(', ')}`);
    if (prefix.length) return { pane: prefix[0], session: M.sessionOf(prefix[0]) || null };
    if (sids.length) {
      const pane = M.paneOfSession(sids[0]) || null;
      if (!pane && needPane) fail(`session ${sids[0]} isn't shown in a pane (pane show ${sids[0]} brings it back)`);
      return { pane, session: sids[0] };
    }
    fail(`no pane or session "${sel}"`);
  }

  function resolveTab(sel, caller) {
    const tabs = S.layout.tabs;
    if (sel === undefined || sel === null || sel === '') {
      const p = callerPane(caller);
      return (p && M.findPane(p).tab) || M.activeTab();
    }
    if (sel === '.') return M.activeTab();
    const n = /^#(\d+)$/.exec(sel);
    if (n) return tabs[+n[1] - 1] || fail(`no tab ${sel}`);
    const exact = tabs.find((t) => t.id === sel) || tabs.filter((t) => t.name === sel);
    if (exact && !Array.isArray(exact)) return exact;
    if (exact.length === 1) return exact[0];
    if (exact.length > 1) fail(`more than one tab is named "${sel}"`);
    const prefix = tabs.filter((t) => t.id.startsWith(sel));
    if (prefix.length === 1) return prefix[0];
    fail(prefix.length ? `"${sel}" is ambiguous` : `no tab "${sel}"`);
  }

  // ---- JSON shapes (acceptance/CLI.md, with Next's own fields) ----
  const INDICATOR = { busy: 'working', needs: 'needs_you', finished: 'finished' };
  function paneJSON(node, tab, rects) {
    const sid = M.sessionOf(node.id) || null, live = sid && S.live[sid];
    const out = {
      id: node.id, kind: node.view || 'terminal', session: sid, cwd: M.folderOf(node.id), project: M.projectOf(node.id),
      focused: tab.focused === node.id, zoomed: tab.zoomed === node.id, hidden: false,
      indicator: (live && INDICATOR[M.standing(live)]) || 'none',
      title: S.panes[node.id]?.title || '',
    };
    if (sid) out.name = M.sessionName(sid);
    if (live) { out.state = live.state; out.by = live.by || 'user'; if (live.agent) out.agent = { kind: live.agent.agent, event: live.agent.event, session: live.agent.agentSession }; }
    if (node.view === 'file') { out.file = node.path; out.mode = cliMode(node); }
    const r = rects && rects[node.id];
    if (r) out.frame = { x: r.x, y: r.y, width: r.w, height: r.h };
    return out;
  }
  function tabTitle(tab) { return tab.name || M.sessionName(M.sessionOf(tab.focused)) || M.folderOf(tab.focused); }
  function tabJSON(tab, rects) {
    const out = {
      id: tab.id, index: S.layout.tabs.indexOf(tab) + 1, title: tabTitle(tab), selected: tab.id === M.activeTab().id,
      focused_pane: tab.focused, panes: M.panesOf(tab.root).map((n) => paneJSON(n, tab, rects)),
      // The sessions ⌥⌘H hid from this tab (the strip's chips).
      hidden: M.hiddenOf(tab),
    };
    if (tab.name) out.name = tab.name;
    return out;
  }
  function where(paneId) {
    const f = M.findPane(paneId);
    return { pane: paneId, tab: f ? f.tab.id : null, window: WINDOW, session: M.sessionOf(paneId) || null };
  }

  // ---- layout helpers ----
  function replaceNode(node, id, fn) {
    if (node.type === 'pane') return node.id === id ? fn(node) : node;
    return { ...node, a: replaceNode(node.a, id, fn), b: replaceNode(node.b, id, fn) };
  }
  // A session the CLI puts in a visible pane counts as the user's (DESIGN "Sessions the user started").
  function startFields(args, folder) {
    return { cmd: args.cmd || null, name: args.name || M.defaultName(folder), cwd: folder, by: 'user' };
  }
  // A pane for a new session (with --cmd), else the picker (as ⌘D; PARITY "split" departure).
  function newPaneFor(args, folder, project) {
    if (args.cmd || args.shell) return M.newPane({ cwd: folder, start: startFields(args, folder) });
    return M.newPane({ view: 'picker', cwd: folder, picker: { kind: 'claude', name: args.name || '', sel: 0, project } });
  }

  // A new terminal pane gets its session once native starts it (on its first slot, or at once in a
  // tab that isn't showing); wait for it.
  function sessionSoon(paneId, ms = 6000) {
    return new Promise((resolve) => {
      const t0 = Date.now();
      (function poll() {
        const sid = S.panes[paneId]?.session;
        if (sid || Date.now() - t0 > ms || !M.findPane(paneId)) return resolve(sid || null);
        setTimeout(poll, 40);
      })();
    });
  }
  async function placed(paneId, waitSession) {
    const sid = waitSession ? await sessionSoon(paneId) : null;
    return { ...where(paneId), session: sid || M.sessionOf(paneId) || null };
  }

  // ---- the commands ----
  const waiters = new Map(); // request id -> {path, resolve}
  const H = {};

  H.ls = () => {
    const rects = Umi.views.panes.slotRects();
    const shown = new Set(Object.values(S.panes).map((p) => p.session));
    return {
      windows: [{ id: WINDOW, index: 1, selected_tab: M.activeTab().id, tabs: S.layout.tabs.map((t) => tabJSON(t, rects)),
        sidebar: { visible: S.layout.sidebar !== false, mode: S.layout.sidebarMode || 'tabs' } }],
      current_tab: M.activeTab().id, current_pane: M.activeTab().focused,
      // Every live session, shown or not, with who started it.
      sessions: Object.values(S.live).map((s) => ({ id: s.id, name: M.sessionName(s.id), by: s.by || 'user', state: s.state,
        standing: M.standing(s), kind: s.kind, folder: s.folder, project: s.project, alive: s.alive,
        pane: shown.has(s.id) ? M.paneOfSession(s.id) || null : null })),
    };
  };

  // Which session a selector means, for the daemon-side commands (send, keys, read, wait).
  H.resolve = ({ pane }, caller) => {
    const r = resolvePane(pane, caller, { needPane: false });
    if (!r.session) fail(`pane ${r.pane} shows no session (${M.findPane(r.pane)?.node.view || 'nothing'})`);
    return r;
  };

  H['pane.info'] = ({ pane }, caller) => {
    const r = resolvePane(pane, caller);
    const f = M.findPane(r.pane);
    return { ...paneJSON(f.node, f.tab, Umi.views.panes.slotRects()), tab: f.tab.id, window: WINDOW };
  };

  H['tab.new'] = (args, caller) => {
    const from = callerPane(caller) || M.activeTab().focused;
    const folder = args.cwd || M.folderOf(from);
    let pane;
    Umi.app.update(() => {
      const cur = M.activeTab();
      pane = M.newPane({ cwd: folder, start: startFields(args, folder) });
      const t = { id: 't' + Math.random().toString(36).slice(2, 10), root: pane, focused: pane.id };
      if (args.title) t.name = args.title;
      const tabs = S.layout.tabs;
      if (args.noFocus) tabs.push(t);
      else { tabs.splice(Math.max(tabs.indexOf(cur) + 1, tabs.filter((x) => x.pinned).length), 0, t); S.layout.activeTab = t.id; }
    }, { focus: !args.noFocus });
    return placed(pane.id, true);
  };

  H['tab.focus'] = ({ tab }, caller) => {
    const t = resolveTab(tab, caller);
    Umi.app.update(() => { S.layout.activeTab = t.id; });
    return tabSummary(t);
  };
  function tabSummary(t) { return { tab: t.id, window: WINDOW, index: S.layout.tabs.indexOf(t) + 1, title: tabTitle(t) }; }
  H['tab.next'] = () => { Umi.app.run('nextTab'); return tabSummary(M.activeTab()); };
  H['tab.prev'] = () => { Umi.app.run('prevTab'); return tabSummary(M.activeTab()); };
  // Stops showing the tab's panes (⌥⌘W, the same action, so ⇧⌘T brings it back); their sessions
  // keep running.
  H['tab.close'] = ({ tab }, caller) => {
    const t = resolveTab(tab, caller);
    Umi.app.update(() => Umi.actions.closeTab({ tab: t.id }));
    return { tab: t.id, window: WINDOW };
  };
  H['tab.rename'] = ({ tab, name }, caller) => {
    const t = resolveTab(tab, caller);
    Umi.app.update(() => { if (name) t.name = name; else delete t.name; });
    return tabSummary(t);
  };
  // As ⌃⇧↑↓: within the pinned or the unpinned tabs, never across.
  H['tab.move'] = ({ tab, d }, caller) => {
    const t = resolveTab(tab, caller);
    if (t.archived) fail('the tab is archived; unarchive it first');
    let moved = false;
    Umi.app.update(() => { moved = Umi.arrange.moveTab(t, d < 0 ? -1 : 1); });
    const among = S.layout.tabs.some((x) => x.pinned && !x.archived) ? ` of the ${t.pinned ? 'pinned' : 'unpinned'} tabs` : '';
    if (!moved) fail(`the tab is already ${d < 0 ? 'first' : 'last'}${among}`);
    return tabSummary(t);
  };

  H.split = async (args, caller) => {
    const r = resolvePane(args.pane, caller);
    const f = M.findPane(r.pane);
    const dir = args.dir || 'right';
    if (!['right', 'down', 'left', 'up'].includes(dir)) fail(`split: unknown direction "${dir}" (right, down, left, up)`);
    const folder = args.cwd || M.folderOf(r.pane);
    const p = newPaneFor(args, folder, M.projectOf(r.pane));
    const ratio = args.ratio != null ? +args.ratio : 0.5;
    if (!(ratio > 0 && ratio < 1)) fail('split: --ratio takes a number between 0 and 1');
    const before = dir === 'left' || dir === 'up';
    Umi.app.update(() => {
      f.tab.root = replaceNode(f.tab.root, r.pane, (old) => ({
        type: 'split', dir: dir === 'right' || dir === 'left' ? 'row' : 'column',
        ratio: before ? ratio : 1 - ratio, a: before ? p : old, b: before ? old : p,
      }));
      if (!args.noFocus) { f.tab.focused = p.id; S.layout.activeTab = f.tab.id; }
    }, { focus: !args.noFocus });
    return placed(p.id, !!p.start);
  };

  H['pane.focus'] = ({ pane }, caller) => {
    const r = resolvePane(pane, caller, { needPane: false });
    Umi.app.update(() => { if (r.pane) M.focusPane(r.pane); else M.showSession(r.session); });
    return where(M.activeTab().focused);
  };
  // ⌘W: closes the pane and ends its session; ⇧⌘T resumes an agent's transcript.
  H['pane.close'] = ({ pane }, caller) => {
    const r = resolvePane(pane, caller);
    Umi.app.update(() => { Umi.arrange.noteClosePane(r.pane); M.closeAndEnd(r.pane); }, { focus: r.pane === M.activeTab().focused });
    return { panes: [r.pane], session: r.session };
  };
  // ⌥⌘H: stops showing the pane; the session keeps running and the tab's strip lists it.
  H['pane.hide'] = ({ pane }, caller) => {
    const r = resolvePane(pane, caller);
    Umi.app.update(() => { Umi.arrange.noteClosePane(r.pane); M.hide(r.pane); }, { focus: r.pane === M.activeTab().focused });
    return { panes: [r.pane], sessions: r.session ? [r.session] : [] };
  };
  // Shows a session that no pane shows, at the right end of the current tab; focus stays put
  // unless --focus. A pane already on show is only focused (with --focus).
  H['pane.show'] = ({ pane, focus }, caller) => {
    const r = resolvePane(pane, caller, { needPane: false });
    if (r.pane) {
      if (focus) Umi.app.update(() => M.focusPane(r.pane));
      return { panes: [r.pane], hid: [] };
    }
    // The strip's own show, which focuses what it shows; focus goes back unless --focus.
    Umi.app.update(() => {
      const tab = M.activeTab(), keep = tab.focused;
      Umi.actions.showHidden({ session: r.session });
      if (!focus && M.findPane(keep)) { S.layout.activeTab = M.findPane(keep).tab.id; M.findPane(keep).tab.focused = keep; }
    }, { focus: true });
    return { panes: [M.paneOfSession(r.session) || null].filter(Boolean), hid: [], session: r.session };
  };
  H['pane.exit'] = ({ pane }, caller) => {
    const r = resolvePane(pane, caller, { needPane: false });
    if (!r.session) fail('that pane shows no session');
    Umi.bridge.post({ type: 'exitSession', session: r.session });
    return { session: r.session };
  };
  H['pane.rename'] = ({ pane, name }, caller) => {
    const r = resolvePane(pane, caller, { needPane: false });
    if (!r.session) fail('that pane shows no session');
    Umi.app.update(() => M.rename(r.session, name));
    return { pane: r.pane, session: r.session, name: M.sessionName(r.session) };
  };
  H['pane.swap'] = ({ pane, target }, caller) => {
    const a = resolvePane(pane, caller), b = resolvePane(target, caller);
    if (a.pane === b.pane) fail('pane swap: a pane can\'t swap with itself');
    Umi.app.run('swapPanes', { a: a.pane, b: b.pane });
    return { pane: a.pane, target: b.pane };
  };
  H['pane.resize'] = ({ pane, dir, amount }, caller) => {
    const r = resolvePane(pane, caller);
    let moved = false;
    Umi.app.update(() => { moved = Umi.actions.resizePane({ pane: r.pane, dir, amount }); });
    if (!moved) fail(`pane resize: no divider ${dir === 'left' || dir === 'right' ? 'beside' : 'above or below'} the pane to move ${dir}`);
    return { pane: r.pane };
  };
  H['pane.move'] = ({ pane, newTab, noFocus }, caller) => {
    if (!newTab) fail('pane move: Umi next moves panes with --new-tab only');
    const r = resolvePane(pane, caller);
    const f = M.findPane(r.pane);
    if (M.paneIds(f.tab.root).length < 2) fail('pane move --new-tab: the pane is alone in its tab already');
    Umi.app.update(() => {
      const before = S.layout.activeTab, keep = f.tab.focused;
      f.tab.focused = r.pane;
      S.layout.activeTab = f.tab.id;
      M.moveFocusedPane();
      if (noFocus) { S.layout.activeTab = before; if (keep !== r.pane) f.tab.focused = keep; }
    }, { focus: !noFocus });
    return { ...where(r.pane), panes: [r.pane] };
  };
  H['pane.zoom'] = ({ pane }, caller) => {
    const r = resolvePane(pane, caller);
    Umi.app.update(() => { M.focusPane(r.pane); Umi.actions.toggleZoom({ pane: r.pane }); });
    return { pane: r.pane };
  };

  H.sidebar = ({ mode }) => {
    const L = S.layout;
    const status = () => ({ visible: L.sidebar !== false, mode: L.sidebarMode || 'tabs', window: WINDOW });
    if (!mode || mode === 'status') return status();
    if (mode === 'on' || mode === 'off' || mode === 'toggle') {
      const want = mode === 'toggle' ? L.sidebar === false : mode === 'on';
      Umi.app.update(() => { L.sidebar = want; }, { focus: false });
      return status();
    }
    if (['tabs', 'files', 'search'].includes(mode)) {
      Umi.app.run('sidebarMode', { mode });
      return status();
    }
    fail(`sidebar: unknown mode "${mode}" (on off toggle status tabs files search)`);
  };

  // A desktop notification (T-6). DESIGN's snooze rules: a snoozed session, or one on the
  // docket, fires no alert (exit 0, `suppressed` says why).
  H.notify = async ({ title, body, pane }, caller) => {
    let sid = null;
    if (pane || caller?.session) { try { sid = resolvePane(pane, caller, { needPane: false }).session; } catch (e) { if (pane) throw e; } }
    if (sid && M.isSnoozed(sid)) return { title, suppressed: 'snoozed', session: sid };
    if (sid && S.live[sid]?.docket) return { title, suppressed: 'docket', session: sid };
    const r = await Umi.bridge.request('notify', { title, body: body || '' });
    return { title, status: r.status, ...(sid ? { session: sid } : {}) };
  };

  H.go = ({ next, back }) => {
    if (back) {
      Umi.app.run('goBack');
      return where(M.activeTab().focused);
    }
    if (!next) fail('go: use go --next jump or go --back');
    const before = M.activeTab().focused;
    Umi.app.run('nextWaiting');
    if (M.activeTab().focused === before) fail('nothing in jump');
    return where(M.activeTab().focused);
  };

  H.shortcuts = () => ({
    shortcuts: Umi.shortcuts.table.map((e) => ({
      id: e.id, title: e.label, group: e.group, kind: 'umi',
      keys: e.keys ? [e.keys] : [], display: [e.display || Umi.shortcuts.format(e.keys)],
      default: e.keys ? [e.keys] : [], changed: false, ...(e.native ? { native: e.native } : {}),
    })),
    files: ['next/app/web/shortcuts.js'],
  });

  // ---- editor (track a's file panes: view 'file', {path, mode: 'rendered'|'raw'}) ----
  // The CLI says preview and source, as Umi's does.
  const TO_PANE = { preview: 'rendered', source: 'raw' };
  // A file with no rendered view (not Markdown, JSON, CSV or TSV) is always in source.
  const hasPreview = (path) => /\.(md|markdown|mdown|mkd|mdx)$/i.test(path) || UmiData.handles(path);
  function cliMode(node) { return node.mode === 'raw' || !hasPreview(node.path) ? 'source' : 'preview'; }
  const filePanes = (tab) => M.panesOf(tab.root).filter((n) => n.view === 'file');
  const fileAnywhere = (path) => {
    for (const t of S.layout.tabs) { const n = filePanes(t).find((x) => x.path === path); if (n) return { tab: t, node: n }; }
    return null;
  };

  // Opens each file to the right of the pane (the caller's, or the tab's focused pane), each next
  // one to the right of the one before, with track a's openFile; keyboard focus stays put.
  H.edit = ({ paths, mode, pane, tab }, caller) => {
    const refused = paths.filter((p) => /^[a-z]+:\/\//i.test(p));
    if (refused.length) fail(`web pages don't open in Umi next yet: ${refused.join(' ')}`);
    let beside = tab ? resolveTab(tab, caller).focused : resolvePane(pane, caller).pane;
    const docs = [];
    for (const path of paths) {
      let id;
      Umi.app.update(() => { id = Umi.actions.openFile({ path, pane: beside, focus: false, ...(mode ? { mode: TO_PANE[mode] } : {}) }); });
      const node = id && M.findPane(id)?.node;
      if (!node) fail(`couldn't open ${path}`);
      docs.push({ path: node.path, pane: id, mode: cliMode(node) });
      beside = id;
    }
    const t = docs.length ? M.findPane(docs[0].pane).tab.id : null;
    return { documents: docs, pages: [], tab: t, window: WINDOW, hid: [] };
  };

  const isDirty = (id) => !!Umi.views.file?.isDirty?.(id);
  H['editor.ls'] = ({ pane, tab }, caller) => {
    const t = tab ? resolveTab(tab, caller) : pane ? M.findPane(resolvePane(pane, caller).pane).tab : resolveTab(null, caller);
    const docs = filePanes(t).map((n) => ({ path: n.path, pane: n.id, mode: cliMode(n), dirty: isDirty(n.id), hidden: false }));
    const active = docs.find((d) => d.pane === t.focused);
    return { documents: docs, active: active ? active.path : null, tab: t.id };
  };
  function pickFile(file, caller) {
    const t = resolveTab(null, caller);
    if (file) {
      const found = fileAnywhere(file);
      return found ? found.node : fail(`${file} isn't open`);
    }
    const n = M.findPane(t.focused)?.node;
    if (n && n.view === 'file') return n;
    const all = filePanes(t);
    return all.length === 1 ? all[0] : fail(all.length ? 'more than one file is open in the tab: name one' : 'no file is open in the tab');
  }
  // Refuses unsaved edits without --force; with it, the edits (and their kept draft) go.
  H['editor.close'] = ({ file, force }, caller) => {
    const n = pickFile(file, caller);
    if (isDirty(n.id) && !force) fail(`${n.path} has unsaved changes (--force closes it anyway)`);
    Umi.app.update(() => M.removePane(n.id), { focus: false });
    // The view keeps a draft as it goes (on removal too): drop it after.
    if (force && S.layout.meta?.drafts?.[n.path]) { delete S.layout.meta.drafts[n.path]; Umi.app.save(); }
    return { path: n.path, pane: n.id };
  };
  H['editor.mode'] = ({ mode, file }, caller) => {
    const n = pickFile(file, caller);
    if (mode && mode !== 'preview' && mode !== 'source') fail('editor mode: preview or source');
    const want = mode || (cliMode(n) === 'preview' ? 'source' : 'preview');
    const v = Umi.views.file?.get?.(n.id);
    Umi.app.update(() => { if (v) v.setMode(TO_PANE[want]); else n.mode = TO_PANE[want]; }, { focus: false });
    return { path: n.path, pane: n.id, mode: want };
  };

  // Answered when the user presses Done on that file's comments (the file view's
  // 'umi:commentsDone'); the file's margin shows how many agents wait.
  function countWaiting(path) {
    const n = [...waiters.values()].filter((w) => w.path === path).length;
    Umi.views.file?.setWaiting?.(path, n);
  }
  H['comments.wait'] = ({ path }, _caller, id) => new Promise((resolve) => {
    waiters.set(id, { path, resolve });
    countWaiting(path);
  });
  function commentsDone(path) {
    for (const [id, w] of waiters) if (w.path === path) { waiters.delete(id); w.resolve({ path }); }
    countWaiting(path);
  }
  window.addEventListener('umi:commentsDone', (e) => commentsDone(e.detail.path));

  // ---- wiring ----
  Umi.bridge.on('cli', async (msg) => {
    const { cmd, args = {}, caller = {} } = msg.req || {};
    const reply = (ok, value) => Umi.bridge.post(ok ? { type: 'cliReply', id: msg.id, ok: true, result: value ?? null }
      : { type: 'cliReply', id: msg.id, ok: false, error: value });
    const h = H[cmd];
    if (!h) return reply(false, `unknown command ${cmd}`);
    if (!S.layout) return reply(false, 'the layout hasn\'t loaded yet; try again');
    try { reply(true, await h(args, caller, msg.id)); }
    catch (e) { reply(false, e.message || String(e)); }
  });
  Umi.bridge.on('cliCancel', (msg) => { const w = waiters.get(msg.id); waiters.delete(msg.id); if (w) countWaiting(w.path); });

  const waiting = () => [...waiters.values()].map((w) => w.path);
  return { handlers: H, commentsDone, waiting, resolvePane, resolveTab };
})();

// Actions the CLI asked for (PARITY: swapPanes, resizePane); keys may take them up later.
Umi.actions.swapPanes = ({ a, b }) => {
  const M = Umi.model, fa = M.findPane(a), fb = M.findPane(b);
  if (!fa || !fb) return;
  const na = fa.node, nb = fb.node;
  const swap = (n) => (n.type === 'pane' ? (n.id === a ? nb : n.id === b ? na : n) : { ...n, a: swap(n.a), b: swap(n.b) });
  for (const t of new Set([fa.tab, fb.tab])) {
    t.root = swap(t.root);
    if (t.focused === a && t !== fb.tab) t.focused = b; else if (t.focused === b && t !== fa.tab) t.focused = a;
  }
};

// Moves the divider nearest the pane on its `dir` side by `amount` cells (Umi's unit; a cell is
// taken as 8×16 px), as Ghostty's resize_split does. Returns false when no divider is there.
Umi.actions.resizePane = ({ pane, dir, amount = 5 }) => {
  const M = Umi.model, f = M.findPane(pane);
  if (!f) return false;
  const horizontal = dir === 'left' || dir === 'right';
  const want = horizontal ? 'row' : 'column';
  // The path from the root to the pane.
  const path = [];
  (function walk(n) {
    if (n.type === 'pane') return n.id === pane;
    path.push(n);
    if (walk(n.a)) return true;
    if (walk(n.b)) return true;
    path.pop();
    return false;
  })(f.tab.root);
  const split = path.reverse().find((n) => n.dir === want);
  if (!split) return false;
  const rects = Umi.views.panes.slotRects();
  const ids = M.paneIds(split.a).concat(M.paneIds(split.b)).map((id) => rects[id]).filter(Boolean);
  const size = horizontal ? Math.max(...ids.map((r) => r.x + r.w)) - Math.min(...ids.map((r) => r.x))
                          : Math.max(...ids.map((r) => r.y + r.h)) - Math.min(...ids.map((r) => r.y));
  if (!(size > 0)) return false;
  const px = amount * (horizontal ? 8 : 16);
  const d = (dir === 'right' || dir === 'down' ? 1 : -1) * px / size;
  split.ratio = Math.min(0.95, Math.max(0.05, split.ratio + d));
  return true;
};
