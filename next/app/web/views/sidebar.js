// The sidebar: Review (what waits for Alejo, by project, the current project first) above Warp's
// vertical tabs (SPEC S-3). A new tab's name is edited in its row: Enter keeps it, Esc keeps the
// folder name.
'use strict';
Umi.views = Umi.views || {};

Umi.views.sidebar = (() => {
  const S = Umi.state, M = Umi.model;
  const shortPath = (p) => (p && S.home && p.startsWith(S.home) ? '~' + p.slice(S.home.length) : p || '');
  const base = (p) => (p ? shortPath(p).split('/').filter(Boolean).pop() || '/' : '');

  function tabRow(tab, i) {
    const info = S.panes[tab.focused] || {};
    const count = M.paneIds(tab.root).length;
    const el = document.createElement('div');
    el.className = 'tab' + (tab.id === S.layout.activeTab ? ' active' : '');
    el.innerHTML = `
      <div class="icon"><svg viewBox="0 0 16 16" width="14" height="14" fill="none" stroke="currentColor" stroke-width="1.1"><rect x="1.5" y="2.5" width="13" height="11" rx="2"/><path d="M4.5 6l2 1.75-2 1.75M8 10h3" stroke-linecap="round" stroke-linejoin="round"/></svg></div>
      <div class="text"><div class="line1"></div><div class="line2"></div></div>
      <div class="key"></div>
      <button class="close" title="Stop showing this tab (its sessions keep running)">×</button>`;
    const line1 = el.querySelector('.line1');
    const folder = M.folderOf(tab.focused);
    if (S.ui.editingTab === tab.id) {
      const input = document.createElement('input');
      input.className = 'tab-name';
      input.spellcheck = false;
      input.placeholder = base(folder) || 'Tab name';
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
            if (sid && !S.layout.meta?.sessions?.[sid]?.name) M.rename(sid, tab.name);
          } else delete tab.name;
          S.ui.editingTab = null;
          S.ui.tabDraft = null;
        });
      });
      line1.append(input);
    } else {
      const name = document.createElement('span');
      name.className = 'name';
      name.textContent = tabName(tab);
      line1.append(name);
      if (tab.pinned) line1.prepend(mark('pin', '📌', 'Pinned (⌃⌘P)'));
      if (Umi.arrange.isSynced(tab)) line1.append(mark('sync', linkIcon, 'Input synchronized (⌥⌘I)'));
      if (count > 1) {
        const c = document.createElement('span');
        c.className = 'count';
        c.textContent = String(count);
        c.title = `${count} panes`;
        line1.append(c);
      }
    }
    const line2 = el.querySelector('.line2');
    if (info.exitCode != null && ![0, 130, 141, -1].includes(info.exitCode)) {
      const f = document.createElement('span');
      f.className = 'failed';
      f.textContent = '▲';
      line2.append(f);
    }
    const sid = M.sessionOf(tab.focused);
    line2.append(document.createTextNode(shortPath(info.title) || (sid && S.live[sid]?.foreground) || shortPath(folder)));
    const listed = M.listedTabs().length;
    el.querySelector('.key').textContent = i < 0 ? '' : i < 8 ? `⌘${i + 1}` : i === listed - 1 ? '⌘9' : '';
    el.dataset.tab = tab.id;
    el.addEventListener('mousedown', (e) => {
      if (e.target.closest('.close, input') || e.button !== 0) return;
      Umi.app.update(() => { S.layout.activeTab = tab.id; S.ui.sidebarFocus = null; });
      if (!tab.archived) dragTab(e, tab);
    });
    el.addEventListener('dblclick', (e) => {
      if (e.target.closest('.close, input')) return;
      Umi.app.update(() => { S.layout.activeTab = tab.id; Umi.actions.renameTab(); });
    });
    el.querySelector('.close').addEventListener('click', () => {
      Umi.app.run('closeTab', { tab: tab.id });
    });
    return el;
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
    const move = (e) => {
      if (!moved && Math.abs(e.clientY - down.clientY) < 4) return;
      moved = true;
      document.body.classList.add('dragging-tab');
      document.querySelectorAll('#tabs .tab').forEach((r) => r.classList.remove('drop-before', 'drop-after'));
      const row = document.elementFromPoint(e.clientX, e.clientY)?.closest('#tabs .tab');
      const t = row && S.layout.tabs.find((x) => x.id === row.dataset.tab);
      target = t && t !== tab && !!t.pinned === !!tab.pinned ? t : null;
      if (!target) return;
      const r = row.getBoundingClientRect();
      after = e.clientY > r.top + r.height / 2;
      row.classList.add(after ? 'drop-after' : 'drop-before');
    };
    const up = () => {
      window.removeEventListener('mousemove', move);
      window.removeEventListener('mouseup', up);
      document.body.classList.remove('dragging-tab');
      if (moved && target) Umi.app.update(() => Umi.arrange.placeTab(tab, target, after));
      else if (moved) render();
    };
    window.addEventListener('mousemove', move);
    window.addEventListener('mouseup', up);
  }

  // SPEC AR-1: the Archived row at the top while a tab is archived; a click opens it in place.
  function renderArchive(list) {
    const archived = Umi.arrange.archived();
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

  function renderReview() {
    const box = document.querySelector('#review');
    box.textContent = '';
    const groups = M.review();
    box.hidden = !groups.length;
    if (!groups.length) return;
    const h = document.createElement('div');
    h.className = 'section-head';
    h.textContent = 'Review';
    box.append(h);
    for (const g of groups) {
      const gh = document.createElement('div');
      gh.className = 'review-project' + (g.current ? ' current' : '');
      gh.textContent = base(g.project);
      box.append(gh);
      for (const s of g.items) {
        const row = document.createElement('div');
        row.className = 'review-row';
        row.innerHTML = '<span class="dot"></span><span class="name"></span><span class="what"></span>';
        row.querySelector('.dot').classList.toggle('badge', s.badge && g.current);
        row.querySelector('.name').textContent = M.sessionName(s.id);
        const st = Umi.status.parseStatus(s.agent?.reply);
        row.querySelector('.what').textContent = s.docketFailed ? 'docket hook failed'
          : s.badge ? 'snooze over'
          : s.agent?.event === 'PermissionRequest' ? 'needs permission'
          : s.agent?.event === 'Notification' ? 'asks you'
          : s.agent?.event === 'Interrupt' ? 'interrupted'
          : st && st.kind === 'waiting' ? 'waiting on you' : st && st.kind === 'progress' ? 'stopped in progress'
          : st ? (Umi.status.isDone(st) ? 'done' : st.detail) : 'no status line';
        row.title = s.docketFailed ? (s.docket.error || '') : st ? `Status: ${st.kind}${st.detail ? ': ' + st.detail : ''}` : '';
        row.addEventListener('mousedown', () => Umi.app.update(() => M.showSession(s.id)));
        box.append(row);
      }
    }
  }

  function render() {
    document.body.classList.toggle('no-sidebar', S.layout.sidebar === false);
    if (S.layout.sidebarWidth) document.documentElement.style.setProperty('--sidebar-width', S.layout.sidebarWidth + 'px');
    renderReview();
    const list = document.querySelector('#tabs');
    list.textContent = '';
    renderArchive(list);
    // "Search tabs..." lists only the tabs it matches (keeping their ⌘ numbers).
    M.listedTabs().forEach((tab, i) => { if (Umi.views.modes.matchesTab(tab)) list.append(tabRow(tab, i)); });
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
  // A tab's name as its row shows it: the given name, else its focused pane's folder.
  const tabName = (tab) => tab.name || base(M.folderOf(tab.focused)) || 'Terminal';

  return { render, focus, tabName };
})();
