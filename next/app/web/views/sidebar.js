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
      name.textContent = tab.name || base(folder) || 'Terminal';
      line1.append(name);
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
    el.querySelector('.key').textContent = i < 8 ? `⌘${i + 1}` : i === S.layout.tabs.length - 1 ? '⌘9' : '';
    el.addEventListener('mousedown', (e) => {
      if (e.target.closest('.close, input')) return;
      Umi.app.update(() => { S.layout.activeTab = tab.id; });
    });
    el.addEventListener('dblclick', (e) => {
      if (e.target.closest('.close, input')) return;
      Umi.app.update(() => { S.layout.activeTab = tab.id; Umi.actions.renameTab(); });
    });
    el.querySelector('.close').addEventListener('click', () => {
      Umi.app.update(() => M.paneIds(tab.root).forEach((id) => M.removePane(id)));
    });
    return el;
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
    renderReview();
    const list = document.querySelector('#tabs');
    list.textContent = '';
    S.layout.tabs.forEach((tab, i) => list.append(tabRow(tab, i)));
  }

  function focus() {
    const input = document.querySelector('#tabs input.tab-name');
    if (input && document.activeElement !== input) input.focus();
  }

  document.querySelector('#new-tab').addEventListener('click', () => Umi.app.run('newTab'));
  return { render, focus };
})();
