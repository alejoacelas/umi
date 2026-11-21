// The sidebar's modes (SPEC S-2): Tabs, Files (the project explorer) and Search (global search),
// chosen by the header's buttons or keys, and the header's "Search tabs..." field. Also what the
// three file views share: opening a file, the recent files, the terminal a path is typed into.
//
// Which part of the sidebar has the keys is S.ui.sidebarFocus: 'tabsearch' (the header's field),
// 'files' (the tree), 'search' (the query) or 'results' (search results). It is cleared when an
// action runs (Umi.app.run, unless the action has `keepsFocus`), a pane is focused or a terminal
// is clicked, so the keys go back to the pane.
//
// State: S.layout.sidebarMode ('tabs' | 'files' | 'search'), S.layout.hideDotfiles (⇧⌘>),
// S.layout.meta.recentFiles (absolute paths opened from quick open, the explorer or search,
// most recent first).
'use strict';
Umi.views = Umi.views || {};

Umi.views.modes = (() => {
  const S = Umi.state, M = Umi.model;
  const MODE_OF = { tabsearch: 'tabs', files: 'files', search: 'search', results: 'search' };

  const mode = () => S.layout?.sidebarMode || 'tabs';
  const shown = () => !!S.layout && S.layout.sidebar !== false;

  // Whether a part of the sidebar should have the keys now.
  function hasKeys() {
    const f = S.ui.sidebarFocus;
    return !!f && shown() && MODE_OF[f] === mode();
  }

  function focus() {
    switch (S.ui.sidebarFocus) {
      case 'tabsearch': { const i = tabSearch(); if (document.activeElement !== i) i.focus(); break; }
      case 'files': Umi.views.explorer.focus(); break;
      case 'search': Umi.views.search.focusQuery(); break;
      case 'results': Umi.views.search.focusResults(); break;
    }
  }

  // Gives the keys back to the focused pane.
  function focusPane() { Umi.app.update(() => { S.ui.sidebarFocus = null; }); }

  // ---- header ----
  const tabSearch = () => document.querySelector('#tab-search input');

  function wireHeader() {
    const head = document.querySelector('#sidebar-head');
    head.querySelector('#tab-search .glyph').innerHTML = Umi.icons.svg.search;
    const glyphs = { tabs: Umi.icons.svg.tabs, files: Umi.icons.svg.folder, search: Umi.icons.svg.search };
    head.querySelectorAll('button.mode').forEach((b) => {
      b.innerHTML = glyphs[b.dataset.mode];
      b.addEventListener('click', () => Umi.app.run('sidebarMode', { mode: b.dataset.mode }));
    });
    const input = tabSearch();
    input.addEventListener('focus', () => {
      if (S.ui.sidebarFocus === 'tabsearch') return;
      S.ui.sidebarFocus = 'tabsearch';
      Umi.app.report(true);
    });
    input.addEventListener('input', () => { S.ui.tabQuery = input.value; Umi.views.sidebar.render(); });
    input.addEventListener('keydown', (e) => {
      if (e.key === 'Escape') {
        // Esc: clears the query and gives the keys back to the pane (Umi's endSearch).
        e.preventDefault();
        input.value = '';
        S.ui.tabQuery = '';
        focusPane();
      } else if (e.key === 'Enter') {
        e.preventDefault();
        const first = M.listedTabs().find(matchesTab);
        Umi.app.update(() => { if (first) S.layout.activeTab = first.id; S.ui.sidebarFocus = null; });
      }
    });
  }

  // "Search tabs...": a tab matches when its name, folder or what its focused pane shows contains
  // the query (Umi also matches the branch and the agent's title).
  function matchesTab(tab) {
    const q = (S.ui.tabQuery || '').trim().toLowerCase();
    if (!q) return true;
    const info = S.panes[tab.focused] || {};
    const sid = M.sessionOf(tab.focused);
    const hay = [tab.name, M.folderOf(tab.focused), info.title, sid && S.live[sid]?.foreground, sid && M.sessionName(sid)];
    return hay.some((h) => h && String(h).toLowerCase().includes(q));
  }

  function render() {
    if (!S.layout) return;
    const m = mode();
    document.body.dataset.sidebarMode = m;
    document.querySelectorAll('#sidebar-head button.mode').forEach((b) => b.classList.toggle('on', b.dataset.mode === m));
    document.querySelector('#explorer').hidden = m !== 'files';
    document.querySelector('#search').hidden = m !== 'search';
    if (shown() && m === 'files') Umi.views.explorer.render(); else Umi.views.explorer.hide();
    if (shown() && m === 'search') Umi.views.search.render();
  }

  // ---- shared by the explorer, search and quick open ----

  // Their root, as Umi's: the git top folder of the focused pane's folder (a worktree's own, where
  // Umi.fs.root() is the main checkout), else that folder. Null while git is being asked; the
  // sidebar draws again once it answers. rootOf(folder) gives a promise.
  const roots = new Map(), asking = new Map();
  function rootOf(folder) {
    if (roots.has(folder)) return Promise.resolve(roots.get(folder));
    if (!asking.has(folder)) {
      asking.set(folder, Umi.fs.gitRoot(folder).then((r) => r.root || folder, () => folder).then((r) => {
        roots.set(folder, r);
        asking.delete(folder);
        Umi.views.sidebar.render();
        return r;
      }));
    }
    return asking.get(folder);
  }
  function root() {
    const folder = M.folderOf(M.activeTab().focused);
    if (roots.has(folder)) return roots.get(folder);
    rootOf(folder);
    return null;
  }

  // Opens a file in the editor (track a's file pane) beside the focused pane; files that aren't
  // UTF-8 text, or are too big for the editor, open with their default app (as Umi does).
  async function openPath(path, { line, col } = {}) {
    try {
      await Umi.fs.read(path);
    } catch (e) {
      if (e.code === 'binary' || e.code === 'tooLarge') return Umi.fs.openDefault(path);
      return flash(`Can't open ${path.split('/').pop()}: ${e.message}`);
    }
    const meta = S.layout.meta = S.layout.meta || { sessions: {} };
    meta.recentFiles = [path, ...(meta.recentFiles || []).filter((p) => p !== path)].slice(0, 100);
    Umi.app.run('openFile', { path, ...(line ? { line } : {}), ...(col ? { col } : {}) });
  }

  const recentFiles = () => S.layout?.meta?.recentFiles || [];

  // The pane `Insert Path` types into: the focused pane when it shows a session, else the tab's
  // first pane that does.
  function terminalPane() {
    const tab = M.activeTab();
    const ok = (id) => { const n = M.findPane(id)?.node; return n && (n.view || 'terminal') === 'terminal' && M.sessionOf(id); };
    if (ok(tab.focused)) return tab.focused;
    return M.paneIds(tab.root).find(ok) || null;
  }
  // The terminal `cd to Directory` types into: terminalPane() while its shell is at the prompt.
  function promptPane() {
    const p = terminalPane();
    const s = p && S.live[M.sessionOf(p)];
    return s && s.kind === 'shell' && s.state === 'waiting' ? p : null;
  }
  const shellQuote = (p) => (/^[\w@%+=:,./-]+$/.test(p) ? p : "'" + p.replace(/'/g, "'\\''") + "'");
  const sendText = (pane, text) => Umi.bridge.request('sendText', { session: M.sessionOf(pane), text })
    .catch((e) => flash(`Can't type into the terminal: ${e.message}`));

  // A short message at the top of the sidebar (a failed rename, open or delete).
  let flashTimer = null;
  function flash(text) {
    const el = document.querySelector('#sidebar-flash');
    el.textContent = text;
    el.hidden = false;
    clearTimeout(flashTimer);
    flashTimer = setTimeout(() => { el.hidden = true; }, 5000);
  }

  wireHeader();
  return { mode, shown, hasKeys, focus, focusPane, render, matchesTab, root, rootOf, openPath, recentFiles, terminalPane, promptPane, shellQuote, sendText, flash };
})();

Object.assign(Umi.actions, {
  // ⇧⌘E / ⌃1: Files with the keys in the tree; pressed again (Files shown), back to Tabs and the pane.
  toggleExplorer: () => {
    const S = Umi.state, V = Umi.views.modes;
    if (V.shown() && V.mode() === 'files') { S.layout.sidebarMode = 'tabs'; return; }
    S.layout.sidebarMode = 'files';
    S.layout.sidebar = true;
    S.ui.sidebarFocus = 'files';
  },
  // ⇧⌘F: Search with the keys in the query, its text selected.
  openSearch: () => {
    const S = Umi.state;
    S.layout.sidebarMode = 'search';
    S.layout.sidebar = true;
    S.ui.sidebarFocus = 'search';
    S.ui.searchSelectAll = true;
  },
  // ⌃3: Search, or back to Tabs when it's shown.
  toggleSearch: () => {
    const S = Umi.state, V = Umi.views.modes;
    if (V.shown() && V.mode() === 'search') { S.layout.sidebarMode = 'tabs'; return; }
    Umi.actions.openSearch();
  },
  sidebarMode: ({ mode }) => {
    const S = Umi.state;
    S.layout.sidebarMode = mode;
    S.layout.sidebar = true;
  },
  // ⌥⌘F: the keys in "Search tabs...".
  searchTabs: () => {
    const S = Umi.state;
    S.layout.sidebarMode = 'tabs';
    S.layout.sidebar = true;
    S.ui.sidebarFocus = 'tabsearch';
  },
  // ⇧⌘>: shows or hides dotfiles in the explorer (shown by default).
  toggleDotfiles: () => { const S = Umi.state; S.layout.hideDotfiles = !S.layout.hideDotfiles; },
  // ⌘O: quick open over the focused pane's project.
  quickOpen: () => {
    const S = Umi.state, M = Umi.model;
    if (S.ui.panel?.name === 'quickOpen') return M.closePanel();
    const folder = M.folderOf(M.activeTab().focused);
    M.openPanel('quickOpen', { root: Umi.views.modes.root(), folder, query: '', sel: 0 });
  },
});
Umi.actions.toggleDotfiles.keepsFocus = true;
