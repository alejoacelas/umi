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
      return el;
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
  const shortPath = (p) => (p && S.home && (p === S.home || p.startsWith(S.home + '/')) ? '~' + p.slice(S.home.length) : p || '');

  // A chip's label: the session's given name, else what its terminal's title says, else its folder.
  function chipLabel(node) {
    if ((node.view || 'terminal') !== 'terminal') return node.view === 'picker' ? 'New session' : node.view;
    const sid = M.sessionOf(node.id), live = sid && S.live[sid];
    const given = sid && (S.layout.meta?.sessions?.[sid]?.name || live?.name);
    return given || shortPath(S.panes[node.id]?.title) || shortPath(M.folderOf(node.id)) || 'Terminal';
  }

  function renderStrip(tab) {
    const strip = document.querySelector('#strip');
    strip.textContent = '';
    const leaves = [];
    const walk = (n) => (n.type === 'pane' ? leaves.push(n) : (walk(n.a), walk(n.b)));
    walk(tab.root);
    for (const node of leaves) {
      const chip = document.createElement('div');
      chip.className = 'chip' + (node.id === tab.focused ? ' focused' : '');
      chip.innerHTML = termIcon + '<span></span>';
      chip.querySelector('span').textContent = chipLabel(node);
      chip.title = chip.querySelector('span').textContent;
      chip.addEventListener('mousedown', () => Umi.app.update(() => M.focusPane(node.id)));
      strip.append(chip);
    }
  }

  // Rects of the strip's chips, which take clicks in the title bar.
  function chromeRects() {
    return [...document.querySelectorAll('#strip .chip')].map((c) => {
      const r = c.getBoundingClientRect();
      return { x: r.left, y: r.top, w: r.width, h: r.height };
    });
  }

  function render() {
    renderStrip(M.activeTab());
    const main = document.querySelector('#panes');
    main.textContent = '';
    const tab = M.activeTab();
    main.classList.toggle('multi', M.paneIds(tab.root).length > 1);
    main.append(renderNode(tab.root));
    main.querySelectorAll('.slot').forEach((s) => s.classList.toggle('focused', s.dataset.pane === tab.focused));
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
