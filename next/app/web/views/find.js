// Find in a terminal (⌘F; ⌘G / ⇧⌘G next and previous; Esc closes), on Ghostty's own search:
// the page draws the bar at the top right of the pane and asks native to search
// (Umi.bridge.request('termSearch', {pane, needle}) and 'termSearchNav' {pane, dir}); Ghostty
// highlights the matches in the terminal and native reports the count and the selected match
// ({type: 'search', pane, total, selected}). The bar lies over the terminal: native cuts it out
// of the terminal's view (`holes` in the rects message), so the terminal keeps its size.
//
// State: ui.find {pane, needle, total, selected, focus} (not persisted).
'use strict';
Umi.views = Umi.views || {};

Umi.views.find = (() => {
  const S = Umi.state, M = Umi.model;
  let timer = null;

  function bar() {
    let el = document.querySelector('#findbar');
    if (el) return el;
    el = document.createElement('div');
    el.id = 'findbar';
    el.hidden = true;
    el.innerHTML = `<input spellcheck="false" placeholder="Find"><span class="count"></span>
      <button class="prev" title="Previous match (⇧⌘G)">↑</button><button class="next" title="Next match (⌘G)">↓</button>
      <button class="close" title="Close (Esc)">×</button>`;
    const input = el.querySelector('input');
    input.addEventListener('input', () => {
      const f = S.ui.find;
      if (!f) return;
      f.needle = input.value;
      clearTimeout(timer);
      // Ghostty searches on its own thread; a short pause keeps it from restarting on each key.
      timer = setTimeout(() => search(f), 60);
    });
    input.addEventListener('keydown', (e) => {
      if (e.key === 'Escape') { e.preventDefault(); Umi.app.run('findClose'); }
      else if (e.key === 'Enter') { e.preventDefault(); Umi.app.run(e.shiftKey ? 'findPrev' : 'findNext'); }
    });
    el.addEventListener('mousedown', (e) => {
      const f = S.ui.find;
      if (f) {
        f.focus = true;
        if (M.activeTab().focused !== f.pane && M.findPane(f.pane)) Umi.app.update(() => M.focusPane(f.pane), { focus: false });
      }
      if (e.target.closest('button')) e.preventDefault();
    });
    el.querySelector('.prev').addEventListener('click', () => Umi.app.run('findPrev'));
    el.querySelector('.next').addEventListener('click', () => Umi.app.run('findNext'));
    el.querySelector('.close').addEventListener('click', () => Umi.app.run('findClose'));
    document.querySelector('#work').append(el);
    return el;
  }

  function search(f) {
    Umi.bridge.request('termSearch', { pane: f.pane, needle: f.needle }).catch(() => {});
  }

  // Places the bar at the top right of its pane's slot, or hides it.
  function render() {
    const el = bar(), f = S.ui.find;
    const slot = f && document.querySelector(`#panes .slot[data-pane="${f.pane}"][data-view="terminal"]`);
    el.hidden = !slot;
    if (!slot) return;
    const work = document.querySelector('#work').getBoundingClientRect(), r = slot.getBoundingClientRect();
    el.style.top = `${r.top - work.top + 6}px`;
    el.style.right = `${work.right - r.right + 12}px`;
    el.style.maxWidth = `${Math.max(160, r.width - 24)}px`;
    const input = el.querySelector('input');
    if (input.value !== f.needle) input.value = f.needle;
    el.querySelector('.count').textContent = !f.needle ? ''
      : f.total == null ? '…' : f.total === 0 ? 'No matches'
      : `${f.selected != null && f.selected >= 0 ? f.selected + 1 : '?'} of ${f.total}`;
  }

  function focus() {
    const input = bar().querySelector('input');
    if (document.activeElement !== input) { input.focus(); input.select(); }
  }

  // The bar's rect while it shows, in CSS px: native cuts it out of the terminal under it.
  function holeRect() {
    const el = document.querySelector('#findbar');
    if (!el || el.hidden) return null;
    const r = el.getBoundingClientRect();
    return { x: r.left, y: r.top, w: r.width, h: r.height };
  }

  // The bar has the keys only while its pane is the focused one (another tab or pane: the keys go there).
  const wantsKeys = () => !!(S.ui.find && S.ui.find.focus && S.layout && S.ui.find.pane === M.activeTab().focused);

  return { render, focus, holeRect, wantsKeys, search };
})();

Object.assign(Umi.actions, {
  // ⌘F on a terminal: the bar for the focused pane, its field focused (again: select its text).
  find: () => {
    const p = Umi.model.focusedPane();
    if (!p || p.view !== 'terminal') return;
    const f = Umi.state.ui.find;
    if (f && f.pane === p.id) { f.focus = true; return; }
    if (f) Umi.bridge.request('termSearchEnd', { pane: f.pane }).catch(() => {});
    Umi.state.ui.find = { pane: p.id, needle: '', total: null, selected: null, focus: true };
  },
  findNext: () => { const f = Umi.state.ui.find; if (f && f.needle) Umi.bridge.request('termSearchNav', { pane: f.pane, dir: 'next' }).catch(() => {}); },
  findPrev: () => { const f = Umi.state.ui.find; if (f && f.needle) Umi.bridge.request('termSearchNav', { pane: f.pane, dir: 'previous' }).catch(() => {}); },
  findClose: () => {
    const f = Umi.state.ui.find;
    if (!f) return;
    Umi.bridge.request('termSearchEnd', { pane: f.pane }).catch(() => {});
    Umi.state.ui.find = null;
  },
});

Umi.bridge.on('search', (msg) => {
  const f = Umi.state.ui.find;
  if (!f || f.pane !== msg.pane) return;
  if ('total' in msg) f.total = msg.total;
  if ('selected' in msg) f.selected = msg.selected;
  Umi.views.find.render();
});
// Ghostty ended the search itself (e.g. its own binding): the bar closes.
Umi.bridge.on('searchEnded', (msg) => {
  if (Umi.state.ui.find?.pane === msg.pane) Umi.app.update(() => { Umi.state.ui.find = null; }, { focus: false });
});
