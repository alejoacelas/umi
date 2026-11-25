// The sidebar: Warp's vertical tabs (SPEC S-3). A new tab's name is edited in its row: Enter keeps it, Esc keeps the
// folder name.
'use strict';
Umi.views = Umi.views || {};

Umi.views.sidebar = (() => {
  const S = Umi.state, M = Umi.model;
  const shortPath = (p) => (p && S.home && (p === S.home || p.startsWith(S.home + '/')) ? '~' + p.slice(S.home.length) : p || '');
  const base = (p) => (p ? shortPath(p).split('/').filter(Boolean).pop() || '/' : '');

  // What a tab's row shows: the row is drawn from this alone, so when it is unchanged the row is
  // left as it is (render).
  function rowShows(tab, i) {
    const info = S.panes[tab.focused] || {};
    const sid = M.sessionOf(tab.focused);
    const folder = M.folderOf(tab.focused);
    const listed = M.listedTabs().length;
    return {
      active: tab.id === S.layout.activeTab,
      editing: S.ui.editingTab === tab.id,
      name: tabName(tab), placeholder: base(folder) || 'Tab name',
      pinned: !!tab.pinned, synced: Umi.arrange.isSynced(tab), count: M.paneIds(tab.root).length,
      failed: info.exitCode != null && ![0, 130, 141, -1].includes(info.exitCode),
      line2: shortPath(info.title) || (sid && S.live[sid]?.foreground) || shortPath(folder),
      key: i < 0 ? '' : i < 8 ? `⌘${i + 1}` : i === listed - 1 ? '⌘9' : '',
    };
  }

  function tabRow(tab, i, d = rowShows(tab, i)) {
    const count = d.count;
    const el = document.createElement('div');
    el.className = 'tab' + (d.active ? ' active' : '');
    el.innerHTML = `
      <div class="icon"><svg viewBox="0 0 16 16" width="14" height="14" fill="none" stroke="currentColor" stroke-width="1.1"><rect x="1.5" y="2.5" width="13" height="11" rx="2"/><path d="M4.5 6l2 1.75-2 1.75M8 10h3" stroke-linecap="round" stroke-linejoin="round"/></svg></div>
      <div class="text"><div class="line1"></div><div class="line2"></div></div>
      <div class="key"></div>
      <button class="close" title="Stop showing this tab (its sessions keep running)">×</button>`;
    const line1 = el.querySelector('.line1');
    if (d.editing) {
      const input = document.createElement('input');
      input.className = 'tab-name';
      input.spellcheck = false;
      input.placeholder = d.placeholder;
      input.value = S.ui.tabDraft ?? tab.name ?? '';
      input.addEventListener('input', () => { S.ui.tabDraft = input.value; });
      input.addEventListener('keydown', (e) => {
        if (e.key !== 'Enter' && e.key !== 'Escape') return;
        e.preventDefault();
        Umi.app.update(() => {
          if (e.key === 'Enter' && input.value.trim()) {
            tab.name = input.value.trim();
            // A new tab's one session takes the tab's name too (DESIGN "Names at creation").
            const ids = M.paneIds(tab.root), sid = ids.length === 1 && M.sessionOf(ids[0]);
            if (sid && !S.live[sid]?.agent?.title && !S.layout.meta?.sessions?.[sid]?.name) M.renameFromMenu(sid, tab.name);
          } else delete tab.name;
          S.ui.editingTab = null;
          S.ui.tabDraft = null;
        });
      });
      line1.append(input);
    } else {
      const name = document.createElement('span');
      name.className = 'name';
      name.textContent = d.name;
      line1.append(name);
      if (d.pinned) line1.prepend(mark('pin', '📌', 'Pinned (⌃⌘P)'));
      if (d.synced) line1.append(mark('sync', linkIcon, 'Input synchronized (⌥⌘I)'));
      if (count > 1) {
        const c = document.createElement('span');
        c.className = 'count';
        c.textContent = String(count);
        c.title = `${count} panes`;
        line1.append(c);
      }
    }
    const line2 = el.querySelector('.line2');
    if (d.failed) {
      const f = document.createElement('span');
      f.className = 'failed';
      f.textContent = '▲';
      line2.append(f);
    }
    line2.append(document.createTextNode(d.line2));
    el.querySelector('.key').textContent = d.key;
    el.dataset.tab = tab.id;
    el.dataset.shows = shows(d);
    el.addEventListener('mousedown', (e) => {
      if (e.target.closest('.close, input') || e.button !== 0) return;
      // The row outlives the click (render keeps unchanged rows), so WebKit's own handling of a
      // press on it (selection, drag, autoscroll) is turned off: dragTab handles the mouse.
      e.preventDefault();
      if (document.activeElement && document.activeElement !== document.body) document.activeElement.blur();
      Umi.app.update(() => { S.layout.activeTab = tab.id; S.ui.sidebarFocus = null; });
      if (!tab.archived) dragTab(e, tab);
    });
    el.addEventListener('dblclick', (e) => {
      if (e.target.closest('.close, input')) return;
      Umi.app.update(() => { S.layout.activeTab = tab.id; Umi.actions.renameTab(); });
    });
    // On mousedown, not click: the row may be drawn again before the button comes up. It never
    // reaches the row, so it starts no drag and selects nothing.
    el.querySelector('.close').addEventListener('mousedown', (e) => {
      if (e.button !== 0) return;
      e.preventDefault();
      e.stopPropagation();
      Umi.app.run('closeTab', { tab: tab.id });
    });
    el.addEventListener('contextmenu', (e) => {
      e.preventDefault();
      tabMenu(tab, e.clientX, e.clientY);
    });
    return el;
  }

  // A row's right-click menu (SPEC S-4), as Umi's UmiTabMenu: Warp's items, labels and order,
  // sections between lines, an item that can't apply left out. It acts on the row's tab, selected
  // or not.
  //   Pin tab (Unpin tab), Archive Tab (an archived tab: Unarchive Tab only) | Copy branch, Copy
  //   tab title, Copy working directory, Copy pull request link | Rename tab, Reset tab name,
  //   Rename active pane, Reset active pane name, Move Tab Down, Move Tab Up | Close tab, Close
  //   other tabs, Close Tabs Below
  // Departures (PARITY.md): no tab groups or colours, no Save as New Config (no launch
  // configurations) and no moves to other windows (one window).
  async function tabItems(tab) {
    const A = Umi.arrange, sections = [];
    const item = (title, fn) => ({ title, fn: () => Umi.app.update(fn) });
    const folder = M.folderOf(tab.focused);
    const sid = M.sessionOf(tab.focused);
    if (tab.archived) sections.push([item('Unarchive Tab', () => A.unarchive(tab))]);
    else sections.push([item(tab.pinned ? 'Unpin tab' : 'Pin tab', () => A.togglePin(tab)), item('Archive Tab', () => A.archive(tab))]);

    let git = {};
    if (folder) { try { git = await Umi.bridge.request('gitBranch', { path: folder }); } catch { git = {}; } }
    const copy = (text) => () => Umi.bridge.request('clipboard', { text });
    const copies = [];
    if (git.branch) copies.push({ title: 'Copy branch', fn: copy(git.branch) });
    copies.push({ title: 'Copy tab title', fn: copy(tabName(tab)) });
    if (folder) copies.push({ title: 'Copy working directory', fn: copy(folder) });
    if (git.pr) copies.push({ title: 'Copy pull request link', fn: copy(git.pr) });
    sections.push(copies);

    const modify = [item('Rename tab', () => { S.layout.activeTab = tab.id; S.ui.editingTab = tab.id; S.ui.tabDraft = tab.name || ''; })];
    if (tab.name) modify.push(item('Reset tab name', () => { delete tab.name; }));
    if (sid) {
      modify.push(item('Rename active pane', () => { S.layout.activeTab = tab.id; M.openPanel('palette', { mode: 'rename', sid }); }));
      if (S.layout.meta?.sessions?.[sid]?.name || (S.live[sid]?.agent?.title && S.live[sid].agent.title !== S.live[sid].name)) {
        modify.push(item('Reset active pane name', () => M.renameFromMenu(sid, '')));
      }
    }
    // Within its group: the pinned or the unpinned tabs.
    const group = S.layout.tabs.filter((x) => !x.archived && !!x.pinned === !!tab.pinned);
    const at = group.indexOf(tab);
    if (at >= 0 && at < group.length - 1) modify.push(item('Move Tab Down', () => A.moveTab(tab, 1)));
    if (at > 0) modify.push(item('Move Tab Up', () => A.moveTab(tab, -1)));
    sections.push(modify);

    const close = (t) => Umi.actions.closeTab({ tab: t.id });
    const closes = [item('Close tab', () => close(tab))];
    const list = tab.archived ? Umi.arrange.archived() : group;
    if (list.length > 1) closes.push(item('Close other tabs', () => list.filter((t) => t !== tab).forEach(close)));
    const i = list.indexOf(tab);
    if (i >= 0 && i < list.length - 1) closes.push(item('Close Tabs Below', () => list.slice(i + 1).forEach(close)));
    sections.push(closes);

    const items = [];
    for (const s of sections) {
      if (!s.length) continue;
      if (items.length) items.push({ separator: true });
      items.push(...s);
    }
    return items;
  }

  async function tabMenu(tab, x, y) {
    const items = await tabItems(tab);
    const r = await Umi.bridge.request('menu', { items: items.map(({ title, separator }) => (separator ? { separator } : { title })), x, y });
    if (r && r.index != null) items[r.index].fn();
  }

  const linkIcon = '<svg viewBox="0 0 16 16" width="11" height="11" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round"><path d="M6.5 9.5l3-3"/><path d="M7.5 4.5l1-1a2.5 2.5 0 013.5 3.5l-1 1"/><path d="M8.5 11.5l-1 1A2.5 2.5 0 014 9l1-1"/></svg>';
  function mark(cls, html, title) {
    const m = document.createElement('span');
    m.className = 'mark ' + cls;
    m.innerHTML = html;
    m.title = title;
    return m;
  }

  // Dragging a row moves the tab within its group (pinned or not) where it's dropped (SPEC M-4).
  function dragTab(down, tab) {
    let moved = false, target = null, after = false;
    // The row level with the pointer, from the rows' boxes.
    const rowAt = (y) => [...document.querySelectorAll('#tabs .tab')].find((r) => { const b = r.getBoundingClientRect(); return y >= b.top && y < b.bottom; });
    const move = (e) => {
      if (!moved && Math.abs(e.clientY - down.clientY) < 4) return;
      moved = true;
      document.body.classList.add('dragging-tab');
      document.querySelectorAll('#tabs .tab').forEach((r) => r.classList.remove('drop-before', 'drop-after'));
      const row = rowAt(e.clientY);
      const t = row && S.layout.tabs.find((x) => x.id === row.dataset.tab);
      target = t && t !== tab && !!t.pinned === !!tab.pinned ? t : null;
      if (!target) return;
      const r = row.getBoundingClientRect();
      after = e.clientY > r.top + r.height / 2;
      row.classList.add(after ? 'drop-after' : 'drop-before');
    };
    const up = (e) => {
      // Where the button comes up decides, whatever moves were seen on the way.
      move(e);
      window.removeEventListener('mousemove', move);
      window.removeEventListener('mouseup', up);
      document.body.classList.remove('dragging-tab');
      document.querySelectorAll('#tabs .tab').forEach((r) => r.classList.remove('drop-before', 'drop-after'));
      if (moved && target) Umi.app.update(() => Umi.arrange.placeTab(tab, target, after));
    };
    window.addEventListener('mousemove', move);
    window.addEventListener('mouseup', up);
  }

  // SPEC AR-1: the Archived row at the top while a tab is archived; a click opens it in place.
  function renderArchive(list, archived) {
    if (!archived.length) return;
    const row = document.createElement('div');
    row.className = 'archive-row' + (S.layout.archiveOpen ? ' open' : '');
    row.innerHTML = '<span class="chev">›</span><span></span>';
    row.lastChild.textContent = `Archived · ${archived.length}`;
    row.addEventListener('mousedown', () => Umi.app.update(() => { S.layout.archiveOpen = !S.layout.archiveOpen; }, { focus: false }));
    list.append(row);
    if (!S.layout.archiveOpen) return;
    const box = document.createElement('div');
    box.className = 'archive-box';
    archived.forEach((t) => box.append(tabRow(t, -1)));
    list.append(box);
  }

  // Titles and sessions change many times a second, and a row drawn again under the pointer
  // loses a click, so only rows whose content changed are replaced; the whole list is drawn
  // again only when its rows change (a tab added, moved, archived, filtered out). The row being
  // renamed is never replaced while its name is edited, so its field keeps the caret.
  let shape = null;
  const shows = (d) => JSON.stringify({ ...d, active: undefined });
  function render() {
    document.body.classList.toggle('no-sidebar', S.layout.sidebar === false);
    if (S.layout.sidebarWidth) document.documentElement.style.setProperty('--sidebar-width', S.layout.sidebarWidth + 'px');
    const list = document.querySelector('#tabs');
    const archived = Umi.arrange.archived();
    const open = !!S.layout.archiveOpen;
    // "Search tabs..." lists only the tabs it matches (keeping their ⌘ numbers).
    const listed = M.listedTabs().map((tab, i) => ({ tab, i })).filter((r) => Umi.views.modes.matchesTab(r.tab));
    const rows = [...(open ? archived.map((tab) => ({ tab, i: -1 })) : []), ...listed];
    const now = JSON.stringify([archived.length, open, rows.map((r) => r.tab.id)]);
    if (now === shape) {
      for (const { tab, i } of rows) {
        const old = list.querySelector(`.tab[data-tab="${CSS.escape(tab.id)}"]`);
        if (!old) continue;
        const d = rowShows(tab, i);
        old.classList.toggle('active', d.active);
        if (d.editing && old.querySelector('input.tab-name')) continue;
        if (old.dataset.shows !== shows(d)) old.replaceWith(tabRow(tab, i, d));
      }
    } else {
      // The rows change: a name being edited comes back in the new field where it was.
      const was = list.querySelector('input.tab-name');
      const caret = was && document.activeElement === was ? [was.selectionStart, was.selectionEnd] : null;
      shape = now;
      list.textContent = '';
      renderArchive(list, archived);
      for (const { tab, i } of listed) list.append(tabRow(tab, i));
      const input = caret && list.querySelector('input.tab-name');
      if (input) { input.focus(); input.setSelectionRange(...caret); }
    }
    Umi.views.modes.render();
  }

  function focus() {
    const input = document.querySelector('#tabs input.tab-name');
    if (input && document.activeElement !== input) input.focus();
  }

  document.querySelector('#new-tab').addEventListener('click', () => Umi.app.run('newTab'));

  // S-8: dragging the sidebar's edge sets its width, 180–600 px, kept in the layout.
  const edge = document.createElement('div');
  edge.id = 'sidebar-edge';
  document.querySelector('#sidebar').append(edge);
  edge.addEventListener('mousedown', (down) => {
    down.preventDefault();
    const start = document.querySelector('#sidebar').getBoundingClientRect().width;
    document.body.classList.add('resizing-sidebar');
    const move = (e) => {
      S.layout.sidebarWidth = Math.round(Math.min(600, Math.max(180, start + e.clientX - down.clientX)));
      document.documentElement.style.setProperty('--sidebar-width', S.layout.sidebarWidth + 'px');
      Umi.app.report(false);
    };
    const up = () => {
      window.removeEventListener('mousemove', move);
      window.removeEventListener('mouseup', up);
      document.body.classList.remove('resizing-sidebar');
      Umi.app.update(() => {});
    };
    window.addEventListener('mousemove', move);
    window.addEventListener('mouseup', up);
  });
  const tabName = (tab) => tab.name || S.live[M.sessionOf(tab.focused)]?.agent?.title || base(M.folderOf(tab.focused)) || 'Terminal';

  return { render, focus, tabName, tabItems };
})();
