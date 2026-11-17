// The sidebar: Warp's vertical tabs (SPEC S-3). Later sections (Review) go in #sidebar too.
'use strict';
Umi.views = Umi.views || {};

Umi.views.sidebar = (() => {
  const S = Umi.state, M = Umi.model;
  const shortPath = (p) => (p && S.home && p.startsWith(S.home) ? '~' + p.slice(S.home.length) : p || '');
  const base = (p) => (p ? shortPath(p).split('/').filter(Boolean).pop() || '/' : '');

  function row(tab, i) {
    const info = S.panes[tab.focused] || {};
    const count = M.paneIds(tab.root).length;
    const el = document.createElement('div');
    el.className = 'tab' + (tab.id === S.layout.activeTab ? ' active' : '');
    el.innerHTML = `
      <div class="icon">&gt;_</div>
      <div class="text"><div class="line1"></div><div class="line2"></div></div>
      <div class="key"></div>
      <button class="close" title="Close tab">×</button>`;
    const line1 = el.querySelector('.line1');
    line1.textContent = tab.name || base(M.cwdOf(tab.focused)) || 'Terminal';
    if (count > 1) {
      const c = document.createElement('span');
      c.className = 'count';
      c.textContent = `· ${count}`;
      line1.append(c);
    }
    const line2 = el.querySelector('.line2');
    if (info.exitCode != null && ![0, 130, 141, -1].includes(info.exitCode)) {
      const f = document.createElement('span');
      f.className = 'failed';
      f.textContent = '▲';
      line2.append(f);
    }
    line2.append(document.createTextNode(info.title || shortPath(M.cwdOf(tab.focused))));
    el.querySelector('.key').textContent = i < 8 ? `⌘${i + 1}` : i === S.layout.tabs.length - 1 ? '⌘9' : '';
    el.addEventListener('mousedown', (e) => {
      if (e.target.closest('.close')) return;
      Umi.app.update(() => { S.layout.activeTab = tab.id; });
    });
    el.querySelector('.close').addEventListener('click', () => {
      Umi.app.update(() => M.paneIds(tab.root).forEach((id) => M.closePane(id)));
    });
    return el;
  }

  function render() {
    document.body.classList.toggle('no-sidebar', S.layout.sidebar === false);
    const list = document.querySelector('#tabs');
    list.textContent = '';
    S.layout.tabs.forEach((tab, i) => list.append(row(tab, i)));
  }

  document.querySelector('#new-tab').addEventListener('click', () => Umi.app.run('newTab'));
  return { render };
})();
