// The active tab's split layout. Each pane gets a slot; what fills it depends on the pane's view:
// 'terminal' slots stay empty (a native Ghostty view sits there and their rects go to native);
// other views (later: 'picker') are drawn here by a renderer in `renderers`.
'use strict';
Umi.views = Umi.views || {};

Umi.views.panes = (() => {
  const S = Umi.state, M = Umi.model;

  // view name -> (slot element, pane node) => void. A view without a renderer shows its name.
  const renderers = {
    terminal() {},
    picker: (el, node) => Umi.views.picker.render(el, node),
  };

  function renderNode(node) {
    if (node.type === 'pane') {
      const el = document.createElement('div');
      el.className = 'slot';
      el.dataset.pane = node.id;
      el.dataset.view = node.view || 'terminal';
      const r = renderers[el.dataset.view];
      if (r) r(el, node);
      else el.textContent = el.dataset.view;
      if (el.dataset.view !== 'terminal') {
        el.addEventListener('mousedown', () => Umi.app.update(() => M.focusPane(node.id), { focus: false }));
      }
      // The pane: its header above the slot (the slot alone goes to native, so the terminal sits
      // under the header).
      const pane = document.createElement('div');
      pane.className = 'pane';
      pane.dataset.pane = node.id;
      pane.append(paneHead(node), el);
      return pane;
    }
    const el = document.createElement('div');
    el.className = `split ${node.dir}`;
    const a = document.createElement('div'), b = document.createElement('div');
    a.className = b.className = 'child';
    a.style.flex = `${node.ratio} 1 0`;
    b.style.flex = `${1 - node.ratio} 1 0`;
    a.append(renderNode(node.a));
    b.append(renderNode(node.b));
    const div = document.createElement('div');
    div.className = 'divider';
    div.addEventListener('mousedown', (e) => dragDivider(e, node, el));
    el.append(a, div, b);
    return el;
  }

  const termIcon = '<svg viewBox="0 0 16 16" width="12" height="12" fill="none" stroke="currentColor" stroke-width="1.2"><rect x="1.5" y="2.5" width="13" height="11" rx="2"/><path d="M4.5 6l2 1.75-2 1.75M8 10h3" stroke-linecap="round" stroke-linejoin="round"/></svg>';
  // A file pane's chip shows the file's type icon, the explorer's (icons.js).
  const fileIcon = (path) => `<img class="file-icon" src="${Umi.icons.file(path || '')}" width="12" height="12" alt="" draggable="false">`;
  const shortPath = (p) => (p && S.home && (p === S.home || p.startsWith(S.home + '/')) ? '~' + p.slice(S.home.length) : p || '');

  // A chip's label: the session's given name, else what its terminal's title says, else its folder.
  function chipLabel(node) {
    if (node.view === 'file') return Umi.views.file.label(node);
    if ((node.view || 'terminal') !== 'terminal') return node.view === 'picker' ? 'New session' : node.view;
    const sid = M.sessionOf(node.id), live = sid && S.live[sid];
    const given = sid && (S.layout.meta?.sessions?.[sid]?.name || live?.name);
    return given || shortPath(S.panes[node.id]?.title) || shortPath(M.folderOf(node.id)) || 'Terminal';
  }

  // A hidden session's chip label: its given name, else its folder.
  function hiddenLabel(sid) {
    const live = S.live[sid];
    // Before the daemon's list has it (just started), what its last pane reported.
    const info = Object.values(S.panes).find((p) => p.session === sid) || {};
    return S.layout.meta?.sessions?.[sid]?.name || live?.name || shortPath(live?.folder || info.title || info.pwd) || 'Terminal';
  }

  // Each pane's header: its status mark (marks.js), icon and name. In a tab showing several panes
  // the focused pane's header is lit in the accent: that is how focus shows (Alejo, 2026-11-18).
  // A click focuses the pane.
  function paneHead(node) {
    const head = document.createElement('div');
    head.className = 'pane-head' + (node.view === 'file' && Umi.views.file.isDirty(node.id) ? ' dirty' : '');
    head.dataset.pane = node.id;
    const label = chipLabel(node);
    head.innerHTML = (node.view === 'file' ? fileIcon(node.path) : termIcon) + '<span></span>';
    head.querySelector('span').textContent = label;
    head.title = label;
    head.addEventListener('mousedown', (e) => { e.preventDefault(); Umi.app.update(() => M.focusPane(node.id)); });
    return head;
  }

  // The top bar: a chip per open tab, in the sidebar's order, with the tab's status mark
  // (marks.js); the current tab's filled. Then a chip per session ⌥⌘H hid from the current tab
  // (SPEC H-5), dim and in italics: clicking one shows it again at the right end, focused.
  function renderStrip(tab) {
    const strip = document.querySelector('#strip');
    strip.textContent = '';
    const chip = (label, cls, icon, onDown) => {
      const el = document.createElement('div');
      el.className = 'chip' + cls;
      el.innerHTML = icon + '<span></span>';
      el.querySelector('span').textContent = label;
      el.title = label;
      el.addEventListener('mousedown', onDown);
      strip.append(el);
      return el;
    };
    for (const t of M.listedTabs()) {
      const name = Umi.views.sidebar.tabName(t);
      const el = chip(name, t.id === tab.id ? ' focused' : '', '', () => Umi.app.update(() => { S.layout.activeTab = t.id; S.ui.sidebarFocus = null; }));
      el.dataset.tab = t.id;
    }
    for (const sid of M.hiddenOf(tab)) {
      const el = chip(hiddenLabel(sid), ' hidden', termIcon, () => Umi.app.run('showHidden', { session: sid }));
      el.dataset.session = sid;
      el.title = hiddenLabel(sid) + ' (hidden: click to show it again)';
    }
  }

  // Rects of the strip's chips, which take clicks in the title bar.
  function chromeRects() {
    return [...document.querySelectorAll('#strip .chip')].map((c) => {
      const r = c.getBoundingClientRect();
      return { x: r.left, y: r.top, w: r.width, h: r.height };
    });
  }

  let lastTab = null;
  function render() {
    renderStrip(M.activeTab());
    const main = document.querySelector('#panes');
    main.textContent = '';
    const tab = M.activeTab();
    if (lastTab && lastTab !== tab.id) { main.classList.remove('fade-in'); void main.offsetWidth; main.classList.add('fade-in'); }
    lastTab = tab.id;
    // A zoomed tab shows only its zoomed pane; the others' sessions keep running (native hides
    // terminals that get no slot).
    const zoomed = tab.zoomed && M.panesOf(tab.root).find((p) => p.id === tab.zoomed);
    main.classList.toggle('multi', !zoomed && M.paneIds(tab.root).length > 1);
    main.append(renderNode(zoomed || tab.root));
    main.querySelectorAll('.slot, .pane').forEach((s) => s.classList.toggle('focused', s.dataset.pane === tab.focused));
    Umi.views.file?.sync(); // file views sit over their slots and outlive this redraw
  }

  function dragDivider(e, node, el) {
    e.preventDefault();
    const box = el.getBoundingClientRect();
    const move = (ev) => {
      const r = node.dir === 'row' ? (ev.clientX - box.left) / box.width : (ev.clientY - box.top) / box.height;
      node.ratio = Math.min(0.9, Math.max(0.1, r));
      render();
      Umi.app.report(false);
    };
    const up = () => {
      window.removeEventListener('mousemove', move);
      window.removeEventListener('mouseup', up);
      Umi.app.update(() => {});
    };
    window.addEventListener('mousemove', move);
    window.addEventListener('mouseup', up);
  }

  // Rects of every slot (all views), in CSS px.
  function slotRects() {
    const out = {};
    document.querySelectorAll('#panes .slot').forEach((s) => {
      const r = s.getBoundingClientRect();
      out[s.dataset.pane] = { x: r.left, y: r.top, w: r.width, h: r.height };
    });
    return out;
  }

  // Rects native places terminals in: terminal slots only.
  function terminalRects() {
    const out = {};
    document.querySelectorAll('#panes .slot[data-view="terminal"]').forEach((s) => {
      const r = s.getBoundingClientRect();
      out[s.dataset.pane] = { x: r.left, y: r.top, w: r.width, h: r.height };
    });
    return out;
  }

  // Where clicks over a terminal belong to the web layer: each divider's grab area (its ::before).
  function passThroughRects() {
    return [...document.querySelectorAll('#panes .divider')].map((d) => {
      const r = d.getBoundingClientRect(), row = d.parentElement.classList.contains('row');
      return row ? { x: r.left - 3, y: r.top, w: r.width + 6, h: r.height }
                 : { x: r.left, y: r.top - 3, w: r.width, h: r.height + 6 };
    });
  }

  // Redraws the pickers' lists in place (new session data) without touching their name fields.
  function refreshPickers() {
    document.querySelectorAll('#panes .slot[data-view="picker"]').forEach((el) => {
      const found = M.findPane(el.dataset.pane);
      if (found) Umi.views.picker.refresh(el, found.node);
    });
  }

  return { render, renderStrip, renderers, slotRects, terminalRects, passThroughRects, chromeRects, refreshPickers };
})();
